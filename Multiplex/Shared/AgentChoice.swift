import AppIntents

/// The CLI agent as an intent/widget-configuration parameter. Raw values
/// mirror `AgentKind` one-to-one (unit-tested) so the app maps with
/// `AgentKind(rawValue:)` while the widget target never imports the
/// detection models.
enum AgentChoice: String, AppEnum {
    case claudeCode
    case codex
    case pi

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let caseDisplayRepresentations: [AgentChoice: DisplayRepresentation] = [
        .claudeCode: "Claude Code",
        .codex: "Codex",
        .pi: "Pi",
    ]
}

/// Picker rows for a host's pre-configured launch models — shared by the
/// Open Agent Shortcut's provider (app process) and the Host widget's
/// configuration provider (widget process), so both offer the same list.
/// Presentation-only hygiene (trim, drop empties, dedupe in order); the
/// launch grammar's token gate stays app-side where the value is consumed.
enum AgentModelChoices {
    static func values(configured: [String]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for raw in configured {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { continue }
            values.append(model)
        }
        return values
    }
}
