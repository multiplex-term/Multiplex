import AppIntents
import Foundation

/// Shortcuts entry points. Both intents foreground the app and hand their
/// action to `ExternalActionRouter`; the mounted deck then runs the same
/// status-guarded flows as a widget deep link, so Shortcuts, Siri, widgets,
/// and the URL scheme share one execution path.

struct OpenHostShellIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Shell"
    static let description = IntentDescription(
        "Opens the host's most recent tmux session in Multiplex, creating one if none exists.",
        categoryName: "Terminal"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open a shell on \(\.$host)")
    }

    @Dependency private var router: ExternalActionRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.submit(.openShell(host: .id(host.id), sessionName: nil))
        return .result()
    }
}

struct OpenHostAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Agent"
    static let description = IntentDescription(
        // `LocalizedStringResource` must be a literal to be extractable for
        // localization, so this copy cannot be split with `+`.
        // swiftlint:disable:next line_length
        "Starts a CLI agent in a fresh tmux session, with an optional working directory, setup script, and first prompt.",
        categoryName: "Terminal"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Agent", default: .claudeCode) var agent: AgentChoice
    /// A free String so Shortcuts variables keep working; suggestions are
    /// the published snapshot's last-known session names. The app resolves
    /// the name against the live probe — a session that no longer exists
    /// falls back to the fresh-session launch. Declared (and summarized)
    /// before Model: where the agent lands reads before how it launches.
    @Parameter(
        title: "Session",
        // Literal for the same reason as the other descriptions here.
        // swiftlint:disable:next line_length
        description: "Launches the agent inside this existing session instead of creating one. Leave empty for a fresh session.",
        optionsProvider: AgentSessionOptionsProvider()
    ) var session: String?
    /// Placement inside an existing session, as the URL grammar's token —
    /// a new window on tmux; a new tab in the focused workspace (default)
    /// or a new workspace on herdr. Ignored for fresh-session launches.
    @Parameter(
        title: "Open In",
        // Literal for the same reason as the other descriptions here.
        // swiftlint:disable:next line_length
        description: "Where an existing-session launch opens: a new window on tmux; a new tab in the focused workspace or a new workspace on herdr.",
        optionsProvider: AgentPlacementOptionsProvider()
    ) var placement: String?
    /// Options follow the selected host's configured paths. An unset value
    /// uses its first configured directory (or Home when it has none) —
    /// for fresh sessions and in-session launches alike.
    @Parameter(
        title: "Working Directory",
        // Literal for the same reason as the other descriptions here.
        // swiftlint:disable:next line_length
        description: "Where the new session — or the new window, tab, or workspace inside an existing session — starts. Leave empty for the host default.",
        optionsProvider: AgentWorkingDirectoryOptionsProvider()
    ) var directory: String?
    /// Host-dependent stable ids keep a configured Shortcut working when a
    /// script is renamed. An unset value preserves the pre-picker behavior;
    /// None lets one Shortcut override a remembered script.
    @Parameter(
        title: "Setup Script",
        description: "Runs before the agent. Leave empty for the setup script remembered in Multiplex.",
        optionsProvider: AgentSetupScriptOptionsProvider()
    ) var setupScript: String?
    /// Suggestions come from the host's pre-configured launch models (Host
    /// Settings) — full Codex/Pi ids are typed once there, then picked here.
    /// The value stays a free String so Shortcuts variables and unlisted
    /// models keep working; a value the launch grammar rejects (whitespace,
    /// leading `-`) falls back to the agent default rather than reaching the
    /// shell malformed.
    @Parameter(
        title: "Model",
        // Literal for the same reason as the other descriptions here.
        // swiftlint:disable:next line_length
        description: "Launches the agent with --model set to this value. Configure choices in Multiplex's Host Settings; leave empty for the agent's default model.",
        optionsProvider: AgentModelOptionsProvider()
    ) var model: String?
    /// Optional so Shortcuts users can leave it off or set "Ask Each Time";
    /// sent as the agent's shell-quoted launch argument.
    @Parameter(title: "First Prompt") var prompt: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$agent) on \(\.$host)") {
            \.$session
            \.$placement
            \.$directory
            \.$setupScript
            \.$model
            \.$prompt
        }
    }

    @Dependency private var router: ExternalActionRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        let kind = AgentKind(rawValue: agent.rawValue) ?? .claudeCode
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let script = ShortcutSetupScriptOptions.selection(for: setupScript)
        let launchModel = model.flatMap(AgentKind.normalizedLaunchModel)
        let sessionName = session?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target: ExternalSessionTarget = sessionName.isEmpty
            ? .newSession
            : .existingSession(
                name: sessionName,
                placement: placement
                    .flatMap(ExternalSessionPlacement.init(token:)) ?? .tab)
        router.submit(.openAgent(
            host: .id(host.id),
            agent: kind,
            prompt: text.isEmpty ? nil : text,
            askForPrompt: false,
            directory: path.isEmpty ? nil : path,
            setupScript: script,
            model: launchModel,
            target: target
        ))
        return .result()
    }
}

