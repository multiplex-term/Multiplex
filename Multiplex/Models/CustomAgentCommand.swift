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
        let normalizedLineEndings = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let safeText = normalizedLineEndings.unicodeScalars.reduce(into: "") {
            result, scalar in
            let allowedControl = scalar.value == 0x09 || scalar.value == 0x0A
            if allowedControl || !CharacterSet.controlCharacters.contains(scalar) {
                result.append(Character(scalar))
            }
        }
        return safeText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compact, single-line copy for the system MORE menu and accessibility.
    /// The actual payload is never truncated.
    var menuLabel: String {
        let value = normalizedContent
        guard !value.isEmpty else { return "Custom command" }

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

    // MARK: Persistence compatibility

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case autoSubmit
        case showInBar
        case shared
    }

    /// Commands saved before `showInBar` existed keep their former placement:
    /// short single-line-safe labels stay on the bar, while long commands and
    /// labels containing a tab remain in MORE until the user opts them in.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        content = try container.decode(String.self, forKey: .content)
        autoSubmit = try container.decodeIfPresent(Bool.self, forKey: .autoSubmit) ?? true
        if let storedPlacement = try container.decodeIfPresent(Bool.self, forKey: .showInBar) {
            showInBar = storedPlacement
        } else {
            let legacyContent = Self.normalizeContent(content)
            showInBar = !legacyContent.isEmpty
                && legacyContent.count <= Self.maximumBarLabelLength
                && !legacyContent.contains("\t")
        }
        shared = try container.decodeIfPresent(Bool.self, forKey: .shared) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(autoSubmit, forKey: .autoSubmit)
        try container.encode(showInBar, forKey: .showInBar)
        try container.encode(shared, forKey: .shared)
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

        private enum CodingKeys: String, CodingKey {
            case agent
            case commands
            case builtInPlacements
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            agent = try container.decode(AgentKind.self, forKey: .agent)
            commands = try container.decodeIfPresent(
                [CustomAgentCommand].self,
                forKey: .commands
            ) ?? []
            builtInPlacements = try container.decodeIfPresent(
                [String: AgentCommandPlacement].self,
                forKey: .builtInPlacements
            ) ?? [:]
        }
    }

    private(set) var profiles: [Profile]

    /// Pi is encoded outside the legacy `profiles` array. Builds that predate
    /// Pi decode that array with a strict two-case AgentKind; putting `.pi`
    /// there would make the entire mirrored Host record undecodable. The
    /// marker also lets HostSync recognize when an older peer decoded and
    /// re-encoded the configuration, dropping the unknown Pi key.
    private(set) var piProfileVersion: Int

    private static let currentPiProfileVersion = 1
    private static let supportedAgents = AgentKind.allCases

    init(
        profiles: [Profile] = [],
        piProfileVersion: Int = Self.currentPiProfileVersion
    ) {
        self.piProfileVersion = max(0, piProfileVersion)
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
        // A current build may be editing a record that an older peer already
        // round-tripped without Pi's unknown coding keys. A Claude/Codex edit
        // cannot certify that missing Pi state; keep marker 0 so HostSync can
        // still recover it from a current-schema peer. Editing Pi itself is
        // authoritative and establishes the current schema.
        if agent == .pi {
            piProfileVersion = Self.currentPiProfileVersion
        }
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
        case piProfile
        case piProfileVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyProfiles = try container.decodeIfPresent(
            [Profile].self,
            forKey: .profiles
        ) ?? []
        let encodedPiProfile = try container.decodeIfPresent(
            Profile.self,
            forKey: .piProfile
        )
        let validPiProfile = encodedPiProfile.flatMap {
            $0.agent == .pi ? $0 : nil
        }
        let carriedPiProfile = legacyProfiles.first { $0.agent == .pi }
        let piProfile = validPiProfile ?? carriedPiProfile
        let storedVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .piProfileVersion
        )
        self.init(
            profiles: legacyProfiles.filter { $0.agent != .pi }
                + (piProfile.map { [$0] } ?? []),
            piProfileVersion: storedVersion
                ?? (piProfile == nil ? 0 : Self.currentPiProfileVersion)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            profiles.filter { $0.agent != .pi },
            forKey: .profiles
        )
        try container.encodeIfPresent(profile(for: .pi), forKey: .piProfile)
        try container.encode(piProfileVersion, forKey: .piProfileVersion)
    }

    /// Restore only the Pi profile that an older peer could not retain,
    /// leaving that peer's newer Claude Code/Codex edits intact.
    mutating func preservePiProfile(from source: AgentCommandConfiguration) {
        guard piProfileVersion < source.piProfileVersion else { return }
        // The older peer *can* edit shared rows through its Claude/Codex
        // profiles. If it deleted or unshared one there, restoring Pi's stale
        // shared copy would make reconciliation resurrect that explicit edit.
        // Preserve Pi-only rows unconditionally; preserve a shared row only
        // while the destination still carries that UUID as shared.
        let retainedSharedIDs = Set(
            profiles
                .filter { $0.agent != .pi }
                .flatMap(\.commands)
                .filter(\.shared)
                .map(\.id)
        )
        profiles.removeAll { $0.agent == .pi }
        if var sourceProfile = source.profile(for: .pi) {
            sourceProfile.commands.removeAll {
                $0.shared && !retainedSharedIDs.contains($0.id)
            }
            if !sourceProfile.commands.isEmpty
                || !sourceProfile.builtInPlacements.isEmpty {
                profiles.append(sourceProfile)
            }
        }
        piProfileVersion = source.piProfileVersion
        sortProfiles()
        reconcileSharedCommands()
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

    /// Repair one-sided shared rows from older or manually edited records.
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
