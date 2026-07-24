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
    /// Reach this host's SSH endpoint through the app's embedded userspace
    /// Tailscale node (tailscale-rs backend). Works on all three platforms;
    /// for v1 it cannot carry mosh's datagram transport.
    var useTailscale: Bool = false
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
    /// tmux options for sessions created from Multiplex — conf-style text
    /// stored in this record (never a file on the host), one option per
    /// line (`mouse on`). Each line is applied to the freshly minted
    /// session as an explicitly targeted `set-option -t <that session>`,
    /// so sessions created host-side are never touched and attach never
    /// applies anything. Hosts start with `defaultNewSessionTmuxConf`;
    /// records written before the field existed decode to it too. Empty
    /// means the user cleared it: apply nothing, the host's own
    /// `~/.tmux.conf` alone keeps governing, as tmux always does.
    var newSessionTmuxConf: String = Host.defaultNewSessionTmuxConf

    /// `mouse on` is the app's premise, not a taste choice: pans scroll
    /// tmux's own scrollback through the wheel events SwiftTerm reports,
    /// and Claude Code history jumps take the sticky-click fast path only
    /// while the pane reports mouse mode.
    static let defaultNewSessionTmuxConf = "mouse on"
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
        useTailscale = try container.decodeIfPresent(Bool.self, forKey: .useTailscale) ?? false
        moshServerPath = try container.decodeIfPresent(String.self, forKey: .moshServerPath)
        moshPorts = try container.decodeIfPresent(String.self, forKey: .moshPorts)
        workingDirs = try container.decodeIfPresent([String].self, forKey: .workingDirs) ?? []
        sessionScripts = SessionScript.normalized(
            try container.decodeIfPresent([SessionScript].self, forKey: .sessionScripts) ?? []
        )
        newSessionTmuxConf = try container.decodeIfPresent(
            String.self, forKey: .newSessionTmuxConf
        ) ?? Host.defaultNewSessionTmuxConf
        agentCommandConfiguration = try container.decodeIfPresent(
            AgentCommandConfiguration.self,
            forKey: .agentCommandConfiguration
        ) ?? AgentCommandConfiguration()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    /// Hashable identity for the connection model and the wall feed that
    /// drives it. Command-setup, setup-script, and new-session tmux conf
    /// edits must not tear down the probe connection; every other
    /// current/future Host field remains part of the identity.
    var connectionModelConfiguration: Host {
        var configuration = self
        configuration.agentCommandConfiguration = AgentCommandConfiguration()
        configuration.sessionScripts = []
        configuration.newSessionTmuxConf = Host.defaultNewSessionTmuxConf
        configuration.updatedAt = .distantPast
        return configuration
    }

    func hasSameConnectionModelConfiguration(as other: Host) -> Bool {
        connectionModelConfiguration == other.connectionModelConfiguration
    }
}
