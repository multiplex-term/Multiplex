import Foundation

/// One user-authored helper. Its host-owned `AgentCommandConfiguration`
/// supplies the agent association; keeping the command itself scope-agnostic
/// lets the editor and injection rules stay identical across supported
/// agents.
struct CustomAgentCommand: Identifiable, Codable, Hashable {
    /// Bar labels retain at most this many user-authored characters. Longer
    /// labels append three dots; the command payload itself is never changed.
    static let maximumBarLabelLength = 9
    private static let maximumMenuLabelLength = 36

    var id: UUID = UUID()
    var content: String
    var autoSubmit: Bool = true
    var showInBar: Bool = true
    /// Mirror this command into every supported agent helper profile.
    var shared: Bool = false

    init(
        id: UUID = UUID(),
        content: String,
        autoSubmit: Bool = true,
        showInBar: Bool = true,
        shared: Bool = false
    ) {
        self.id = id
        self.content = content
        self.autoSubmit = autoSubmit
        self.showInBar = showInBar
        self.shared = shared
    }

    /// The canonical bytes persisted and typed. Normalize pasted Windows or
    /// classic-Mac line endings, remove invisible terminal control bytes
    /// (especially tmux's Ctrl-B prefix), then trim only the outside of the
    /// command. Tabs, indentation, and newlines inside a multiline prompt
    /// remain untouched.
    var normalizedContent: String {
        Self.normalizeContent(content)
    }

    /// Compact chip copy for the bar. Placement is an explicit user choice;
    /// display-only glyphs keep multiline content and tabs on one physical
    /// line. The first nine characters are retained and longer labels append
    /// `...`, while the full command remains the injected payload.
    var barLabel: String? {
        guard showInBar else { return nil }
        let label = normalizedContent
            .replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\t", with: "⇥")
        guard !label.isEmpty else { return nil }
        guard label.count > Self.maximumBarLabelLength else { return label }
        return String(label.prefix(Self.maximumBarLabelLength)) + "..."
    }

    private static func normalizeContent(_ content: String) -> String {
        ComposedText.lineNormalized(content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compact, single-line copy for the system MORE menu and accessibility.
    /// The actual payload is never truncated.
    var menuLabel: String {
        let value = normalizedContent
        guard !value.isEmpty else { return String(localized: "Custom command") }

        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        let firstLine = lines.first.map(String.init) ?? value
        let collapsed = firstLine
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let summary = lines.count > 1 ? "\(collapsed) …" : collapsed
        guard summary.count > Self.maximumMenuLabelLength else { return summary }
        return String(summary.prefix(Self.maximumMenuLabelLength - 1)) + "…"
    }

    /// Runtime command routed through the same ordered terminal input pump as
    /// built-ins. Custom helpers always consume the free daily command taste;
    /// otherwise recreating a built-in slash command would bypass the meter.
    var agentCommand: AgentCommand {
        AgentCommand(
            label: barLabel ?? menuLabel,
            payload: Data(normalizedContent.utf8),
            consumesSlashChipTaste: true,
            submitsAfterPause: autoSubmit
        )
    }

    /// Resolve editor rows before persistence: trim content, drop blank rows,
    /// and collapse exact duplicates while preserving the user's order. The
    /// same content may intentionally exist once as type-only and once as
    /// auto-submit, since those are distinct actions.
    static func normalized(_ commands: [CustomAgentCommand]) -> [CustomAgentCommand] {
        var seenIDs = Set<UUID>()
        var seenCommands = Set<DuplicateKey>()
        var result: [CustomAgentCommand] = []

        for var command in commands {
            let content = command.normalizedContent
            let key = DuplicateKey(content: content, autoSubmit: command.autoSubmit)
            guard !content.isEmpty,
                  seenIDs.insert(command.id).inserted,
                  seenCommands.insert(key).inserted
            else { continue }
            command.content = content
            result.append(command)
        }
        return result
    }

    private struct DuplicateKey: Hashable {
        var content: String
        var autoSubmit: Bool
    }

    /// Commands with the same injected bytes and submit behavior are the same
    /// action even if their bar placement or sharing metadata differs. The
    /// configuration uses this when a shared command replaces an equivalent local copy
    /// in another agent profile.
    func hasSameAction(as other: CustomAgentCommand) -> Bool {
        DuplicateKey(content: normalizedContent, autoSubmit: autoSubmit)
            == DuplicateKey(content: other.normalizedContent, autoSubmit: other.autoSubmit)
    }
}

/// The complete helper setup for one host. It is part of the Codable `Host`
/// record, so commands and built-in Bar/More choices follow that host through
/// the synchronizable Keychain mirror. Shared rows mirror across all of this
/// configuration's supported agent profiles.
struct AgentCommandConfiguration: Codable, Hashable {
    struct Profile: Codable, Hashable {
        var agent: AgentKind
        var commands: [CustomAgentCommand]
        var builtInPlacements: [String: AgentCommandPlacement]

        init(
            agent: AgentKind,
            commands: [CustomAgentCommand] = [],
            builtInPlacements: [String: AgentCommandPlacement] = [:]
        ) {
            self.agent = agent
            self.commands = commands
            self.builtInPlacements = builtInPlacements
        }

        fileprivate enum CodingKeys: String, CodingKey {
            case agent, commands, builtInPlacements
        }
    }

    /// `Host.sessionBackend`'s rule for a synced enum: read the raw string
    /// and treat a value this build cannot name as absent. A profile for a
    /// CLI added by a newer app (Grok Build arrived this way, 2026-08-16)
    /// decodes to nil and is dropped, while a known agent's malformed
    /// profile still throws — one unknown agent must not take the whole
    /// Host record down, and a corrupt one must not vanish silently.
    private struct LenientProfile: Decodable {
        var profile: Profile?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Profile.CodingKeys.self)
            guard let agent = AgentKind(rawValue: try container.decode(String.self, forKey: .agent))
            else { return }
            profile = Profile(
                agent: agent,
                commands: try container.decode([CustomAgentCommand].self, forKey: .commands),
                builtInPlacements: try container.decode(
                    [String: AgentCommandPlacement].self, forKey: .builtInPlacements
                )
            )
        }
    }

