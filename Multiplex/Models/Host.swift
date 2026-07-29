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
    /// Whether the deck monitors this host. A disabled host keeps its record,
    /// its secrets, and its place in the fleet, but the app never dials it on
    /// its own: no wall probe, no local-network check, and widget/Shortcut
    /// actions refuse it instead of connecting. Turning it back on is one
    /// press on its tile. Rides the synced record, so a host switched off
    /// stays off on the user's other devices.
    var isEnabled: Bool = true
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
    /// Pre-configured `--model` values per agent (keyed by
    /// `AgentKind.rawValue`), in the user's order. Full model ids are typed
    /// once here — Host Settings — and every launch surface (New Session
    /// sheet, Open Agent Shortcut, Host widget setting) then offers them as
    /// a picker; only Claude Code has human-friendly aliases, so free text
    /// alone was a bad experience for Codex and Pi. Host-scoped on purpose,
    /// not just for the sync ride: Pi's available models genuinely differ
    /// per machine with its configured providers. A model is never applied
    /// because it exists — launches without a choice use the agent's own
    /// default. Unknown agent keys survive normalization so a record
    /// written by a newer schema keeps its lists through an edit-save here.
    var agentLaunchModels: [String: [String]] = [:]
    /// tmux options for sessions created from Multiplex — conf-style text
    /// stored in this record (never a file on the host), one option per
    /// line (`mouse on`, `focus-events on`). Each line is applied to the
    /// freshly minted session through an explicitly targeted
    /// `set-option -t <that session>`. Session-scoped options never alter
    /// sessions created host-side; tmux's server-scoped options remain
    /// server-wide. Attach never applies anything. Hosts start with
    /// `defaultNewSessionTmuxConf`;
    /// records written before the field existed decode to it too. Empty
    /// means the user cleared it: apply nothing, the host's own
    /// `~/.tmux.conf` alone keeps governing, as tmux always does.
    var newSessionTmuxConf: String = Host.defaultNewSessionTmuxConf

    /// `mouse on` is the app's premise, not a taste choice: pans scroll
    /// tmux's own scrollback through the wheel events SwiftTerm reports,
    /// and Claude Code history jumps take the sticky-click fast path only
    /// while the pane reports mouse mode. `focus-events on` lets tmux pass
    /// the terminal client's focus changes through to focus-aware apps.
    static let defaultNewSessionTmuxConf = "mouse on\nfocus-events on"
    /// SSH host key fingerprints (`"<key type> SHA256:<b64>"`) recorded for
    /// this host — today written by the bind flow, which learns them from
    /// the machine itself before the first connection. Storage only for now:
    /// the TOFU validator that enforces them is its own change, but hosts
    /// bound via `mpx bind` arrive carrying the data it needs. Rides the
    /// synced record; empty means nothing recorded.
    var pinnedHostKeys: [String] = []
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

    /// The configured launch models for one agent, picker-ready.
    func launchModels(for agent: AgentKind) -> [String] {
        agentLaunchModels[agent.rawValue] ?? []
    }

    /// Canonical form for persistence: known agents' lists pass the launch
    /// grammar's token gate and dedupe in order (an invalid entry can never
    /// ride a launch line, so storing it would only fabricate a dead picker
    /// row); empty lists drop their key. Unknown agent keys pass through
    /// verbatim — validating a newer schema's list against today's grammar
    /// could destroy it.
    static func normalizedLaunchModels(_ raw: [String: [String]]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (agentRaw, models) in raw {
            guard AgentKind(rawValue: agentRaw) != nil else {
                if !models.isEmpty { result[agentRaw] = models }
                continue
            }
            var seen = Set<String>()
            let cleaned = models
                .compactMap(AgentKind.normalizedLaunchModel)
                .filter { seen.insert($0).inserted }
            if !cleaned.isEmpty { result[agentRaw] = cleaned }
        }
        return result
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
        // Records written before the switch existed are hosts the user
        // expects to see probing: absent means enabled.
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        useMosh = try container.decodeIfPresent(Bool.self, forKey: .useMosh) ?? false
        moshServerPath = try container.decodeIfPresent(String.self, forKey: .moshServerPath)
        moshPorts = try container.decodeIfPresent(String.self, forKey: .moshPorts)
        workingDirs = try container.decodeIfPresent([String].self, forKey: .workingDirs) ?? []
        sessionScripts = SessionScript.normalized(
            try container.decodeIfPresent([SessionScript].self, forKey: .sessionScripts) ?? []
        )
        agentLaunchModels = Host.normalizedLaunchModels(
            try container.decodeIfPresent(
                [String: [String]].self, forKey: .agentLaunchModels) ?? [:]
        )
        newSessionTmuxConf = try container.decodeIfPresent(
            String.self, forKey: .newSessionTmuxConf
        ) ?? Host.defaultNewSessionTmuxConf
        pinnedHostKeys = try container.decodeIfPresent(
            [String].self, forKey: .pinnedHostKeys
        ) ?? []
        agentCommandConfiguration = try container.decodeIfPresent(
            AgentCommandConfiguration.self,
            forKey: .agentCommandConfiguration
        ) ?? AgentCommandConfiguration()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    /// Hashable identity for the connection model and the wall feed that
    /// drives it. Command-setup, setup-script, launch-model, and new-session
    /// tmux conf edits must not tear down the probe connection; every other
    /// current/future Host field remains part of the identity — `isEnabled`
    /// deliberately included, so a host switched off on another device
    /// restarts the wall feed here, which is where the live probe is dropped.
    var connectionModelConfiguration: Host {
        var configuration = self
        configuration.agentCommandConfiguration = AgentCommandConfiguration()
        configuration.sessionScripts = []
        configuration.agentLaunchModels = [:]
        configuration.newSessionTmuxConf = Host.defaultNewSessionTmuxConf
        configuration.updatedAt = .distantPast
        return configuration
    }

    func hasSameConnectionModelConfiguration(as other: Host) -> Bool {
        connectionModelConfiguration == other.connectionModelConfiguration
    }
}
