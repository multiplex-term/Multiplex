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

/// Which host setup script an external agent launch runs before the agent.
/// The default preserves the New Session sheet's remembered choice; `none`
/// is a deliberate override, and ids survive script renames. A deleted id
/// fails soft to no script rather than falling back to a different command.
enum ExternalSetupScriptSelection: Hashable {
    case remembered
    case none
    case id(UUID)

    static let rememberedToken = "default"
    static let noneToken = "none"

    init?(token rawValue: String) {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch token.lowercased() {
        case "", Self.rememberedToken, "remembered":
            self = .remembered
        case Self.noneToken:
            self = .none
        default:
            guard let id = UUID(uuidString: token) else { return nil }
            self = .id(id)
        }
    }

    /// Canonical URL/Shortcut token. Remembered is represented by omission
    /// in URLs so existing widget links keep the same behavior.
    var token: String? {
        switch self {
        case .remembered: nil
        case .none: Self.noneToken
        case .id(let id): id.uuidString
        }
    }
}

/// Where an external agent launch lands. The default mints a fresh session
/// (the original behavior); an existing-session target opens the agent
/// *inside* that session instead — tmux as a new window, herdr as a new tab
/// in the focused workspace or a new workspace, per the placement. The name
/// is resolved against the host's probe list at perform time: a session that
/// died since the widget/Shortcut was configured falls back to the fresh-
/// session mint (fail-soft, the openShell rule), while an in-session create
/// that fails stays a visible failure — minting a surprise second session
/// would hide it.
enum ExternalSessionTarget: Hashable {
    case newSession
    case existingSession(name: String, placement: ExternalSessionPlacement)
}

/// How an agent lands inside an existing session. tmux has exactly one
/// granularity below a session — both spellings open a new window — while
/// herdr distinguishes a new tab in the session's focused workspace from a
/// whole new workspace. Tokens ride URLs and Shortcut values: `tab` (the
/// omitted default), `workspace`, and `window` — the adapter maps herdr
/// workspace → window, so the tmux-natural spelling lands on the workspace
/// branch.
enum ExternalSessionPlacement: String, Hashable {
    case tab
    case workspace

    init?(token: String) {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", Self.tab.rawValue: self = .tab
        case Self.workspace.rawValue, "window": self = .workspace
        default: return nil
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
    /// `backend` names which multiplexer the session belongs to; nil means
    /// the host's default, which is what every URL, widget, and Shortcut
    /// written before a host could show two means — and still the only
    /// answer a single-backend host has.
    case openShell(
        host: ExternalHostRef, sessionName: String?,
        backend: Host.SessionBackend? = nil)
    /// Mint a detached tmux session launching the agent — optionally with a
    /// first prompt as its shell-quoted launch argument — then attach it.
    /// `askForPrompt` presents the in-app prompt sheet first (the widget's
    /// ASK mode); the sheet resubmits with the entered prompt, directory,
    /// model, and setup-script choice. `directory` semantics: nil = the
    /// host's default (first working dir), `"~"` = explicitly home (the
    /// quoting layer expands it to `$HOME`), anything else = that path.
    /// `model` rides the launch as `--model <value>`; nil — including any
    /// value `AgentKind.normalizedLaunchModel` rejects — means the agent's
    /// own default, never the New Session sheet's remembered choice (an
    /// automation without a model must behave the same on every device).
    /// `target` picks where the launch lands (`ExternalSessionTarget`):
    /// a fresh session, or inside an existing one.
    /// `backend` picks the multiplexer: which one a fresh session is minted
    /// on, and which namespace an `existingSession` target is resolved in.
    /// nil is the host's default (see `openShell`).
    case openAgent(
        host: ExternalHostRef, agent: AgentKind, prompt: String?,
        askForPrompt: Bool, directory: String?,
        setupScript: ExternalSetupScriptSelection, model: String?,
        target: ExternalSessionTarget, backend: Host.SessionBackend? = nil)

    /// Whether an untrusted (non-widget) URL has to be confirmed before this
    /// runs. The widget's ASK mode is exempt: it presents the prompt sheet,
    /// which names the host and agent and discards the URL's own prompt in
    /// favour of what the person types — an in-app confirmation already.
    var needsOriginConfirmation: Bool {
        switch self {
        case .openShell: true
        case .openAgent(_, _, _, let askForPrompt, _, _, _, _, _): !askForPrompt
        }
    }

    var hostRef: ExternalHostRef {
        switch self {
        case .openShell(let host, _, _): host
        case .openAgent(let host, _, _, _, _, _, _, _, _): host
        }
    }
}

/// `multiplex://open?host=<uuid|name>&action=shell|agent[&agent=<kind>]
/// [&prompt=<text>][&ask=1][&dir=<path>][&script=<uuid|none>][&model=<id>]
/// [&session=<name>][&in=tab|workspace|window]`
/// — built by widgets, parsed by `onOpenURL`. Omitting `script` uses the
/// remembered New Session choice; omitting `model` uses the agent's own
/// default (a malformed model token also parses as omitted — fail-soft, the
/// setup-script id stays the one strict token because a wrong script runs
/// arbitrary text). On `action=agent`, `session` targets an existing
/// session (omitted = mint a fresh one) and `in` picks the placement
/// inside it — a malformed token reads as the tab default, fail-soft like
/// `model`, because the performer validates the name against the live
/// session list anyway.
enum ExternalActionURL {
    static let scheme = "multiplex"
    static let authority = "open"

