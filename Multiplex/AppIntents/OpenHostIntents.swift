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
        "Starts a CLI agent in a fresh tmux session, with an optional working directory, setup script, and first prompt.",
        categoryName: "Terminal"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Agent", default: .claudeCode) var agent: AgentChoice
    /// Options follow the selected host's configured paths. An unset value
    /// uses its first configured directory (or Home when it has none).
    @Parameter(
        title: "Working Directory",
        description: "Where the new session starts. Leave empty for the host default.",
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
    /// Optional so Shortcuts users can leave it off or set "Ask Each Time";
    /// sent as the agent's shell-quoted launch argument.
    @Parameter(title: "First Prompt") var prompt: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$agent) on \(\.$host)") {
            \.$directory
            \.$setupScript
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
        router.submit(.openAgent(
            host: .id(host.id),
            agent: kind,
            prompt: text.isEmpty ? nil : text,
            askForPrompt: false,
            directory: path.isEmpty ? nil : path,
            setupScript: script
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

/// Pure ordering/normalization behind the dynamic provider.
enum ShortcutWorkingDirectoryOptions {
    static func values(configured: [String]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for raw in configured {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path != "~", seen.insert(path).inserted else { continue }
            values.append(path)
        }
        values.append("~")
        return values
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
