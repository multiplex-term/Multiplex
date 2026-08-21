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
        var presentConfirmation: (ExternalActionConfirmation) -> Void
    }

    /// Bumped on every submit — the scene roots' raise-the-deck trigger.
    private(set) var pendingSignal = 0
    private(set) var hasContext = false

    @ObservationIgnored private var queue: [(action: ExternalAction, trusted: Bool)] = []
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var contextToken: UUID?
    @ObservationIgnored private var drainTask: Task<Void, Never>?

    /// A newly resolved terminal-only scene uses this to recover work that
    /// arrived while UIKit was still withholding its restoration payload.
    /// `pendingSignal` alone is historical and cannot distinguish queued work
    /// from an action a Deck already drained.
    var hasPendingActions: Bool { !queue.isEmpty }

    /// The app lock holds the queue. Actions arrive from outside the app —
    /// a widget tap, a Shortcut, a `multiplex://` URL any other app can
    /// open — and performing one connects to a host, mints a tmux session,
    /// runs the host's setup script, and types an agent prompt. None of that
    /// may happen behind the veil: the veil's promise is that the device
    /// owner authenticates before this app acts on their hosts. Work waits
    /// (it is not dropped) and drains on unlock.
    var isHeldByAppLock = false {
        didSet {
            guard isHeldByAppLock != oldValue, !isHeldByAppLock else { return }
            drainIfReady()
        }
    }

    /// `trusted` is the URL-origin verdict (`ExternalActionTrust`). App
    /// Intents, the agent-prompt sheet's resubmit, and the confirmation's own
    /// approval are trusted by construction — the person ran them from inside
    /// the app. A `multiplex://` URL is trusted only when it carries this
    /// install's widget token; everything else is confirmed first.
    func submit(_ action: ExternalAction, trusted: Bool = true) {
        queue.append((action, trusted))
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
        guard drainTask == nil, context != nil, !queue.isEmpty,
              !isHeldByAppLock else { return }
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
        while let context, !queue.isEmpty, !isHeldByAppLock {
            let entry = queue.removeFirst()
            await ExternalActionPerformer.perform(
                entry.action, trusted: entry.trusted, context: context)
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
    static func perform(
        _ action: ExternalAction,
        trusted: Bool = true,
        context: ExternalActionRouter.Context
    ) async {
        guard let host = resolveHost(action.hostRef, in: context.store) else {
            context.presentFailure(ExternalActionFailure(
                hostName: action.hostRef.displayName,
                message: String(localized: """
                    No configured host matches this shortcut. Pick a host in the \
                    widget or shortcut settings.
                    """)
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
                message: String(localized: """
                    \(host.name) is disabled. Enable it on the deck to open \
                    sessions on it.
                    """)
            ))
            return
        }
        // Host resolution and the enabled check run first so the
        // confirmation can name the machine and never appears for a link
        // that could not have run anyway.
        guard trusted || !action.needsOriginConfirmation else {
            context.presentConfirmation(
                ExternalActionConfirmation.make(for: action, hostName: host.name))
            return
        }
        switch action {
        case .openShell(_, let sessionName, let backend):
            await openShell(
                on: host, requestedSession: sessionName,
                backend: backend, context: context)
        case .openAgent(
            _, let agent, let prompt, let askForPrompt, let directory,
            let setupScript, let model, let target, let backend
        ):
            if askForPrompt {
                context.presentAgentPrompt(AgentPromptRequest(
                    host: host,
                    agent: agent,
                    directory: directory,
                    setupScript: setupScript,
                    model: model,
                    target: target,
                    backend: backend
                ))
                return
            }
            await openAgent(
                agent,
                prompt: prompt,
                directory: directory,
                setupScript: setupScript,
                model: model,
                target: target,
                backend: backend,
                on: host,
                context: context
            )
        case .openFile(_, let path, let line):
            openFile(path: path, line: line, on: host, context: context)
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
        backend: Host.SessionBackend?,
        context: ExternalActionRouter.Context
    ) async {
        guard let model = await connectedModel(for: host, context: context) else { return }
        // A named backend narrows the search to its namespace; without one,
        // every monitored backend's sessions are candidates and the record
        // that matches carries the backend the attach must use.
        // `host.sessionBackend` is the tie-break, never the assumption.
        let sessions = backend.map { scopedSessions(model, to: $0) }
            ?? model.allSessions
        // A widget tile names the exact session it showed; a session that
        // died since that snapshot falls back to the last one opened here,
        // then the most recent — the widgets' own order.
        let requested = requestedSession.flatMap { name in
            sessions.first { $0.name == name }
        }
        let lastOpened = context.store.recentSessions[host.id].flatMap { key in
            sessions.first { $0.id == key }
        }
        let fallback = lastOpened ?? ExternalActionPlan.mostRecentSession(in: sessions)
        if let target = requested ?? fallback {
            if context.workspace.focusTab(
                hostID: host.id,
                sessionName: target.name,
                backend: target.backend
            ) { return }
            open(
                mode: .attach(host: host, session: target),
                on: host,
                context: context
            )
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

    /// A named backend the host no longer monitors resolves to nothing
    /// rather than silently landing on another one — fail-soft everywhere
    /// else in this file means "fall back to a safe default", but attaching
    /// the wrong multiplexer's same-named session is not safe.
    private static func scopedSessions(
        _ model: HostConnectionModel, to backend: Host.SessionBackend
    ) -> [TmuxSession] {
        model.host.monitors(backend) ? model.sessions(on: backend) : []
    }

    private static func openAgent(
        _ agent: AgentKind,
        prompt: String?,
        directory: String?,
        setupScript: ExternalSetupScriptSelection,
        model launchModel: String?,
        target: ExternalSessionTarget,
        backend: Host.SessionBackend?,
        on host: Host,
        context: ExternalActionRouter.Context
    ) async {
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
        let launch = agent.launchCommand(model: launchModel, initialPrompt: prompt ?? "")
        // A configured target names the exact session it was set up with; a
        // session that died since falls through to the fresh-session mint
        // (fail-soft, openShell's rule). An in-session create that FAILS
        // stays a visible failure instead — a fallback mint there would
        // hide it behind a surprise second session.
        let candidates = backend.map { scopedSessions(model, to: $0) }
            ?? model.allSessions
        if case .existingSession(let name, let placement) = target,
           let session = candidates.first(where: { $0.name == name }) {
            guard let mode = await model.launchInSession(
                named: session.name,
                // The TARGET session's backend, not the host's: an `in=tab`
                // launch aimed at a herdr session on a tmux-primary host
                // must run herdr's verbs.
                backend: session.backend,
                placement: placement,
                // Same rule as the fresh-session mint below: the Working
                // Directory field, else the host's first configured dir —
                // one field, one meaning, wherever the agent lands.
                directory: directory ?? host.workingDirs.first,
                label: agent.launchCommand,
                running: script?.normalizedBody,
                typing: launch
            ) else {
                presentLaunchInSessionFailure(
                    session: session.name, backend: session.backend,
                    placement: placement,
                    for: model, host: host, context: context)
                return
            }
            // Created first, revealed second: the fresh pane is already the
            // session's current window/focus, so an existing tab needs only
            // the reveal and a missing one attaches straight onto it.
            if context.workspace.focusTab(
                hostID: host.id,
                sessionName: session.name,
                backend: session.backend
            ) { return }
            open(mode: mode, on: host, context: context)
            return
        }
        guard let created = await model.createSession(
            base: agent.launchCommand,
            // A named backend mints there; nil is the host's default. One
            // the host no longer monitors falls back rather than failing —
            // minting is not the ambiguous case, attaching is.
            backend: backend.flatMap { host.monitors($0) ? $0 : nil },
            inDirectoryOf: nil,
            startingIn: directory ?? host.workingDirs.first,
            applying: host.newSessionTmuxConf,
            running: script?.normalizedBody,
            typing: launch
        ) else {
            presentCreateFailure(for: model, host: host, context: context)
            return
        }
        open(mode: created, on: host, context: context)
    }

    /// Register the in-memory viewer before its auxiliary route reaches a
    /// window. Unlike shell actions this needs no deck probe: the viewer owns
    /// its SSH control-plane connection and reports read failures in its pane.
    private static func openFile(
        path: String, line: Int?, on host: Host,
        context: ExternalActionRouter.Context
    ) {
        guard let target = TerminalPathTarget.resolveExplicit(path, line: line) else {
            context.presentFailure(ExternalActionFailure(
                hostName: host.name,
                message: String(
                    localized: "Enter a remote file path and an optional positive line number.")
            ))
            return
        }
        if context.workspace.openFileViewer(
            target,
            onActiveTerminalForHost: host.id
        ) {
            return
        }
        let tab = TerminalRoute(hostID: host.id, mode: .fileViewer(path: target.path))
        context.workspace.openFileViewer(
            tab: tab,
            host: host,
            startDirectory: host.workingDirs.first,
            anchorSession: nil,
            target: target
        )
        context.open(TerminalWindowRoute(tab: tab))
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

    /// Failure copy for an in-session launch, in the backend's own noun —
    /// the person configured "New Tab"/"New Workspace"/"New Window" and the
    /// alert should say which one didn't happen.
    private static func presentLaunchInSessionFailure(
        session: String, backend: Host.SessionBackend,
        placement: ExternalSessionPlacement,
        for model: HostConnectionModel, host: Host,
        context: ExternalActionRouter.Context
    ) {
        let noun: String
        // The RESOLVED session's backend names the thing that didn't
        // happen, not the host's primary.
        switch (backend, placement) {
        case (.tmux, _): noun = String(localized: "window")
        case (.herdr, .tab): noun = String(localized: "tab")
        case (.herdr, .workspace): noun = String(localized: "workspace")
        }
        let message: String
        if case .failed(let reason) = model.phase {
            message = reason
        } else {
            message = String(
                localized: "Couldn't open a new \(noun) in session \(session) on \(host.name).")
        }
        context.presentFailure(ExternalActionFailure(hostName: host.name, message: message))
    }

    private static func presentCreateFailure(
        for model: HostConnectionModel, host: Host,
        context: ExternalActionRouter.Context
    ) {
        // The mint's own cause leads — a host with no herdr installed fails
        // with a perfectly healthy link, and the connection's reason (or a
        // generic one) would send the user after the wrong thing.
        // createSession marks the host failed when the control link IS the
        // problem; reuse that reason when it exists.
        let message: String
        switch model.sessionCreateFailure {
        case .backendMissing(let backend):
            message = HostGuide.backendMissingMessage(backend, hostName: host.name)
        case nil:
            if case .failed(let reason) = model.phase {
                message = reason
            } else {
                message = String(localized: "Couldn't create the session on \(host.name).")
            }
        }
        context.presentFailure(ExternalActionFailure(hostName: host.name, message: message))
    }

    private static func failureMessage(for phase: HostConnectionModel.Phase, host: Host) -> String {
        switch phase {
        case .failed(let reason): reason
        default: String(localized: "Couldn't reach \(host.name). No response.")
        }
    }
}
