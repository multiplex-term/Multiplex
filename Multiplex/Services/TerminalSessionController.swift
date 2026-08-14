import Foundation
import Observation
import os
import SwiftTerm
import UIKit

/// Owns one terminal tab's shell: opens a dedicated transport — an SSH
/// PTY, or a mosh session bootstrapped over SSH when the host asks for it
/// — running tmux attach / new-session / a plain shell, and pumps bytes
/// between the transport and the SwiftTerm view.
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

    /// Local scrollback for this tab's terminal view; nil disables it.
    /// A transport capability, so it lives beside the transport choice:
    /// mosh syncs ONE live screen and anything archived above it is junk
    /// (stale frames from scroll-op diffs, resync resets, and resizes) —
    /// full record in docs/agents/mosh.md.
    var localScrollbackLines: Int? { host.useMosh ? nil : 5000 }

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

    /// Strongly owned (SwiftTerm's delegate back-reference is weak): the view
    /// carries the terminal buffer and scrollback, and tabs move between
    /// windows — the adopting window re-parents this same view, so what's on
    /// screen survives a merge/split. Released with the controller on close.
    private(set) var terminalView: TerminalView?
    /// The byte pipe under this tab — SSH PTY or mosh session.
    private var transport: (any TerminalTransport)?
    /// SSH path only: the exec/SFTP surface (pane cwd, file drops). nil on
    /// mosh tabs — their bootstrap SSH connection is transient by design.
    private var connection: SSHConnection?
    /// mosh path only: contact nudges on foreground.
    private var moshSession: MoshSession?
    /// A live mosh session that hasn't heard its server past mosh's 6.5 s
    /// threshold. Input still queues and the link self-heals; the chrome
    /// just shows it truthfully. Always false on SSH tabs.
    private(set) var contactLost = false
    private var pendingOutput: [UInt8] = []
    /// One short-delay drain per transport run replaces a MainActor Task and a
    /// Data→Array copy for every network chunk. Parsing remains on the main
    /// actor because SwiftTerm's view/delegate/display machinery is UIKit.
    private var outputCoalescer: TerminalOutputCoalescer?
    /// SSH handoff tabs only: watches early PTY output for the oh-my-zsh
    /// update prompt, whose stdin drain swallows the injected attach line.
    /// nil once resolved (prompt handled, attach seen, or window elapsed).
    private var handoffWatch: ShellHandoff.UpdatePromptWatch?
    private var lastCols = 80
    private var lastRows = 24
    private var started = false
    private var transportGeneration = 0
    private var runTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<Data>.Continuation?
    private struct TerminalSize: Sendable {
        var cols: Int
        var rows: Int
    }
    private var resizeTask: Task<Void, Never>?
    private var resizeContinuation: AsyncStream<TerminalSize>.Continuation?
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

    #if !os(visionOS)
    /// The terminal's app-owned dictation controls, from the pane's side:
    /// LISTENING while the microphone is open, or a short failure the user
    /// can act on. Settled words are already in the session, so the payload
    /// is only what has been heard and not yet typed.
    enum DictationState: Equatable {
        case listening(String)
        case failed(String)
    }
    private(set) var dictation: DictationState?
    private var dictationSession: DictationSession?
    private var dictationClearTask: Task<Void, Never>?
    /// The key has been pressed and a dictation is in flight — which starts
    /// before `dictation` does, because the first press waits on the system's
    /// microphone and speech-recognition alerts. Whichever mic control was
    /// pressed latches on this; the pane's LISTENING bar waits for the
    /// microphone itself.
    private var dictationRequested = false
    #endif

    init(route: TerminalRoute, host: Host, attention: AttentionCenter? = nil) {
        self.route = route
        self.host = host
        self.attention = attention
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

    func bind(_ view: TerminalView) {
        terminalView = view
        applyTouchInteractionModes()
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
            if let terminal = view?.getTerminal() {
                let screenRow = position.row - terminal.buffer.yDisp
                if screenRow >= 0 && screenRow < terminal.rows {
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
        }
        if !pendingOutput.isEmpty {
            view.feed(byteArray: pendingOutput[...])
            pendingOutput.removeAll()
        }
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

    #if !os(visionOS)
    /// The keyboard lock as a named menu action. The rail key's hold gesture
    /// stays the fast path, but nothing on screen announced it — a held key
    /// is unfindable, so the same lock/unlock lives in the terminal's actions
    /// menu. Lock hides while a hardware keyboard makes it redundant; an
    /// already-held lock keeps Unlock available. Unlocking asks for the
    /// keyboard back, exactly like the padlock's short press.
    func toggleKeyboardLock() {
        guard let terminalView else { return }
        if KeyboardLock.shared.isLocked {
            TerminalFocusArbiter.unlock(terminalView)
        } else {
            TerminalFocusArbiter.lock(terminalView)
        }
    }
    #endif

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
        let output = TerminalOutputCoalescer { [weak self] bytes in
            guard let self, self.transportGeneration == generation else { return }
            self.feed(bytes)
        }
        outputCoalescer = output
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(generation: generation, output: output)
            if self.transportGeneration == generation {
                self.runTask = nil
            }
        }
    }

    private func run(
        generation: Int,
        output: TerminalOutputCoalescer
    ) async {
        if host.useMosh {
            await runMosh(generation: generation, output: output)
        } else {
            await runSSH(generation: generation, output: output)
        }
    }

    private func runSSH(
        generation: Int,
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
        transport = connection
        do {
            try await connection.connect()
            try Task.checkCancellation()
            guard transportGeneration == generation,
                  self.connection === connection
            else {
                await connection.close()
                return
            }
            let openedSize = TerminalSize(cols: lastCols, rows: lastRows)
            // Armed before the PTY opens so the first output chunk is already
            // scanned; an rc-time oh-my-zsh update prompt swallows the
            // injected handoff line and needs a re-type (ShellHandoff).
            handoffWatch = route.remoteCommand == nil
                ? nil
                : ShellHandoff.UpdatePromptWatch()
            try await connection.openShell(
                command: route.remoteCommand,
                cols: openedSize.cols,
                rows: openedSize.rows,
                onData: { data in
                    output.append(data)
                },
                onClose: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        self?.handleClose(
                            reason: reason,
                            generation: generation,
                            output: output
                        )
                    }
                }
            )
            try Task.checkCancellation()
            guard transportGeneration == generation,
                  self.connection === connection
            else {
                await connection.close()
                return
            }
            startTransportPumps(for: connection, openedAt: openedSize)
            markLive()
            startDirectShellMonitoring()
        } catch {
            await connection.close()
            guard transportGeneration == generation,
                  self.connection === connection
            else { return }
            captureKeyPassphraseChallenge(from: error)
            let message = (error as? SSHConnectionError)?.userMessage(host: host)
                ?? "Couldn't reach \(host.name). \(error.localizedDescription)"
            status = .ended(message)
            self.connection = nil
            transport = nil
            outputCoalescer = nil
            handoffWatch = nil
            considerAutomaticResume()
        }
    }

    /// mosh: a transient SSH connection launches mosh-server, then the
    /// session itself rides UDP — resilient to roaming and sleep. The
    /// deck's probe (and file drops) stay SSH; this tab simply has no
    /// exec surface.
    private func runMosh(
        generation: Int,
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
            let openedSize = TerminalSize(cols: lastCols, rows: lastRows)
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
                        self?.handleClose(
                            reason: reason,
                            generation: generation,
                            output: output
                        )
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
            startTransportPumps(for: session, openedAt: openedSize)
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
                ?? "Couldn't reach \(host.name) over mosh. \(error.localizedDescription)"
            status = .ended(message)
            moshSession = nil
            transport = nil
            outputCoalescer = nil
            considerAutomaticResume()
        }
    }

    /// Pinged after every coalesced output flush reaches the terminal —
    /// visionOS's gaze link-hover overlay debounces its region rebuild
    /// behind this, so affordances follow the screen without polling.
    var onOutputFlushed: (() -> Void)?

    private func feed(_ bytes: [UInt8]) {
        scanForSwallowedHandoff(bytes)
        guard let terminalView else {
            pendingOutput.append(contentsOf: bytes)
            return
        }
        terminalView.feed(byteArray: bytes[...])
        onOutputFlushed?()
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
            let payload = Data(ShellHandoff.payload(for: command).utf8)
            // The ordered input pump keeps the re-type serialized with any
            // keystrokes; before the pump exists (output can arrive while
            // runSSH is still between openShell and startTransportPumps),
            // write straight to the transport — the user can't type yet.
            if let inputContinuation {
                inputContinuation.yield(payload)
            } else if let transport {
                Task { try? await transport.write(payload) }
            }
        }
    }

    /// OSC title updates are also the no-exec fallback signal for direct mosh
    /// shells. SSH shells use the foreground process probe as authority, but
    /// retaining Claude/Codex's explicit title here prevents a very fast turn
    /// from erasing the identifying idle title before the next poll.
    func terminalTitleChanged(_ title: String) {
        remoteTitle = title
        guard route.sessionName == nil else { return }
        guard title != lastTerminalTitleProcessedForAgentHint else { return }
        lastTerminalTitleProcessedForAgentHint = title
        if let hint = AgentSignature.classifyTerminal(
            title: title,
            visibleLines: terminalScreenSnapshot().lines,
            isAlternateScreen: terminalView?.getTerminal().isCurrentBufferAlternate ?? false,
            previous: directShellAgent ?? terminalAgentHint
        ) {
            terminalAgentHint = hint
        } else if !AgentAttention.hasSpinnerPrefix(title) {
            terminalAgentHint = nil
        }
    }

    private func handleClose(
        reason: String?,
        generation: Int,
        output: TerminalOutputCoalescer
    ) {
        // Network callbacks enqueue bytes synchronously before their close
        // callback. Flush that final tail before ending the run, then ignore a
        // late close from any superseded transport generation.
        output.flush()
        guard transportGeneration == generation,
              outputCoalescer === output
        else { return }
        stopTransportPumps()
        stopDirectShellMonitoring()
        setTmuxCopyModeUIActive(false)
        setSelectTextModeUIActive(false)
        resetHistoryState()
        handoffWatch = nil
        status = .ended(reason)
        contactLost = false
        let endedTransport = transport
        transport = nil
        connection = nil
        moshSession = nil
        outputCoalescer = nil
        Task { await endedTransport?.close() }
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
        guard let terminalView else { return ([], false) }
        let terminal = terminalView.getTerminal()
        let rows = max(0, terminal.getDims().rows)
        let lines = (0..<rows).compactMap { row in
            terminal.getLine(row: row)?.translateToString(
                trimRight: true,
                skipNullCellsFollowingWide: true
            )
        }
        return (lines, terminal.isCurrentBufferAlternate)
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

    // MARK: Input pump

    /// Keystrokes flow through one AsyncStream consumed by a single task —
    /// yield order is preserved, unlike a Task spawned per keystroke, and
    /// the terminal thread never waits on the network.
    private func startInputPump(for transport: any TerminalTransport) {
        stopInputPump()
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        inputContinuation = continuation
        inputTask = Task {
            for await chunk in stream {
                try? await transport.write(chunk)
            }
        }
    }

    private func stopInputPump() {
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask?.cancel()
        inputTask = nil
    }

    /// Resize callbacks can arrive for every layout pass while a window is
    /// dragged. Keep only the newest dimensions and let one ordered task talk
    /// to the transport, rather than minting an unbounded task per callback.
    private func startResizePump(for transport: any TerminalTransport) {
        stopResizePump()
        let (stream, continuation) = AsyncStream.makeStream(
            of: TerminalSize.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        resizeContinuation = continuation
        resizeTask = Task {
            for await size in stream {
                try? await transport.resize(cols: size.cols, rows: size.rows)
            }
        }
    }

    private func stopResizePump() {
        resizeContinuation?.finish()
        resizeContinuation = nil
        resizeTask?.cancel()
        resizeTask = nil
    }

    private func startTransportPumps(
        for transport: any TerminalTransport,
        openedAt size: TerminalSize
    ) {
        startInputPump(for: transport)
        startResizePump(for: transport)
        // Layout may have changed while the handshake/open call was awaiting;
        // reconcile once with the newest geometry before normal coalescing.
        if lastCols != size.cols || lastRows != size.rows {
            resizeContinuation?.yield(TerminalSize(cols: lastCols, rows: lastRows))
        }
    }

    private func stopTransportPumps() {
        stopInputPump()
        stopResizePump()
    }

    // MARK: Terminal view events

    func sendInput(_ data: Data) {
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
        inputContinuation?.yield(data)
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
        let command = switch backend {
        case .tmux: TmuxProbe.paneRectsCommand(sessionName: sessionName)
        case .herdr: HerdrProbe.snapshotCommand(sessionName: sessionName)
        }
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
                    case .herdr: HerdrProbe.parsePaneScreenRects(output)
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
        case nil: nil
        }
    }

    func selectShortcutSwitchChoice(_ choice: TmuxWindowChoice) {
        switch route.sessionBackend {
        case .tmux: selectTmuxWindow(choice)
        case .herdr: selectHerdrWorkspace(choice)
        case nil: break
        }
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
    var isDictating: Bool { dictationRequested }

    /// One dictation action shared by the physical-keyboard rail slot and the
    /// software-keyboard lock tip. Neither path reaches the system keyboard's
    /// own microphone, so both run the same app-owned recognition session.
    func toggleDictation() {
        if dictationRequested {
            stopDictation()
        } else {
            startDictation()
        }
    }

    /// Finish and type the tail. Most of the dictation is already in the
    /// session — this is the last words the hold rules were still sitting on,
    /// and the recognizer gets a moment to make its final pass over them
    /// first. A press that has not reached the microphone yet has nothing to
    /// type, so it simply abandons the attempt.
    func stopDictation() {
        guard let dictationSession else { return }
        if dictationSession.isListening {
            dictationSession.stop()
        } else {
            dictationSession.cancel()
        }
    }

    /// Leave without typing the rest. Words that already settled are in the
    /// session and stay there — a terminal has no undo, so this abandons the
    /// queue, not the dictation's past.
    func cancelDictation() {
        dictationSession?.cancel()
    }

    /// The LISTENING bar's language chip: persist the pick, and when a take
    /// is live restart it in the new language — the recognizer heard the old
    /// one, and "applies next time" from a control pressed mid-take would
    /// read as the pick not working. The restart abandons only the unsettled
    /// queue; words already typed stay, like any cancel. A full restart, not
    /// an in-place engine swap: a recognition task created while the daemon
    /// tears its predecessor down comes back dead (the session's whole
    /// restart-backoff ladder exists for that), and the well-worn start path
    /// costs one bar blink.
    func selectDictationLanguage(_ choice: DictationLanguageChoice) {
        DictationLanguageSetting.setChosen(choice.id)
        guard dictationRequested else { return }
        dictationSession?.cancel()
        startDictation()
    }

    private func startDictation() {
        guard status == .live else { return }
        // The jump search owns the pane's input while it pages the remote
        // transcript; dictated text would interleave with its PgUp stream.
        if case .finding = historyJump { return }
        dictationClearTask?.cancel()
        dictation = nil
        dictationRequested = true
        let session = dictationSession ?? DictationSession()
        dictationSession = session
        session.start(
            locale: DictationLanguageSetting.chosenLocale(),
            onStart: { [weak self] in
                guard let self, dictationRequested else { return }
                dictation = .listening("")
            },
            onText: { [weak self] settled in
                self?.typeDictated(settled)
            },
            onPending: { [weak self] pending in
                guard let self, dictationRequested else { return }
                dictation = .listening(DictationText.preview(pending))
            },
            onFinish: { [weak self] outcome in
                self?.finishDictation(outcome)
            }
        )
    }

    /// One chunk of settled speech, typed exactly like a rail key or a
    /// dropped file's path — through SwiftTerm and the ordered input pump,
    /// never submitted. The stream already sanitized it and owns the spacing
    /// between chunks, so it goes out verbatim.
    private func typeDictated(_ text: String) {
        guard dictationRequested else { return }
        guard status == .live, let terminalView else {
            // The session being spoken into is gone. Stop rather than aim the
            // rest of the sentence at whatever takes its place.
            dictationSession?.cancel()
            return
        }
        terminalView.send(txt: text)
    }

    private func finishDictation(_ outcome: DictationSession.Outcome) {
        dictationRequested = false
        dictation = nil
        switch outcome {
        case .ended, .cancelled:
            // Everything that settled was typed as it landed; there is no
            // trailing text left to deliver here.
            break
        case .failure(let message):
            dictation = .failed(message)
            dictationClearTask?.cancel()
            dictationClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                if case .failed = self?.dictation { self?.dictation = nil }
            }
        }
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
        guard let terminalView else { return }
        terminalView.allowMouseReporting =
            !(tmuxCopyModeUIActive || selectTextModeUIActive)
        terminalView.forceRemoteCursorScroll = tmuxCopyModeUIActive
        terminalView.suppressRemotePanScroll =
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
                agentHistory = .unavailable("NO WORKING DIRECTORY")
                return
            }
            guard result.filePath != nil else {
                agentHistory = .unavailable("NO SESSION FILE")
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
            agentHistory = .unavailable("HISTORY UNAVAILABLE")
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
                else { return .failed("SESSION NOT FOUND") }
                // The walk's coordinate: tmux aims at the session (its
                // active pane answers); herdr aims at the prologue's
                // bake-vetted focused pane.
                let target: AgentSessionHistory.JumpTarget = isHerdr
                    ? .herdr(sessionName: sessionName, paneID: prologue.sessionID)
                    : .tmux(sessionID: prologue.sessionID)
                switch AgentAttention.classify(
                    title: prologue.paneTitle, tail: prologue.capture
                ) {
                case .busy: return .failed("AGENT IS BUSY")
                case .needsYou: return .failed("ANSWER THE AGENT FIRST")
                case .idle: break
                }
                let targetNeedles = AgentSessionHistory.needles(
                    for: message, paneColumns: prologue.paneWidth
                )
                guard let targetPrimary = targetNeedles.first else {
                    return .failed("MESSAGE TOO SHORT TO FIND")
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
                            ? "ANOTHER CLIENT RESIZES THIS SESSION"
                            : "NOT IN THE VISIBLE TRANSCRIPT"
                    )
                case .short:
                    return .failed("TERMINAL TOO SHORT TO JUMP")
                case .resized:
                    return .failed(
                        prologue.clientSizeCount > 1
                            ? "ANOTHER CLIENT RESIZES THIS SESSION"
                            : "RESIZED MID-JUMP — TRY AGAIN"
                    )
                case nil:
                    return .failed("SEARCH FAILED")
                }
            }
        } catch {
            outcome = .failed("SEARCH FAILED")
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

    func terminalResized(cols: Int, rows: Int) {
        guard cols != lastCols || rows != lastRows else { return }
        lastCols = cols
        lastRows = rows
        guard status == .live else { return }
        resizeContinuation?.yield(TerminalSize(cols: cols, rows: rows))
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
    func deliverDrop(_ files: [DroppedFile]) {
        // The jump search owns the pane's input while it pages; the FINDING
        // veil is visible over the drop target for its few seconds.
        if case .finding = historyJump { return }
        if host.useMosh || route.sessionBackend == nil,
           status == .live, dropTask == nil, !files.isEmpty {
            // Mosh has no SFTP channel, while a plain shell has no
            // multiplexer pane whose foreground cwd can be resolved. Say so
            // instead of silently discarding the user's attach/drop intent.
            dropClearTask?.cancel()
            dropState = .failed("File upload requires tmux or herdr over SSH")
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
            let destination = try await dropDestination(over: connection)
            let uploads = try files.map { file -> SSHUpload in
                guard file.data.count <= DropText.maxBytes else {
                    throw DropError(message: "\(file.name) is over 64 MB")
                }
                return SSHUpload(
                    data: file.data,
                    preferredName: DropText.sanitizedName(file.name)
                )
            }
            let displayNames = files.map(\.name)
            dropState = .uploading(name: files[0].name, fraction: 0)
            let finalNames = try await connection.uploadFiles(
                uploads,
                toDirectory: destination.directory,
                prepareGitIgnoredDirectory: destination.prepareGitIgnoredDirectory,
                onProgress: { [weak self] index, fraction in
                    Task { @MainActor [weak self] in
                        guard case .uploading = self?.dropState else { return }
                        self?.dropState = .uploading(
                            name: displayNames[index],
                            fraction: fraction
                        )
                    }
                }
            )
            let typedPaths = finalNames.map { finalName in
                // Relative names read best in a prompt, but only when the
                // file verifiably sits under the pane's cwd.
                destination.typedPrefix.map { $0 + finalName }
                    ?? destination.directory + "/" + finalName
            }
            dropState = nil
            sendInput(Data(DropText.typedPaths(typedPaths).utf8))
        } catch is CancellationError {
            dropState = nil
        } catch {
            dropState = .failed((error as? DropError)?.message ?? "Upload failed")
            dropClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.dropState = nil
            }
        }
    }

    private struct DropDestination {
        var directory: String
        /// Prefix for typed relative paths ("" = bare name,
        /// ".multiplex-drops/" inside git worktrees); nil types absolute.
        var typedPrefix: String?
        var prepareGitIgnoredDirectory: Bool
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
        case nil:
            return (nil, false)
        }
    }

    // MARK: Links

    /// A link the terminal resolved under a tap or long press. Returns
    /// whether this pane claims the gesture. URLs confirm through the link
    /// sheet; path-shaped text (implicit detection matches those too) now
    /// confirms through the file-viewer sheet instead of falling to
    /// selection; only what neither resolver accepts ($VAR/…, colon prose)
    /// still declines into text selection.
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
        if let path = TerminalPathTarget.resolve(target) {
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
            return HerdrProbe.parsePaneWorkingDirectory(output, atScreenCell: cell)
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
        dictationClearTask?.cancel()
        dictationSession?.cancel()
        dictationSession = nil
        dictationRequested = false
        dictation = nil
        #endif
        dropTask?.cancel()
        dropTask = nil
        dropClearTask?.cancel()
        dropState = nil
        outputCoalescer?.flush()
        transportGeneration &+= 1
        runTask?.cancel()
        runTask = nil
        outputCoalescer = nil
        stopTransportPumps()
        stopDirectShellMonitoring()
        setTmuxCopyModeUIActive(false)
        setSelectTextModeUIActive(false)
        resetHistoryState()
        status = .ended(nil)
        keyPassphraseChallenge = nil
        contactLost = false
        let transport = self.transport
        self.transport = nil
        self.connection = nil
        self.moshSession = nil
        Task { await transport?.close() }
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
private final class TerminalOutputCoalescer: @unchecked Sendable {
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
