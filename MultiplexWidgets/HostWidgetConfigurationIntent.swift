import AppIntents
import Foundation

/// Per-widget settings for the host widget ("can setting"): which host, what
/// a small widget's single tap opens, which agent the AGENT key launches,
/// and whether it should ask for a first prompt in the app before launching.
struct HostWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Host Widget"
    static let description = IntentDescription(
        "Pick the host this widget monitors and what a tap opens.")

    @Parameter(title: "Host")
    var host: HostEntity?

    /// Small widgets have exactly one tap; medium always shows both keys.
    @Parameter(title: "Tap Opens (Small Widget)", default: .shell)
    var action: WidgetTapAction

    @Parameter(title: "Agent", default: .claudeCode)
    var agent: AgentChoice

    @Parameter(title: "Ask for Prompt", default: false)
    var askForPrompt: Bool
}

enum WidgetTapAction: String, AppEnum {
    case shell
    case agent

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
    static let caseDisplayRepresentations: [WidgetTapAction: DisplayRepresentation] = [
        .shell: "Shell",
        .agent: "Agent",
    ]
}
