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

/// One SSH connection: exec channels for probing, plus at most one
/// interactive PTY shell. Built on Citadel (SwiftNIO SSH).
actor SSHConnection {
    private let host: Host
    private let secrets: HostSecrets

    private var client: SSHClient?
    private var stdinWriter: TTYStdinWriter?
    private var shellTask: Task<Void, Never>?

    init(host: Host, secrets: HostSecrets) {
        self.host = host
        self.secrets = secrets
    }

    // MARK: Lifecycle

    func connect() async throws {
        guard client == nil else { return }
        let method = try authenticationMethod()
        do {
            client = try await SSHClient.connect(
                host: host.hostname,
                port: host.port,
                authenticationMethod: method,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        } catch let error as SSHConnectionError {
            throw error
        } catch {
            throw SSHConnectionError.connectFailed(shortDescription(of: error))
        }
    }

    func close() async {
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
