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
        "Starts a CLI agent in a fresh tmux session on the host — optionally already working on a first prompt.",
        categoryName: "Terminal"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Agent", default: .claudeCode) var agent: AgentChoice
    /// Optional so Shortcuts users can leave it off or set "Ask Each Time";
    /// sent as the agent's shell-quoted launch argument.
    @Parameter(title: "First Prompt") var prompt: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$agent) on \(\.$host)") {
            \.$prompt
        }
    }

    @Dependency private var router: ExternalActionRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        let kind = AgentKind(rawValue: agent.rawValue) ?? .claudeCode
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        router.submit(.openAgent(
            host: .id(host.id),
            agent: kind,
            prompt: text.isEmpty ? nil : text,
            askForPrompt: false,
            directory: nil
        ))
        return .result()
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
