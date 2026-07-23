import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// A passphrase entered from the connection-time prompt. Every connection to
/// the same host can reuse it for the life of this process, while persistence
/// remains an explicit user choice. The revision lets a failed background
/// probe tell whether a *new* answer arrived before it retries.
enum SSHKeyPassphraseSession {
    enum Override: Equatable {
        case none
        case value(String)
        case cleared
    }

    struct Snapshot: Equatable {
        var value: Override
        var revision: UInt64
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var overrides: [UUID: Override] = [:]
        var revisions: [UUID: UInt64] = [:]
    }

    private static let storage = Storage()

    static func snapshot(for hostID: UUID) -> Snapshot {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return Snapshot(
            value: storage.overrides[hostID] ?? .none,
            revision: storage.revisions[hostID] ?? 0
        )
    }

    /// Keep the answer in memory for this run and, when requested, mirror it
    /// to the same synchronizable Keychain family as the host's other secret.
    static func accept(_ passphrase: String, for hostID: UUID, saveToICloud: Bool) {
        storage.lock.lock()
        storage.overrides[hostID] = .value(passphrase)
        storage.revisions[hostID, default: 0] &+= 1
        storage.lock.unlock()

        if saveToICloud {
            KeychainStore.set(passphrase, for: hostID, kind: .keyPassphrase)
        }
    }

    /// An empty field in Host Settings is a real deletion, not "leave the old
    /// passphrase alone." Retain a process-local tombstone so a cached secret
    /// cannot resurrect the deleted value for the next minute.
    static func clear(for hostID: UUID) {
        storage.lock.lock()
        storage.overrides[hostID] = .cleared
        storage.revisions[hostID, default: 0] &+= 1
        storage.lock.unlock()
        KeychainStore.delete(for: hostID, kind: .keyPassphrase)
    }

    static func forget(for hostID: UUID) {
        storage.lock.lock()
        storage.overrides[hostID] = nil
        storage.revisions[hostID] = nil
        storage.lock.unlock()
    }
}

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
        ).applyingSessionPassphrase(for: host.id)
    }

    /// Synchronizable Keychain reads may consult securityd/iCloud state and
    /// occasionally take long enough to miss frames. Connection setup is
    /// already asynchronous, so keep that blocking work off the UI actor.
    static func loadOffMain(for host: Host) async -> HostSecrets {
        await Task.detached(priority: .userInitiated) {
            load(for: host)
        }.value
    }

    func applyingSessionPassphrase(for hostID: UUID) -> HostSecrets {
        var resolved = self
        switch SSHKeyPassphraseSession.snapshot(for: hostID).value {
        case .none:
            break
        case .value(let passphrase):
            resolved.passphrase = passphrase
        case .cleared:
            resolved.passphrase = nil
        }
        return resolved
    }
}

struct SSHKeyPassphraseChallenge: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case required
        case incorrect
    }

    let id: UUID
    let hostID: UUID
    let hostName: String
    let reason: Reason
    /// Runtime-passphrase revision that just failed. A later revision means
    /// another window supplied a new answer and this connection may resume.
    let attemptedRevision: UInt64

    init(host: Host, reason: Reason) {
        id = UUID()
        hostID = host.id
        hostName = host.name
        self.reason = reason
        attemptedRevision = SSHKeyPassphraseSession.snapshot(for: host.id).revision
    }

    func reissued() -> SSHKeyPassphraseChallenge {
        SSHKeyPassphraseChallenge(
            id: UUID(),
            hostID: hostID,
            hostName: hostName,
            reason: reason,
            attemptedRevision: attemptedRevision
        )
    }

    private init(
        id: UUID,
        hostID: UUID,
        hostName: String,
        reason: Reason,
        attemptedRevision: UInt64
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.reason = reason
        self.attemptedRevision = attemptedRevision
    }
}

enum SSHConnectionError: Error {
    case missingCredentials
    case keyPassphraseRequired
    case incorrectKeyPassphrase
    case unsupportedKey
    case tailscaleUnavailable
    case connectFailed(String)
    case notConnected

    var keyPassphraseReason: SSHKeyPassphraseChallenge.Reason? {
        switch self {
        case .keyPassphraseRequired: .required
        case .incorrectKeyPassphrase: .incorrect
        case .missingCredentials, .unsupportedKey, .tailscaleUnavailable,
             .connectFailed, .notConnected:
            nil
        }
    }

    func userMessage(host: Host) -> String {
        switch self {
        case .missingCredentials:
            "No saved credentials for \(host.name). Edit the host and sign in again."
        case .keyPassphraseRequired:
            "The private key for \(host.name) is encrypted. Enter its passphrase to connect."
        case .incorrectKeyPassphrase:
            "The passphrase didn't unlock the private key for \(host.name). Try again."
        case .unsupportedKey:
            "The private key for \(host.name) couldn't be read. Paste an OpenSSH ed25519 or RSA key."
        case .tailscaleUnavailable:
            "Tailscale connections aren't available on this device (Vision Pro)."
        case .connectFailed(let detail):
            "Couldn't reach \(host.name) (\(detail))."
        case .notConnected:
            "Not connected to \(host.name)."
        }
    }
}

