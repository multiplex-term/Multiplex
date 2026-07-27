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

    /// Rides the launch as `--model <value>`; unset means the agent's
    /// default. Choices are the host's pre-configured launch models from the
    /// published snapshot — full Codex/Pi ids are typed once in Host
    /// Settings, never into a widget text field. Validation stays app-side
    /// in the URL parser, so a stale value falls back to the default
    /// instead of a malformed launch line.
    @Parameter(title: "Model", optionsProvider: WidgetAgentModelOptionsProvider())
    var model: String?

    @Parameter(title: "Ask for Prompt", default: false)
    var askForPrompt: Bool
}

/// Widget-process provider: reads the same `HostEntityProvider` surface the
/// Shortcut picker uses (snapshot-backed here) and the same shared choice
/// builder, so both pickers offer identical rows.
struct WidgetAgentModelOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<HostWidgetConfigurationIntent>(\.$host, \.$agent)
    private var intent

    func results() async throws -> IntentItemCollection<String> {
        let hosts = await HostEntityProvider.all()
        let configured = intent.flatMap { dependency in
            hosts.first { $0.id == dependency.host.id }?
                .agentModels[dependency.agent.rawValue]
        } ?? []
        let items = AgentModelChoices.values(configured: configured)
            .map { IntentItem($0) }
        return IntentItemCollection(
            promptLabel: "Choose a model",
            sections: [IntentItemSection(items: items)]
        )
    }
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
