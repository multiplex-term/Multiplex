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
