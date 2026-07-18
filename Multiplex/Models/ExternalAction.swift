import Foundation

/// A host named from outside the app. Widgets and intents carry the stable
/// UUID; hand-typed URLs (and the dev harness) may use the display name,
/// resolved case-insensitively against the store at perform time.
enum ExternalHostRef: Hashable {
    case id(UUID)
    case named(String)

    /// What a not-found failure calls the host.
    var displayName: String {
        switch self {
        case .id: "Host"
        case .named(let name): name
        }
    }
}

/// An externally requested app action — the payload behind the `multiplex://`
/// URL scheme (widget taps, automation) and the App Intents. The queue and
/// execution live in `ExternalActionRouter`; this file stays pure so the URL
/// codec and planning helpers are unit-testable.
enum ExternalAction: Hashable {
    /// Attach a tmux session on the host. A named session (a fleet tile's
    /// tap) is attached exactly when it still exists; nil — or a session
    /// that died since the widget snapshot — falls back to the most recent,
    /// creating one if none exist.
    case openShell(host: ExternalHostRef, sessionName: String?)
    /// Mint a detached tmux session launching the agent — optionally with a
    /// first prompt as its shell-quoted launch argument — then attach it.
    /// `askForPrompt` presents the in-app prompt sheet first (the widget's
    /// ASK mode); the sheet resubmits with the entered prompt and its
    /// working-directory choice. `directory` semantics: nil = the host's
    /// default (first working dir), `"~"` = explicitly home (the quoting
    /// layer expands it to `$HOME`), anything else = that path.
    case openAgent(
        host: ExternalHostRef, agent: AgentKind, prompt: String?,
        askForPrompt: Bool, directory: String?)

    var hostRef: ExternalHostRef {
        switch self {
        case .openShell(let host, _): host
        case .openAgent(let host, _, _, _, _): host
        }
    }
}

/// `multiplex://open?host=<uuid|name>&action=shell|agent[&agent=<kind>]
/// [&prompt=<text>][&ask=1]` — built by widgets, parsed by `onOpenURL`.
enum ExternalActionURL {
    static let scheme = "multiplex"
    static let authority = "open"

    static func url(for action: ExternalAction) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = authority
        var items = [hostItem(for: action.hostRef)]
        switch action {
        case .openShell(_, let sessionName):
            items.append(URLQueryItem(name: "action", value: "shell"))
            if let sessionName, !sessionName.isEmpty {
                items.append(URLQueryItem(name: "session", value: sessionName))
            }
        case .openAgent(_, let agent, let prompt, let askForPrompt, let directory):
            items.append(URLQueryItem(name: "action", value: "agent"))
            items.append(URLQueryItem(name: "agent", value: agent.rawValue))
            if let prompt, !prompt.isEmpty {
                items.append(URLQueryItem(name: "prompt", value: prompt))
            }
            if askForPrompt {
                items.append(URLQueryItem(name: "ask", value: "1"))
            }
            if let directory, !directory.isEmpty {
                items.append(URLQueryItem(name: "dir", value: directory))
            }
        }
        components.queryItems = items
        // These components always form a valid URL; the fallback is inert.
        return components.url ?? URL(string: "\(scheme)://\(authority)")!
    }

    static func action(from url: URL) -> ExternalAction? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == authority
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let hostToken = value("host"), !hostToken.isEmpty else { return nil }
        let hostRef = UUID(uuidString: hostToken).map(ExternalHostRef.id)
            ?? .named(hostToken)

        switch value("action")?.lowercased() ?? "shell" {
        case "shell":
            let sessionName = value("session").flatMap { $0.isEmpty ? nil : $0 }
            return .openShell(host: hostRef, sessionName: sessionName)
        case "agent":
            let agent = value("agent").flatMap(agentKind) ?? .claudeCode
            let prompt = value("prompt").flatMap { $0.isEmpty ? nil : $0 }
            let ask = ["1", "true", "yes"]
                .contains(value("ask")?.lowercased() ?? "")
            let directory = value("dir").flatMap { $0.isEmpty ? nil : $0 }
            return .openAgent(
                host: hostRef, agent: agent, prompt: prompt,
                askForPrompt: ask, directory: directory)
        default:
            return nil
        }
    }

    /// Accepts the enum's rawValue and the launch-command spelling
    /// ("claudeCode" and "claude" alike), case-insensitively.
    static func agentKind(_ raw: String) -> AgentKind? {
        let token = raw.lowercased()
        return AgentKind.allCases.first {
            $0.rawValue.lowercased() == token || $0.launchCommand == token
        }
    }

    private static func hostItem(for ref: ExternalHostRef) -> URLQueryItem {
        switch ref {
        case .id(let id): URLQueryItem(name: "host", value: id.uuidString)
        case .named(let name): URLQueryItem(name: "host", value: name)
        }
    }
}

/// Pure planning helpers for external actions.
enum ExternalActionPlan {
    /// The session an "open shell" targets: the newest by creation date,
    /// name-ordered on a tie so the choice is deterministic.
    static func mostRecentSessionName(in sessions: [TmuxSession]) -> String? {
        sessions.max { lhs, rhs in
            (lhs.created, lhs.name) < (rhs.created, rhs.name)
        }?.name
    }
}

/// The in-app "ask for the first prompt" sheet's payload (widget ASK mode).
/// `directory` seeds the sheet's Starts-in picker with whatever the
/// originating action carried (same nil/`"~"`/path semantics as the action).
struct AgentPromptRequest: Identifiable {
    let id = UUID()
    var host: Host
    var agent: AgentKind
    var directory: String?
}

/// What the deck's failure alert shows when an external action can't run.
struct ExternalActionFailure: Equatable {
    /// The host's display name, or a generic noun when resolution failed.
    var hostName: String
    var message: String
}
