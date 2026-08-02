import Foundation
import Observation

/// One queue for actions arriving from outside the app — widget deep links,
/// the `multiplex://` scheme, and App Intents. Actions are performed by the
/// mounted deck (`DeckWindow` attaches a `Context` carrying its stores and
/// its mode-correct `TerminalRouteOpener` closure), so classic windows and
/// the single-window shell reuse the exact seams the Attach button drives.
/// Submissions queue until a context exists; a scene root that sees pending
/// work without a context raises the one deck scene to mount it.
@MainActor
@Observable
final class ExternalActionRouter {
    /// One process-wide router: App Intents resolve it through
    /// `AppDependencyManager` before any scene exists, and SwiftUI's `App`
    /// struct may be re-initialized — a per-init instance could leave the
    /// dependency manager pointing at an orphan while `@State` kept the
    /// original.
    static let shared = ExternalActionRouter()

    struct Context {
        var store: HostStore
        var hub: ConnectionHub
        var workspace: TerminalWorkspace
        var open: (TerminalWindowRoute) -> Void
        var presentAgentPrompt: (AgentPromptRequest) -> Void
        var presentFailure: (ExternalActionFailure) -> Void
    }

    /// Bumped on every submit — the scene roots' raise-the-deck trigger.
    private(set) var pendingSignal = 0
    private(set) var hasContext = false

    @ObservationIgnored private var queue: [ExternalAction] = []
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var contextToken: UUID?
    @ObservationIgnored private var drainTask: Task<Void, Never>?

    /// A newly resolved terminal-only scene uses this to recover work that
    /// arrived while UIKit was still withholding its restoration payload.
    /// `pendingSignal` alone is historical and cannot distinguish queued work
    /// from an action a Deck already drained.
    var hasPendingActions: Bool { !queue.isEmpty }

    func submit(_ action: ExternalAction) {
        queue.append(action)
        pendingSignal &+= 1
        drainIfReady()
    }

    /// The mounted deck registers itself as the executor. Last writer wins:
    /// a shell's nested deck and a classic deck never coexist, and the token
    /// keeps a stale `detach` (from a disappearing duplicate) from clearing
    /// the live context.
    @discardableResult
    func attach(_ context: Context) -> UUID {
        let token = UUID()
        self.context = context
        contextToken = token
        hasContext = true
        drainIfReady()
        return token
    }

    func detach(_ token: UUID) {
        guard contextToken == token else { return }
        context = nil
        contextToken = nil
        hasContext = false
    }

    private func drainIfReady() {
        guard drainTask == nil, context != nil, !queue.isEmpty else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
            guard let self else { return }
            self.drainTask = nil
            // A submit that landed while the last action was performing
            // found drainTask non-nil; pick it up now.
            self.drainIfReady()
        }
    }

    private func drain() async {
        while let context, !queue.isEmpty {
            let action = queue.removeFirst()
            await ExternalActionPerformer.perform(action, context: context)
        }
    }
}

/// Executes one external action against the live app graph. Reuses the
/// existing user-action seams only: `refreshAndWait` + `phase` as the
/// connection status guard, `TerminalWorkspace.focusTab` for reveal-instead-
/// of-duplicate, and `HostConnectionModel.createSession` (the New Session
/// sheet's path) for minting shell and agent sessions.
@MainActor
enum ExternalActionPerformer {
    static func perform(_ action: ExternalAction, context: ExternalActionRouter.Context) async {
        guard let host = resolveHost(action.hostRef, in: context.store) else {
            context.presentFailure(ExternalActionFailure(
                hostName: action.hostRef.displayName,
                message: "No configured host matches this shortcut. Pick a host in the widget or shortcut settings."
            ))
            return
        }
        // A widget tile or Shortcut can outlive the switch being turned off.
        // Say so instead of dialling a host the user has taken off the air —
        // and instead of the resolution message above, which would blame the
        // shortcut for a host that is right there on the deck.
        guard host.isEnabled else {
            context.presentFailure(ExternalActionFailure(
                hostName: host.name,
                message: "\(host.name) is disabled. Enable it on the deck to open sessions on it."
            ))
            return
        }
        switch action {
        case .openShell(_, let sessionName):
            await openShell(on: host, requestedSession: sessionName, context: context)
        case .openAgent(
            _, let agent, let prompt, let askForPrompt, let directory,
            let setupScript, let model
        ):
            if askForPrompt {
                context.presentAgentPrompt(AgentPromptRequest(
                    host: host,
                    agent: agent,
                    directory: directory,
                    setupScript: setupScript,
                    model: model
                ))
                return
            }
            await openAgent(
                agent,
                prompt: prompt,
                directory: directory,
                setupScript: setupScript,
                model: model,
                on: host,
                context: context
            )
        }
    }

