import AppIntents
import Foundation

/// The CLI agent as an intent/widget-configuration parameter. Raw values
/// mirror `AgentKind` one-to-one (unit-tested) so the app maps with
/// `AgentKind(rawValue:)` while the widget target never imports the
/// detection models.
enum AgentChoice: String, AppEnum {
    case claudeCode
    case codex
    case pi
    case grok
    case antigravity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let caseDisplayRepresentations: [AgentChoice: DisplayRepresentation] = [
        .claudeCode: "Claude Code",
        .codex: "Codex",
        .pi: "Pi",
        .grok: "Grok Build",
        .antigravity: "Antigravity",
    ]
}

/// Picker rows for a host's pre-configured launch models — shared by the
/// Open Agent Shortcut's provider (app process) and the Host widget's
/// configuration provider (widget process), so both offer the same list.
/// Presentation-only hygiene (trim, drop empties, dedupe in order); the
/// launch grammar's token gate stays app-side where the value is consumed.
enum AgentModelChoices {
    struct Choice: Equatable {
        var value: String
        var title: String
    }

    /// The empty string is the "no model" sentinel every consumer already
    /// honors: the widget link builder skips empty values and the Shortcut's
    /// perform normalizes them to nil, so picking it launches the agent's
    /// own default.
    static let agentDefaultValue = ""

    /// Always non-empty, like the setup-script provider's Default/None
    /// rows: an options query that returns zero items makes the picker
    /// sheet open and immediately dismiss (observed in widget config), so
    /// "Agent Default" leads even when the host has nothing configured —
    /// which is also the honest way to say where configuration lives.
    static func choices(configured: [String]) -> [Choice] {
        var choices = [Choice(value: agentDefaultValue, title: String(localized: "Agent Default"))]
        choices += values(configured: configured).map {
            Choice(value: $0, title: $0)
        }
        return choices
    }

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
