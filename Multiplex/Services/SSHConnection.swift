import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// Secrets for one host, loaded from the Keychain at connect time.
struct HostSecrets: Sendable {
    var password: String?
    var privateKey: String?
    var passphrase: String?

    static func load(for host: Host) -> HostSecrets {
        HostSecrets(
            password: KeychainStore.get(for: host.id, kind: .password),
            privateKey: KeychainStore.get(for: host.id, kind: .privateKey),
            passphrase: KeychainStore.get(for: host.id, kind: .keyPassphrase)
        )
    }

    /// Synchronizable Keychain reads may consult securityd/iCloud state and
    /// occasionally take long enough to miss frames. Connection setup is
    /// already asynchronous, so keep that blocking work off the UI actor.
    static func loadOffMain(for host: Host) async -> HostSecrets {
        await Task.detached(priority: .userInitiated) {
            load(for: host)
        }.value
    }
}

enum SSHConnectionError: Error {
    case missingCredentials
    case unsupportedKey
    case connectFailed(String)
    case notConnected

    func userMessage(host: Host) -> String {
        switch self {
        case .missingCredentials:
            "No saved credentials for \(host.name). Edit the host and sign in again."
        case .unsupportedKey:
            "The private key for \(host.name) couldn't be read. Paste an OpenSSH ed25519 or RSA key."
        case .connectFailed(let detail):
            "Couldn't reach \(host.name) (\(detail))."
        case .notConnected:
            "Not connected to \(host.name)."
        }
    }
}

struct SSHUpload {
    var data: Data
    var preferredName: String
}