    static func resolveHost(_ ref: ExternalHostRef, in store: HostStore) -> Host? {
        switch ref {
        case .id(let id):
            return store.host(id: id)
        case .named(let name):
            return store.hosts.first { $0.name == name }
                ?? store.hosts.first { $0.name.lowercased() == name.lowercased() }
        }
    }

    private static func openShell(
        on host: Host, requestedSession: String?,
        context: ExternalActionRouter.Context
    ) async {
        guard let model = await connectedModel(for: host, context: context) else { return }
        let sessions = model.tmux.sessions
        // A widget tile names the exact session it showed; a session that
        // died since that snapshot falls back to the most recent (fail-soft,
        // same spirit as the deck's tiles resurrecting from a live probe).
        let requested = requestedSession.flatMap { name in
            sessions.first { $0.name == name }?.name
        }
        if let target = requested ?? ExternalActionPlan.mostRecentSessionName(in: sessions) {
            if context.workspace.focusTab(hostID: host.id, sessionName: target) { return }
            open(mode: .attach(host: host, sessionName: target), on: host, context: context)
        } else {
            // Headless creation inherits the New Session sheet's remembered
            // setup script (nil unless its REMEMBER opt-in is on) — a widget
            // tap must not produce a lesser session than the sheet would.
            guard let created = await model.createSession(
                base: "main",
                inDirectoryOf: nil,
                startingIn: host.workingDirs.first,
                applying: host.newSessionTmuxConf,
                running: NewSessionPreferences().rememberedScript(for: host)?.normalizedBody,
                typing: nil
            ) else {
                presentCreateFailure(for: model, host: host, context: context)
                return
            }
            open(mode: created, on: host, context: context)
        }
    }

    private static func openAgent(
        _ agent: AgentKind,
        prompt: String?,
        directory: String?,
        setupScript: ExternalSetupScriptSelection,
        model launchModel: String?,
        on host: Host,
        context: ExternalActionRouter.Context
    ) async {
        // v1.3 fence: a widget/Shortcut agent launch on a herdr-backend
        // host refuses with its own sentence instead of half-working —
        // attach and focus flows above stay live.
        guard host.sessionBackend == .tmux else {
            context.presentFailure(ExternalActionFailure(
                hostName: host.name,
                message: "Agent launch isn't available on herdr hosts yet — "
                    + "attach and start the agent in its workspace."
            ))
            return
        }
        guard let model = await connectedModel(for: host, context: context) else { return }
        // nil = the host's default working dir; the sheet's explicit Home
        // choice arrives as "~", which the quoting layer expands to $HOME.
        // The Shortcut picker can select a stable script id, explicitly opt
        // out, or preserve the remembered New Session choice. The launch
        // model stays binary — carried or the agent's default — so the same
        // widget/Shortcut behaves identically on every device.
        let script = ExternalActionPlan.setupScript(
            for: setupScript,
            available: host.sessionScripts,
            remembered: NewSessionPreferences().rememberedScript(for: host)
        )
        guard let created = await model.createSession(
            base: agent.launchCommand,
            inDirectoryOf: nil,
            startingIn: directory ?? host.workingDirs.first,
            applying: host.newSessionTmuxConf,
            running: script?.normalizedBody,
            typing: agent.launchCommand(model: launchModel, initialPrompt: prompt ?? "")
        ) else {
            presentCreateFailure(for: model, host: host, context: context)
            return
        }
        open(mode: created, on: host, context: context)
    }

    /// The status guard: one fresh (or joined in-flight) probe, then the
    /// settled phase decides. `ensureConnection` already rebuilds links
    /// severed by suspension, and the probe's own deadlines bound the wait.
    private static func connectedModel(
        for host: Host, context: ExternalActionRouter.Context
    ) async -> HostConnectionModel? {
        let model = context.hub.model(for: host)
        model.resetConnectRetryBackoff()
        await model.refreshAndWait(ifStaleFor: 0)
        guard model.phase == .connected else {
            context.presentFailure(ExternalActionFailure(
                hostName: host.name,
                message: failureMessage(for: model.phase, host: host)
            ))
            return nil
        }
        return model
    }

    private static func open(
        mode: TerminalRoute.Mode, on host: Host, context: ExternalActionRouter.Context
    ) {
        context.open(TerminalWindowRoute(tab: TerminalRoute(hostID: host.id, mode: mode)))
    }

    private static func presentCreateFailure(
        for model: HostConnectionModel, host: Host,
        context: ExternalActionRouter.Context
    ) {
        // createSession marks the host failed when the control link is the
        // problem; reuse that reason when it exists.
        let message: String
        if case .failed(let reason) = model.phase {
            message = reason
        } else {
            message = "Couldn't create the session on \(host.name)."
        }
        context.presentFailure(ExternalActionFailure(hostName: host.name, message: message))
    }

    private static func failureMessage(for phase: HostConnectionModel.Phase, host: Host) -> String {
        switch phase {
        case .failed(let reason): reason
        default: "Couldn't reach \(host.name). No response."
        }
    }
}
