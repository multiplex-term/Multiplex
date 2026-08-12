import Foundation

/// The host sheet's Test Connection button: one throwaway SSH connection
/// using the form's (possibly unsaved) credentials, then a `command -v`
/// sweep for the tools the app needs on the host. Everything except `run`
/// is pure — the command builder, output parser, and failure wording are
/// unit-tested against real Citadel/NIO error shapes.
enum HostTest {
    /// What a successful sign-in found on the host.
    struct Report: Equatable {
        /// Whether the host's explicitly selected session backend is on the
        /// same exec PATH the deck will use.
        var multiplexerFound = false
        /// nil when the host doesn't use mosh (nothing to check).
        var moshServerFound: Bool?
    }

    enum Outcome: Equatable {
        case connected(Report)
        case failed(String)
    }

    /// Connect + auth deadline. Generous — DNS, TCP, the SSH handshake,
    /// and auth all fit inside it; a black-holed address must not hang the
    /// sheet forever (Citadel's futures never time out on their own).
    static let connectDeadline: Double = 15
    private static let execDeadline: Double = 10

    static func run(host: Host, secrets: HostSecrets) async -> Outcome {
        let connection = SSHConnection(host: host, secrets: secrets)
        defer { Task { await connection.close() } }
        do {
            try await deadlined(seconds: connectDeadline) { try await connection.connect() }
            let output = try await deadlined(seconds: execDeadline) {
                try await connection.exec(checkCommand(for: host))
            }
            return .connected(parseReport(
                output,
                backend: host.sessionBackend,
                checksMosh: host.useMosh
            ))
        } catch {
            return .failed(failureMessage(for: error, host: host))
        }
    }

    // MARK: Tool sweep (pure)

    /// The selected multiplexer (tmux or herdr); mosh-server when the host
    /// uses mosh — at its configured path if one is set (`command -v`
    /// accepts a pathname and checks it's executable). Always exits 0:
    /// Citadel throws on a non-zero exit status, and "tool missing" must
    /// read as a report line, not a failed connection.
    static func checkCommand(for host: Host) -> String {
        let pathPrefix = host.sessionBackend == .herdr
            ? HerdrProbe.pathPrefix : TmuxProbe.pathPrefix
        let marker = host.sessionBackend == .herdr ? "HERDR" : "TMUX"
        var command = pathPrefix
            + "command -v \(host.sessionBackend.rawValue) >/dev/null 2>&1"
            + " && echo MPXT_\(marker)_OK || echo MPXT_\(marker)_MISSING; "
        if host.useMosh {
            let configured = host.moshServerPath?.trimmingCharacters(in: .whitespaces) ?? ""
            let server = configured.isEmpty ? "mosh-server" : configured
            command += "command -v \(server.shellQuoted) >/dev/null 2>&1"
                + " && echo MPXT_MOSH_OK || echo MPXT_MOSH_MISSING; "
        }
        command += "true"
        return command
    }

    static func parseReport(
        _ output: String,
        backend: Host.SessionBackend,
        checksMosh: Bool
    ) -> Report {
        let marker = backend == .herdr ? "MPXT_HERDR_OK" : "MPXT_TMUX_OK"
        return Report(
            multiplexerFound: output.contains(marker),
            moshServerFound: checksMosh ? output.contains("MPXT_MOSH_OK") : nil
        )
    }

    // MARK: Failure wording (pure)

    /// Words that say what to fix, not what the transport saw.
    static func failureMessage(for error: Error, host: Host) -> String {
        if let ssh = error as? SSHConnectionError {
            switch ssh {
            case .missingCredentials:
                return host.authMethod == .password
                    ? "Enter a password first."
                    : "Paste a private key first."
            case .keyPassphraseRequired:
                return "This private key is encrypted. Enter its passphrase above."
            case .incorrectKeyPassphrase:
                return "That passphrase didn't unlock the private key. Try again."
            case .unsupportedKey:
                return "The private key couldn't be read. Paste an OpenSSH ed25519 "
                    + "or RSA key, including its BEGIN/END lines."
            case .connectFailed(let detail):
                return connectFailureMessage(detail, host: host)
            case .notConnected:
                return "The connection closed before the check finished. Try again."
            case .hostKeyRefused(let refusal):
                // The Host key section sits directly below this one, so
                // "below" names a control the reader can actually see.
                switch refusal {
                case .changed(let expected, let presented):
                    return "\(host.hostname) presented a different host key than the one "
                        + "recorded for this host — \(expected.fingerprint), got "
                        + "\(presented.fingerprint). Nothing was sent. If you rebuilt the "
                        + "server, forget the recorded key below and check again."
                case .unrecognizedAlgorithm(let presented, _):
                    return "\(host.hostname) identified itself with a \(presented.algorithm) "
                        + "key, which isn't recorded for this host. Nothing was sent. If its "
                        + "host keys changed, forget the recorded keys below and check again."
                }
            }
        }
        if error is DeadlineExceeded {
            return "No answer from \(host.hostname) after \(Int(connectDeadline)) seconds — check the address and port, and that the host is reachable from this network."
        }
        return connectFailureMessage(String(describing: error), host: host)
    }

    /// Classify a raw transport error by well-known substrings. Citadel and
    /// NIO error descriptions are stable enough for this; an unmatched
    /// detail is kept as a suffix — an unreadable reason still beats none.
    static func connectFailureMessage(_ detail: String, host: Host) -> String {
        let lower = detail.lowercased()
        if lower.contains("authentication") || lower.contains("permission denied") {
            return host.authMethod == .password
                ? "\(host.hostname) rejected the sign-in — check the user name and password."
                : "\(host.hostname) rejected the key — check the user name, and that the key's public half is in ~/.ssh/authorized_keys on the host."
        }
        if lower.contains("connection refused") || lower.contains("econnrefused") {
            return "\(host.hostname) refused the connection on port \(host.port) — is an SSH server listening there?"
        }
        if lower.contains("dnsaerror") || lower.contains("dnsaaaaerror")
            || lower.contains("nodename nor servname")
            || lower.contains("name or service not known") {
            return "Couldn't find “\(host.hostname)” — check the address for typos."
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "\(host.hostname) didn't answer — check the port, and any firewall between this device and the host."
        }
        if lower.contains("network is unreachable") || lower.contains("enetunreach")
            || lower.contains("no route to host") || lower.contains("ehostunreach") {
            return "No route to \(host.hostname) — check this device's network connection."
        }
        if lower.contains("connection reset") || lower.contains("econnreset") {
            return "\(host.hostname) dropped the connection — the port may not speak SSH."
        }
        return "Couldn't connect to \(host.hostname): \(detail)"
    }

}
