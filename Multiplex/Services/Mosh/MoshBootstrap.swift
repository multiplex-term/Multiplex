import Foundation

enum MoshBootstrapError: Error {
    case dnsFailure
    case sshFailed(String)
    case serverFailed(String)

    func userMessage(host: Host) -> String {
        switch self {
        case .dnsFailure:
            String(localized: "Couldn't resolve \(host.hostname).")
        case .sshFailed(let detail):
            String(localized: "Couldn't reach \(host.name) to start mosh (\(detail)).")
        case .serverFailed(let detail):
            String(localized: "mosh-server didn't start on \(host.name): \(detail)")
        }
    }
}

/// Launches `mosh-server` over a short-lived SSH connection and returns
/// where (and with what key) to aim the UDP session. The hostname is
/// resolved here and the SSH bootstrap pinned to the literal address, so
/// SSH and UDP always land on the same machine even behind multi-record
/// DNS. Command building and output parsing are pure and unit-tested.
enum MoshBootstrap {
    struct Target: Equatable, Sendable {
        var ip: String
        var port: UInt16
        var key: MoshKey
        var isIPv6: Bool

        /// Datagram payload budget: mosh's conservative 1280-byte path MTU
        /// minus IP/UDP headers, minus the packet layer's 28 bytes.
        var datagramBudget: Int { (isIPv6 ? 1216 : 1252) - 28 }
    }

    /// Left mosh-server's default idle shutdown disabled would strand a
    /// server (holding a tmux attach client) whenever the app dies without
    /// the shutdown handshake; an hour bounds the damage while letting a
    /// suspended headset resume within it.
    static let networkTimeoutSeconds = 3600

    // MARK: - Command construction (pure)

    /// One remote line: PATH widened like the tmux probe, then mosh-server
    /// with 256 colors, bound to the SSH connection's address (`-s`), a
    /// UTF-8 locale, optional port range, and the wrapped command.
    /// stderr folds into stdout so failures travel back to the parser.
    static func command(
        serverPath: String?,
        ports: String?,
        locale: String,
        remoteCommand: String?,
        bindToSSHAddress: Bool = true
    ) -> String {
        var parts: [String] = []
        let server = serverPath?.isEmpty == false ? serverPath!.shellQuoted : "mosh-server"
        parts.append("MOSH_SERVER_NETWORK_TMOUT=\(networkTimeoutSeconds) \(server) new -c 256")
        if bindToSSHAddress { parts.append("-s") }
        parts.append("-l LANG=\(locale)")
        if let ports, !ports.isEmpty {
            parts.append("-p \(ports.shellQuoted)")
        }
        if let remoteCommand {
            parts.append("-- \(remoteCommand)")
        }
        return TmuxProbe.pathPrefix + parts.joined(separator: " ") + " 2>&1"
    }

    // MARK: - Output parsing (pure)

    /// Scan for mosh.pl's line: `MOSH CONNECT <port> <22-char base64 key>`.
    static func parseConnect(_ output: String) -> (port: UInt16, key: MoshKey)? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, fields[0] == "MOSH", fields[1] == "CONNECT",
                  let port = UInt16(fields[2]), port > 0,
                  let key = MoshKey(base64: String(fields[3]))
            else { continue }
            return (port, key)
        }
        return nil
    }

    static func mentionsLocaleFailure(_ output: String) -> Bool {
        output.contains("UTF-8 native locale")
    }

    static func mentionsSSHConnectionFailure(_ output: String) -> Bool {
        output.contains("SSH_CONNECTION")
    }

    /// A short, single-line tail of server output for error surfaces.
    static func failureDetail(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[mosh-server") }
        let tail = lines.suffix(2).joined(separator: " · ")
        let clipped = tail.count > 160 ? String(tail.prefix(160)) + "…" : tail
        return clipped.isEmpty ? String(localized: "no output") : clipped
    }

    // MARK: - Resolution

    /// Numeric addresses for a hostname, IPv4 first (mosh's default
    /// family preference). A literal address resolves to itself.
    static func resolve(_ hostname: String) -> [(ip: String, isIPv6: Bool)] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var v4: [(String, Bool)] = []
        var v6: [(String, Bool)] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let info = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr, info.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            ) == 0 {
                let ip = String(cString: buffer)
                if info.pointee.ai_family == AF_INET6 {
                    if !v6.contains(where: { $0.0 == ip }) { v6.append((ip, true)) }
                } else if info.pointee.ai_family == AF_INET {
                    if !v4.contains(where: { $0.0 == ip }) { v4.append((ip, false)) }
                }
            }
            node = info.pointee.ai_next
        }
        return v4 + v6
    }

    // MARK: - The bootstrap itself

    static func start(host: Host, secrets: HostSecrets, remoteCommand: String?) async throws -> Target {
        let addresses = resolve(host.hostname)
        guard !addresses.isEmpty else { throw MoshBootstrapError.dnsFailure }

        var lastError = MoshBootstrapError.dnsFailure
        for address in addresses {
            var pinned = host
            pinned.hostname = address.ip
            let ssh = SSHConnection(host: pinned, secrets: secrets)
            do {
                try await ssh.connect()
            } catch {
                // Every resolved address uses the same private key. Missing or
                // incorrect passphrases are actionable UI challenges, not an
                // address-specific bootstrap failure; preserve the typed
                // error instead of flattening it into MoshBootstrapError.
                if (error as? SSHConnectionError)?.keyPassphraseReason != nil {
                    await ssh.close()
                    throw error
                }
                let detail = (error as? SSHConnectionError).map { _ in String(describing: error) }
                    ?? error.localizedDescription
                lastError = .sshFailed(detail)
                await ssh.close()
                continue
            }

            do {
                let target = try await launchServer(
                    over: ssh, host: host, remoteCommand: remoteCommand, address: address
                )
                await ssh.close()
                return target
            } catch let error as MoshBootstrapError {
                lastError = error
                await ssh.close()
            } catch {
                lastError = .sshFailed(String(describing: error))
                await ssh.close()
            }
        }
        throw lastError
    }

    /// Try en_US.UTF-8 first; fall back once for hosts that only ship
    /// C.UTF-8, and once more without `-s` for sshds that don't set
    /// SSH_CONNECTION.
    private static func launchServer(
        over ssh: SSHConnection,
        host: Host,
        remoteCommand: String?,
        address: (ip: String, isIPv6: Bool)
    ) async throws -> Target {
        var locale = "en_US.UTF-8"
        var bindToSSHAddress = true

        for _ in 0 ..< 3 {
            let output = try await ssh.exec(command(
                serverPath: host.moshServerPath,
                ports: host.moshPorts,
                locale: locale,
                remoteCommand: remoteCommand,
                bindToSSHAddress: bindToSSHAddress
            ))
            if let (port, key) = parseConnect(output) {
                return Target(ip: address.ip, port: port, key: key, isIPv6: address.isIPv6)
            }
            if mentionsLocaleFailure(output), locale != "C.UTF-8" {
                locale = "C.UTF-8"
                continue
            }
            if mentionsSSHConnectionFailure(output), bindToSSHAddress {
                bindToSSHAddress = false
                continue
            }
            throw MoshBootstrapError.serverFailed(failureDetail(output))
        }
        throw MoshBootstrapError.serverFailed(String(localized: "gave up after fallbacks"))
    }
}
