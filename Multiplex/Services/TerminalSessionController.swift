import Foundation
import Observation
import os
import SwiftTerm
import UIKit

/// Owns one terminal tab's shell: opens a dedicated transport — an SSH
/// PTY, or a mosh session bootstrapped over SSH when the host asks for it
/// — running tmux attach / new-session / a plain shell, and pumps bytes
/// between the transport and the SwiftTerm view.
///
/// A tab draws one emulator (`TerminalScreen`), except on a backend that
/// hands its panes out separately (`PanedTerminalTransport` — a Rex tab):
/// there it draws one per pane, and `terminalView`, input, the key rail and
/// everything else that means "the terminal" follow the pane the keyboard
/// is on.
@MainActor
@Observable
final class TerminalSessionController {
    enum Status: Equatable {
        case connecting
        case live
        case ended(String?)
    }

    /// File-drop progress surfaced by the pane's status pill.
    enum DropState: Equatable {
        case uploading(name: String, fraction: Double)
        case failed(String)
    }

    let route: TerminalRoute
    let host: Host
    /// Alert sink for in-band signals (bell); nil in tests/previews.
    private weak var attention: AttentionCenter?

    private(set) var status: Status = .connecting
    /// True while this tab is re-attaching itself after the app was
    /// suspended, rather than connecting for the first time — the pane says
    /// so, because the session on the host was never lost.
    private(set) var isResuming = false
    private(set) var remoteTitle: String = ""
    /// A user-opened terminal may ask immediately for an encrypted key's
    /// missing/corrected passphrase. Cancelling leaves the challenge here so
    /// RECONNECT can re-present it without retrying the same bad secret.
    private(set) var keyPassphraseChallenge: SSHKeyPassphraseChallenge?

    /// Plain-shell agent state comes from that tab's own PTY rather than the
    /// tmux fleet probe. It drives the same helper strip and attention UI as
    /// an attached pane; nil for tmux routes and when no supported foreground
    /// agent is running.
    private(set) var directShellAgent: AgentKind?
    private(set) var directShellAttention: PaneAgentState?
    /// The foreground process group's cwd, when the shell probe could reveal
    /// it — a plain shell's only source for locating agent session files.
    private(set) var directShellWorkingDirectory: String?

    /// App-owned interaction state layered over tmux copy mode. While it is
    /// active, SwiftTerm stops forwarding taps as tmux mouse clicks: pans
    /// still move through the alternate screen, while a hold/double-tap uses
    /// iPadOS's native text selection and copies into the local pasteboard.
    /// The terminal HUD provides the explicit exit path tmux itself lacks.
    private(set) var tmuxCopyModeUIActive = false

    /// The copy-mode HUD's backend-agnostic sibling: the same tap ownership
    /// flip (mouse reporting off, so hold/double-tap run native selection
    /// over the visible screen and copy to the device pasteboard) without
    /// entering any remote mode — herdr has no copy mode to enter, and on
    /// tmux nothing needs to touch the server just to select. Pans are
    /// suppressed rather than translated: no remote view answers cursor
    /// keys here, and the alternate screen has no local scrollback. Entry
    /// is the selection block's SELECT / SELECT ALL; exit is the floating
    /// block's DONE, its COPY (the grab finishes the mode), or a keyboard
    /// Escape (consumed — see `sendInput`).
    private(set) var selectTextModeUIActive = false
    /// Drops a stale focused-pane-rect answer when the mode ends or a
    /// resize refetches before the previous exec came home.
    private var selectTextClampGeneration = 0
    private var selectTextClampTask: Task<Void, Never>?

    /// Whether this tab's bytes ride mosh — THE transport question, asked
    /// here by everything that depends on the answer (the run, scrollback,
    /// FILE, the bar's MOSH badge). The host's preference, except on a Rex
    /// tab: it has no PTY for mosh-server to run, so it rides SSH whatever
    /// the host prefers.
    var ridesMosh: Bool { host.useMosh && route.rexTarget == nil }

    /// Local scrollback for this tab's terminal view; nil disables it.
    /// A transport capability, so it lives beside the transport choice:
    /// mosh syncs ONE live screen and anything archived above it is junk
    /// (stale frames from scroll-op diffs, resync resets, and resizes) —
    /// full record in docs/agents/mosh.md.
    var localScrollbackLines: Int? { ridesMosh ? nil : 5000 }

    /// The HISTORY surface: user prompts read from the agent's own session
    /// file on the host (see `AgentSessionHistory`). Present while the panel
    /// is open; cleared on dismiss so a stale list never reopens.
    enum AgentHistoryStatus: Equatable {
        case loading
        case loaded(
            agent: AgentKind,
            messages: [AgentUserMessage],
            jumpAvailable: Bool
        )
        case unavailable(String)
    }
    private(set) var agentHistory: AgentHistoryStatus?
    private var historyLoadTask: Task<Void, Never>?

    /// Jump-to-message drives Claude Code's own PgUp pager over the control
    /// path. While `.finding`, the terminal's input is locked (a keystroke
    /// would interleave with the remote paging); `.jumped` keeps a BACK TO
    /// LIVE exit visible until the user returns or types.
    enum HistoryJumpPhase: Equatable {
        case finding(preview: String)
        case jumped(preview: String, pages: Int)
    }
    private(set) var historyJump: HistoryJumpPhase?
    private var historyJumpTask: Task<Void, Never>?
    private var historyJumpTarget: AgentSessionHistory.JumpTarget?
    /// Transient status pill ("AGENT IS BUSY", "NOT IN THE VISIBLE
    /// TRANSCRIPT") — jump failures are outcomes, not errors.
    private(set) var historyNotice: String?
    private var historyNoticeClearTask: Task<Void, Never>?

    /// How far a *docked* keyboard presentation (software keyboard, or the
    /// accessory-only key rail of hardware-keyboard mode) intrudes above the
    /// window's bottom safe-area edge — published by the terminal's
    /// keyboard-clearance owner (`SwiftTermView`'s coordinator) so chrome
    /// that rests on that edge (the iPad agent helper strip) can pad itself
    /// above the keyboard instead of being painted over. Floating pills
    /// report 0, same as the terminal's own inset. Always 0 on visionOS.
    private(set) var keyboardObstruction: CGFloat = 0

    func reportKeyboardObstruction(_ height: CGFloat) {
        guard keyboardObstruction != height else { return }
        keyboardObstruction = height
    }

    /// The view of the screen the keyboard is on — the tab's only one, or
    /// the active pane's. The screen owns it (`TerminalScreen`); this is the
    /// observed mirror everything above the terminal reads, so chrome
    /// follows the tab's focus from pane to pane without knowing there are
    /// panes.
    private(set) var terminalView: TerminalView?
    /// The emulators this tab draws: one, or — on a paned tab — one per
    /// pane in layout order, none until the attach has said what they are.
    @ObservationIgnored private(set) var screens: [TerminalScreen] = []
    @ObservationIgnored private var activeScreen: TerminalScreen?
    /// Whether this tab's backend hands its panes out separately, for the
    /// tab to draw (`PanedTerminalTransport`). Rex is the one that does.
    var drawsPanes: Bool { route.rexTarget != nil }
    /// How a paned tab's panes are arranged, as its transport last said (and
    /// as a divider drag here has since moved it). nil on every other tab,
    /// and until an attach has answered.
    private(set) var paneLayout: PaneLayout?
    /// The pane the tab's keyboard is on.
    private(set) var activePaneID: PaneID?
    /// The pane a paned tab draws ALONE, over the room of all the others;
    /// nil while it draws them all. The tab's own: no backend is asked, and
    /// the layout — every hidden pane's size included — stays as it is, so
    /// leaving the zoom is instant. It ends when the keyboard goes to
    /// another pane, as tmux's and Rex's own zooms do.
    private(set) var zoomedPaneID: PaneID?
    /// The surface's side of `paneLayout`: it must have every pane laid out
    /// — and so measured — by the time it returns. A new pane's terminal is
    /// opened at the grid this pass gives it.
    @ObservationIgnored private var onPaneLayoutChanged: (() -> Void)?
    /// Whose `onPaneLayoutChanged` that is. A tab moved to another window
    /// has two surfaces for a moment, and only the newer may make emulator
    /// views: the older one adopting them back would pull them out of the
    /// window the tab just arrived in.
    @ObservationIgnored private weak var paneLayoutObserver: AnyObject?
    /// The byte pipe under this tab — SSH PTY or mosh session. nil on a
    /// paned tab, whose link is `panedTransport`.
    private var transport: (any TerminalTransport)?
    /// A paned tab's link: one stream per pane and the layout they sit in.
    private var panedTransport: (any PanedTerminalTransport)?
    /// The paned transport as the Rex client it is on a Rex tab.
    private var rexSession: RexSession? { panedTransport as? RexSession }
    /// Routes each pane's output to its screen from the transport's own
    /// isolation; one per paned run.
    @ObservationIgnored private var paneOutput: PaneOutputRouter?
    @ObservationIgnored private var paneCommands: AsyncStream<PaneCommand>.Continuation?
    @ObservationIgnored private var paneCommandTask: Task<Void, Never>?
    /// The terminal a Rex tab's keyboard is on: learned when the attach
    /// settles on one, moved by a touch on another pane and by the REX
    /// panel's Switch Terminal. nil until then, and on every other kind of
    /// tab. Two readers: the next transport run prefers it over the route's
    /// own block, so a reconnect comes back to the terminal the user was
    /// on; and the window reads the tab's agent from it — the session's
    /// fronted terminal is somebody else's choice.
    private(set) var rexBlockID: String?
    /// SSH path only: the exec/SFTP surface (pane cwd, file drops). nil on
    /// mosh tabs — their bootstrap SSH connection is transient by design.
    private var connection: SSHConnection?
    /// mosh path only: contact nudges on foreground.
    private var moshSession: MoshSession?
    /// A live mosh session that hasn't heard its server past mosh's 6.5 s
    /// threshold. Input still queues and the link self-heals; the chrome
    /// just shows it truthfully. Always false on SSH tabs.
    private(set) var contactLost = false
    /// SSH handoff tabs only: watches early PTY output for the oh-my-zsh
    /// update prompt, whose stdin drain swallows the injected attach line.
    /// nil once resolved (prompt handled, attach seen, or window elapsed).
    private var handoffWatch: ShellHandoff.UpdatePromptWatch?
    private var started = false
    private var transportGeneration = 0
    /// Session-volume counters drained by the stats pump. Written on the
    /// MainActor by the two byte funnels (`feed`, `sendInput`).
    private var statsBytesIn = 0
    private var statsBytesOut = 0
    /// Pairs live/ended pushes exactly once per transport run, so the
    /// center's live-tab bookkeeping can't drift on paths that end a
    /// transport that never went live (or end one twice).
    private var statsReportedLive = false
    /// Times this tab actually went live — the 2nd+ are RELINKS. Counted at
    /// the state machine that owns liveness, never at attempts: a host that
    /// is simply down must not climb the stability row while retries fail.
    private var statsLiveRuns = 0
    private var statsTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    /// Background cadence for a plain PTY. The focused TerminalWindow may
    /// request a faster refresh, coalesced by the same in-flight/staleness
    /// gates; tmux tabs continue to use ConnectionHub's fleet probe.
    private var directShellMonitorTask: Task<Void, Never>?
    private var directShellProbeGenerationInFlight: Int?
    private var lastDirectShellProbe: Date?
    private var directShellMonitorGeneration = 0
    private var terminalAgentHint: AgentKind?
    private var lastTerminalTitleProcessedForAgentHint: String?
    private var directShellAttentionAgent: AgentKind?
    /// Keyed by this tab's own UUID: a direct shell has no session record,
    /// so there is nothing else to key an edge baseline by.
    private var directShellAttentionTracker = AttentionTracker<String>()
    private(set) var dropState: DropState?
    private var dropTask: Task<Void, Never>?
    private var dropClearTask: Task<Void, Never>?
    /// The target the user activated in this pane, awaiting confirmation.
    /// The pane never opens one straight from the gesture: the target is
    /// remote output, so the destination is shown first (see `TerminalLink`
    /// / `TerminalPathTarget`). ONE slot for both kinds — the link sheet and
    /// the path sheet structurally cannot contend for the same press.
    private enum PendingActivation {
        case link(TerminalLink)
        case path(TerminalPathTarget)
    }
    private var pendingActivation: PendingActivation?

    var pendingLink: TerminalLink? {
        if case .link(let link) = pendingActivation { return link }
        return nil
    }

    var pendingPath: TerminalPathTarget? {
        if case .path(let path) = pendingActivation { return path }
        return nil
    }

    /// The screen cell of the last path press — which PANE the path was
    /// printed in, so a relative path resolves against that pane's cwd
    /// rather than the active one's. Overwritten by the next path press,
    /// never cleared with the sheet: the ▤ VIEW confirmation reads it
    /// after the sheet dismisses. nil for non-gesture summons (the debug
    /// hooks, Shortcuts) and scrollback presses, which keep the
    /// active-pane fallback.
    private(set) var pathPressScreenCell: (col: Int, row: Int)?

    /// The grid this tab reports to the remote — the attached client's
    /// screen as the backend lays it out, which herdr's content-relative
    /// pane rects need to land on screen cells.
    var screenSize: (cols: Int, rows: Int) {
        (cols: activeScreen?.cols ?? 80, rows: activeScreen?.rows ?? 24)
    }

    #if !os(visionOS)
    /// The terminal's app-owned dictation controls, from the pane's side:
    /// LISTENING while the microphone is open, or a short failure the user
    /// can act on. Settled words are already in the session, so the payload
    /// is only what has been heard and not yet typed.
    enum DictationState: Equatable {
        case listening(String)
        case failed(String)
    }
    /// The pane's take. `dictationPhase` is its observed mirror — the driver
    /// itself is not observable.
    @ObservationIgnored private let dictationDriver = DictationDriver()
    private var dictationPhase: DictationDriver.State = .idle