/// One SSH connection: exec channels for probing, plus at most one
/// interactive PTY shell. Built on Citadel (SwiftNIO SSH).
actor SSHConnection {
    private let host: Host
    private let secrets: HostSecrets

    private var client: SSHClient?
    /// Actor methods are reentrant at awaits. Join concurrent callers to one
    /// handshake instead of opening duplicate TCP/SSH transports when a user
    /// action lands during a background connection attempt.
    private var connectTask: Task<SSHClient, Error>?
    private var connectGeneration = 0
    private var stdinWriter: TTYStdinWriter?
    private var shellTask: Task<Void, Never>?
    /// Set by `close()`. A connect that was abandoned on a deadline can
    /// resolve *after* close ran — this makes that late client shut itself
    /// down instead of leaking an open connection.
    private var isClosed = false

    init(host: Host, secrets: HostSecrets) {
        self.host = host
        self.secrets = secrets
    }

    // MARK: Lifecycle

    func connect() async throws {
        guard client == nil else { return }
        guard !isClosed else { throw SSHConnectionError.notConnected }
        let task: Task<SSHClient, Error>
        let generation: Int
        if let inFlight = connectTask {
            task = inFlight
            generation = connectGeneration
        } else {
            let method = try authenticationMethod()
            connectGeneration &+= 1
            generation = connectGeneration
            task = Task {
                try await SSHClient.connect(
                    host: host.hostname,
                    port: host.port,
                    authenticationMethod: method,
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
            }
            connectTask = task
        }
        do {
            let connected = try await task.value
            guard generation == connectGeneration, !isClosed else {
                try? await connected.close()
                throw SSHConnectionError.notConnected
            }
            client = connected
            connectTask = nil
        } catch let error as SSHConnectionError {
            if generation == connectGeneration { connectTask = nil }
            throw error
        } catch {
            if generation == connectGeneration { connectTask = nil }
            throw SSHConnectionError.connectFailed(shortDescription(of: error))
        }
    }

    func close() async {
        isClosed = true
        connectGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        shellTask?.cancel()
        shellTask = nil
        stdinWriter = nil
        if let client {
            try? await client.close()
        }
        client = nil
    }

    // MARK: Auth

    private func authenticationMethod() throws -> SSHAuthenticationMethod {
        switch host.authMethod {
        case .password:
            guard let password = secrets.password, !password.isEmpty else {
                throw SSHConnectionError.missingCredentials
            }
            return .passwordBased(username: host.username, password: password)

        case .privateKey:
            guard let keyText = secrets.privateKey,
                  keyText.contains("PRIVATE KEY")
            else {
                throw SSHConnectionError.missingCredentials
            }
            var decryptionKey: Data?
            if let passphrase = secrets.passphrase, !passphrase.isEmpty {
                decryptionKey = Data(passphrase.utf8)
            }
            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: decryptionKey) {
                return .ed25519(username: host.username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryptionKey) {
                return .rsa(username: host.username, privateKey: key)
            }
            throw SSHConnectionError.unsupportedKey
        }
    }

    // MARK: Exec (tmux probing)

    func exec(_ command: String) async throws -> String {
        guard let client else { throw SSHConnectionError.notConnected }
        let buffer = try await client.executeCommand(command)
        return String(decoding: buffer.readableBytesView, as: UTF8.self)
    }

    // MARK: SFTP (file drops)

    /// Upload dropped files into `directory`, resolving name collisions
    /// atomically (`.forceCreate` = O_EXCL, so two clients can't clobber
    /// each other) and reporting per-file progress. The batch shares one
    /// SFTP subsystem/channel instead of negotiating one per attachment.
    /// Returns the file names actually used in request order.
    func uploadFiles(
        _ uploads: [SSHUpload],
        toDirectory directory: String,
        prepareGitIgnoredDirectory: Bool = false,
        onProgress: @escaping @Sendable (_ index: Int, _ fraction: Double) -> Void
    ) async throws -> [String] {
        guard let client else { throw SSHConnectionError.notConnected }
        return try await client.withSFTP { sftp in
            if prepareGitIgnoredDirectory {
                // Best-effort, idempotent: the folder and its self-ignoring
                // .gitignore may already exist; never overwrite either
                // (forceCreate = O_EXCL keeps a user-customized one intact).
                try? await sftp.createDirectory(atPath: directory)
                if let gitignore = try? await sftp.openFile(
                    filePath: directory + "/.gitignore",
                    flags: [.write, .create, .forceCreate]
                ) {
                    try? await gitignore.write(ByteBuffer(string: "*\n"), at: 0)
                    try? await gitignore.close()
                }
            }
            var names: [String] = []
            names.reserveCapacity(uploads.count)
            for (index, upload) in uploads.enumerated() {
                var file: SFTPFile?
                var name = upload.preferredName
                for attempt in 0..<8 {
                    let candidate = DropText.candidate(upload.preferredName, attempt: attempt)
                    let path = directory.hasSuffix("/")
                        ? directory + candidate
                        : directory + "/" + candidate
                    do {
                        file = try await sftp.openFile(
                            filePath: path,
                            flags: [.write, .create, .forceCreate]
                        )
                        name = candidate
                        break
                    } catch {
                        // Usually "already exists" (O_EXCL); a persistent
                        // error (permissions, bad dir) surfaces on last try.
                        if attempt == 7 { throw error }
                    }
                }
                guard let file else {
                    throw DropError(message: "Couldn't create \(upload.preferredName)")
                }
                do {
                    let chunkSize = 512 * 1024
                    var offset = 0
                    while offset < upload.data.count {
                        let end = min(offset + chunkSize, upload.data.count)
                        try await file.write(
                            ByteBuffer(bytes: upload.data[offset..<end]),
                            at: UInt64(offset)
                        )
                        offset = end
                        onProgress(index, Double(offset) / Double(upload.data.count))
                    }
                    if upload.data.isEmpty { onProgress(index, 1) }
                    try await file.close()
                    names.append(name)
                } catch {
                    try? await file.close()
                    throw error
                }
            }
            return names
        }
    }

    /// The account's home directory ($HOME is where the SFTP session
    /// starts) — the drop destination when a pane cwd can't be resolved.
    func remoteHomeDirectory() async throws -> String {
        guard let client else { throw SSHConnectionError.notConnected }
        return try await client.withSFTP { sftp in
            try await sftp.getRealPath(atPath: ".")
        }
    }

    // MARK: Interactive PTY shell

    /// Opens a PTY'd login shell. When `command` is set (tmux attach/create),
    /// it is injected as the first stdin line with terminal echo disabled, so
    /// the handoff into tmux is silent. Returns once the PTY is live.
    func openShell(
        command: String?,
        cols: Int,
        rows: Int,
        onData: @Sendable @escaping (Data) -> Void,
        onClose: @Sendable @escaping (String?) -> Void
    ) async throws {
        guard let client else { throw SSHConnectionError.notConnected }
        guard shellTask == nil else { return }

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: command == nil
                ? SSHTerminalModes([:])
                : SSHTerminalModes([.ECHO: 0])
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OneShotGate(continuation)
            shellTask = Task {
                do {
                    try await client.withPTY(request) { inbound, outbound in
                        await self.storeWriter(outbound)
                        if let command {
                            try await outbound.write(ByteBuffer(string: command + "\n"))
                        }
                        gate.open()
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buffer), .stderr(let buffer):
                                onData(Data(buffer.readableBytesView))
                            }
                        }
                    }
                    onClose(nil)
                } catch {
                    let detail = self.shortDescription(of: error)
                    if !gate.fail(SSHConnectionError.connectFailed(detail)) {
                        onClose(detail)
                    }
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        guard let stdinWriter else { throw SSHConnectionError.notConnected }
        try await stdinWriter.write(ByteBuffer(bytes: data))
    }

    func resize(cols: Int, rows: Int) async throws {
        guard let stdinWriter else { return }
        try await stdinWriter.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    private func storeWriter(_ writer: TTYStdinWriter) {
        stdinWriter = writer
    }

    private nonisolated func shortDescription(of error: Error) -> String {
        let text = String(describing: error)
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}

/// Resumes a continuation exactly once, from whichever side gets there first
/// (the PTY going live vs. the channel failing during setup).
private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    /// PTY is live — resume the waiter. No-op if already resolved.
    func open() {
        take()?.resume()
    }

    /// Setup failed — throw to the waiter. Returns false if the gate had
    /// already opened (the failure happened after the shell was live).
    func fail(_ error: Error) -> Bool {
        guard let continuation = take() else { return false }
        continuation.resume(throwing: error)
        return true
    }
}