    private(set) var profiles: [Profile]

    private static let supportedAgents = AgentKind.allCases

    init(profiles: [Profile] = []) {
        var seenAgents = Set<AgentKind>()
        self.profiles = profiles.compactMap { profile in
            guard seenAgents.insert(profile.agent).inserted else { return nil }
            let commands = CustomAgentCommand.normalized(profile.commands)
            let placements = AgentCommandSet.normalizedPlacementOverrides(
                profile.builtInPlacements,
                for: profile.agent
            )
            guard !commands.isEmpty || !placements.isEmpty else { return nil }
            return Profile(
                agent: profile.agent,
                commands: commands,
                builtInPlacements: placements
            )
        }
        sortProfiles()
        reconcileSharedCommands()
    }

    var isEmpty: Bool { profiles.isEmpty }

    func commands(for agent: AgentKind) -> [CustomAgentCommand] {
        profile(for: agent)?.commands ?? []
    }

    func builtInPlacements(
        for agent: AgentKind
    ) -> [String: AgentCommandPlacement] {
        profile(for: agent)?.builtInPlacements ?? [:]
    }

    mutating func replace(
        _ commands: [CustomAgentCommand],
        builtInPlacements: [String: AgentCommandPlacement],
        for agent: AgentKind
    ) {
        let previous = self.commands(for: agent)
        let resolved = CustomAgentCommand.normalized(commands)
        let resolvedPlacements = AgentCommandSet.normalizedPlacementOverrides(
            builtInPlacements,
            for: agent
        )
        setProfile(
            commands: resolved,
            builtInPlacements: resolvedPlacements,
            for: agent
        )

        // This edited profile is authoritative for shared rows it used to
        // contain. Withdrawals and updates affect every other agent profile
        // inside this host-owned configuration.
        let previousSharedIDs = Set(previous.filter(\.shared).map(\.id))
        let currentShared = resolved.filter(\.shared)
        let currentSharedIDs = Set(currentShared.map(\.id))

        for other in Self.supportedAgents where other != agent {
            var otherCommands = self.commands(for: other)
            let withdrawnIDs = previousSharedIDs.subtracting(currentSharedIDs)
            otherCommands.removeAll { withdrawnIDs.contains($0.id) }
            for command in currentShared {
                upsertShared(command, into: &otherCommands)
            }
            setProfile(
                commands: CustomAgentCommand.normalized(otherCommands),
                builtInPlacements: self.builtInPlacements(for: other),
                for: other
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let profiles = try container.decode([LenientProfile].self, forKey: .profiles)
        self.init(profiles: profiles.compactMap(\.profile))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profiles, forKey: .profiles)
    }

    private func profile(for agent: AgentKind) -> Profile? {
        profiles.first { $0.agent == agent }
    }

    private mutating func setProfile(
        commands: [CustomAgentCommand],
        builtInPlacements: [String: AgentCommandPlacement],
        for agent: AgentKind
    ) {
        let profile = Profile(
            agent: agent,
            commands: commands,
            builtInPlacements: builtInPlacements
        )
        if commands.isEmpty, builtInPlacements.isEmpty {
            profiles.removeAll { $0.agent == agent }
        } else if let index = profiles.firstIndex(where: { $0.agent == agent }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        sortProfiles()
    }

    private func upsertShared(
        _ command: CustomAgentCommand,
        into commands: inout [CustomAgentCommand]
    ) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else if let index = commands.firstIndex(where: {
            $0.hasSameAction(as: command)
        }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
    }

    /// Normalize one-sided shared rows loaded from persistence.
    private mutating func reconcileSharedCommands() {
        let sharedCommands = Self.supportedAgents.flatMap {
            commands(for: $0).filter(\.shared)
        }
        var reconciledIDs = Set<UUID>()
        for command in sharedCommands where reconciledIDs.insert(command.id).inserted {
            for agent in Self.supportedAgents {
                var commands = self.commands(for: agent)
                upsertShared(command, into: &commands)
                setProfile(
                    commands: CustomAgentCommand.normalized(commands),
                    builtInPlacements: builtInPlacements(for: agent),
                    for: agent
                )
            }
        }
    }

    private mutating func sortProfiles() {
        profiles.sort {
            let lhs = Self.supportedAgents.firstIndex(of: $0.agent) ?? .max
            let rhs = Self.supportedAgents.firstIndex(of: $1.agent) ?? .max
            return lhs < rhs
        }
    }
}