    var dictation: DictationState? {
        switch dictationPhase {
        case .listening(let pending): .listening(pending)
        case .failed(let message): .failed(message)
        case .idle, .starting: nil
        }
    }
    #endif

    init(route: TerminalRoute, host: Host, attention: AttentionCenter? = nil) {
        self.route = route
        self.host = host
        self.attention = attention
        if route.rexTarget == nil {
            let screen = TerminalScreen()
            screens = [screen]
            activeScreen = screen
        }
        #if !os(visionOS)
        dictationDriver.onStateChange = { [weak self] in
            guard let self else { return }
            dictationPhase = dictationDriver.state
        }
        dictationDriver.onText = { [weak self] settled in self?.typeDictated(settled) }
        #endif
    }

    /// The remote rang the terminal bell (BEL through the PTY — how opt-in
    /// agent hooks and `terminal_bell` notifications reach an attached tab,
    /// on SSH and mosh alike).
    func bellRang() {
        attention?.handleBell(from: self)
    }

    var windowTitle: String {
        "\(route.displayName) — \(host.name)"
    }

    /// The one screen of a tab that draws no panes.
    var soleScreen: TerminalScreen? { drawsPanes ? nil : screens.first }

    /// Replace, never stack: the surface that lays this tab's panes out is
    /// the last one installed.
    func observePaneLayout(as observer: AnyObject, _ changed: @escaping () -> Void) {
        paneLayoutObserver = observer
        onPaneLayoutChanged = changed
    }

    func isPaneLayoutObserver(_ candidate: AnyObject) -> Bool {
        paneLayoutObserver === candidate
    }

    func screen(for pane: PaneID) -> TerminalScreen? {
        screens.first { $0.paneID == pane }
    }

    /// A surface made (or adopted) the view for one of this tab's screens.
    func bind(_ view: TerminalView, to screen: TerminalScreen) {
        applyTouchInteractionModes(to: view)
        // Touch never hovers, so SwiftTerm's pointer-gated activation can
        // never fire here; this pane decides instead. The view owns the
        // closure and this controller owns the view — capture weakly.
        view.linkActivationIgnoresHighlight = true
        view.linkActivationHandler = { [weak self, weak view] target, _, rowTexts, position in
            guard let self else { return false }
            // Buffer row → visible-screen cell: pane rectangles live in
            // screen coordinates, and a press up in scrollback names no
            // pane (the composite screen is the only pane-mapped surface).
            var cell: (col: Int, row: Int)?
            if let state = view?.terminalStateSnapshot() {
                let screenRow = position.row - state.viewportRow
                if screenRow >= 0 && screenRow < state.dimensions.rows {
                    cell = (col: position.col, row: screenRow)
                }
            }
            return self.activateLink(target, rowFragments: rowTexts, pressedAt: cell)
        }
        // herdr resizes its pane splits by mouse drag, so a long press on a
        // border cell becomes a remote press-drag-release. herdr tabs only:
        // the same drag under tmux starts a copy-mode selection, and the
        // fork's filter is consulted only while the client requested button
        // tracking, so a plain shell never loses its long press.
        if route.sessionBackend == .herdr {
            view.longPressMouseDragFilter = { _, content in
                HerdrPaneBorder.isBorderCell(content)
            }
            // herdr selects by mouse drag inside the pane and, for a client
            // under SSH, copies over OSC 52 (`clipboardCopy`) — the selection
            // iTerm and Ghostty users get. Local selection sees only the
            // composited screen, so it sweeps whatever a TUI draws beside
            // the text; a long press that raised the block and then travels
            // hands the drag to herdr instead.
            view.longPressDragSelectsRemotely = true
        }
        screen.attach(view)
        if screen === activeScreen { terminalView = view }
    }

    /// Route keyboard input to this window's terminal.
    func focusTerminal() {
        guard let terminalView else { return }
        TerminalFocusArbiter.claim(terminalView)
    }

    /// Temporarily free the keyboard's screen region for a chrome-owned
    /// presentation while preserving this tab as the app-wide focus owner.
    @discardableResult
    func suspendFocusForPresentation() -> Bool {
        guard let terminalView else { return false }
        return TerminalFocusArbiter.suspendForPresentation(terminalView)
    }

    /// Restore input after that presentation only if this tab still owns it.
    func resumeFocusAfterPresentation() {
        guard let terminalView else { return }
        TerminalFocusArbiter.resumeAfterPresentation(terminalView)
    }

    /// The single-window shell navigated back to its deck. Focus ownership
    /// still goes through the app-wide arbiter even though both surfaces live
    /// in one scene.
    func releaseFocus() {
        guard let terminalView else { return }
        TerminalFocusArbiter.release(terminalView)
    }

    /// Bring this tab's hosting window scene forward and take keyboard
    /// focus — the deck tile's press-to-focus path. The scene raise is
    /// explicit: the arbiter only activates a scene when focus *switches*
    /// hands, and this terminal may already own focus while its window
    /// sits behind the deck the user is pressing.
    func revealWindow() {
        guard let terminalView else { return }
        if let scene = terminalView.window?.windowScene {
            UIApplication.shared.activateSceneSession(
                for: UISceneSessionActivationRequest(session: scene.session)
            )
        }
        TerminalFocusArbiter.claim(terminalView)
    }

    /// Explicit user request on the chrome's keyboard key: hide the keyboard
    /// when this terminal is presenting it, otherwise bring the normal system
    /// keyboard back. The arbiter owns the visibility check and the stuck
    /// custom-input-view / hardware-keyboard rebuild details.
    func toggleKeyboard() {
        guard let terminalView else { return }
        TerminalFocusArbiter.toggle(terminalView)
    }

    /// The keyboard lock as a named menu action. The rail / cluster key's
    /// hold gesture stays the fast path, but nothing on screen announced it —
    /// a held key is unfindable, so the same lock/unlock lives in the
    /// terminal's actions menu. Lock hides while a hardware keyboard makes it
    /// redundant (iPad/iPhone; visionOS has no monitor and always offers
    /// it); an already-held lock keeps Unlock available. Unlocking asks for
    /// the keyboard back, exactly like the padlock's short press.
    func toggleKeyboardLock() {
        guard let terminalView else { return }
        if KeyboardLock.shared.isLocked {
            TerminalFocusArbiter.unlock(terminalView)
        } else {
            TerminalFocusArbiter.lock(terminalView)
        }
    }

    /// Arrange Keys — the key rail's / cluster's reorder mode, per tab like
    /// the message box and never persisted (the ORDER is, in
    /// `KeyBarOrderStore`).
    private(set) var keyBarArranging = false

    func setKeyBarArranging(_ arranging: Bool) {
        guard keyBarArranging != arranging else { return }
        keyBarArranging = arranging
    }

    func toggleKeyBarArranging() {
        setKeyBarArranging(!keyBarArranging)
    }

    /// Scene became active again: re-assert focus only if this terminal is
    /// already the app-wide owner — every window's scene activates at once
    /// on foreground, and notification order must not elect a new owner.
    func restoreFocusIfOwner(allowed: Bool = true) {
        guard let terminalView else { return }
        TerminalFocusArbiter.restore(terminalView, allowed: allowed)
    }

    func start() {
        guard !started else { return }
        started = true
        beginTransportRun()
    }

