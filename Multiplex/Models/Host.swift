import Foundation

/// A remote machine reachable over SSH. Secrets live in the Keychain, keyed by `id`.
struct Host: Identifiable, Codable, Hashable {
    enum AuthMethod: String, Codable, CaseIterable, Identifiable {
        case password
        case privateKey

        var id: String { rawValue }
        var label: String {
            switch self {
            case .password: "Password"
            case .privateKey: "Private key"
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var hostname: String
    var port: Int = 22
    var username: String
    var authMethod: AuthMethod = .password
    /// Attach terminals over mosh (SSP over UDP) instead of the SSH PTY.
    /// The credentials above still authenticate the SSH bootstrap that
    /// launches `mosh-server`; deck probing stays on SSH either way.
    var useMosh: Bool = false
    /// Absolute path to `mosh-server` when it isn't on the exec PATH.
    var moshServerPath: String?
    /// UDP port or range ("60000:61000") handed to `mosh-server -p`.
    var moshPorts: String?
    /// Remote directories new sessions can start in, in the user's order —
    /// the first is the default; the rest are choices in the New Session
    /// prompt. Empty means $HOME.
    var workingDirs: [String] = []
    /// Named setup scripts, in the user's order (order is presentation only
    /// — a script runs only when chosen, never because it exists). The
    /// selected one is typed into a freshly created session's shell before
    /// the optional agent launch line.
    var sessionScripts: [SessionScript] = []
    /// Agent-helper commands and built-in Bar/More placement for this host.
    /// This is part of the mirrored host record so the setup follows the host
    /// to the user's other devices through iCloud Keychain.
    var agentCommandConfiguration = AgentCommandConfiguration()
    /// Bumped on every user edit. When the same host arrives from another
    /// device via the Keychain mirror, the newer record wins.
    var updatedAt: Date = .distantPast

    var address: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}

// Decoding lives in an extension so the memberwise initializer survives.
// Post-schema fields are optional on decode so one incomplete hosts.json or
// mirrored record does not drop the whole list.
extension Host {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        useMosh = try container.decodeIfPresent(Bool.self, forKey: .useMosh) ?? false
        moshServerPath = try container.decodeIfPresent(String.self, forKey: .moshServerPath)
        moshPorts = try container.decodeIfPresent(String.self, forKey: .moshPorts)
        workingDirs = try container.decodeIfPresent([String].self, forKey: .workingDirs) ?? []
        sessionScripts = SessionScript.normalized(
            try container.decodeIfPresent([SessionScript].self, forKey: .sessionScripts) ?? []
        )
        agentCommandConfiguration = try container.decodeIfPresent(
            AgentCommandConfiguration.self,
            forKey: .agentCommandConfiguration
        ) ?? AgentCommandConfiguration()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    /// Hashable identity for the connection model and the wall feed that
    /// drives it. Command-setup and setup-script edits must not tear down the
    /// probe connection; every other current/future Host field remains part
    /// of the identity.
    var connectionModelConfiguration: Host {
        var configuration = self
        configuration.agentCommandConfiguration = AgentCommandConfiguration()
        configuration.sessionScripts = []
        configuration.updatedAt = .distantPast
        return configuration
    }

    func hasSameConnectionModelConfiguration(as other: Host) -> Bool {
        connectionModelConfiguration == other.connectionModelConfiguration
    }
}