/// A host-dependent String picker keeps Shortcut setup aligned with the same
/// ordered working-directory list used by New Session. The value remains a
/// String so Shortcuts can also supply variables; only the suggested choices
/// are constrained.
struct AgentWorkingDirectoryOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenHostAgentIntent>(\.$host)
    private var intent

    func results() async throws -> IntentItemCollection<String> {
        let hosts = await HostEntityProvider.all()
        let configured = hosts.first { $0.id == intent?.host.id }?.workingDirs ?? []
        let values = ShortcutWorkingDirectoryOptions.values(configured: configured)
        var items: [IntentItem<String>] = values.dropLast().map { IntentItem($0) }
        items.append(IntentItem("~", title: "Home"))
        return IntentItemCollection(
            promptLabel: "Choose a working directory",
            sections: [IntentItemSection(items: items)]
        )
    }
}

/// The host's pre-configured launch models for the selected agent, as
/// Shortcut suggestions. Same shared choice builder as the widget's Model
/// setting, so both surfaces offer identical rows.
struct AgentModelOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenHostAgentIntent>(\.$host, \.$agent)
    private var intent

    func results() async throws -> IntentItemCollection<String> {
        let hosts = await HostEntityProvider.all()
        let configured = intent.flatMap { dependency in
            hosts.first { $0.id == dependency.host.id }?
                .agentModels[dependency.agent.rawValue]
        } ?? []
        // Same never-empty rule as the widget's provider: the leading
        // Agent Default row keeps the picker presentable with nothing
        // configured, and its empty value normalizes to "no model".
        let items = AgentModelChoices.choices(configured: configured)
            .map { IntentItem($0.value, title: "\($0.title)") }
        return IntentItemCollection(
            promptLabel: "Choose a model",
            sections: [IntentItemSection(items: items)]
        )
    }
}

/// The host's last-known sessions from the published App Group snapshot —
/// the same list the widget renders (sessions are probe state, so the
/// snapshot is the one store both processes can read). Names only; the
/// performer revalidates against the live probe before anything types.
struct AgentSessionOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenHostAgentIntent>(\.$host)
    private var intent

    func results() async throws -> IntentItemCollection<String> {
        let names = (SharedStateStore.load()?.hosts ?? [])
            .first { $0.id == intent?.host.id }?
            .sessions.map(\.name) ?? []
        // Same never-empty rule as every provider here: New Session leads.
        let items = SessionTargetChoices.sessionChoices(names: names)
            .map { IntentItem($0.value, title: "\($0.title)") }
        return IntentItemCollection(
            promptLabel: "Choose a session",
            sections: [IntentItemSection(items: items)]
        )
    }
}

/// Placement rows in the selected host's backend vocabulary — tmux's one
/// honest "New Window" row, or herdr's tab/workspace split. Shared builder
/// with the widget's provider so both surfaces offer identical rows.
struct AgentPlacementOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenHostAgentIntent>(\.$host)
    private var intent

    func results() async throws -> IntentItemCollection<String> {
        let hosts = await HostEntityProvider.all()
        let backend = hosts.first { $0.id == intent?.host.id }?.backendRaw
        let items = SessionTargetChoices.placementChoices(backendRaw: backend)
            .map { IntentItem($0.value, title: "\($0.title)") }
        return IntentItemCollection(
            promptLabel: "Choose where the agent opens",
            sections: [IntentItemSection(items: items)]
        )
    }
}

/// A second host-dependent picker exposes only names and ids. Script bodies
/// never become Shortcut parameter values; the router resolves the id against
/// the live Host immediately before it creates the remote session.
struct AgentSetupScriptOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenHostAgentIntent>(\.$host)
    private var intent

    func results() async throws -> IntentItemCollection<String> {
        let hosts = await HostEntityProvider.all()
        let configured = hosts.first { $0.id == intent?.host.id }?.sessionScripts ?? []
        let items = ShortcutSetupScriptOptions.choices(configured: configured).map {
            IntentItem($0.value, title: "\($0.title)")
        }
        return IntentItemCollection(
            promptLabel: "Choose a setup script",
            sections: [IntentItemSection(items: items)]
        )
    }
}

/// Pure option ordering and token validation behind the dynamic provider.
/// Invalid variable input resolves to None — never to arbitrary text that
/// could be typed into the remote shell.
enum ShortcutSetupScriptOptions {
    struct Choice: Equatable {
        var value: String
        var title: String
    }

    static func choices(configured: [ShortcutSessionScript]) -> [Choice] {
        var choices = [
            Choice(
                value: ExternalSetupScriptSelection.rememberedToken,
                title: "New Session Default"
            ),
            Choice(
                value: ExternalSetupScriptSelection.noneToken,
                title: "None"
            ),
        ]
        var seen = Set<UUID>()
        for script in configured where seen.insert(script.id).inserted {
            let name = script.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            choices.append(Choice(
                value: script.id.uuidString,
                title: name.isEmpty ? "Script" : name
            ))
        }
        return choices
    }

    static func selection(for value: String?) -> ExternalSetupScriptSelection {
        guard let value else { return .remembered }
        return ExternalSetupScriptSelection(token: value) ?? .none
    }
}

struct MultiplexShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenHostShellIntent(),
            phrases: [
                "Open a \(.applicationName) shell",
                "Open a shell in \(.applicationName)",
                "Open a \(.applicationName) shell on \(\.$host)",
            ],
            shortTitle: "Open Shell",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: OpenHostAgentIntent(),
            phrases: [
                "Start an agent in \(.applicationName)",
                "Start a \(.applicationName) agent on \(\.$host)",
            ],
            shortTitle: "Open Agent",
            systemImageName: "sparkles"
        )
    }
}