    private func beginTransportRun() {
        transportGeneration &+= 1
        let generation = transportGeneration
        for screen in screens {
            // A new run attaches at this tab's own size.
            screen.setGridPin(nil)
            screen.outputCoalescer = makeOutputCoalescer(for: screen, generation: generation)
        }
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(generation: generation)
            if self.transportGeneration == generation {
                self.runTask = nil
            }
        }
    }

    private func makeOutputCoalescer(
        for screen: TerminalScreen, generation: Int
    ) -> TerminalOutputCoalescer {
        TerminalOutputCoalescer { [weak self, weak screen] bytes in
            guard let self, let screen, self.transportGeneration == generation else { return }
            self.feed(bytes, to: screen)
        }
    }

    private func run(generation: Int) async {
        if let rex = route.rexTarget {
            await runRex(rex, generation: generation)
        } else if let screen = screens.first, let output = screen.outputCoalescer {
            if ridesMosh {
                await runMosh(generation: generation, screen: screen, output: output)
            } else {
                await runSSH(generation: generation, screen: screen, output: output)
            }
        }
    }

    /// The tab's own SSH connection, carrying a PTY that runs the route's
    /// remote command. The connection stays this tab's exec surface.
    private func runSSH(
        generation: Int,
        screen: TerminalScreen,
        output: TerminalOutputCoalescer
    ) async {
        let secrets = await HostSecrets.loadOffMain(for: host)
        guard transportGeneration == generation, !Task.isCancelled else { return }
        let connection = SSHConnection(host: host, secrets: secrets)
        guard transportGeneration == generation else {
            await connection.close()
            return
        }
        self.connection = connection
        self.transport = connection
        do {
            try await connection.connect()
            try Task.checkCancellation()
            guard transportGeneration == generation,
                  self.connection === connection
            else {
                await connection.close()
                return
            }
            let openedSize = screen.openingSize
            // Armed before the PTY opens so the first output chunk is
            // already scanned; an rc-time oh-my-zsh update prompt swallows
            // the injected handoff line and needs a re-type (ShellHandoff).
            handoffWatch = route.remoteCommand == nil
                ? nil
                : ShellHandoff.UpdatePromptWatch()
            try await connection.openShell(
                command: route.remoteCommand,
                cols: openedSize.cols, rows: openedSize.rows,
                onData: { data in
                    output.append(data)
                },
                onClose: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        self?.handleClose(reason: reason, generation: generation)
                    }
                })
            try Task.checkCancellation()
            guard transportGeneration == generation,
                  self.connection === connection
            else {
                await connection.close()
                return
            }
            startTransportPumps(for: connection, screen: screen, openedAt: openedSize)
            markLive()
            startDirectShellMonitoring()
        } catch {
            await connection.close()
            guard transportGeneration == generation,
                  self.connection === connection
            else { return }
            captureKeyPassphraseChallenge(from: error)
            let message = (error as? SSHConnectionError)?.userMessage(host: host)
                ?? String(localized: "Couldn't reach \(host.name). \(error.localizedDescription)")
            status = .ended(message)
            self.connection = nil
            self.transport = nil
            screen.outputCoalescer = nil
            handoffWatch = nil
            considerAutomaticResume()
        }
    }

    /// A Rex tab: the tab's own SSH connection carries no PTY at all, only
    /// byte pipes to the Rex server — one for control and one per pane —
    /// with `RexSession` speaking its protocol over them. The connection
    /// stays this tab's exec surface, and closing the session closes it.
    private func runRex(
        _ target: (sessionID: String, blockID: String?), generation: Int
    ) async {
        let secrets = await HostSecrets.loadOffMain(for: host)
        guard transportGeneration == generation, !Task.isCancelled else { return }
        let connection = SSHConnection(host: host, secrets: secrets)
        guard transportGeneration == generation else {
            await connection.close()
            return
        }
        let rex = RexSession(
            connection: connection,
            sessionID: target.sessionID,
            blockID: rexBlockID ?? target.blockID,
            clientVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
        self.connection = connection
        await runPanes(over: rex, generation: generation) { events in
            try await connection.connect()
            try Task.checkCancellation()
            try await rex.open(events: events)
        }
    }

    /// One run of a paned transport, whichever backend's: hand it the tab's
    /// side of `PaneEvents`, let `open` bring it up, and go live. Nothing in
    /// here is Rex's — a second paned backend makes its transport and calls
    /// this.
    private func runPanes(
        over transport: any PanedTerminalTransport, generation: Int,
        open: (PaneEvents) async throws -> Void
    ) async {
        let router = PaneOutputRouter()
        panedTransport = transport
        paneOutput = router
        startPaneCommandPump(for: transport)
        do {
            try await open(PaneEvents(
                arrange: { [weak self] arrangement in
                    await MainActor.run { [weak self] in
                        self?.applyArrangement(arrangement, generation: generation) ?? [:]
                    }
                },
                output: { pane, data in
                    router.append(data, to: pane)
                },
                grid: { [weak self] pane, grid in
                    await MainActor.run { [weak self] in
                        guard let self, self.transportGeneration == generation,
                              let screen = self.screen(for: pane)
                        else { return }
                        // What was written for the old grid is parsed at
                        // the old grid.
                        screen.outputCoalescer?.flush()
                        screen.setGridPin(grid)
                    }
                },
                close: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        self?.handleClose(reason: reason, generation: generation)
                    }
                }))
            try Task.checkCancellation()
            guard transportGeneration == generation, panedTransport === transport else {
                await transport.close()
                return
            }
            markLive()
            #if DEBUG
            debugAutoSwitchRexTerminal()
            debugAutoPaneShortcuts()
            #endif
        } catch {
            await transport.close()
            guard transportGeneration == generation, panedTransport === transport
            else { return }
            captureKeyPassphraseChallenge(from: error)
            let message = (error as? RexSession.Failure)?.message
                ?? (error as? SSHConnectionError)?.userMessage(host: host)
                ?? String(localized: "Couldn't reach \(host.name). \(error.localizedDescription)")
            status = .ended(message)
            connection = nil
            endPanedRun()
            considerAutomaticResume()
        }
    }

    /// Runs this tab over a paned transport a test made, with no SSH
    /// connection under it: everything from the arrangement down — screens,
    /// focus, the pumps, the commands — is the real thing.
    func runPanesForTesting(
        over transport: any PanedTerminalTransport,
        open: (PaneEvents) async throws -> Void
    ) async {
        transportGeneration &+= 1
        await runPanes(over: transport, generation: transportGeneration, open: open)
    }

    /// mosh: a transient SSH connection launches mosh-server, then the
    /// session itself rides UDP — resilient to roaming and sleep. The
    /// deck's probe (and file drops) stay SSH; this tab simply has no
    /// exec surface.
    private func runMosh(
        generation: Int,
        screen: TerminalScreen,
        output: TerminalOutputCoalescer
    ) async {
        contactLost = false
        do {
            let secrets = await HostSecrets.loadOffMain(for: host)
            try Task.checkCancellation()
            guard transportGeneration == generation else { return }
            let target = try await MoshBootstrap.start(
                host: host,
                secrets: secrets,
                remoteCommand: route.moshRemoteCommand
            )
            try Task.checkCancellation()
            guard transportGeneration == generation else { return }
            let openedSize = TerminalGrid(cols: screen.cols, rows: screen.rows)
            let session = try MoshSession(
                target: target,
                cols: openedSize.cols,
                rows: openedSize.rows
            )
            moshSession = session
            transport = session
            try await session.open(
                onData: { data in
                    output.append(data)
                },
                onClose: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        self?.handleClose(reason: reason, generation: generation)
                    }
                },
                onContact: { [weak self] lost in
                    Task { @MainActor [weak self] in
                        guard self?.transportGeneration == generation else { return }
                        self?.contactLost = lost
                    }
                }
            )
            try Task.checkCancellation()
            guard transportGeneration == generation,
                  moshSession === session
            else {
                await session.close()
                return
            }
            startTransportPumps(for: session, screen: screen, openedAt: openedSize)
            markLive()
            startDirectShellMonitoring()
        } catch {
            let session = moshSession
            await session?.close()
            guard transportGeneration == generation,
                  moshSession === session
            else { return }
            captureKeyPassphraseChallenge(from: error)
            let message = (error as? MoshBootstrapError)?.userMessage(host: host)
                ?? (error as? MoshSession.Failure)?.userMessage(host: host)
                ?? (error as? SSHConnectionError)?.userMessage(host: host)
                ?? String(
                    localized: """
                        Couldn't reach \(host.name) over mosh. \
                        \(error.localizedDescription)
                        """
                )
            status = .ended(message)
            moshSession = nil
            transport = nil
            screen.outputCoalescer = nil
            considerAutomaticResume()
        }
    }

    private func feed(_ bytes: [UInt8], to screen: TerminalScreen) {
        statsBytesIn += bytes.count
        // Only a PTY has a handoff line to lose.
        if screen.paneID == nil { scanForSwallowedHandoff(bytes) }
        screen.feed(bytes)
    }

    /// Modern oh-my-zsh drains all buffered stdin before blocking on its
    /// update prompt, eating the injected tmux handoff line whole. When the
    /// prompt surfaces in early output, re-type the payload: its sacrificial
    /// `:` answers the prompt ("skip") and the command then attaches. At most
    /// once per transport run; the watch also retires itself when tmux's
    /// alternate-screen takeover proves the handoff landed.
    private func scanForSwallowedHandoff(_ bytes: [UInt8]) {
        guard handoffWatch != nil, let command = route.remoteCommand else { return }
        switch handoffWatch!.consume(bytes) {
        case .watching:
            return
        case .done:
            handoffWatch = nil
        case .promptDetected:
            handoffWatch = nil
            let handoff = RemoteShellEnvelope.handoff(command)
            let payload = Data(ShellHandoff.payload(for: handoff).utf8)
            // The ordered input pump keeps the re-type serialized with any
            // keystrokes; before the pump exists (output can arrive while
            // runSSH is still between openShell and startTransportPumps),
            // write straight to the transport — the user can't type yet.
            if screens.first?.send(payload) != true, let transport {
                Task { try? await transport.write(payload) }
            }
        }
    }

    /// OSC title updates are also the no-exec fallback signal for direct mosh
    /// shells. SSH shells use the foreground process probe as authority, but
    /// retaining Claude/Codex's explicit title here prevents a very fast turn
    /// from erasing the identifying idle title before the next poll.
    func terminalTitleChanged(_ title: String, from screen: TerminalScreen? = nil) {
        let screen = screen ?? activeScreen
        screen?.title = title
        // The tab's title is the pane's the keyboard is on.
        guard screen === activeScreen else { return }
        remoteTitle = title
        guard route.sessionName == nil else { return }
        guard title != lastTerminalTitleProcessedForAgentHint else { return }
        lastTerminalTitleProcessedForAgentHint = title
        if let hint = AgentSignature.classifyTerminal(
            title: title,
            visibleLines: terminalScreenSnapshot().lines,
            isAlternateScreen: terminalView?.isAlternateBufferActive ?? false,
            previous: directShellAgent ?? terminalAgentHint
        ) {
            terminalAgentHint = hint
        } else if !AgentAttention.hasSpinnerPrefix(title) {
            terminalAgentHint = nil
        }
    }

    private func handleClose(reason: String?, generation: Int) {
        // Network callbacks enqueue bytes synchronously before their close
        // callback. Flush that final tail before ending the run, then ignore a
        // late close from any superseded transport generation — or a second
        // one from a run that has already been ended.
        guard transportGeneration == generation,
              transport != nil || panedTransport != nil
        else { return }
        for screen in screens { screen.outputCoalescer?.flush() }
        stopTransportPumps()
        stopDirectShellMonitoring()
        endStatsRun(reason: reason)
        setTmuxCopyModeUIActive(false)
        setSelectTextModeUIActive(false)
        resetHistoryState()
        handoffWatch = nil
        status = .ended(reason)
        contactLost = false
        let endedTransport = transport
        let endedPanes = panedTransport
        transport = nil
        connection = nil
        moshSession = nil
        endPanedRun()
        for screen in screens { screen.outputCoalescer = nil }
        Task {
            await endedTransport?.close()
            await endedPanes?.close()
        }
        considerAutomaticResume()
    }

    // MARK: Plain-shell agent monitoring

    private static let directShellProbeInterval: Duration = .seconds(5)

    private func startDirectShellMonitoring() {
        guard route.sessionName == nil else { return }
        directShellMonitorTask?.cancel()
        directShellMonitorGeneration &+= 1
        directShellMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Same gate as the wall feed and the terminal window's
                // probes: iOS suspension is what normally parks this loop,
                // and a hidden app must not keep issuing SSH exec probes —
                // unless this tab's host bought background time, which is
                // exactly so a shell agent's turn-end can still be seen.
                if BackgroundActivity.shared.permitsWork(for: self.host) {
                    await self.refreshDirectShellAgent(ifStaleFor: 4)
                }
                try? await Task.sleep(for: Self.directShellProbeInterval)
            }
        }
    }

    /// Refresh a plain shell's foreground-agent observation. Background tabs
    /// call at the fleet's five-second cadence; the one app-wide focus owner
    /// asks once per second so its helper strip follows process changes
    /// promptly. Concurrent callers collapse into the in-flight operation.
    func refreshDirectShellAgent(ifStaleFor minimumAge: TimeInterval = 0) async {
        guard route.sessionName == nil,
              status == .live,
              directShellProbeGenerationInFlight == nil
        else { return }
        if minimumAge > 0,
           let lastDirectShellProbe,
           Date().timeIntervalSince(lastDirectShellProbe) < minimumAge {
            return
        }

        let generation = directShellMonitorGeneration
        directShellProbeGenerationInFlight = generation
        defer {
            if directShellProbeGenerationInFlight == generation {
                directShellProbeGenerationInFlight = nil
            }
        }
        let probedConnection = connection
        let outcome: ShellAgentProbe.Outcome
        if let probedConnection {
            do {
                outcome = ShellAgentProbe.parse(
                    try await probedConnection.exec(ShellAgentProbe.command)
                )
            } catch {
                outcome = .unavailable
            }
        } else {
            // A direct mosh shell deliberately has no retained SSH control
            // surface; use the narrow in-band title/screen fallback below.
            outcome = .unavailable
        }

        guard generation == directShellMonitorGeneration,
              status == .live,
              connection === probedConnection
        else { return }
        lastDirectShellProbe = Date()
        let screen = terminalScreenSnapshot()
        let agent: AgentKind?
        switch outcome {
        case .available(let detected, let workingDirectory):
            // Definitive even when nil: this is what clears stale titles and
            // helper UI as soon as the foreground agent exits.
            agent = detected
            directShellWorkingDirectory = workingDirectory
        case .unavailable:
            agent = AgentSignature.classifyTerminal(
                title: remoteTitle,
                visibleLines: screen.lines,
                isAlternateScreen: screen.isAlternate,
                previous: directShellAgent ?? terminalAgentHint
            )
        }
        publishDirectShellObservation(agent: agent, tail: screen.lines)
    }

    private func publishDirectShellObservation(agent: AgentKind?, tail: [String]) {
        if directShellAttentionAgent != agent {
            directShellAttentionTracker.reset()
            directShellAttentionAgent = agent
        }
        directShellAgent = agent
        let state = AgentAttention.classifyVerified(
            title: remoteTitle,
            tail: tail,
            agent: agent
        )
        directShellAttention = state
        let events = directShellAttentionTracker.update(
            session: route.id.uuidString,
            state: state,
            hasBell: false
        )
        if let event = events.max(by: { $0.priority < $1.priority }) {
            var dialogSummary: String?
            if case .needsInput(let kind) = event {
                dialogSummary = AgentAttention.dialogSummary(in: tail, kind: kind)
            }
            attention?.handleDirectShellEvent(
                event, agent: agent, dialogSummary: dialogSummary, from: self)
        }
    }

    private func terminalScreenSnapshot() -> (lines: [String], isAlternate: Bool) {
        activeScreen?.snapshot() ?? ([], false)
    }

    private func stopDirectShellMonitoring() {
        directShellMonitorTask?.cancel()
        directShellMonitorTask = nil
        directShellMonitorGeneration &+= 1
        directShellProbeGenerationInFlight = nil
        lastDirectShellProbe = nil
        terminalAgentHint = nil
        lastTerminalTitleProcessedForAgentHint = nil
        directShellAgent = nil
        directShellAttention = nil
        directShellWorkingDirectory = nil
        directShellAttentionAgent = nil
        directShellAttentionTracker.reset()
    }

    // MARK: Pumps

    /// Each screen pumps its own input and size (`TerminalScreen
    /// .startPumps`); this ties the one screen of a single-stream tab to
    /// its transport.
    private func startTransportPumps(
        for transport: any TerminalTransport,
        screen: TerminalScreen,
        openedAt size: TerminalGrid
    ) {
        screen.startPumps(
            write: { try await transport.write($0) },
            resize: { try await transport.resize(cols: $0.cols, rows: $0.rows) },
            openedAt: size)
    }

    private func stopTransportPumps() {
        for screen in screens { screen.stopPumps() }
    }

    // MARK: Panes

    /// A paned transport said how the tab's panes are arranged. Screens are
    /// made for the panes that are new and dropped for the ones that left,
    /// the surface lays the result out, and the grid each pane measured goes
    /// back: the transport opens a new pane's terminal at it.
    private func applyArrangement(
        _ arrangement: PaneArrangement, generation: Int
    ) -> [PaneID: TerminalGrid] {
        guard transportGeneration == generation,
              let panedTransport, let paneOutput
        else { return [:] }
        var arranged: [TerminalScreen] = []
        for pane in arrangement.layout.panes {
            let screen = screen(for: pane) ?? TerminalScreen(paneID: pane)
            if screen.outputCoalescer == nil {
                screen.outputCoalescer = makeOutputCoalescer(for: screen, generation: generation)
            }
            paneOutput.set(screen.outputCoalescer, for: pane)
            if !screen.hasPumps {
                // From the arrangement on, not from the attach: a pane's
                // size has to reach the transport while its terminal is
                // still being opened.
                screen.startPumps(
                    write: { try await panedTransport.write($0, to: pane) },
                    resize: {
                        try await panedTransport.resize(pane: pane, cols: $0.cols, rows: $0.rows)
                    },
                    openedAt: screen.openingSize)
            }
            arranged.append(screen)
        }
        let retired = screens.filter { screen in !arranged.contains { $0 === screen } }
        screens = arranged
        paneLayout = arrangement.layout
        let focused = arrangement.focus.flatMap { screen(for: $0) }
        if let focused {
            activate(focused)
        } else if activeScreen.map({ active in !arranged.contains { $0 === active } }) ?? true {
            activate(arranged.first)
        }
        // A zoom needs its pane, and others for it to cover.
        if let zoomed = zoomedPaneID,
           arranged.count < 2 || !arranged.contains(where: { $0.paneID == zoomed }) {
            zoomedPaneID = nil
        }
        for screen in retired {
            screen.stopPumps()
            screen.outputCoalescer = nil
            if let pane = screen.paneID { paneOutput.set(nil, for: pane) }
            if let view = screen.terminalView { Self.closeTerminalUI(view) }
        }
        // The surface lays the panes out NOW, so the grids below are the
        // ones the panes really have.
        onPaneLayoutChanged?()
        return Dictionary(uniqueKeysWithValues: arranged.compactMap { screen in
            screen.paneID.map { ($0, screen.openingSize) }
        })
    }

    /// Moves the tab's focus to another of its screens. Everything that
    /// reads `terminalView` follows; the keyboard itself is the surface's
    /// to move (it knows whether this tab is the one on screen).
    private func activate(_ screen: TerminalScreen?) {
        guard screen !== activeScreen else { return }
        // A selection in progress belongs to the pane being left — and so
        // does a zoom: the pane the keyboard goes to has to be on screen.
        setSelectTextModeUIActive(false)
        if zoomedPaneID != nil, zoomedPaneID != screen?.paneID { zoomedPaneID = nil }
        activeScreen = screen
        terminalView = screen?.terminalView
        activePaneID = screen?.paneID
        remoteTitle = screen?.title ?? ""
        guard let pane = screen?.paneID else { return }
        if route.rexTarget != nil { rexBlockID = pane.rawValue }
        paneCommands?.yield(.focus(pane))
    }

    /// The person put the keyboard on one of the tab's panes.
    func focusPane(_ pane: PaneID) {
        guard let screen = screen(for: pane) else { return }
        let wasZoomed = zoomedPaneID
        activate(screen)
        if zoomedPaneID != wasZoomed { onPaneLayoutChanged?() }
    }

    /// One row of a paned tab's shortcut panel, on the pane the keyboard is
    /// on.
    func performPaneShortcut(_ shortcut: PaneShortcut) {
        guard status == .live, let pane = activePaneID else { return }
        guard let command = shortcut.command(on: pane) else {
            togglePaneZoom()
            return
        }
        paneCommands?.yield(command)
    }

    /// Draws the pane the keyboard is on alone, or all of them again. A
    /// tab with one pane has nothing to zoom; leaving a zoom always works,
    /// whatever state the link is in.
    func togglePaneZoom() {
        if zoomedPaneID != nil {
            zoomedPaneID = nil
        } else {
            guard let pane = activePaneID, screens.count > 1 else { return }
            zoomedPaneID = pane
        }
        onPaneLayoutChanged?()
    }

    /// A divider was dragged. The tab's own layout moves at once — the drag
    /// has to follow the finger — and the transport is asked to make it so;
    /// what it answers arrives as an arrangement like any other.
    func setPaneRatio(_ ratio: Double, ofSplit splitID: String) {
        guard status == .live, let layout = paneLayout,
              layout.split(withID: splitID) != nil
        else { return }
        let moved = layout.settingRatio(ratio, ofSplit: splitID)
        guard moved != layout else { return }
        paneLayout = moved
        onPaneLayoutChanged?()
        paneCommands?.yield(.setRatio(ratio, splitID: splitID))
    }

    /// Commands go to the transport in the order they were made — a drag
    /// makes dozens, and the last one has to be the one that stands.
    private func startPaneCommandPump(for transport: any PanedTerminalTransport) {
        stopPaneCommandPump()
        let (commands, continuation) = AsyncStream.makeStream(of: PaneCommand.self)
        paneCommands = continuation
        paneCommandTask = Task { [weak self] in
            for await command in commands {
                do {
                    try await transport.perform(command)
                } catch {
                    self?.paneCommandFailed(command, error)
                }
            }
        }
    }

    private func stopPaneCommandPump() {
        paneCommands?.finish()
        paneCommands = nil
        paneCommandTask?.cancel()
        paneCommandTask = nil
    }

    /// A split or a close the backend refused is said on the pane; a focus
    /// or a ratio it would not take needs no words — the next arrangement
    /// shows what stands.
    private func paneCommandFailed(_ command: PaneCommand, _ error: Error) {
        let reason = (error as? RexSession.Failure)?.message ?? error.localizedDescription
        switch command {
        case .split:
            showHistoryNotice(String(localized: "Couldn't split the pane. \(reason)"))
        case .close:
            showHistoryNotice(String(localized: "Couldn't close the pane. \(reason)"))
        case .newWindow:
            // "Tab" is the one paned backend's word for it (Rex).
            showHistoryNotice(String(localized: "Couldn't open a new tab. \(reason)"))
        case .setRatio, .focus:
            break
        }
    }

    /// What a paned run leaves behind when it ends, however it ends. The
    /// screens stay: a reconnect draws the same panes again, each over what
    /// it last showed.
    private func endPanedRun() {
        panedTransport = nil
        paneOutput?.removeAll()
        paneOutput = nil
        stopPaneCommandPump()
        stopTransportPumps()
    }

    // MARK: Terminal view events

    /// What the emulator said by itself — an answer to a query in the
    /// output (device attributes, cursor position, a color), or a report of
    /// its own focus or size — rather than anything a person did.
    ///
    /// On a PTY that is input like any other: this emulator is the only
    /// terminal the program has. A Rex terminal lives on the Rex server,
    /// which parses the same output and answers it there, so none of it is
    /// forwarded. Forwarding did two things, both measured: the program
    /// read every answer twice, and — since a write is what claims a Rex
    /// terminal's size (`RexSession`) — a tab nobody was touching took the
    /// terminal back from whoever was using it in Rex, each time the
    /// program asked something. A program that asks on every resize made
    /// that a loop: the two clients traded the size for as long as the
    /// other kept claiming it.
    func sendTerminalReport(_ data: Data, from screen: TerminalScreen? = nil) {
        guard route.rexTarget == nil else { return }
        sendInput(data, from: screen)
    }

    /// `screen` is the emulator the input came out of; nil is the one the
    /// keyboard is on, which is what every caller that is not an emulator
    /// means.
    func sendInput(_ data: Data, from screen: TerminalScreen? = nil) {
        guard status == .live else { return }
        // While the jump search pages the remote transcript, a keystroke
        // would interleave with the automated PgUp stream — the FINDING veil
        // is the visible contract for this lock.
        if case .finding = historyJump { return }
        if case .jumped = historyJump {
            // Typing (or Escape) returns Claude Code's pager to the live
            // tail on its own; drop the app-side state with it.
            historyJump = nil
            historyJumpTarget = nil
        }
        // Escape is the select-text HUD's exit key and the mode is app-local,
        // so the byte must not leak to the remote (it could interrupt a
        // running agent). When tmux copy mode is also active the byte keeps
        // riding below — tmux needs it to leave its own mode.
        if selectTextModeUIActive, data == Data([0x1B]) {
            setSelectTextModeUIActive(false)
            if !tmuxCopyModeUIActive { return }
        }
        statsBytesOut += data.count
        (screen ?? activeScreen)?.send(data)
        // Both the app-owned DONE action and a hardware/software Escape key
        // travel through this same delegate path. Restore normal tmux mouse
        // reporting only after the cancel byte has joined the ordered pump.
        if tmuxCopyModeUIActive, data == Data([0x1B]) {
            setTmuxCopyModeUIActive(false)
        }
    }

    /// One entry point for the shared shortcut panel: dispatch by the row's
    /// own payload. A payload mismatched to this tab's backend fails closed
    /// on the per-backend route guards below.
    func performPanelShortcut(_ item: ShortcutPanelItem) {
        switch item.payload {
        case .tmux(let shortcut): performTmuxShortcut(shortcut)
        case .herdr(let shortcut): performHerdrShortcut(shortcut)
        case .pane(let shortcut): performPaneShortcut(shortcut)
        }
    }

    /// Apply the panel's native rename field: the stock `,` binding opens a
    /// client-side tmux prompt an exec can neither target (several clients)
    /// nor drive — command-prompt blocks the exec until answered — so the
    /// panel collects the name and this renames the active window directly.
    func performPanelRename(_ item: ShortcutPanelItem, to name: String) {
        guard case .tmux(let shortcut) = item.payload,
              shortcut.promptsForWindowName,
              status == .live, route.usesTmux,
              let sessionName = route.sessionName
        else { return }
        if case .finding = historyJump { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await executeControlCommand(TmuxProbe.renameWindowCommand(
                sessionName: sessionName, newName: trimmed
            ))
        }
    }

    /// A held resize row: the same active-pane command at tmux's own coarse
    /// step. Only resize rows hold, so anything else fails closed.
    func performPanelShortcutCoarse(_ item: ShortcutPanelItem) {
        guard case .tmux(let shortcut) = item.payload,
              shortcut.resizeDirection != nil
        else { return }
        performTmuxShortcut(shortcut, resizeCells: TmuxShortcut.coarseResizeCells)
    }

    /// Hand the visible screen to native selection on any session-backed
    /// tab. Entered from the selection block's SELECT/SELECT ALL, which carry
    /// the gesture's cell so selection targets that pane — and the backend's
    /// focus follows it, the switch a tap would have made had the mode not
    /// kept taps local. No position (the DEBUG
    /// hook) targets the focused pane.
    func beginSelectTextMode(atScreenPosition point: (col: Int, row: Int)? = nil) {
        guard status == .live else { return }
        if case .finding = historyJump { return }
        setSelectTextModeUIActive(true)
        refreshSelectTextClamp(targeting: point)
    }

    /// The block's DONE. Local state only — the remote never entered a mode.
    func finishSelectTextMode() {
        setSelectTextModeUIActive(false)
    }

    /// Ask the backend for the visible panes' screen rectangles and clamp
    /// local selection into the target pane — the pressed one when a
    /// position rides along, the focused one otherwise. A selection must
    /// not bleed across a pane border, and Select All should mean the pane,
    /// not the screen (which on herdr would also sweep the sidebar and tab
    /// bar). When the target is not the focused pane, focus follows: tmux
    /// by pane id; herdr's only focus verb is directional, so one step
    /// fires and only in a two-pane layout, where a single step is exact.
    /// Fail-soft throughout: no answer leaves the whole-screen behavior.
    ///
    /// The geometry applies only once two consecutive answers agree
    /// (`PaneClampSettle`): with a second client of another size attached,
    /// the backend sizes its one shared viewport to the last client that
    /// typed — and the entry gesture is itself such input — so the first
    /// answer can still describe the other client's geometry (reported
    /// 2026-08-09 as a mispositioned selection block on iPhone beside a
    /// terminal `herdr attach`; the ~200 ms viewport-move lag is measured).
    private func refreshSelectTextClamp(targeting point: (col: Int, row: Int)? = nil) {
        guard selectTextModeUIActive,
              let backend = route.sessionBackend,
              let sessionName = route.sessionName
        else { return }
        selectTextClampGeneration &+= 1
        let generation = selectTextClampGeneration
        // nil where there is no pane-rect query to make: each pane of a Rex
        // tab is its own emulator, so a selection cannot cross into a
        // sibling and has nothing to be clamped away from. (The `.rex` arms
        // further down only keep those switches total.)
        let command: String? = switch backend {
        case .tmux: TmuxProbe.paneRectsCommand(sessionName: sessionName)
        case .herdr: HerdrProbe.snapshotCommand(sessionName: sessionName)
        case .rex: nil
        }
        guard let command else { return }
        // Cancellation ends a superseded fetch at its next sleep — resize
        // re-enters here on every keyboard show/hide, and the generation
        // check alone would let each stale task finish its execs first.
        selectTextClampTask?.cancel()
        selectTextClampTask = Task {
            // All rounds share one control connection: on mosh the closure
            // is a fresh SSH handshake, so per-round connections would pay
            // it twice per Select Text entry.
            let settled = (try? await withControlConnection { control -> [PaneScreenRectEntry]? in
                var settle = PaneClampSettle()
                for attempt in 0..<PaneClampSettle.maxRounds {
                    if attempt > 0 {
                        try await Task.sleep(
                            for: .milliseconds(PaneClampSettle.retryDelayMilliseconds)
                        )
                    }
                    guard generation == selectTextClampGeneration,
                          selectTextModeUIActive
                    else { return nil }
                    let output = try await control.exec(command)
                    guard generation == selectTextClampGeneration,
                          selectTextModeUIActive
                    else { return nil }
                    let round = switch backend {
                    case .tmux: TmuxProbe.parsePaneRects(output)
                    case .herdr: HerdrProbe.parsePaneScreenRects(output, screenSize: screenSize)
                    case .rex: [PaneScreenRectEntry]()
                    }
                    // No answer keeps the current no-clamp behavior;
                    // retrying could not distinguish a host without the
                    // verb from noise.
                    guard !round.isEmpty else { return nil }
                    if let panes = settle.offer(round) { return panes }
                }
                return nil
            }) ?? nil
            guard let panes = settled else { return }
            let focused = panes.first(where: \.isFocused)
            guard let target = point.flatMap({ p in
                panes.first(where: { $0.rect.contains(col: p.col, row: p.row) })
            }) ?? focused ?? panes.first
            else { return }
            terminalView?.selectionClampRect = (target.rect.columns, target.rect.rows)
            guard !target.isFocused else { return }
            switch backend {
            case .tmux:
                await executeControlCommand(
                    TmuxProbe.focusPaneCommand(paneID: target.id)
                )
            case .herdr:
                guard panes.count == 2, let focused,
                      let direction = PaneScreenRect.direction(
                        from: focused.rect, to: target.rect
                      )
                else { return }
                await executeControlCommand(HerdrProbe.focusPaneDirectionCommand(
                    sessionName: sessionName, direction: direction
                ))
            case .rex:
                return
            }
        }
    }

    /// Run one command from the shared tmux panel. Split rows use the SSH
    /// control plane on every transport: on iPad a stock Ctrl-B + shifted `%`
    /// burst can intermittently reach tmux without its prefix and type `%`
    /// into the pane, including on an SSH tab. Other ordinary rows enter
    /// through SwiftTerm exactly like keyboard input. Confirmed destructive
    /// rows already use the control path to avoid tmux's prompt.
    func performTmuxShortcut(_ shortcut: TmuxShortcut, resizeCells: Int = 1) {
        guard status == .live, route.usesTmux,
              let sessionName = route.sessionName
        else { return }
        // The jump search owns the pane while it pages; a shortcut now would
        // either be dropped by the input lock (leaving copy-mode UI stuck
        // half-armed) or race the remote script.
        if case .finding = historyJump { return }
        switch TmuxProbe.shortcutDelivery(
            shortcut, sessionName: sessionName, resizeCells: resizeCells
        ) {
        case .controlCommand(let command):
            Task { await executeControlCommand(command) }
        case .terminalInput(let input):
            guard let terminalView else { return }
            if shortcut == .copyMode {
                // Copy mode freezes the remote pane for navigation, but its
                // default mouse table fights UIKit selection. Switch the
                // surface to native selection before the binding arrives;
                // remote pans continue as cursor keys in the alternate screen.
                setTmuxCopyModeUIActive(true)
            }
            terminalView.send(input)
        case nil:
            return
        }
    }

    /// Run one command from the herdr panel (HRDR) — `performTmuxShortcut`'s
    /// herdr-backend sibling. Non-destructive rows send herdr's stock ⌃B
    /// binding through SwiftTerm; the confirmed closes resolve the focused
    /// target from one snapshot exec and close it by id, so they follow the
    /// server's truth rather than a rebindable key.
    func performHerdrShortcut(_ shortcut: HerdrShortcut) {
        guard status == .live, route.sessionBackend == .herdr,
              let sessionName = route.sessionName
        else { return }
        if case .finding = historyJump { return }
        if let input = shortcut.bindingInput {
            terminalView?.send(input)
            return
        }
        guard let scope = shortcut.closeScope else { return }
        Task { await closeHerdrFocusedTarget(scope, sessionName: sessionName) }
    }

    /// Snapshot → focused id → close, two control execs. An unreadable
    /// snapshot or an unnamed focus declines silently — the tmux closes'
    /// `[ -n "$target" ]` posture: a close must never guess its target.
    private func closeHerdrFocusedTarget(
        _ scope: HerdrShortcut.CloseScope, sessionName: String
    ) async {
        let snapshot = HerdrProbe.snapshotCommand(sessionName: sessionName)
        guard let output = try? await withControlConnection({
            try await $0.exec(snapshot)
        }),
            let target = HerdrProbe.parseFocusedCloseTarget(output, scope: scope),
            let close = HerdrProbe.closeShortcutCommand(
                sessionName: sessionName, scope: scope, targetID: target
            )
        else { return }
        await executeControlCommand(close)
    }

    /// The shortcut panel's switch list — tmux windows or herdr workspaces,
    /// decided by this tab's backend so the panel never learns one.
    func loadShortcutSwitchChoices() async -> [TmuxWindowChoice]? {
        switch route.sessionBackend {
        case .tmux: await loadTmuxWindowList()
        case .herdr: await loadHerdrWorkspaceList()
        case .rex: await loadRexTerminalList()
        case nil: nil
        }
    }

    func selectShortcutSwitchChoice(_ choice: TmuxWindowChoice) {
        switch route.sessionBackend {
        case .tmux: selectTmuxWindow(choice)
        case .herdr: selectHerdrWorkspace(choice)
        case .rex: selectRexTerminal(choice)
        case nil: break
        }
    }

    #if DEBUG
    private static var debugRexSwitchFired = false

    /// `MULTIPLEX_AUTO_REX_SWITCH=<n>` — the headless stand-in for pressing
    /// the REX panel's nth Switch Terminal row (simctl has no tap). It goes
    /// through the same two entry points the panel uses, six seconds after
    /// the first Rex tab goes live, once per process.
    private func debugAutoSwitchRexTerminal() {
        guard !Self.debugRexSwitchFired,
              let raw = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_REX_SWITCH"],
              let position = Int(raw), position > 0
        else { return }
        Self.debugRexSwitchFired = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, let choices = await self.loadRexTerminalList(),
                  choices.indices.contains(position - 1)
            else { return }
            self.selectRexTerminal(choices[position - 1])
        }
    }

    private static var debugPaneActionsFired = false

    /// `MULTIPLEX_AUTO_PANE_ACTIONS=splitRight,splitDown,ratio:0.3,focus:1,closePane`
    /// — the headless stand-in for the pane rows of the REX panel, a
    /// divider drag and a touch on a pane (simctl has neither tap nor
    /// drag). Each step goes through the entry point its control uses, four
    /// seconds apart, starting six seconds after the first Rex tab goes
    /// live, once per process. `ratio:` moves the first split of the
    /// layout; `focus:` puts the keyboard on the nth pane in reading order.
    private func debugAutoPaneShortcuts() {
        guard !Self.debugPaneActionsFired,
              let raw = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_PANE_ACTIONS"],
              !raw.isEmpty
        else { return }
        Self.debugPaneActionsFired = true
        let steps = raw.split(separator: ",").map(String.init)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            for step in steps {
                guard let self, self.status == .live else { return }
                if let shortcut = PaneShortcut(rawValue: step) {
                    self.performPaneShortcut(shortcut)
                } else if step.hasPrefix("ratio:"), let ratio = Double(step.dropFirst(6)),
                          case .split(let split)? = self.paneLayout {
                    self.setPaneRatio(ratio, ofSplit: split.id)
                } else if step.hasPrefix("focus:"), let position = Int(step.dropFirst(6)),
                          let panes = self.paneLayout?.panes,
                          panes.indices.contains(position - 1) {
                    self.focusPane(panes[position - 1])
                    self.focusTerminal()
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
    #endif

    /// The REX panel's Switch Terminal rows: every terminal of this tab's
    /// session, asked of the server over the tab's own control connection.
    func loadRexTerminalList() async -> [TmuxWindowChoice]? {
        guard status == .live, let rexSession else { return nil }
        return await rexSession.terminalChoices()
    }

    /// Point this tab at another terminal of its session, in place. Unlike
    /// tmux and herdr, where the remote client redraws itself, the tab's
    /// own transport does the switching (`RexSession.showTerminal`): a
    /// terminal among the panes on show takes the keyboard, one in another
    /// window brings that window's panes in. Where the tab lands comes back
    /// as an arrangement's focus (`activate`), and is remembered for this
    /// controller's life so a reconnect comes back to the terminal the user
    /// was on, not the one the tab opened with.
    func selectRexTerminal(_ choice: TmuxWindowChoice) {
        guard status == .live, let rexSession else { return }
        Task { await rexSession.showTerminal(choice.tmuxID) }
    }

    /// The directory the pane the keyboard is on is working in.
    private func rexWorkingDirectory() async -> String? {
        guard let rexSession, let pane = activePaneID else { return nil }
        return await rexSession.workingDirectory(of: pane)
    }

    /// The shortcut panel's window list, read through the control path so
    /// SSH and mosh tabs answer alike. A failure returns nil and the panel
    /// simply shows no window section — the shortcut grid stays useful.
    func loadTmuxWindowList() async -> [TmuxWindowChoice]? {
        guard status == .live, route.usesTmux,
              let sessionName = route.sessionName
        else { return nil }
        let command = TmuxProbe.windowListCommand(sessionName: sessionName)
        guard let output = try? await withControlConnection({
            try await $0.exec(command)
        }) else { return nil }
        return TmuxProbe.parseWindowList(output)
    }

    /// Switch the attached session to one of its windows. Direct control
    /// path like the confirmed close actions: no terminal input, no `:`
    /// prompt, and the attached client follows tmux's own state change.
    func selectTmuxWindow(_ window: TmuxWindowChoice) {
        guard status == .live, route.usesTmux else { return }
        if case .finding = historyJump { return }
        let command = TmuxProbe.selectWindowCommand(windowID: window.tmuxID)
        Task { await executeControlCommand(command) }
    }

    /// The herdr panel's workspace rows, through the same control path.
    func loadHerdrWorkspaceList() async -> [TmuxWindowChoice]? {
        guard status == .live, route.sessionBackend == .herdr,
              let sessionName = route.sessionName
        else { return nil }
        let command = HerdrProbe.workspaceListCommand(sessionName: sessionName)
        guard let output = try? await withControlConnection({
            try await $0.exec(command)
        }) else { return nil }
        return HerdrProbe.parseWorkspaceChoices(output)
    }

    /// Focus one workspace of the attached herdr session — the session's ONE
    /// global focus moves, and the attached client follows on its own.
    func selectHerdrWorkspace(_ choice: TmuxWindowChoice) {
        guard status == .live, route.sessionBackend == .herdr,
              let sessionName = route.sessionName
        else { return }
        if case .finding = historyJump { return }
        guard let command = HerdrProbe.focusWorkspaceCommand(
            sessionName: sessionName, workspaceID: choice.tmuxID
        ) else { return }
        Task { await executeControlCommand(command) }
    }

    /// Leave the contextual copy UI and tmux copy mode together. Escape is
    /// deliberately sent through SwiftTerm, so DONE, the rail, and a physical
    /// keyboard all preserve the terminal's single ordered input path.
    func finishTmuxCopyMode() {
        guard tmuxCopyModeUIActive else { return }
        guard status == .live, let terminalView else {
            setTmuxCopyModeUIActive(false)
            return
        }
        terminalView.send(EscapeSequences.cmdEsc)
    }

    #if !os(visionOS)
    /// What either mic control shows: engaged from the press, not from the
    /// microphone, so a permission alert never leaves the action looking
    /// untouched.
    var isDictating: Bool { dictationPhase.isActive }

    /// One dictation action shared by the physical-keyboard rail slot and the
    /// software-keyboard lock tip. Neither path reaches the system keyboard's
    /// own microphone, so both run the same app-owned recognition session.
    func toggleDictation() {
        if isDictating {
            stopDictation()
        } else {
            startDictation()
        }
    }

    /// Finish and type the tail. Most of the dictation is already in the
    /// session — this is the last words the hold rules were still sitting on.
    func stopDictation() {
        dictationDriver.stop()
    }

    /// Leave without typing the rest. Words that already settled are in the
    /// session and stay there — a terminal has no undo, so this abandons the
    /// queue, not the dictation's past.
    func cancelDictation() {
        dictationDriver.cancel()
    }

    /// The LISTENING bar's language chip (see `DictationDriver.selectLanguage`).
    func selectDictationLanguage(_ choice: DictationLanguageChoice) {
        dictationDriver.selectLanguage(choice)
    }

    private func startDictation() {
        guard status == .live else { return }
        // The jump search owns the pane's input while it pages the remote
        // transcript; dictated text would interleave with its PgUp stream.
        if case .finding = historyJump { return }
        dictationDriver.start()
    }

    /// One chunk of settled speech, typed exactly like a rail key or a
    /// dropped file's path — through SwiftTerm and the ordered input pump,
    /// never submitted. The stream already sanitized it and owns the spacing
    /// between chunks, so it goes out verbatim.
    private func typeDictated(_ text: String) {
        guard status == .live, let terminalView else {
            // The session being spoken into is gone. Stop rather than aim the
            // rest of the sentence at whatever takes its place.
            dictationDriver.cancel()
            return
        }
        terminalView.send(txt: text)
    }
    #endif

    private func setTmuxCopyModeUIActive(_ active: Bool) {
        guard tmuxCopyModeUIActive != active else { return }
        tmuxCopyModeUIActive = active
        applyTouchInteractionModes()
    }

    private func setSelectTextModeUIActive(_ active: Bool) {
        guard selectTextModeUIActive != active else { return }
        selectTextModeUIActive = active
        applyTouchInteractionModes()
        if !active {
            selectTextClampGeneration &+= 1
            terminalView?.selectionClampRect = nil
        }
    }

    /// The one writer for the view flags the two app-owned interaction modes
    /// share. Copy mode keeps pans alive as cursor keys (tmux copy mode
    /// answers them); select-text has no remote listener, so its pans are
    /// suppressed outright — unless copy mode is active too and wins.
    private func applyTouchInteractionModes() {
        for screen in screens {
            if let view = screen.terminalView { applyTouchInteractionModes(to: view) }
        }
    }

    private func applyTouchInteractionModes(to view: TerminalView) {
        view.allowMouseReporting =
            !(tmuxCopyModeUIActive || selectTextModeUIActive)
        view.forceRemoteCursorScroll = tmuxCopyModeUIActive
        view.suppressRemotePanScroll =
            selectTextModeUIActive && !tmuxCopyModeUIActive
    }

    /// SSH tabs already own an exec-capable connection next to their PTY.
    /// Mosh tabs deliberately do not, so a destructive user action opens a
    /// short-lived SSH control connection and closes it after the command.
    private func executeControlCommand(_ command: String) async {
        if let connection {
            _ = try? await connection.exec(command)
            return
        }

        let secrets = await HostSecrets.loadOffMain(for: host)
        let control = SSHConnection(host: host, secrets: secrets)
        do {
            try await control.connect()
            _ = try await control.exec(command)
        } catch {
            captureKeyPassphraseChallenge(from: error)
            // The attached terminal remains the source of truth: a failed
            // control action leaves it intact instead of ending the tab.
        }
        await control.close()
    }

    /// SSH tabs reuse their own exec-capable connection; a mosh tab opens
    /// one short-lived control connection for the whole closure, so a
    /// multi-exec flow (history read, jump prologue + find) pays a single
    /// handshake instead of one per command.
    private func withControlConnection<T: Sendable>(
        _ body: (SSHConnection) async throws -> T
    ) async throws -> T {
        if let connection { return try await body(connection) }
        let secrets = await HostSecrets.loadOffMain(for: host)
        let control = SSHConnection(host: host, secrets: secrets)
        do {
            try await control.connect()
        } catch {
            captureKeyPassphraseChallenge(from: error)
            await control.close()
            throw error
        }
        do {
            let value = try await body(control)
            await control.close()
            return value
        } catch {
            await control.close()
            throw error
        }
    }

    // MARK: Agent message history (HISTORY surface + jump-to-message)

    /// Whether this tab can read agent session files at all: tmux routes
    /// resolve the pane cwd over the control path (mosh included — SSH stays
    /// the control plane); a plain shell needs its probe-discovered cwd and
    /// its own exec surface (direct mosh shells have neither).
    var canOfferAgentHistory: Bool {
        guard status == .live else { return false }
        if route.usesTmux { return true }
        // herdr resolves the same transcript identity through its own
        // surfaces: focused-pane cwd from a snapshot, the registry walk
        // rooted at `pane process-info`'s shell_pid (verified 0.7.5).
        if route.sessionBackend == .herdr { return true }
        // Only a true plain shell may use its own process-discovered cwd.
        guard route.sessionName == nil else { return false }
        return connection != nil && directShellWorkingDirectory != nil
    }

    /// The HISTORY panel opened: read the active session file's user
    /// prompts. Reloaded on every open — the file is append-only and the
    /// bounded tail read is cheap. Claude Code only: the session-file
    /// surface concentrates on the one agent whose pager jump is exact.
    func openAgentHistory(for agent: AgentKind) {
        guard canOfferAgentHistory, agent == .claudeCode else { return }
        historyLoadTask?.cancel()
        agentHistory = .loading
        historyLoadTask = Task { [weak self] in
            await self?.loadAgentHistory(agent)
        }
    }

    func closeAgentHistory() {
        historyLoadTask?.cancel()
        historyLoadTask = nil
        agentHistory = nil
    }

    private func loadAgentHistory(_ agent: AgentKind) async {
        let shellCwd = directShellWorkingDirectory
        do {
            let result: AgentSessionHistory.ReadResult? =
                try await withControlConnection { [route] connection in
                    let cwd: String?
                    let preferredSessionID: String?
                    let configDir: String?
                    if route.usesTmux, let sessionName = route.sessionName {
                        let output = try await connection.exec(
                            AgentSessionHistory.paneContextCommand(
                                sessionName: sessionName
                            )
                        )
                        let context = AgentSessionHistory.parsePaneContext(output)
                        cwd = context?.cwd
                        preferredSessionID = context?.agentSessionID
                        configDir = context?.configDir
                    } else if route.sessionBackend == .herdr,
                              let sessionName = route.sessionName {
                        let output = try await connection.exec(
                            AgentSessionHistory.herdrPaneContextCommand(
                                sessionName: sessionName
                            )
                        )
                        let context = AgentSessionHistory.parseHerdrPaneContext(output)
                        cwd = context?.cwd
                        preferredSessionID = context?.agentSessionID
                        configDir = context?.configDir
                    } else {
                        cwd = shellCwd
                        preferredSessionID = nil
                        configDir = nil
                    }
                    guard let cwd else { return nil }
                    let output = try await connection.exec(
                        AgentSessionHistory.readCommand(
                            cwd: cwd,
                            preferredSessionID: preferredSessionID,
                            configDir: configDir
                        )
                    )
                    return AgentSessionHistory.parseReadOutput(output)
                }
            guard !Task.isCancelled, agentHistory != nil else { return }
            guard let result else {
                agentHistory = .unavailable(String(localized: "NO WORKING DIRECTORY"))
                return
            }
            guard result.filePath != nil else {
                agentHistory = .unavailable(String(localized: "NO SESSION FILE"))
                return
            }
            agentHistory = .loaded(
                agent: agent,
                messages: result.messages,
                jumpAvailable: (route.usesTmux || route.sessionBackend == .herdr)
                    && agent == .claudeCode
            )
        } catch {
            guard !Task.isCancelled, agentHistory != nil else { return }
            agentHistory = .unavailable(String(localized: "HISTORY UNAVAILABLE"))
        }
    }

    private enum HistoryJumpOutcome {
        case found(target: AgentSessionHistory.JumpTarget, pages: Int)
        case failed(String)
    }

    /// Scroll the live Claude Code transcript back to `message`: verify the
    /// agent is idle (paging a running turn fights streaming repaints, and
    /// the restore path must never need Esc), then run the one-exec remote
    /// header-oracle walk — see `AgentSessionHistory.jumpFindCommand`. The
    /// full loaded message list rides along: every pinned turn header the
    /// pager shows is matched against it, so each step is directed.
    func startHistoryJump(to message: AgentUserMessage) {
        guard status == .live,
              route.usesTmux || route.sessionBackend == .herdr,
              let sessionName = route.sessionName,
              !tmuxCopyModeUIActive,
              case .loaded(let agent, let messages, true) = agentHistory,
              agent == .claudeCode,
              message.reachable
        else { return }
        // Only an in-flight search blocks a new jump. A lingering `.jumped`
        // state is superseded directly — the find script normalizes to live
        // first, so chaining jumps needs no manual BACK TO LIVE.
        if case .finding = historyJump { return }
        #if !os(visionOS)
        // The search is about to lock the input pump, which would swallow
        // dictated words without a trace. Close the microphone instead.
        cancelDictation()
        #endif
        historyJumpTarget = nil
        let preview = String(message.firstLine.prefix(24))
        historyJump = .finding(preview: preview)
        historyJumpTask = Task { [weak self] in
            await self?.runHistoryJump(
                message: message,
                allMessages: messages,
                sessionName: sessionName,
                preview: preview
            )
        }
    }

    private func runHistoryJump(
        message: AgentUserMessage,
        allMessages: [AgentUserMessage],
        sessionName: String,
        preview: String
    ) async {
        let outcome: HistoryJumpOutcome
        let isHerdr = route.sessionBackend == .herdr
        do {
            outcome = try await withControlConnection { connection in
                let prologueOutput = try await connection.exec(
                    isHerdr
                        ? AgentSessionHistory.herdrJumpPrologueCommand(
                            sessionName: sessionName
                        )
                        : AgentSessionHistory.jumpPrologueCommand(
                            sessionName: sessionName
                        )
                )
                guard let prologue = isHerdr
                    ? AgentSessionHistory.parseHerdrJumpPrologue(prologueOutput)
                    : AgentSessionHistory.parseJumpPrologue(prologueOutput)
                else { return .failed(String(localized: "SESSION NOT FOUND")) }
                // The walk's coordinate: tmux aims at the session (its
                // active pane answers); herdr aims at the prologue's
                // bake-vetted focused pane.
                let target: AgentSessionHistory.JumpTarget = isHerdr
                    ? .herdr(sessionName: sessionName, paneID: prologue.sessionID)
                    : .tmux(sessionID: prologue.sessionID)
                switch AgentAttention.classify(
                    title: prologue.paneTitle, tail: prologue.capture
                ) {
                case .busy: return .failed(String(localized: "AGENT IS BUSY"))
                case .needsYou: return .failed(String(localized: "ANSWER THE AGENT FIRST"))
                case .idle: break
                }
                let targetNeedles = AgentSessionHistory.needles(
                    for: message, paneColumns: prologue.paneWidth
                )
                guard let targetPrimary = targetNeedles.first else {
                    return .failed(String(localized: "MESSAGE TOO SHORT TO FIND"))
                }
                let entries = AgentSessionHistory.needleEntries(
                    for: allMessages, paneColumns: prologue.paneWidth
                )
                // Identical prompts ("commit") share one needle: tell the
                // walk how many NEWER twins to climb past so it lands on
                // the requested one, not the nearest. Prefix matching, not
                // equality — the walk's row sightings are prefix matches,
                // so a newer "commit everything" row would count as a
                // sighting of target "commit" and must be climbed through
                // too. The shorter fallback needle can conflate MORE
                // prompts, so it carries its own count for the mid-walk
                // swap.
                let newerTwins = entries.filter {
                    $0.index > message.ordinal && $0.text.hasPrefix(targetPrimary)
                }.count
                let fallbackTwins = targetNeedles.dropFirst().first.map { fb in
                    entries.filter {
                        $0.index > message.ordinal && $0.text.hasPrefix(fb)
                    }.count
                }
                let findOutput = try await connection.exec(
                    AgentSessionHistory.jumpFindCommand(
                        target: target,
                        needles: entries,
                        targetIndex: message.ordinal,
                        targetNeedles: targetNeedles,
                        newerTwinCount: newerTwins,
                        fallbackTwinCount: fallbackTwins,
                        // Narrow/short panes rewrap the transcript into far
                        // more rows; the runaway stop scales with the pane
                        // the prologue just measured.
                        sendBudget: AgentSessionHistory.jumpSendBudget(
                            paneWidth: prologue.paneWidth,
                            paneHeight: prologue.capture.count
                        ),
                        // Claude's sticky header is click-to-jump when the
                        // pane has SGR mouse reporting on — the walk skips
                        // whole responses instead of scrolling them.
                        headerClicks: prologue.supportsHeaderClicks
                    )
                )
                switch AgentSessionHistory.parseJumpFind(findOutput) {
                case .found(let pages), .near(let pages):
                    // .near landed at the turn's top: the sticky header IS
                    // the message's flattened row (a rebuilt transcript
                    // omits long multiline prompt bodies). From the user's
                    // seat that is the jump destination.
                    return .found(target: target, pages: pages)
                case .top, .exhausted:
                    // The remote script already restored the live view. A
                    // second differently-sized client can invalidate the
                    // walk without a mid-walk flip (it reflows the render
                    // the needles were built against), so name it.
                    return .failed(
                        prologue.clientSizeCount > 1
                            ? String(localized: "ANOTHER CLIENT RESIZES THIS SESSION")
                            : String(localized: "NOT IN THE VISIBLE TRANSCRIPT")
                    )
                case .short:
                    return .failed(String(localized: "TERMINAL TOO SHORT TO JUMP"))
                case .resized:
                    return .failed(
                        prologue.clientSizeCount > 1
                            ? String(localized: "ANOTHER CLIENT RESIZES THIS SESSION")
                            : String(localized: "RESIZED MID-JUMP — TRY AGAIN")
                    )
                case nil:
                    return .failed(String(localized: "SEARCH FAILED"))
                }
            }
        } catch {
            outcome = .failed(String(localized: "SEARCH FAILED"))
        }

        switch outcome {
        case .found(let target, let pages):
            if Task.isCancelled || historyJump == nil {
                // Cancelled mid-find but the search landed: put the pane
                // back rather than leaving it silently paged.
                returnTranscriptToLive(target: target, pages: pages)
                return
            }
            historyJumpTarget = target
            historyJump = .jumped(preview: preview, pages: pages)
        case .failed(let reason):
            guard !Task.isCancelled, historyJump != nil else { return }
            historyJump = nil
            showHistoryNotice(reason)
        }
    }

    /// CANCEL during `.finding`. The remote script is already running and
    /// finishes on its own (it self-restores on a miss); a late FOUND result
    /// is answered with a restore in `runHistoryJump`.
    func cancelHistoryJump() {
        guard case .finding = historyJump else { return }
        historyJump = nil
        historyJumpTask?.cancel()
    }

    /// BACK TO LIVE from `.jumped`: Claude's Ctrl+End scroll-bottom binding,
    /// never Esc — a turn may have started since the search verified idle.
    func finishHistoryJump() {
        guard case .jumped(_, let pages) = historyJump else { return }
        let target = historyJumpTarget
        historyJump = nil
        historyJumpTarget = nil
        guard let target else { return }
        returnTranscriptToLive(target: target, pages: pages)
    }

    private func returnTranscriptToLive(
        target: AgentSessionHistory.JumpTarget, pages: Int
    ) {
        Task { [weak self] in
            _ = try? await self?.withControlConnection { connection in
                try await connection.exec(
                    AgentSessionHistory.jumpReturnCommand(
                        target: target, pages: pages
                    )
                )
            }
        }
    }

    private func showHistoryNotice(_ text: String) {
        historyNoticeClearTask?.cancel()
        historyNotice = text
        historyNoticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.historyNotice = nil
        }
    }

    private func resetHistoryState() {
        historyLoadTask?.cancel()
        historyLoadTask = nil
        agentHistory = nil
        historyJumpTask?.cancel()
        historyJumpTask = nil
        historyJump = nil
        historyJumpTarget = nil
        historyNoticeClearTask?.cancel()
        historyNoticeClearTask = nil
        historyNotice = nil
    }

    #if DEBUG
    /// Runtime verification only: deliberately enters through SwiftTerm so
    /// the proof covers TerminalView → delegate → this controller's ordered
    /// input pump, exactly like a shortcut row selected by the user.
    @discardableResult
    func debugSendTmuxShortcutThroughTerminal(_ shortcut: TmuxShortcut) -> Bool {
        guard status == .live,
              route.usesTmux,
              shortcut.bindingInput != nil,
              terminalView != nil
        else { return false }
        performTmuxShortcut(shortcut)
        return true
    }
    #endif

    func terminalResized(cols: Int, rows: Int, of screen: TerminalScreen? = nil) {
        guard let screen = screen ?? activeScreen,
              screen.resized(cols: cols, rows: rows),
              status == .live
        else { return }
        // A resize relayouts the multiplexer's panes, so a select-text clamp
        // fetched for the old geometry is wrong — refetch (the generation
        // counter drops the stale answer if resizes storm).
        if selectTextModeUIActive { refreshSelectTextClamp() }
    }

    /// Scene became active again: a mosh transport heartbeats immediately
    /// (and replaces its socket if suspension killed it), so the session
    /// proves itself within a round trip instead of a heartbeat interval.
    func transportForegrounded() {
        guard let moshSession else { return }
        Task { await moshSession.nudge() }
    }

    // MARK: File attachments and drops

    /// Files selected from terminal chrome or dropped on this tab's pane:
    /// upload each into the active pane's working directory over this tab's
    /// own connection, then type the resulting paths through the input pump
    /// — no Enter, the user finishes the prompt. One batch at a time.
    /// Whether this tab can take a file: an SSH-backed session tab. Mosh has
    /// no SFTP channel, and a plain shell has no multiplexer pane whose
    /// foreground cwd could be resolved. The chrome's FILE rule and the
    /// Talkback paperclip both read this.
    var canUploadFiles: Bool {
        !ridesMosh && route.sessionBackend != nil
    }

    static let uploadUnavailableMessage =
        String(localized: "File upload requires tmux or herdr over SSH")

    func deliverDrop(_ files: [DroppedFile]) {
        // The jump search owns the pane's input while it pages; the FINDING
        // veil is visible over the drop target for its few seconds.
        if case .finding = historyJump { return }
        if !canUploadFiles, status == .live, dropTask == nil, !files.isEmpty {
            // Say so instead of silently discarding the user's attach/drop
            // intent.
            dropClearTask?.cancel()
            dropState = .failed(Self.uploadUnavailableMessage)
            dropClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.dropState = nil
            }
            return
        }
        guard status == .live, let connection, dropTask == nil, !files.isEmpty else { return }
        dropClearTask?.cancel()
        dropClearTask = nil
        dropTask = Task { [weak self] in
            await self?.performDrop(files, over: connection)
            self?.dropTask = nil
        }
    }

    private func performDrop(_ files: [DroppedFile], over connection: SSHConnection) async {
        do {
            let displayNames = files.map(\.name)
            dropState = .uploading(name: files[0].name, fraction: 0)
            let typedPaths = try await uploadForTypedPaths(files, over: connection) { [weak self] index, fraction in
                Task { @MainActor [weak self] in
                    guard case .uploading = self?.dropState else { return }
                    self?.dropState = .uploading(
                        name: displayNames[index],
                        fraction: fraction
                    )
                }
            }
            dropState = nil
            sendInput(Data(DropText.typedPaths(typedPaths).utf8))
        } catch is CancellationError {
            dropState = nil
        } catch {
            dropState = .failed((error as? DropError)?.message ?? String(localized: "Upload failed"))
            dropClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.dropState = nil
            }
        }
    }

    /// The one upload for both roads — the pane's drop path and the Talkback
    /// draft: the destination resolved once per batch, names sanitized, the
    /// 64 MB cap applied, and the paths as they will be typed handed back.
    /// Progress arrives per file index; failure throws (`DropError` carries
    /// the user-facing words).
    private func uploadForTypedPaths(
        _ files: [DroppedFile],
        over connection: SSHConnection,
        onProgress: @escaping @Sendable (_ index: Int, _ fraction: Double) -> Void
    ) async throws -> [String] {
        try await upload(
            files,
            to: dropDestination(over: connection),
            over: connection,
            onProgress: onProgress
        )
    }

    private func upload(
        _ files: [DroppedFile],
        to destination: DropDestination,
        over connection: SSHConnection,
        onProgress: @escaping @Sendable (_ index: Int, _ fraction: Double) -> Void
    ) async throws -> [String] {
        let uploads = try files.map { file -> SSHUpload in
            guard file.data.count <= DropText.maxBytes else {
                throw DropError(message: String(localized: "\(file.name) is over 64 MB"))
            }
            return SSHUpload(
                data: file.data,
                preferredName: DropText.sanitizedName(file.name)
            )
        }
        let finalNames = try await connection.uploadFiles(
            uploads,
            toDirectory: destination.directory,
            prepareGitIgnoredDirectory: destination.prepareGitIgnoredDirectory,
            onProgress: onProgress
        )
        return finalNames.map(destination.typedPath(for:))
    }

    private struct DropDestination {
        var directory: String
        /// Prefix for typed relative paths ("" = bare name,
        /// ".multiplex-drops/" inside git worktrees); nil types absolute.
        var typedPrefix: String?
        var prepareGitIgnoredDirectory: Bool

        /// Relative names read best in a prompt, but only when the file
        /// verifiably sits under the pane's cwd.
        func typedPath(for finalName: String) -> String {
            typedPrefix.map { $0 + finalName } ?? directory + "/" + finalName
        }
    }

    /// The pane's cwd when the session backend can tell us (both follow
    /// the foreground process, i.e. the agent's own cwd) — corralled into
    /// a self-ignoring `.multiplex-drops/` when that cwd is inside a git
    /// worktree, so drops never clutter `git status`. Otherwise $HOME with
    /// absolute typed paths.
    private func dropDestination(
        over connection: SSHConnection
    ) async throws -> DropDestination {
        let anchor = await paneDropAnchor(over: connection)
        if let path = anchor.cwd {
            if anchor.insideGitWorktree {
                return DropDestination(
                    directory: path + "/" + DropText.dropsDirectoryName,
                    typedPrefix: DropText.dropsDirectoryName + "/",
                    prepareGitIgnoredDirectory: true
                )
            }
            return DropDestination(
                directory: path,
                typedPrefix: "",
                prepareGitIgnoredDirectory: false
            )
        }
        return DropDestination(
            directory: try await connection.remoteHomeDirectory(),
            typedPrefix: nil,
            prepareGitIgnoredDirectory: false
        )
    }

    /// The backend-dispatched cwd + git-worktree answer behind a drop.
    /// tmux resolves both in one exec (the cwd stays in a shell variable
    /// for the git check). herdr's cwd comes home in snapshot JSON —
    /// strictly the focused pane, where this tab's typed paths land — so
    /// the corral check is its own exec with the app-resolved path
    /// respliced; both print the marker `TmuxProbe.parseDropDestination`
    /// reads. Any failure is (nil, false): the $HOME fallback, never an
    /// error.
    private func paneDropAnchor(
        over connection: SSHConnection
    ) async -> (cwd: String?, insideGitWorktree: Bool) {
        guard let sessionName = route.sessionName else { return (nil, false) }
        switch route.sessionBackend {
        case .tmux:
            let output = (try? await connection.exec(
                TmuxProbe.dropDestinationCommand(sessionName: sessionName)
            )) ?? ""
            return TmuxProbe.parseDropDestination(output)
        case .herdr:
            let snapshot = (try? await connection.exec(
                HerdrProbe.snapshotCommand(sessionName: sessionName)
            )) ?? ""
            guard let cwd = HerdrProbe.parseFocusedPaneWorkingDirectory(snapshot)
            else { return (nil, false) }
            let check = (try? await connection.exec(
                TmuxProbe.gitWorktreeCheckCommand(directory: cwd)
            )) ?? ""
            return (cwd, TmuxProbe.parseDropDestination(check).insideGitWorktree)
        case .rex:
            // Rex answers over the tab's own control connection rather than
            // an exec, and — like herdr — hands the path home as data, so
            // the corral check is its own exec with it respliced.
            guard let cwd = await rexWorkingDirectory()
            else { return (nil, false) }
            let check = (try? await connection.exec(
                TmuxProbe.gitWorktreeCheckCommand(directory: cwd)
            )) ?? ""
            return (cwd, TmuxProbe.parseDropDestination(check).insideGitWorktree)
        case nil:
            return (nil, false)
        }
    }

    // MARK: Talkback

    /// The chat-style message box under this tab's pane. `talkbackOpen` is
    /// what the window, the rail and the cluster watch (it flips on the talk
    /// key); `talkback` is the draft only the composer renders — text and
    /// attachments — so a keystroke never re-renders a window. Both follow
    /// the tab across windows and die with it; never persisted. SEND is
    /// `sendTalkback`. Design record: `local-plan/talkback-bakeoff/`.
    private(set) var talkbackOpen = false
    private(set) var talkback = TalkbackDraft()
    /// The picked bytes behind each attachment, kept until the message is
    /// sent or the chip removed, so a failed upload retries without another
    /// trip through the picker.
    @ObservationIgnored private var talkbackFiles: [UUID: DroppedFile] = [:]
    /// Each queued chip remembers its pick: the drop destination is resolved
    /// once per pick (one exec, like a drop's batch), not once per file — a
    /// later pick re-resolves, the pane's cwd may have moved between picks.
    @ObservationIgnored private var talkbackUploadQueue: [(id: UUID, pick: Int)] = []
    @ObservationIgnored private var talkbackPicks = 0
    @ObservationIgnored private var talkbackPickDestination: (pick: Int, destination: DropDestination)?
    @ObservationIgnored private var talkbackUploadTask: Task<Void, Never>?
    /// The last focus request the composer consumed — per tab, so a tab
    /// switch back to an open box never re-takes the keyboard.
    @ObservationIgnored private var talkbackFocusHandled = 0

    /// The SEND face with this tab's own input rules folded in: nothing goes
    /// while the tab isn't live or the history jump owns the pane.
    var talkbackSendState: TalkbackDraft.SendState {
        guard status == .live else { return .disabled }
        if case .finding = historyJump { return .disabled }
        return talkback.sendState
    }

    /// The talk key. Opening asks the composer to take the keyboard; a key
    /// pressed on an already-open box asks again (the box may have lost the
    /// keyboard to the pane).
    func setTalkbackOpen(_ open: Bool) {
        if open { talkback.focusRequest &+= 1 }
        if talkbackOpen != open { talkbackOpen = open }
    }

    func toggleTalkback() {
        setTalkbackOpen(!talkbackOpen)
    }

    /// True exactly once per open/keypress: the composer focuses its field
    /// on it and never on a mere re-render.
    func consumeTalkbackFocusRequest() -> Bool {
        guard talkback.focusRequest != talkbackFocusHandled else { return false }
        talkbackFocusHandled = talkback.focusRequest
        return true
    }

    /// The field's edits — the composer is the writer, this is the record.
    func setTalkbackText(_ text: String) {
        guard talkback.text != text else { return }
        talkback.text = text
    }

    /// Files picked through the composer's paperclip: each becomes an
    /// uploading chip and joins one serial upload queue (the drop path's
    /// SFTP, into the pane's cwd). Tabs that can't upload fail the chips
    /// with the drop path's own words instead of dropping the intent
    /// silently.
    func attachTalkbackFiles(_ files: [DroppedFile]) {
        talkbackPicks &+= 1
        for file in files {
            let kind = TalkbackAttachment.kind(forName: file.name)
            let attachment = TalkbackAttachment(
                name: file.name,
                byteCount: file.data.count,
                kind: kind
            )
            talkbackFiles[attachment.id] = file
            talkback.attachments.append(attachment)
            enqueueTalkbackUpload(attachment.id, pick: talkbackPicks)
            guard kind == .image else { continue }
            // Decoding a camera-sized photo is tens of milliseconds; the chip
            // shows its ring first and its picture a beat later.
            let id = attachment.id
            let data = file.data
            Task.detached(priority: .userInitiated) { [weak self] in
                let preview = TalkbackThumbnail.jpeg(from: data)
                await MainActor.run { [weak self] in
                    self?.talkback.update(id) { $0.preview = preview }
                }
            }
        }
    }

    /// The drain loop skips an id no longer attached, so removal needs no
    /// queue surgery.
    func removeTalkbackAttachment(_ id: UUID) {
        talkback.attachments.removeAll { $0.id == id }
        talkbackFiles[id] = nil
    }

    /// A failed chip's tap: back to uploading, back in the queue as a pick
    /// of its own (the destination is resolved afresh — it may be what
    /// failed).
    func retryTalkbackAttachment(_ id: UUID) {
        guard talkbackFiles[id] != nil,
              talkback.attachments.first(where: { $0.id == id })?.isFailed == true
        else { return }
        talkback.update(id) { $0.state = .uploading(fraction: 0) }
        talkbackPicks &+= 1
        enqueueTalkbackUpload(id, pick: talkbackPicks)
    }

    /// SEND (`submit`) or a long-press SEND (type only): one paste through
    /// the ordered pump — the landed paths first, then the body, wrapped in
    /// the bracketed-paste markers when the pane has mode 2004 on — and, for
    /// SEND, a CR as its own write ~160 ms later (the slash chips' shape).
    /// Clears the draft; the box stays open. False when nothing went.
    @discardableResult
    func sendTalkback(submit: Bool) -> Bool {
        guard talkbackSendState == .ready else { return false }
        let bracketed = terminalView?.terminalStateSnapshot().bracketedPasteMode == true
        let payload = TalkbackMessage.payload(
            body: talkback.text,
            paths: talkback.readyPaths,
            bracketed: bracketed
        )
        guard !payload.isEmpty else { return false }
        typeTalkback(payload)
        if submit {
            Task { [weak self] in
                try? await Task.sleep(for: TalkbackMessage.submitDelay)
                self?.typeTalkback(TalkbackMessage.submit)
            }
        }
        // `.ready` means nothing is uploading or queued, so the kept bytes
        // are exactly the attachments that just went.
        talkbackFiles.removeAll()
        talkback.clearAfterSend()
        return true
    }

    /// The view's send path when it exists (it stamps the typing-quiet
    /// clock and keeps the caret in view), the pump directly otherwise.
    private func typeTalkback(_ data: Data) {
        if let terminalView {
            terminalView.send(data: [UInt8](data)[...])
        } else {
            sendInput(data)
        }
    }

    private func enqueueTalkbackUpload(_ id: UUID, pick: Int) {
        talkbackUploadQueue.append((id, pick))
        guard talkbackUploadTask == nil else { return }
        talkbackUploadTask = Task { [weak self] in
            await self?.drainTalkbackUploads()
            self?.talkbackUploadTask = nil
        }
    }

    private func drainTalkbackUploads() async {
        while !talkbackUploadQueue.isEmpty {
            let entry = talkbackUploadQueue.removeFirst()
            guard let file = talkbackFiles[entry.id],
                  talkback.attachments.contains(where: { $0.id == entry.id })
            else { continue }
            await uploadTalkbackAttachment(entry.id, file: file, pick: entry.pick)
        }
    }

    /// The drop path's upload, one file at a time so a failure marks only
    /// its own chip, into the destination resolved for this chip's pick.
    private func uploadTalkbackAttachment(_ id: UUID, file: DroppedFile, pick: Int) async {
        guard canUploadFiles else {
            failTalkbackAttachment(id, Self.uploadUnavailableMessage)
            return
        }
        guard status == .live, let connection else {
            failTalkbackAttachment(id, String(localized: "Not connected"))
            return
        }
        do {
            let destination: DropDestination
            if let memo = talkbackPickDestination, memo.pick == pick {
                destination = memo.destination
            } else {
                destination = try await dropDestination(over: connection)
                talkbackPickDestination = (pick, destination)
            }
            let paths = try await upload([file], to: destination, over: connection) { [weak self] _, fraction in
                Task { @MainActor [weak self] in
                    self?.talkback.update(id) { attachment in
                        guard attachment.isUploading else { return }
                        attachment.state = .uploading(fraction: fraction)
                    }
                }
            }
            guard let path = paths.first else {
                throw DropError(message: String(localized: "Upload failed"))
            }
            talkback.update(id) { $0.state = .ready(path: path) }
        } catch is CancellationError {
            failTalkbackAttachment(id, String(localized: "Cancelled"))
        } catch {
            failTalkbackAttachment(
                id, (error as? DropError)?.message ?? String(localized: "Upload failed")
            )
        }
    }

    private func failTalkbackAttachment(_ id: UUID, _ message: String) {
        talkback.update(id) { $0.state = .failed(message) }
    }

    // MARK: Links

    /// A link the terminal resolved under a tap or long press. Returns
    /// whether this pane claims the gesture. URLs confirm through the link
    /// sheet; path-shaped text (implicit detection matches those too) now
    /// confirms through the file-viewer sheet instead of falling to
    /// selection; only what neither resolver accepts ($VAR/…, colon prose,
    /// an agent's `/compact`) still declines into text selection.
    ///
    /// `rowFragments` is the match split at its hard-wrap seams (empty when
    /// it fit one row, or from callers without seam info — the debug hook,
    /// gaze regions): a prose word butting a seam means the rows below start
    /// their own target (`and`⏎`local-plan/x` is not one path), so the cut
    /// suffix resolves first and the join stays the fallback.
    func activateLink(
        _ target: String,
        rowFragments: [String] = [],
        pressedAt cell: (col: Int, row: Int)? = nil
    ) -> Bool {
        // The jump search owns the pane's input while it pages and its veil
        // covers the text being pressed — same rule as a drop.
        if case .finding = historyJump { return false }
        if let cut = WrappedRowGlue.cutTarget(fragments: rowFragments),
           claimResolved(cut, pressedAt: cell) {
            return true
        }
        return claimResolved(target, pressedAt: cell)
    }

    private func claimResolved(_ target: String, pressedAt cell: (col: Int, row: Int)?) -> Bool {
        // `file:` is URI-shaped, but in a remote pane it names a file on the
        // SSH host, never this device. Give the strict local-authority file
        // parser first refusal so it reaches the viewer; malformed/non-local
        // file URIs then fall through to TerminalLink's blocked, copy-only
        // confirmation. Ordinary links must still precede ordinary paths — a
        // schemeless domain such as example.com/docs is legal path syntax too.
        if let file = TerminalPathTarget.resolveFileURL(target) {
            pendingActivation = .path(file)
            pathPressScreenCell = cell
            return true
        }
        if let link = TerminalLink.resolve(target) {
            pendingActivation = .link(link)
            return true
        }
        if let path = TerminalPathTarget.resolvePressed(target) {
            pendingActivation = .path(path)
            pathPressScreenCell = cell
            return true
        }
        return false
    }

    /// Hands the confirmed target to the system. Only an allowlisted scheme
    /// ever reaches here — `TerminalLink` decided that, and the sheet only
    /// offers OPEN for `.openable`.
    func openPendingLink() {
        guard let url = pendingLink?.openableURL else { return }
        pendingActivation = nil
        UIApplication.shared.open(url)
    }

    /// Hands over the link the *sheet* holds, which is not always the one
    /// that was pressed: detection reads rendered rows, so a wrapped line
    /// can hand over a sentence's tail glued to an address, and the sheet's
    /// target is editable. The allowlist still decides — the field's text
    /// went back through `TerminalLink.resolve`, and only `.openable`
    /// reaches here.
    func openConfirmedLink(_ link: TerminalLink) {
        guard let url = link.openableURL else { return }
        pendingActivation = nil
        UIApplication.shared.open(url)
    }

    /// Copy is the answer for everything Multiplex will not open: a blocked
    /// scheme, a malformed target, or a link the user wants elsewhere. What
    /// lands on the pasteboard is what the sheet shows, edits included.
    func copyConfirmedTarget(_ text: String) {
        UIPasteboard.general.string = text
        pendingActivation = nil
    }

    func dismissPendingLink() {
        if case .link = pendingActivation { pendingActivation = nil }
    }

    func dismissPendingPath() {
        if case .path = pendingActivation { pendingActivation = nil }
    }

    /// The pane's cwd for the file viewer's anchor — the pressed pane's
    /// when a cell rides along (a split's panes routinely sit in different
    /// directories), the active/focused pane's otherwise (the git-worktree
    /// question is not asked here). nil when no pane can answer: a plain
    /// shell, a mosh tab (no exec surface), or a dead transport.
    func paneWorkingDirectory(pressedAt cell: (col: Int, row: Int)? = nil) async -> String? {
        guard let sessionName = route.sessionName, let connection
        else { return nil }
        switch route.sessionBackend {
        case .tmux:
            let output = (try? await connection.exec(
                TmuxProbe.pathAnchorCommand(sessionName: sessionName)
            )) ?? ""
            return TmuxProbe.parsePathAnchorDirectory(output, atScreenCell: cell)
        case .herdr:
            let output = (try? await connection.exec(
                HerdrProbe.snapshotCommand(sessionName: sessionName)
            )) ?? ""
            return HerdrProbe.parsePaneWorkingDirectory(
                output, atScreenCell: cell, screenSize: screenSize
            )
        case .rex:
            // A press lands in one pane's own emulator and moves the
            // keyboard there first, so the pressed cell is always its.
            return await rexWorkingDirectory()
        case nil:
            return nil
        }
    }

    // MARK: Actions

    /// Closing the transport detaches the tmux client; tmux keeps the
    /// session. (SSH: channel teardown does it. mosh: the shutdown
    /// handshake ends mosh-server, which HUPs its tmux client.)
    func detach() {
        cancelPendingResume()
        #if !os(visionOS)
        // The tab is going away — release the microphone rather than typing
        // into a session that no longer exists.
        dictationDriver.cancel()
        #endif
        dropTask?.cancel()
        dropTask = nil
        dropClearTask?.cancel()
        dropState = nil
        for screen in screens { screen.outputCoalescer?.flush() }
        transportGeneration &+= 1
        runTask?.cancel()
        runTask = nil
        for screen in screens { screen.outputCoalescer = nil }
        stopTransportPumps()
        stopDirectShellMonitoring()
        endStatsRun(reason: nil)
        setTmuxCopyModeUIActive(false)
        setSelectTextModeUIActive(false)
        resetHistoryState()
        status = .ended(nil)
        keyPassphraseChallenge = nil
        contactLost = false
        let transport = self.transport
        let panes = panedTransport
        self.transport = nil
        self.connection = nil
        self.moshSession = nil
        endPanedRun()
        Task {
            await transport?.close()
            await panes?.close()
        }
        // Closing is final — this path never runs on a tab move — so release
        // each view's frame driver and renderer: SwiftTerm 2 leaves both to
        // an explicit owner call.
        for screen in screens {
            if let view = screen.terminalView { Self.closeTerminalUI(view) }
        }
    }

    /// `updateUiClosed()` answers false while a Metal surface still has GPU
    /// work in flight; it must be retried until the renderer lets go.
    private static func closeTerminalUI(_ view: TerminalView, attempt: Int = 0) {
        guard !view.updateUiClosed(), attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            closeTerminalUI(view, attempt: attempt + 1)
        }
    }

    /// The RECONNECT chip. The user is driving now, so their attempt also
    /// re-arms automatic recovery for the next suspension.
    func reconnect() {
        resumePolicy.userReconnected()
        cancelPendingResume()
        performReconnect()
    }

    private func performReconnect() {
        guard case .ended = status else { return }
        if let challenge = keyPassphraseChallenge {
            let revision = SSHKeyPassphraseSession.snapshot(for: host.id).revision
            if revision <= challenge.attemptedRevision {
                keyPassphraseChallenge = challenge.reissued()
                return
            }
            keyPassphraseChallenge = nil
        }
        setTmuxCopyModeUIActive(false)
        setSelectTextModeUIActive(false)
        resetHistoryState()
        status = .connecting
        beginTransportRun()
    }

    // MARK: Automatic resume after suspension

    /// A backgrounded app is suspended and its sockets die with it, while
    /// the tmux session on the host carries on. `SessionResumePolicy` holds
    /// the (pure) decision of when a dead transport is that damage rather
    /// than a session the user deliberately ended.
    private var resumePolicy = SessionResumePolicy()
    private var resumeTask: Task<Void, Never>?

    private static let resumeLogger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "resume"
    )

    /// The app went away; note whether this tab had a live transport to lose.
    func applicationDidEnterBackground() {
        resumePolicy.appMovedToBackground(isLive: status == .live)
    }

    /// The app is back: repair a transport that died while it was away, and
    /// arm the grace window for a close still in flight from the wake.
    func applicationWillEnterForeground() {
        guard let delay = resumePolicy.appReturnedToForeground(
            now: .now,
            isLive: status == .live
        ) else { return }
        scheduleAutomaticResume(after: delay, trigger: "foreground")
    }

    /// Every path that ends a transport on its own asks here; the user
    /// closing the tab (`detach`) deliberately does not.
    private func considerAutomaticResume() {
        // An encrypted key needs its passphrase from a person, and retrying
        // the same rejected secret only burns attempts.
        let delay = keyPassphraseChallenge == nil
            ? resumePolicy.transportEnded(
                now: .now,
                isForeground: UIApplication.shared.applicationState != .background
            )
            : nil
        guard let delay else {
            // Nothing further is owed: whatever the panel says next, it is
            // not "Reattaching".
            isResuming = false
            return
        }
        scheduleAutomaticResume(after: delay, trigger: "transport-ended")
    }

    private func scheduleAutomaticResume(after delay: TimeInterval, trigger: String) {
        guard case .ended = status else { return }
        Self.resumeLogger.debug(
            "auto-resume \(self.route.displayName, privacy: .public) host=\(self.host.name, privacy: .public) trigger=\(trigger, privacy: .public) attempt=\(self.resumePolicy.attempts, privacy: .public) delay=\(delay, privacy: .public)"
        )
        resumeTask?.cancel()
        isResuming = true
        resumeTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.resumeTask = nil
            guard case .ended = self.status else { return }
            self.performReconnect()
        }
    }

    private func cancelPendingResume() {
        resumeTask?.cancel()
        resumeTask = nil
        isResuming = false
    }

    private func markLive() {
        status = .live
        resumePolicy.sessionBecameLive()
        isResuming = false
        beginStatsRun()
    }

    // MARK: Connection stats

    /// Passive-tap pushes into the app-wide stats center. Everything here is
    /// bookkeeping the tab already does — byte counts from the two funnels,
    /// a mosh session's own transport counters — pushed on a coarse cadence.
    /// No network cost anywhere.
    private static let statsPushInterval: Duration = .seconds(5)
    /// Idle cadence while collection is off — the loop stays armed so a
    /// mid-session re-enable resumes without a reattach, but wakes rarely.
    private static let statsDisabledInterval: Duration = .seconds(30)

    /// The one setup pairing (the teardown twin is `endStatsRun`): live push
    /// + relink accounting + the pump, so no path can start half of it.
    private func beginStatsRun() {
        guard !statsReportedLive else { return }
        statsReportedLive = true
        statsLiveRuns += 1
        let center = ConnectionStatsCenter.shared
        center.recordTransportLive(hostID: host.id)
        if statsLiveRuns > 1 {
            center.recordRelink(hostID: host.id)
        }
        startStatsPump()
    }

    private func endStatsRun(reason: String?) {
        statsTask?.cancel()
        statsTask = nil
        guard statsReportedLive else { return }
        statsReportedLive = false
        // Drain the tail window before the ended push — a session shorter
        // than one pump tick still owes its bytes.
        flushStatsBytes()
        ConnectionStatsCenter.shared.recordTransportEnded(
            hostID: host.id, reason: reason)
    }

    private func startStatsPump() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let collecting = ConnectionStatsCenter.shared.isCollecting
                if collecting {
                    await self.pushLinkStats()
                }
                try? await Task.sleep(
                    for: collecting
                        ? Self.statsPushInterval : Self.statsDisabledInterval
                )
            }
        }
    }

    private func flushStatsBytes() {
        let center = ConnectionStatsCenter.shared
        if center.isCollecting, statsBytesIn > 0 || statsBytesOut > 0 {
            center.addBytes(
                hostID: host.id, bytesIn: statsBytesIn, bytesOut: statsBytesOut)
        }
        statsBytesIn = 0
        statsBytesOut = 0
    }

    private func pushLinkStats() async {
        guard status == .live else { return }
        flushStatsBytes()
        guard let session = moshSession else { return }
        let report = await session.linkReport()
        guard status == .live, moshSession === session else { return }
        ConnectionStatsCenter.shared.recordMosh(hostID: host.id, report: report)
    }

    /// The fork's echo-latency window (keystroke → first echoed paint),
    /// delivered by `SwiftTermView` — the one number that matches "feels
    /// slow" and works identically on SSH and mosh.
    func recordEchoSample(milliseconds: Double) {
        guard status == .live else { return }
        ConnectionStatsCenter.shared.recordEcho(
            hostID: host.id, milliseconds: milliseconds)
    }

    /// Called app-wide after one prompt accepts an answer. Tabs that were
    /// waiting resume their original attach route; live tabs merely clear a
    /// challenge raised by an optional SSH control action.
    func resumeAfterKeyPassphraseUpdate() {
        guard keyPassphraseChallenge != nil else { return }
        keyPassphraseChallenge = nil
        guard case .ended = status else { return }
        setTmuxCopyModeUIActive(false)
        setSelectTextModeUIActive(false)
        resetHistoryState()
        status = .connecting
        beginTransportRun()
    }

    private func captureKeyPassphraseChallenge(from error: Error) {
        guard let reason = (error as? SSHConnectionError)?.keyPassphraseReason else {
            return
        }
        keyPassphraseChallenge = SSHKeyPassphraseChallenge(host: host, reason: reason)
    }
}

/// Receives transport data on NIO / Network.framework queues, then presents
/// one compact byte array to SwiftTerm per short display interval. A terminal
/// still parses every byte in order; only cross-thread hops and array copies
/// are coalesced.
final class TerminalOutputCoalescer: @unchecked Sendable {
    private struct State {
        var chunks: [Data] = []
        var byteCount = 0
        var drainScheduled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let deliver: @MainActor ([UInt8]) -> Void

    init(deliver: @escaping @MainActor ([UInt8]) -> Void) {
        self.deliver = deliver
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let schedule = state.withLock { state -> Bool in
            state.chunks.append(data)
            state.byteCount += data.count
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
            self?.drain()
        }
    }

    @MainActor
    func flush() {
        drain()
    }

    @MainActor
    private func drain() {
        let batch = state.withLock { state -> ([Data], Int) in
            let batch = (state.chunks, state.byteCount)
            state.chunks.removeAll(keepingCapacity: true)
            state.byteCount = 0
            state.drainScheduled = false
            return batch
        }
        guard batch.1 > 0 else { return }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(batch.1)
        for chunk in batch.0 {
            bytes.append(contentsOf: chunk)
        }
        deliver(bytes)
    }
}