    static func url(for action: ExternalAction) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = authority
        var items = [hostItem(for: action.hostRef)]
        switch action {
        case .openShell(_, let sessionName, let backend):
            items.append(URLQueryItem(name: "action", value: "shell"))
            if let sessionName, !sessionName.isEmpty {
                items.append(URLQueryItem(name: "session", value: sessionName))
            }
            if let backend {
                items.append(URLQueryItem(name: "backend", value: backend.rawValue))
            }
        case .openAgent(
            _, let agent, let prompt, let askForPrompt, let directory,
            let setupScript, let model, let target, let backend
        ):
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
            if let token = setupScript.token {
                items.append(URLQueryItem(name: "script", value: token))
            }
            if let model, !model.isEmpty {
                items.append(URLQueryItem(name: "model", value: model))
            }
            if case .existingSession(let name, let placement) = target {
                items.append(URLQueryItem(name: "session", value: name))
                items.append(URLQueryItem(name: "in", value: placement.rawValue))
            }
            // Omitted for the default, so every link written before mixed
            // hosts keeps its exact bytes and its exact meaning.
            if let backend {
                items.append(URLQueryItem(name: "backend", value: backend.rawValue))
            }
        }
        components.queryItems = items
        // These components always form a valid URL; the fallback is inert.
        return components.url ?? URL(string: "\(scheme)://\(authority)")!
    }

    /// One parsed URL: what it asks for, and whether it proved it came from
    /// this install's own widget (`WidgetLink.tokenItemName`). The scheme is
    /// public and a URL carries no origin, so the token is the only thing
    /// that distinguishes a widget tap from a link another app, a web page,
    /// or a message composed — `ExternalActionTrust` makes that call and the
    /// untrusted case is confirmed in-app before it runs.
    struct Request: Equatable {
        var action: ExternalAction
        var token: String?
    }

    static func request(from url: URL) -> Request? {
        guard let action = action(from: url) else { return nil }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == WidgetLink.tokenItemName }?
            .value
        return Request(action: action, token: token?.isEmpty == true ? nil : token)
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
        // Fail-soft like `model` and `in`: an unknown token reads as the
        // host's default rather than failing the whole action, and the
        // performer validates the resolved backend against the host's live
        // record anyway.
        func backend() -> Host.SessionBackend? {
            Host.SessionBackend(token: value("backend"))
        }
        guard let hostToken = value("host"), !hostToken.isEmpty else { return nil }
        let hostRef = UUID(uuidString: hostToken).map(ExternalHostRef.id)
            ?? .named(hostToken)

