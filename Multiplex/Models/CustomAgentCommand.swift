import Foundation

/// One user-authored helper for a particular CLI agent. The owning
/// `CustomAgentCommandStore` supplies the agent association; keeping the
/// command itself agent-agnostic lets the editor and injection rules stay
/// identical for Claude Code and Codex.
struct CustomAgentCommand: Identifiable, Codable, Hashable {
    /// Bar labels retain at most this many user-authored characters. Longer
    /// labels append three dots; the command payload itself is never changed.
    static let maximumBarLabelLength = 9
    private static let maximumMenuLabelLength = 36

    var id: UUID = UUID()
    var content: String
    var autoSubmit: Bool = true
    var showInBar: Bool = true
    /// Mirror this command into both Claude Code and Codex helper profiles.
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
    /// store uses this when a shared command replaces an equivalent local copy
    /// in the other agent profile.
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
