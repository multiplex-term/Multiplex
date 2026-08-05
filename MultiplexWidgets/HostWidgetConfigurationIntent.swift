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

    /// The AGENT key launches inside this existing session; unset/empty
    /// mints a fresh one (the original behavior). Choices are the
    /// snapshot's last-known session names; the app revalidates against
    /// the live probe and a dead name falls back to a fresh session.
    /// Declared before Model on purpose: the config sheet renders fields
    /// in declaration order, and where the agent lands reads before how
    /// it launches.
    @Parameter(title: "Session", optionsProvider: WidgetSessionOptionsProvider())
    var session: String?

    /// Where an existing-session launch opens, as a placement token the
    /// app-side URL parser owns (unset = the tab default). Rows adapt to
    /// the host's backend: tmux's one honest choice is a new window.
    @Parameter(title: "Open In", optionsProvider: WidgetPlacementOptionsProvider())
    var placement: String?

    /// Where the launch starts — fresh sessions and in-session placements
    /// alike, the Shortcut's Working Directory semantics: unset/empty is
    /// the host's default (first configured dir), `"~"` is explicitly
    /// Home. Choices are the snapshot's configured dirs.
    @Parameter(title: "Working Directory", optionsProvider: WidgetWorkingDirectoryOptionsProvider())
    var directory: String?

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

/// The snapshot host a widget-configuration provider should answer for: the
/// explicitly chosen one, else — with Host UNSET, the common case — the
/// FIRST host, mirroring `HostWidgetProvider.entry`'s own fallback. An
/// explicitly chosen host that has left the snapshot resolves to nil (the
/// widget face shows Awaiting data for it; the pickers offer only their
/// leading defaults). Unset-host handling matters twice: the rows should
/// describe the host the widget will actually monitor, and a dependency the
/// sheet considers unresolved must never leave the picker empty-handed.
private func widgetConfiguredHost(_ chosen: HostEntity?) -> WidgetHostState? {
    let hosts = SharedStateStore.load()?.hosts ?? []
    guard let chosen else { return hosts.first }
    return hosts.first { $0.id == chosen.id }
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
        // Never empty — a zero-item options query flash-dismisses the
        // picker; the leading Agent Default row always renders.
        let items = AgentModelChoices.choices(configured: configured)
            .map { IntentItem($0.value, title: "\($0.title)") }
        return IntentItemCollection(
            promptLabel: "Choose a model",
            sections: [IntentItemSection(items: items)]
        )
    }
}

/// Snapshot-backed session rows for the widget's Session setting — the
/// same last-known list the widget itself renders, led by New Session.
struct WidgetSessionOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<HostWidgetConfigurationIntent>(\.$host)
    private var intent

    func results() async throws -> IntentItemCollection<String> {
        let names = widgetConfiguredHost(intent?.host)?.sessions.map(\.name) ?? []
        let items = SessionTargetChoices.sessionChoices(names: names)
            .map { IntentItem($0.value, title: "\($0.title)") }
        return IntentItemCollection(
            promptLabel: "Choose a session",
            sections: [IntentItemSection(items: items)]
        )
    }
}

/// Snapshot-backed directory rows: Host Default, the host's configured
/// working dirs, Home — same shared normalization as the Shortcut's picker.
struct WidgetWorkingDirectoryOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<HostWidgetConfigurationIntent>(\.$host)
    private var intent

    func results() async throws -> IntentItemCollection<String> {
        let configured = widgetConfiguredHost(intent?.host)?.workingDirs ?? []
        let items = ShortcutWorkingDirectoryOptions.choices(configured: configured)
            .map { IntentItem($0.value, title: "\($0.title)") }
        return IntentItemCollection(
            promptLabel: "Choose a working directory",
            sections: [IntentItemSection(items: items)]
        )
    }
}

/// Placement rows in the host's backend vocabulary, from the published
/// `backendRaw` — same shared builder as the Shortcut's provider.
struct WidgetPlacementOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<HostWidgetConfigurationIntent>(\.$host)
    private var intent

    func results() async throws -> IntentItemCollection<String> {
        let backend = widgetConfiguredHost(intent?.host)?.backendRaw
        let items = SessionTargetChoices.placementChoices(backendRaw: backend)
            .map { IntentItem($0.value, title: "\($0.title)") }
        return IntentItemCollection(
            promptLabel: "Choose where the agent opens",
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