        switch value("action")?.lowercased() ?? "shell" {
        case "shell":
            let sessionName = value("session").flatMap { $0.isEmpty ? nil : $0 }
            return .openShell(
                host: hostRef, sessionName: sessionName, backend: backend())
        case "agent":
            let agent = value("agent").flatMap(agentKind) ?? .claudeCode
            let prompt = value("prompt").flatMap { $0.isEmpty ? nil : $0 }
            let ask = ["1", "true", "yes"]
                .contains(value("ask")?.lowercased() ?? "")
            let directory = value("dir").flatMap { $0.isEmpty ? nil : $0 }
            let setupScript: ExternalSetupScriptSelection
            if let token = value("script") {
                guard let parsed = ExternalSetupScriptSelection(token: token)
                else { return nil }
                setupScript = parsed
            } else {
                setupScript = .remembered
            }
            let model = value("model").flatMap(AgentKind.normalizedLaunchModel)
            let target: ExternalSessionTarget
            if let session = value("session"), !session.isEmpty {
                target = .existingSession(
                    name: session,
                    placement: value("in")
                        .flatMap(ExternalSessionPlacement.init(token:)) ?? .tab)
            } else {
                target = .newSession
            }
            return .openAgent(
                host: hostRef, agent: agent, prompt: prompt,
                askForPrompt: ask, directory: directory,
                setupScript: setupScript, model: model, target: target,
                backend: backend())
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
    ///
    /// Returns the RECORD, not the name: on a mixed host the candidate list
    /// spans two namespaces, and re-finding the winner by name would resolve
    /// to whichever backend's namesake sorts first — the exact ambiguity
    /// `SessionKey` exists to abolish. The attach needs `backend` anyway.
    ///
    /// Mirrored by `WidgetHostState.mostRecentSession`, which the widget
    /// process computes over its own projection; `SharedStateTests` pins the
    /// two to the same answer.
    static func mostRecentSession(in sessions: [TmuxSession]) -> TmuxSession? {
        sessions.max { lhs, rhs in
            (lhs.created, lhs.name) < (rhs.created, rhs.name)
        }
    }

    /// Resolve only against the chosen host's current scripts. A stale
    /// explicit id means no script; it must never silently run the remembered
    /// script or another script that later reused the same display name.
    static func setupScript(
        for selection: ExternalSetupScriptSelection,
        available: [SessionScript],
        remembered: SessionScript?
    ) -> SessionScript? {
        switch selection {
        case .remembered:
            guard let remembered else { return nil }
            return available.first { $0.id == remembered.id }
        case .none:
            return nil
        case .id(let id):
            return available.first { $0.id == id }
        }
    }
}

/// The in-app "ask for the first prompt" sheet's payload (widget ASK mode).
/// `directory` and `model` seed the sheet's fields with whatever the
/// originating action carried (same nil/`"~"`/path semantics as the action);
/// `target` rides through untouched and the sheet's title names it, so an
/// existing-session launch is visible in what the person approves.
struct AgentPromptRequest: Identifiable {
    let id = UUID()
    var host: Host
    var agent: AgentKind
    var directory: String?
    var setupScript: ExternalSetupScriptSelection
    var model: String?
    var target: ExternalSessionTarget = .newSession
    /// The multiplexer the approved launch runs on — carried through
    /// untouched like `target`, because the sheet rebuilds the action and
    /// anything it does not hold is silently re-defaulted to the host's
    /// primary. On a mixed host that would land the launch on the other
    /// backend than the one the widget was configured for.
    var backend: Host.SessionBackend?
}

/// Whether a parsed `multiplex://` URL may run without asking. Pure so the
/// rule is unit-testable: a link is trusted exactly when it carries this
/// install's App Group token. No token, a stale token, or an app with no
/// token yet all mean "ask" — never "refuse", because the URL may well be
/// the user's own automation.
enum ExternalActionTrust {
    static func isTrusted(token: String?, expected: String?) -> Bool {
        guard let token, let expected, !expected.isEmpty else { return false }
        return token == expected
    }
}

/// The in-app confirmation an untrusted external action raises before it
/// touches a host. Pure text so the wording is unit-testable; the action it
/// carries is resubmitted (trusted) when the person approves.
struct ExternalActionConfirmation: Equatable {
    var title: String
    var message: String
    var action: ExternalAction

    /// `host` is the resolved record — the confirmation names the machine
    /// this will actually run on, never the token the URL used for it.
    static func make(for action: ExternalAction, hostName: String) -> ExternalActionConfirmation {
        switch action {
        case .openShell(_, let sessionName, _):
            let target = sessionName.map { "session \($0)" } ?? "a session"
            return ExternalActionConfirmation(
                title: "Open \(hostName)?",
                message: """
                    Something outside Multiplex asked to open \(target) on \
                    \(hostName). Open it only if you started this.
                    """,
                action: action
            )
        case .openAgent(_, let agent, let prompt, _, _, _, _, let target, _):
            // An existing-session target is part of what the person approves:
            // the launch types into that session, not a fresh one.
            var location = hostName
            if case .existingSession(let name, _) = target {
                location = "\(hostName) in session \(name)"
            }
            var message = """
                Something outside Multiplex asked to launch \
                \(agent.displayName) on \(location)
                """
            if let prompt, !prompt.isEmpty {
                message += " with this first prompt:\n\n\(prompt)"
            } else {
                message += "."
            }
            message += "\n\nRun it only if you started this."
            return ExternalActionConfirmation(
                title: "Launch \(agent.displayName) on \(hostName)?",
                message: message,
                action: action
            )
        }
    }
}

/// What the deck's failure alert shows when an external action can't run.
struct ExternalActionFailure: Equatable {
    /// The host's display name, or a generic noun when resolution failed.
    var hostName: String
    var message: String
}