/// Reads only the clear-text envelope of an OpenSSH private key. The cipher
/// name precedes the encrypted body, so this can distinguish "needs a
/// passphrase" from a malformed/unsupported key without guessing from
/// Citadel's internal parser errors.
enum OpenSSHPrivateKeyEnvelope {
    enum Encryption: Equatable {
        case unencrypted
        case encrypted
    }

    static func encryption(in keyText: String) -> Encryption? {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(begin), trimmed.hasSuffix(end) else { return nil }

        let payloadStart = trimmed.index(trimmed.startIndex, offsetBy: begin.count)
        let payloadEnd = trimmed.index(trimmed.endIndex, offsetBy: -end.count)
        let payload = trimmed[payloadStart..<payloadEnd]
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(payload)) else { return nil }

        let bytes = [UInt8](data)
        let magic = Array("openssh-key-v1\0".utf8)
        guard bytes.starts(with: magic) else { return nil }
        var offset = magic.count
        guard let cipher = readSSHString(bytes, offset: &offset) else { return nil }
        return cipher == "none" ? .unencrypted : .encrypted
    }

    private static func readSSHString(_ bytes: [UInt8], offset: inout Int) -> String? {
        guard offset + 4 <= bytes.count else { return nil }
        let length = Int(bytes[offset]) << 24
            | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8
            | Int(bytes[offset + 3])
        offset += 4
        guard length >= 0, offset + length <= bytes.count else { return nil }
        defer { offset += length }
        return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
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
            #if !canImport(CLibTailscale)
            if host.useTailscale {
                throw SSHConnectionError.tailscaleUnavailable
            }
            #endif
            let method = try Self.makeAuthenticationMethod(host: host, secrets: secrets)
            connectGeneration &+= 1
            generation = connectGeneration
            task = Task {
                if host.useTailscale {
                    #if canImport(CLibTailscale)
                    let descriptor = try await TailscaleTunnel.shared.dial(
                        hostname: host.hostname,
                        port: host.port
                    )
                    // Citadel's channel-injection overload asserts
                    // inEventLoop in its synchronous prefix, so the dialed
                    // fd is spliced through a one-shot localhost relay and
                    // Citadel dials it via its ordinary bootstrap. The
                    // relay tears itself down when either side closes, so
                    // the client's own close() is its lifetime owner.
                    let relay = TailscaleLoopbackRelay()
                    let relayPort = try relay.start(spliceTo: descriptor)
                    do {
                        return try await SSHClient.connect(
                            host: "127.0.0.1",
                            port: Int(relayPort),
                            authenticationMethod: method,
                            hostKeyValidator: .acceptAnything(),
                            reconnect: .never
                        )
                    } catch {
                        relay.close()
                        throw error
                    }
                    #else
                    throw SSHConnectionError.tailscaleUnavailable
                    #endif
                }

                return try await SSHClient.connect(
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

    static func makeAuthenticationMethod(
        host: Host,
        secrets: HostSecrets
    ) throws -> SSHAuthenticationMethod {
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
            let encryption = OpenSSHPrivateKeyEnvelope.encryption(in: keyText)
            if encryption == .encrypted, decryptionKey == nil {
                throw SSHConnectionError.keyPassphraseRequired
            }

            // The public-key portion of an OpenSSH envelope is never
            // encrypted. Detect it first so an encrypted RSA key does not pay
            // the bcrypt KDF twice (once through the ed25519 parser and again
            // through RSA), and vice versa.
            let keyType = try? SSHKeyDetection.detectPrivateKeyType(from: keyText)
            if keyType == .ed25519,
               let key = try? Curve25519.Signing.PrivateKey(
                   sshEd25519: keyText,
                   decryptionKey: decryptionKey
               ) {
                return .ed25519(username: host.username, privateKey: key)
            }
            if keyType == .rsa,
               let key = try? Insecure.RSA.PrivateKey(
                   sshRsa: keyText,
                   decryptionKey: decryptionKey
               ) {
                return .rsa(username: host.username, privateKey: key)
            }
            if let keyType, keyType != .ed25519, keyType != .rsa {
                throw SSHConnectionError.unsupportedKey
            }

            // Retain the former try-both fallback if type detection itself
            // cannot understand a key Citadel's concrete parser still can.
            if keyType == nil {
                if let key = try? Curve25519.Signing.PrivateKey(
                    sshEd25519: keyText,
                    decryptionKey: decryptionKey
                ) {
                    return .ed25519(username: host.username, privateKey: key)
                }
                if let key = try? Insecure.RSA.PrivateKey(
                    sshRsa: keyText,
                    decryptionKey: decryptionKey
                ) {
                    return .rsa(username: host.username, privateKey: key)
                }
            }
            if encryption == .encrypted {
                throw SSHConnectionError.incorrectKeyPassphrase
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
                            // ShellHandoff prefixes a sacrificial no-op line so an
                            // rc-time stdin reader (oh-my-zsh's update prompt) eats
                            // that instead of the command.
                            try await outbound.write(ByteBuffer(string: ShellHandoff.payload(for: command)))
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
