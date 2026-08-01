import SwiftUI
import UniformTypeIdentifiers
#if DEBUG
import notify
import os
import SwiftTerm
#endif

/// Root of one terminal window scene: the window's tabs (each one SSH
/// shell), resolved from its `TerminalWindowRoute` value. The tab list is
/// the scene value itself — mutating the binding is how tabs merge in,
/// split out, and close, and it's what scene restoration persists.
/// Controllers live in `TerminalWorkspace` keyed by tab id, so a moved tab
/// keeps its live connection and terminal buffer.
///
/// Chrome is the Tally identity: a chassis-framed screen with multiviewer
/// source-label tabs on top and the under-monitor display (UMD) below.
struct TerminalWindowRoot: View {
    struct ShellConfiguration {
        var deckControlLabel: String
        var availableWidth: CGFloat
        /// Safe-area insets the shell hands to this pane rather than
        /// reserving them. The pane's screen and every bar's bezel paint to
        /// the physical edge; the grid, the UMD chips, the tabs, and the key
        /// rail all keep their content inside these.
        var contentSafeArea = EdgeInsets()
        /// The shell's pane runs to the window's bottom edge, so the rail
        /// rests there rather than on the safe-area boundary.
        var railOwnsBottomSafeArea = false
        var showDeck: () -> Void
        var openTerminalRoute: (TerminalWindowRoute) -> Void
        var revealTab: (UUID) -> Void
        var tabsEmptied: () -> Void
        var terminalFocusAllowed: Bool
    }

    @Environment(HostStore.self) private var store
    @Environment(ConnectionHub.self) private var hub
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    #if !os(visionOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @Binding var route: TerminalWindowRoute
    var shell: ShellConfiguration?

    init(
        route: Binding<TerminalWindowRoute>,
        shell: ShellConfiguration? = nil
    ) {
        _route = route
        self.shell = shell
        #if os(visionOS)
        _fontSize = State(initialValue: 14)
        #else
        _fontSize = State(
            initialValue: UIDevice.current.userInterfaceIdiom == .phone ? 12 : 14
        )
        #endif
    }

    @State private var fontSize: CGFloat
    /// Agent shown by the helper strip. Trails `detectedAgent` with a short
    /// grace on loss (two probe ticks) so a transient probe miss doesn't
    /// flap the strip — but never across a tab or pane switch.
    @State private var shownAgent: AgentKind?
    @State private var hideAgentTask: Task<Void, Never>?
    @State private var activePaneFingerprint: TmuxPaneFingerprint?
    @State private var showingPaywall = false
    /// One new-tab exec in flight at a time — a double tap must not mint
    /// two sessions.
    @State private var creatingTab = false
    @State private var newTabFailedHost: String?
    /// Detach long-press picked CLOSE SESSION — destructive, so it confirms
    /// (same policy as the deck's delete action).
    @State private var confirmingCloseActiveSession = false
    /// The pressed KEYCHAIN LOCKED status, snapshotted at tap time.
    @State private var keychainTipRequest: KeychainTipRequest?

    /// Full host snapshots stay at the wall's economical cadence. Only the
    /// app-wide keyboard owner gets the small focused-pane query between
    /// snapshots, so ten visible spatial windows never become ten fast ps
    /// loops.
    private static let hostProbeInterval: Duration = .seconds(5)
    private static let focusedPaneProbeInterval: Duration = .seconds(1)

    private var activeTab: TerminalRoute? { route.activeTab }
    private var activeController: TerminalSessionController? {
        activeTab.flatMap { workspace.controller(for: $0.id) }
    }
    /// The active tab's host record — the viewport's rewrite target and
    /// tether name. Computed here so the body's modifier chain (at the
    /// type-checker's ceiling) never carries the closure.
    private var activeTabHost: Host? {
        activeTab.flatMap { store.host(id: $0.hostID) }
    }
    /// Tabs connect concurrently. Surface the active tab's encrypted-key
    /// challenge first, then any background tab's; accepting one answer
    /// resumes every waiting tab for that host.
    private var keyPassphraseChallenge: SSHKeyPassphraseChallenge? {
        let activeFirst = activeTab.map { [$0] } ?? []
        for tab in activeFirst + route.tabs.filter({ $0.id != activeTab?.id }) {
            if let challenge = workspace.controller(for: tab.id)?.keyPassphraseChallenge {
                return challenge
            }
        }
        return nil
    }
    private var terminalFocusAllowed: Bool {
        shell?.terminalFocusAllowed ?? true
    }
    /// Kept out of the body's modifier chain, which sits at the Swift
    /// type-checker's ceiling: an inline binding here fails to type-check.
    private var newTabFailedAlertBinding: Binding<Bool> {
        Binding(
            get: { newTabFailedHost != nil },
            set: { if !$0 { newTabFailedHost = nil } }
        )
    }
    /// Only the in-scene shell spends the side safe areas on its panes; a
    /// classic terminal scene is laid out inside them already.
    private var contentSafeArea: EdgeInsets {
        shell?.contentSafeArea ?? EdgeInsets()
    }
    private var railOwnsBottomSafeArea: Bool {
        shell?.railOwnsBottomSafeArea ?? false
    }
    private var showsAgentHelper: Bool {
        shownAgent != nil && activeController?.status == .live
    }
    private var terminalBottomChromeHeight: CGFloat {
        #if os(visionOS)
        0
        #else
        showsAgentHelper ? AgentHelperStrip.dockedHeight : 0
        #endif
    }
    private var mergeSources: [TerminalWorkspace.WindowEntry] {
        shell == nil ? workspace.mergeSources(for: route.id) : []
    }
    /// Whether the detach control can offer CLOSE SESSION for the active
    /// tab: there must be a tmux session to kill and a host record to kill
    /// it on.
    private var activeTabHasSession: Bool {
        guard let activeTab else { return false }
        return activeTab.sessionName != nil && store.host(id: activeTab.hostID) != nil
    }

    /// The active tab's KEYCHAIN LOCKED tip (see `KeychainLockCheck`): the
    /// host-level notice from the shared probe, surfaced only when this
    /// tab's session is one of the affected ones — the terminal the user is
    /// actually staring at when Claude Code shows signed out. The deck rail
    /// keeps the host-level view; this keeps it in sight after attach.
    private var activeTabKeychainNotice: KeychainLockNotice? {
        guard let activeTab,
              let sessionName = activeTab.sessionName,
              let host = store.host(id: activeTab.hostID),
              let notice = hub.model(for: host).keychainNotice,
              notice.sessionNames.contains(sessionName)
        else { return nil }
        return notice
    }

    private func presentKeychainTip() {
        guard let activeTab,
              let host = store.host(id: activeTab.hostID),
              let notice = activeTabKeychainNotice
        else { return }
        keychainTipRequest = KeychainTipRequest(
            host: host,
            sessionNames: notice.sessionNames
        )
    }

    /// Agent receiving this tab's keystrokes. tmux routes read the shared
    /// host probe; a plain shell reads its own PTY's foreground-process probe.
    private var detectedAgent: AgentKind? {
        guard let activeTab else { return nil }
        guard let sessionName = activeTab.sessionName else {
            return activeController?.directShellAgent
        }
        guard let host = store.host(id: activeTab.hostID) else { return nil }
        return hub.model(for: host).tmux.sessions
            .first { $0.name == sessionName }?
            .activeAgent
    }

    var body: some View {
        // Split from `lifecycleBody` so neither half's modifier chain
        // reaches the type-checker's ceiling — one combined chain fails to
        // type-check in reasonable time.
        lifecycleBody
            .sheet(isPresented: $showingPaywall) { ProPaywallView() }
            .sheet(item: $keychainTipRequest) { tip in
                KeychainUnlockSheet(
                    host: tip.host,
                    sessionNames: tip.sessionNames
                )
            }
            .terminalLinkConfirmation(
                for: activeController,
                viewportHost: activeTabHost,
                openViewport: openViewport
            )
            .terminalPathConfirmation(
                for: activeController,
                hostName: activeTabHost?.name,
                openViewer: { openFileViewer(target: $0) }
            )
            .alert(
                "Couldn't Create Session",
                isPresented: newTabFailedAlertBinding
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check the connection to \(newTabFailedHost ?? "the host") and try again.")
            }
            .alert(
                "Close Session",
                isPresented: $confirmingCloseActiveSession
            ) {
                Button("Close Session", role: .destructive) {
                    if let activeTab { closeSession(activeTab) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Kills “\(activeTab?.sessionName ?? "")” on \(activeTab.flatMap { store.host(id: $0.hostID) }?.name ?? "the host") and everything running in it, then closes the tab.")
            }
            .sshKeyPassphrasePrompt(
                challenge: keyPassphraseChallenge,
                onSubmit: acceptKeyPassphrase
            )
            .onDisappear {
                // Scene is gone (close button / dismiss): tabs still here are
                // really closing. A merged-away window is already empty, so
                // its moved tabs never detach.
                workspace.unregisterWindow(id: route.id)
                for tab in route.tabs { workspace.closeTab(tab.id) }
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugAgentChip)) { _ in
                debugTapFirstSlashChip()
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugNewTab)) { _ in
                debugNewTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugMessageJump)) { _ in
                debugJumpToOldestMessage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugMessageJumpBack)) { _ in
                guard let controller = activeController,
                      let view = controller.terminalView,
                      view === TerminalFocusArbiter.current
                else { return }
                controller.finishHistoryJump()
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugLink)) { _ in
                debugActivateFirstLink()
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugLinkOpen)) { _ in
                guard let controller = activeController,
                      let view = controller.terminalView,
                      view === TerminalFocusArbiter.current
                else { return }
                controller.openPendingLink()
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugViewportOpen)) { _ in
                debugOpenViewportForPendingLink()
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugFileViewer)) { _ in
                debugOpenFileViewer()
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugPathView)) { _ in
                debugViewPendingPath()
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugFileViewerRepoDiff)) { _ in
                // The tree's ± chip, headlessly: the active file-viewer tab
                // flips to the repo-wide diff.
                guard let activeTab, activeTab.isFileViewer,
                      let fileViewer = workspace.fileViewerController(for: activeTab.id)
                else { return }
                Task { await fileViewer.showRepoDiff() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .multiplexDebugLinkRegions)) { _ in
                debugLogLinkRegions()
            }
            #endif
    }

    private var lifecycleBody: some View {
        platformBody
            .task { syncTabs() }
            // A restored terminal scene may exist without constructing the
            // deck. Refresh the mirrored Host record here too so its command
            // setup can arrive from another device before the editor opens.
            .task { await store.refreshFromCloud() }
            .task { entitlements.refreshSlashChipMeter() }
            .task(id: activeTab?.hostID) { await keepHostProbeWarm() }
            .task(id: activeTab?.id) { await watchActivePane() }
            #if DEBUG
            .task {
                await DeckScene.autoAttachIfRequested(
                    store: store,
                    workspace: workspace,
                    openTerminalWindow: { route in
                        if let shell {
                            shell.openTerminalRoute(route)
                        } else {
                            openWindow(id: "terminal", value: route)
                        }
                    }
                )
            }
            #endif
            .onChange(of: route.tabs) { syncTabs() }
            .onChange(of: terminalFocusAllowed) { _, allowed in
                guard !allowed else { return }
                activeController?.restoreFocusIfOwner(allowed: false)
            }
            // Keyboard focus follows the visible tab…
            .onChange(of: route.activeTabID) { previousTabID, _ in
                if let activeTab, activeTab.isAuxiliaryPane {
                    // A page (or file) makes no responder claim; the terminal
                    // now hidden behind it must not keep receiving hardware keys.
                    if let previousTabID {
                        workspace.controller(for: previousTabID)?.releaseFocus()
                    }
                } else if terminalFocusAllowed {
                    activeController?.focusTerminal()
                }
                // No detection grace across tabs — chips must describe the
                // pane on screen, immediately.
                hideAgentTask?.cancel()
                activePaneFingerprint = nil
                shownAgent = detectedAgent
            }
            .onChange(of: detectedAgent) { _, agent in
                hideAgentTask?.cancel()
                if let agent {
                    shownAgent = agent
                } else {
                    hideAgentTask = Task {
                        try? await Task.sleep(for: .seconds(11))
                        guard !Task.isCancelled else { return }
                        shownAgent = nil
                    }
                }
            }
            // …and the window: restore the owner when the scene reactivates,
            // and prod any mosh transport so it re-establishes contact within
            // a round trip instead of a heartbeat interval.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await store.refreshFromCloud() }
                    entitlements.refreshSlashChipMeter()
                    activeController?.restoreFocusIfOwner(
                        allowed: terminalFocusAllowed
                    )
                    for tab in route.tabs {
                        workspace.controller(for: tab.id)?.transportForegrounded()
                    }
                }
            }
    }

    private func acceptKeyPassphrase(
        _ challenge: SSHKeyPassphraseChallenge,
        passphrase: String,
        saveToICloud: Bool
    ) {
        SSHKeyPassphraseSession.accept(
            passphrase,
            for: challenge.hostID,
            saveToICloud: saveToICloud
        )
        hub.resumeConnectionsWaitingForKeyPassphrase(hostID: challenge.hostID)
        workspace.resumeConnectionsWaitingForKeyPassphrase(hostID: challenge.hostID)
    }

    /// Keep this host's full wall state fresh while a terminal window is
    /// open. Periodic callers share the model and skip a snapshot completed
    /// in the previous four seconds, preventing staggered windows plus the
    /// deck from multiplying the expensive host-wide pass.
    private func keepHostProbeWarm() async {
        #if DEBUG
        AgentChipDebugHook.install()
        NewTabDebugHook.install()
        MessageJumpDebugHook.install()
        TerminalLinkDebugHook.install()
        FileViewerDebugHook.install()
        #endif
        guard let hostID = activeTab?.hostID, let host = store.host(id: hostID) else { return }
        let model = hub.model(for: host)
        while !Task.isCancelled {
            if UIApplication.shared.applicationState == .active {
                // Reuse the existing five-second host probe tick to
                // publish a local-day rollover. This keeps the spent pill
                // from lingering past midnight without adding a meter timer
                // or scheduling any reset work of its own.
                entitlements.refreshSlashChipMeter()
                await model.refreshAndWait(ifStaleFor: 4)
            }
            try? await Task.sleep(for: Self.hostProbeInterval)
        }
    }

    /// Follow pane selection quickly without turning every terminal into a
    /// full wall poller. TerminalFocusArbiter guarantees at most one window
    /// reaches the network-heavy branch app-wide.
    private func watchActivePane() async {
        guard let activeTab,
              !activeTab.isAuxiliaryPane,
              let host = store.host(id: activeTab.hostID)
        else {
            // A viewport/file-viewer tab has no pane, no agent, and no PTY
            // to watch.
            activePaneFingerprint = nil
            shownAgent = nil
            return
        }

        // A plain login shell has no tmux pane to ask. Its controller probes
        // the foreground process group through the PTY's own SSH transport;
        // only the app-wide focus owner requests the one-second fast cadence.
        guard let sessionName = activeTab.sessionName else {
            activePaneFingerprint = nil
            shownAgent = activeController?.directShellAgent
            while !Task.isCancelled {
                if UIApplication.shared.applicationState == .active,
                   let controller = activeController,
                   let view = controller.terminalView,
                   TerminalFocusArbiter.current === view {
                    await controller.refreshDirectShellAgent(ifStaleFor: 0.8)
                    guard !Task.isCancelled,
                          self.activeTab?.id == activeTab.id
                    else { return }
                    // A successful foreground-process observation is
                    // definitive. Do not apply the full-probe grace period:
                    // after the agent exits, stale helpers in a normal shell
                    // could type into the user's prompt.
                    hideAgentTask?.cancel()
                    shownAgent = controller.directShellAgent
                }
                try? await Task.sleep(for: Self.focusedPaneProbeInterval)
            }
            return
        }

        let model = hub.model(for: host)
        shownAgent = detectedAgent
        activePaneFingerprint = model.tmux.sessions
            .first(where: { $0.name == sessionName })?
            .activeWindow?
            .activePane?
            .processFingerprint

        // Join the initial full refresh. This establishes the shared control
        // connection once; the fast path never races a second SSH handshake.
        await model.refreshAndWait(ifStaleFor: 4)

        while !Task.isCancelled {
            if UIApplication.shared.applicationState == .active,
               let view = activeController?.terminalView,
               TerminalFocusArbiter.current === view {
                let detection = await model.detectActiveAgent(in: sessionName)
                // A tab change cancels this task, but an SSH continuation can
                // finish once more. Never apply that old session's answer to
                // the newly active tab.
                guard !Task.isCancelled, self.activeTab?.id == activeTab.id else { return }
                if let detection { apply(detection) }
            }
            try? await Task.sleep(for: Self.focusedPaneProbeInterval)
        }
    }

    private func apply(_ detection: ActivePaneAgentDetection) {
        let changedPane = activePaneFingerprint != detection.fingerprint
        activePaneFingerprint = detection.fingerprint
        hideAgentTask?.cancel()
        if let agent = detection.agent {
            shownAgent = agent
        } else if changedPane || detection.isDefinitive {
            // A pane switch has no grace: commands must never describe the
            // split the user just left. Confirmed agent exit is equally
            // immediate; only an inconclusive same-pane probe preserves UI.
            shownAgent = nil
        }
    }

    /// Type a helper command into the shell. Auto-submitting built-in and
    /// custom commands send CR as a separate, delayed write: Codex's composer
    /// treats Enter inside one rapid burst as a pasted newline (see
    /// `AgentCommand.submitsAfterPause`); 160 ms clears its burst window
    /// with margin, and Claude Code is indifferent.
    private func send(_ command: AgentCommand, via controller: TerminalSessionController) {
        // Built-in slash commands and every custom payload spend the daily
        // free taste. The entitlement store performs check + consume as one
        // MainActor operation, so the final allowed tap sends while a
        // stale/exhausted tap cannot.
        // A denial stays passive: Observation swaps the strip to its Pro pill
        // instead of stealing terminal focus with a modal.
        guard !command.consumesSlashChipTaste || entitlements.consumeSlashChip()
        else { return }
        controller.sendInput(command.payload)
        guard command.submitsAfterPause else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            controller.sendInput(Data([0x0D]))
        }
    }

    #if DEBUG
    /// Inject the first slash command of the focused terminal's strip —
    /// only the window that owns keyboard focus reacts, so one notification
    /// never types into several shells.
    private func debugTapFirstSlashChip() {
        guard let controller = activeController,
              let view = controller.terminalView,
              view === TerminalFocusArbiter.current,
              let activeTab,
              let agent = shownAgent,
              entitlements.isPro || entitlements.canUseSlashChip,
              controller.status == .live,
              let command = AgentCommandSet.commands(
                  in: .bar,
                  for: agent,
                  placementOverrides: store.agentCommandConfiguration(
                      for: activeTab.hostID
                  ).builtInPlacements(for: agent)
              ).first(where: { $0.label.hasPrefix("/") })
        else { return }
        send(command, via: controller)
    }

    /// Headless link proof: scan the focused pane's visible screen for the
    /// first resolvable link and run it through the same
    /// `activateLink` policy a long press uses, so the confirmation sheet
    /// that appears is the real one. Screen coordinates keep the scan on
    /// what is actually rendered rather than the whole scrollback.
    private func debugActivateFirstLink() {
        guard let controller = activeController,
              let view = controller.terminalView,
              view === TerminalFocusArbiter.current
        else { return }
        let terminal = view.getTerminal()
        for row in 0..<terminal.rows {
            var col = 0
            while col < terminal.cols {
                // Same seam-carrying lookup the long-press route uses, so
                // this hook proves the wrapped-glue cut headlessly too.
                guard let result = terminal.linkWithRowTexts(
                    at: .screen(Position(col: col, row: row)),
                    mode: .explicitAndImplicit
                ) else {
                    col += 1
                    continue
                }
                if controller.activateLink(result.text, rowFragments: result.rowTexts) {
                    return
                }
                // A declined match must not stall the scan on its own
                // cells — step past the whole match's worth of columns
                // rather than re-resolving each one.
                col += max(1, result.text.count)
            }
        }
    }

    /// Run the + TAB dropdown's New Session action for the focused window
    /// only — same gating as the chip hook, so one notification never mints
    /// sessions from several windows.
    private func debugNewTab() {
        guard let controller = activeController,
              let view = controller.terminalView,
              view === TerminalFocusArbiter.current
        else { return }
        openNewTab(launching: nil)
    }

    /// The sheet's ⌗ VIEWPORT chip, headlessly: requires a pending link
    /// (raised by `….debug.link`) and runs the exact offer → dock path the
    /// chip takes.
    private func debugOpenViewportForPendingLink() {
        guard let controller = activeController,
              let view = controller.terminalView,
              view === TerminalFocusArbiter.current,
              let link = controller.pendingLink,
              let offer = ViewportOffer.make(for: link, host: activeTabHost)
        else { return }
        controller.dismissPendingLink()
        openViewport(offer)
    }

    /// The + TAB dropdown's File Viewer action, headlessly — focused
    /// window only, same gating as the chip hook.
    private func debugOpenFileViewer() {
        guard let controller = activeController,
              let view = controller.terminalView,
              view === TerminalFocusArbiter.current
        else { return }
        openFileViewer(target: nil)
    }

    /// The path sheet's ▤ VIEW chip, headlessly: requires a pending path
    /// (raised by `….debug.link` over path-shaped text) and runs the exact
    /// resolve → dock path the chip takes.
    private func debugViewPendingPath() {
        guard let controller = activeController,
              let view = controller.terminalView,
              view === TerminalFocusArbiter.current,
              let target = controller.pendingPath
        else { return }
        controller.dismissPendingPath()
        openFileViewer(target: target)
    }

    /// Headless proof of the visionOS gaze link regions: logs what the
    /// hover overlay would light for the focused terminal (category
    /// `links`, debug level — `log stream`, not `log show`). Gaze itself
    /// cannot be driven in the simulator; the region inventory can.
    private func debugLogLinkRegions() {
        guard let controller = activeController,
              let view = controller.terminalView,
              view === TerminalFocusArbiter.current
        else { return }
        let logger = Logger(
            subsystem: "app.multiplexterm.multiplex",
            category: "links"
        )
        let regions = view.visibleLinkRegions()
            .filter { TerminalLink.resolve($0.target) != nil }
        logger.debug("link-regions count=\(regions.count, privacy: .public)")
        for region in regions {
            logger.debug(
                "link-region target=\(region.target, privacy: .public) rects=\(String(describing: region.rects), privacy: .public)"
            )
        }
    }

    /// Headless jump proof: load the focused pane's history and jump to the
    /// oldest REACHABLE prompt (prompts behind a /compact boundary are
    /// peek-only by design) — the deepest exercise of the pipeline (cwd
    /// resolve → session file → parse → idle gate → remote oracle walk).
    /// Host-side capture-pane then shows the old prompt on screen.
    private func debugJumpToOldestMessage() {
        guard let controller = activeController,
              let view = controller.terminalView,
              view === TerminalFocusArbiter.current,
              let agent = shownAgent
        else { return }
        Task {
            controller.openAgentHistory(for: agent)
            for _ in 0..<60 {
                if case .loaded = controller.agentHistory { break }
                if case .unavailable = controller.agentHistory { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard case .loaded(_, let messages, true) = controller.agentHistory,
                  let oldest = messages.first(where: \.reachable)
            else { return }
            controller.startHistoryJump(to: oldest)
            controller.closeAgentHistory()
        }
    }
    #endif

    /// The + TAB button: mint a fresh tmux session next to the active tab —
    /// same host, same directory as its pane (an agent variant also types
    /// its launch command into the new shell) — and attach it as a new tab
    /// of this window. The session exists before the tab appears, so the
    /// attach can't race it. The host's remembered setup script — and, for
    /// an agent variant, that agent's remembered model — rides along while
    /// the New Session sheet's REMEMBER opt-in is on: the quick path
    /// inherits the choices made there, the way it inherits the pane's cwd.
    private func openNewTab(launching agent: AgentKind?) {
        guard !creatingTab,
              let activeTab,
              let host = store.host(id: activeTab.hostID)
        else { return }
        creatingTab = true
        // A plain shell tab has no pane to inherit a directory from —
        // the new session starts in $HOME, named after the host's habit.
        let source = activeTab.sessionName
        let preferences = NewSessionPreferences()
        let script = preferences.rememberedScript(for: host)
        Task {
            defer { creatingTab = false }
            guard let name = await hub.model(for: host).createSession(
                base: agent?.launchCommand ?? source ?? "main",
                inDirectoryOf: source,
                applying: host.newSessionTmuxConf,
                running: script?.normalizedBody,
                typing: agent.map {
                    $0.launchCommand(
                        model: preferences.rememberedModel(for: $0),
                        initialPrompt: ""
                    )
                }
            ) else {
                newTabFailedHost = host.name
                return
            }
            let tab = TerminalRoute(hostID: host.id, mode: .attach(sessionName: name))
            route.tabs.append(tab)
            route.activate(tab.id)
        }
    }

    /// The active tab's monitor-face close wording — the one string the
    /// shared chrome varies between the viewport and the file viewer.
    private var auxiliaryCloseLabel: String {
        activeTab?.isFileViewer == true ? "Close file viewer" : "Close viewport"
    }

    /// Dock a file viewer beside the active tab — the viewport's summon
    /// shape exactly: resolve the pane's cwd first (the same `list-panes`
    /// truth drops use), register the controller BEFORE the tab enters the
    /// route, insert after the active tab, activate. `target` carries a
    /// pressed path (and its line) when the summon came from the path sheet.
    ///
    /// A mosh tab has no exec channel, so it cannot answer that query at
    /// all — its session name rides along instead and the viewer asks over
    /// its own SSH connection. Without it a mosh worktree session rooted the
    /// tree, and every relative path press, at $HOME.
    private func openFileViewer(target: TerminalPathTarget?) {
        guard let activeTab, let host = store.host(id: activeTab.hostID) else { return }
        let anchorID = activeTab.id
        let hostID = activeTab.hostID
        let anchorSessionName = activeTab.sessionName
        Task {
            let cwd = await workspace.controller(for: anchorID)?.paneWorkingDirectory()
            let tab = TerminalRoute(
                hostID: hostID,
                mode: .fileViewer(path: target?.path ?? cwd ?? "~")
            )
            workspace.openFileViewer(
                tab: tab,
                host: host,
                startDirectory: cwd,
                anchorSessionName: anchorSessionName,
                target: target
            )
            dock(tab, after: anchorID)
        }
    }

    /// Dock a confirmed page as a viewport tab immediately after the tab
    /// whose pane printed the URL — the + TAB precedent: arrive where you
    /// are, move later (split it out to stand beside the terminal, merge it
    /// back; the page rides along live). The controller is registered BEFORE
    /// the tab enters the route — `syncTabs` treats a controller-less
    /// viewport tab as a restored corpse, which is the no-persistence rule.
    private func openViewport(_ offer: ViewportOffer) {
        guard let activeTab, let host = store.host(id: activeTab.hostID) else { return }
        let tab = TerminalRoute(
            hostID: activeTab.hostID,
            mode: .viewport(urlString: offer.url.absoluteString)
        )
        workspace.openViewport(tab: tab, offer: offer, host: host)
        dock(tab, after: activeTab.id)
    }

    /// Insert a freshly summoned tab immediately after its anchor (the
    /// + TAB precedent: arrive where you are, move later) and make it
    /// active — the shared tail of every auxiliary summon.
    private func dock(_ tab: TerminalRoute, after anchorID: UUID) {
        if let index = route.tabs.firstIndex(where: { $0.id == anchorID }) {
            route.tabs.insert(tab, at: index + 1)
        } else {
            route.tabs.append(tab)
        }
        route.activate(tab.id)
    }

    // MARK: Layout

    @ViewBuilder
    private var platformBody: some View {
        if let shell {
            shellBody(shell)
        } else {
            classicPlatformBody
        }
    }

    #if os(visionOS)
    private var classicPlatformBody: some View {
        GeometryReader { geometry in
            paneStack
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Theme.bezelHi, lineWidth: 1)
                )
                .ornament(
                    visibility: route.tabs.count > 1 ? .visible : .hidden,
                    attachmentAnchor: .scene(.top),
                    contentAlignment: .center
                ) {
                    // Source labels on an opaque chassis slab, not glass — the
                    // tab strip is part of the monitor, not the room.
                    tabStrip
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Theme.chassis,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                // Stacked console pinned by its LEADING row: the alignment
                // guide puts the first row's midline on the edge anchor, so
                // the agent bar (when detected — else the UMD) straddles the
                // window's bottom edge exactly where the store captures show
                // it, riding the status row, and the rest hangs below. A
                // plain centered stack rises as it grows — three rows lifted
                // the agent bar off the edge onto the screen content — and a
                // below-edge anchor (.top) parked the keys and window bar in
                // the floating keyboard's summon zone (both user-reported).
                .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .center) {
                    if activeTab?.isAuxiliaryPane == true {
                        // A page (or file screen) needs no keys, helper
                        // strip, or session controls — the monitor face
                        // carries DECK, the source label, MERGE, and CLOSE;
                        // the in-window rail owns everything pane-scoped.
                        ViewportUMD(
                            title: umdTitle,
                            mergeSources: mergeSources,
                            showDeck: showDeck,
                            merge: { merge($0) },
                            close: { if let activeTab { close(activeTab.id) } },
                            closeAccessibilityLabel: auxiliaryCloseLabel
                        )
                        .alignmentGuide(VerticalAlignment.center) { _ in 24 }
                    } else {
                    VStack(spacing: 10) {
                        // An ornament has its own intrinsic width. Clamp the
                        // long agent row to the live window width so narrowing
                        // the scene leaves both bottom resize controls clear.
                        helperStrip(
                            floating: true,
                            floatingMaximumWidth: min(
                                AgentHelperStrip.maximumFloatingWidth,
                                max(
                                    1,
                                    geometry.size.width
                                        - AgentHelperStrip.floatingEdgeClearance * 2
                                )
                            )
                        )
                        // The floating visionOS keyboard has no ESC/CTRL/TAB,
                        // arrows, or RET; the chrome carries them (same send
                        // path as typing) plus the keyboard toggle. The keys
                        // flank the UMD on one console row — ESC/CTRL/TAB
                        // left, navigation keys right. The width clamp is
                        // what lets its ViewThatFits compact the key faces —
                        // and it must be OrnamentWidthClamp, never
                        // `.frame(maxWidth:)`: an ornament clips to its
                        // REPORTED bounds, and a frame caps the report, so
                        // the too-narrow floor tier rendered with both key
                        // slabs and DECK sliced off at the window edges.
                        OrnamentWidthClamp(
                            maxWidth: max(1, geometry.size.width - 24)
                        ) {
                            TerminalKeyCluster(controller: activeController) {
                                UMDBar(
                                    controller: activeController,
                                    title: umdTitle,
                                    mergeSources: mergeSources,
                                    showDeck: showDeck,
                                    fontDown: { fontSize = max(9, fontSize - 1) },
                                    fontUp: { fontSize = min(32, fontSize + 1) },
                                    newSession: { openNewTab(launching: $0) },
                                    openFileViewer: { openFileViewer(target: nil) },
                                    merge: { merge($0) },
                                    detach: { detachActiveTab() },
                                    closeSession: activeTabHasSession
                                        ? { confirmingCloseActiveSession = true } : nil,
                                    keychainTip: activeTabKeychainNotice != nil
                                        ? { presentKeychainTip() } : nil,
                                    showsTmuxShortcuts: activeTab?.sessionName != nil
                                )
                            }
                        }
                    }
                    // "Center" resolves through this guide. With an agent
                    // detected, the strip/console-row boundary sits on the
                    // anchor: the agent bar rides ON the status row just
                    // inside the window edge — the store-capture geometry
                    // (fastlane/…/visionos-09-keys.png, pre-merge rows) —
                    // and the console row (keys flanking the UMD) hangs
                    // below. Without one, that row straddles the edge.
                    // Empirical against the system's ornament standoff;
                    // re-verify visually when touching them. Content must
                    // never hang much deeper than this row does: the system
                    // clips ornament content far below the anchor at
                    // compact window widths (a third stacked row rendered
                    // as a sliver).
                    .alignmentGuide(VerticalAlignment.center) { _ in
                        showsAgentHelper ? 40 : 24
                    }
                    }
                }
        }
    }

    #else
    private var classicPlatformBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if route.tabs.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        tabStrip
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .background(Theme.chassis)
                    Rectangle().fill(Theme.bezelHi).frame(height: 1)
                }
                iOSPaneSurface
            }
            .navigationTitle(windowTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.chassis, for: .navigationBar)
            .toolbar { toolbarContent }
        }
    }
    #endif

    private func shellBody(_ configuration: ShellConfiguration) -> some View {
        VStack(spacing: 0) {
            if activeTab?.isAuxiliaryPane == true {
                ViewportUMD(
                    title: umdTitle,
                    mergeSources: [],
                    showDeck: configuration.showDeck,
                    merge: { _ in },
                    close: { if let activeTab { close(activeTab.id) } },
                    style: .shell,
                    deckControlLabel: configuration.deckControlLabel,
                    contentSafeArea: configuration.contentSafeArea,
                    closeAccessibilityLabel: auxiliaryCloseLabel
                )
            } else {
            UMDBar(
                controller: activeController,
                title: umdTitle,
                mergeSources: [],
                showDeck: configuration.showDeck,
                fontDown: { fontSize = max(9, fontSize - 1) },
                fontUp: { fontSize = min(32, fontSize + 1) },
                newSession: { openNewTab(launching: $0) },
                openFileViewer: { openFileViewer(target: nil) },
                merge: { _ in },
                detach: { detachActiveTab() },
                closeSession: activeTabHasSession
                    ? { confirmingCloseActiveSession = true } : nil,
                keychainTip: activeTabKeychainNotice != nil
                    ? { presentKeychainTip() } : nil,
                showsTmuxShortcuts: activeTab?.sessionName != nil,
                style: .shell,
                deckControlLabel: configuration.deckControlLabel,
                availableWidth: configuration.availableWidth,
                contentSafeArea: configuration.contentSafeArea
            )
            }
            if route.tabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    tabStrip
                        .padding(.leading, 10 + configuration.contentSafeArea.leading)
                        .padding(.trailing, 10 + configuration.contentSafeArea.trailing)
                        .padding(.vertical, 6)
                }
                .background(Theme.chassis)
                Rectangle().fill(Theme.bezelHi).frame(height: 1)
            }
            #if os(visionOS)
            paneStack
                .overlay(alignment: .bottom) {
                    if activeTab?.isAuxiliaryPane != true {
                        VStack(spacing: 8) {
                            helperStrip(
                                floating: true,
                                floatingMaximumWidth: max(
                                    1,
                                    configuration.availableWidth - 24
                                )
                            )
                            // The width clamp engages the cluster's compact
                            // tiers in a phone-narrow shell.
                            TerminalKeyCluster(controller: activeController)
                                .frame(maxWidth: max(
                                    1,
                                    configuration.availableWidth - 24
                                ))
                        }
                        .padding(.bottom, 10)
                    }
                }
            #else
            iOSPaneSurface
            #endif
        }
        .background(Theme.chassis)
    }

    #if !os(visionOS)
    private var iOSPaneSurface: some View {
        paneStack
            .overlay(alignment: .bottom) {
                // Reserve this height inside SwiftTermView, then paint the
                // helper into that gap immediately above the bottommost key
                // rail. Keeping the rail inside the UIKit container avoids
                // both TextInputUI accessory hosting and a controller cycle.
                helperStrip(floating: false)
                    .padding(
                        .bottom,
                        (activeController?.keyboardObstruction ?? 0)
                            + TerminalKeyBar.barHeight
                    )
            }
            // A real docked keyboard makes SwiftUI apply the window's bottom
            // safe area twice. Extend through it only while docked so the
            // tmux row, helper, and UIKit rail share one baseline.
            .ignoresSafeArea(
                .container,
                edges: (activeController?.keyboardObstruction ?? 0) > 0
                    ? .bottom : []
            )
            // SwiftUI's automatic avoidance must not touch the terminal:
            // the container is the sole owner of docked clearance.
            .ignoresSafeArea(.keyboard)
    }
    #endif

    /// Every tab's pane stays alive (terminal state, resize events); only
    /// the active one is visible and hittable.
    private var paneStack: some View {
        ZStack {
            ForEach(route.tabs) { tab in
                let isActive = tab.id == activeTab?.id
                Group {
                    if tab.isViewport {
                        // syncTabs guarantees a controller exists for every
                        // viewport tab still in the route.
                        if let viewport = workspace.viewportController(for: tab.id) {
                            ViewportPane(
                                controller: viewport,
                                contentSafeArea: contentSafeArea,
                                close: { close(tab.id) }
                            )
                        }
                    } else if tab.isFileViewer {
                        // Same guarantee, same strip rule (isAuxiliaryPane).
                        if let fileViewer = workspace.fileViewerController(for: tab.id) {
                            FileViewerPane(
                                controller: fileViewer,
                                contentSafeArea: contentSafeArea,
                                isActive: isActive,
                                close: { close(tab.id) }
                            )
                        }
                    } else {
                        TerminalPane(
                            controller: workspace.controller(for: tab.id),
                            hostExists: store.host(id: tab.hostID) != nil,
                            fontSize: fontSize,
                            bottomChromeHeight: terminalBottomChromeHeight,
                            contentSafeArea: contentSafeArea,
                            railOwnsBottomSafeArea: railOwnsBottomSafeArea,
                            isActive: isActive,
                            focusAllowed: terminalFocusAllowed,
                            close: { close(tab.id) }
                        )
                    }
                }
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
            }
        }
        #if os(visionOS)
        .background(Theme.screen.ignoresSafeArea())
        #else
        .background(Theme.screen)
        #endif
    }

    /// The agent helper strip, when the active tab's session runs one.
    /// visionOS floats it in the bottom ornament above the UMD (the window's
    /// bottom edge belongs to the ornament, which would overlap an inset);
    /// iPad docks it as a bottom inset under the screen, where appearing
    /// resizes the PTY like a keyboard would.
    @ViewBuilder
    private func helperStrip(
        floating: Bool,
        floatingMaximumWidth: CGFloat? = nil
    ) -> some View {
        if let activeTab,
           let agent = shownAgent,
           let controller = activeController,
           controller.status == .live {
            let commandConfiguration = store.agentCommandConfiguration(
                for: activeTab.hostID
            )
            AgentHelperStrip(
                agent: agent,
                canShowCommands: entitlements.isPro || entitlements.canUseSlashChip,
                builtInPlacements: commandConfiguration.builtInPlacements(
                    for: agent
                ),
                customCommands: commandConfiguration.commands(for: agent),
                historyController: controller,
                historyLocked: !entitlements.canBrowseAgentHistory,
                floating: floating,
                floatingMaximumWidth: floatingMaximumWidth,
                contentSafeArea: floating ? EdgeInsets() : contentSafeArea,
                send: { send($0, via: controller) },
                saveCommandConfiguration: { commands, placements in
                    store.replaceAgentCommandConfiguration(
                        commands,
                        builtInPlacements: placements,
                        for: agent,
                        hostID: activeTab.hostID
                    )
                },
                openPaywall: { showingPaywall = true },
                isFocusOwner: {
                    guard let terminalView = controller.terminalView else { return false }
                    return TerminalFocusArbiter.current === terminalView
                }
            )
            // A tab switch can keep the same detected agent while changing
            // hosts. Reset any open drafts so they cannot save into the host
            // now behind the terminal surface.
            .id(activeTab.hostID)
        }
    }

    /// An auxiliary tab's label follows what its pane is showing NOW — the
    /// route only knows the summons (a viewport's page moves, a viewer
    /// navigates), so the live controller answers whenever it exists.
    private func tabTitle(for tab: TerminalRoute) -> String {
        if tab.isAuxiliaryPane,
           let auxiliary = workspace.auxiliaryController(for: tab.id) {
            return auxiliary.tabLabel
        }
        return tab.displayName
    }

    private var tabItems: [TerminalTabStrip.Item] {
        let multiHost = Set(route.tabs.map(\.hostID)).count > 1
        return route.tabs.map { tab in
            .init(
                id: tab.id,
                title: tabTitle(for: tab),
                hostName: multiHost ? store.host(id: tab.hostID)?.name : nil,
                controller: workspace.controller(for: tab.id),
                isActive: tab.id == activeTab?.id,
                isAuxiliary: tab.isAuxiliaryPane
            )
        }
    }

    private var tabStrip: some View {
        TerminalTabStrip(
            items: tabItems,
            activate: { route.activate($0) },
            split: { split($0) },
            close: { close($0) },
            allowsSplit: shell == nil
        )
    }

    // MARK: Chrome

    private var windowTitle: String {
        if let activeController { return activeController.windowTitle }
        if let activeTab { return tabTitle(for: activeTab) }
        return "terminal"
    }

    /// "MAIN · DEVBOX" — the UMD source label.
    private var umdTitle: String {
        guard let activeTab else { return windowTitle }
        let host = store.host(id: activeTab.hostID)?.name
        let name = tabTitle(for: activeTab)
        return host.map { "\(name) · \($0)" } ?? name
    }

    #if !os(visionOS)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(iOS 26.0, *) {
            // Liquid Glass otherwise gathers these controls into a rounded
            // floating capsule. The terminal bar is the iPad equivalent of
            // the opaque UMD: independent, square chassis chips.
            ToolbarItemGroup(placement: .topBarLeading) {
                deckButton
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) {
                primaryToolbarActions(trailingPadding: 12)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .topBarLeading) {
                deckButton
            }
            ToolbarItemGroup(placement: .primaryAction) {
                primaryToolbarActions(trailingPadding: 0)
            }
        }
    }

    @ViewBuilder
    private func primaryToolbarActions(trailingPadding: CGFloat) -> some View {
        if activeController?.host.useMosh == true {
            ChassisBadge("MOSH")
                .fixedSize()
                .accessibilityLabel("Connects over mosh")
        }
        if case .needsYou = activeController?.directShellAttention {
            // A classic iPad plain shell has no wall tile or bottom UMD; keep
            // the same captioned state in its toolbar instead.
            TallyLamp(caption: "NEEDS YOU", color: Theme.caution)
                .fixedSize()
                .accessibilityLabel("Agent needs you")
        }
        if activeTabKeychainNotice != nil {
            // Classic iPad windows have no UMD either — the KEYCHAIN LOCKED
            // status rides the toolbar, same as NEEDS YOU above.
            Button {
                presentKeychainTip()
            } label: {
                TallyLamp(caption: "KEYCHAIN LOCKED", color: Theme.caution)
            }
            .buttonStyle(.plain)
            .chassisHover(2)
            .fixedSize()
            .accessibilityLabel(
                "The Mac's keychain is locked, so Claude Code shows signed out"
            )
            .accessibilityHint("Shows how to unlock the keychain")
        }
        if activeTab?.isAuxiliaryPane == true {
            // A page (or file screen) needs none of the terminal's
            // controls: MERGE (the road home for a split-out tab) and
            // CLOSE are the window's whole vocabulary — the rail under
            // the pane owns the rest.
            if !mergeSources.isEmpty {
                mergeMenu
            }
            ChassisChip("CLOSE", prominent: true) {
                if let activeTab { close(activeTab.id) }
            }
            .fixedSize()
            .accessibilityLabel(auxiliaryCloseLabel)
            .padding(.trailing, trailingPadding)
        } else if horizontalSizeClass == .compact {
            // UIKit's automatic toolbar overflow keeps only the trailing
            // DETACH menu when custom chassis controls no longer fit. Own the
            // compact overflow just like the iPhone shell so every displaced
            // action remains reachable in a narrow Stage Manager window.
            terminalOverflowMenu(displacesDirectActions: true)
                .padding(.trailing, trailingPadding)
        } else {
            newTabMenu
            FileAttachMenu(controller: activeController)
                .fixedSize()
            fontButtons
            if !mergeSources.isEmpty {
                mergeMenu
            }
            // Nothing was displaced at this width, but the actions menu is
            // still where the keyboard lock is named — the hold gesture on the
            // rail's keyboard key is otherwise undiscoverable.
            if activeController != nil {
                terminalOverflowMenu(displacesDirectActions: false)
            }
            detachMenu
                .padding(.trailing, trailingPadding)
        }
    }

    private func terminalOverflowMenu(displacesDirectActions: Bool) -> some View {
        TerminalOverflowMenu(
            controller: activeController,
            mergeSources: mergeSources,
            fontDown: { fontSize = max(9, fontSize - 1) },
            fontUp: { fontSize = min(32, fontSize + 1) },
            newSession: { openNewTab(launching: $0) },
            openFileViewer: { openFileViewer(target: nil) },
            merge: { merge($0) },
            detach: { detachActiveTab() },
            closeSession: activeTabHasSession
                ? { confirmingCloseActiveSession = true } : nil,
            displacesDirectActions: displacesDirectActions
        )
        .fixedSize()
    }

    /// Dropdown: detach (tmux keeps the session) or the destructive
    /// alternative — kill the session, then close the tab. A plain shell
    /// tab has no session to kill, so it keeps a direct button.
    @ViewBuilder
    private var detachMenu: some View {
        if activeTabHasSession {
            Menu {
                Button("Detach") { detachActiveTab() }
                Button("Close Session", role: .destructive) {
                    confirmingCloseActiveSession = true
                }
            } label: {
                ChassisBadge("DETACH", prominent: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .chassisHover(2)
            .fixedSize()
            .accessibilityLabel("Detach or close the session")
        } else {
            ChassisChip("DETACH", prominent: true, action: detachActiveTab)
                .fixedSize()
                .accessibilityLabel("Detach: tmux keeps the session")
        }
    }

    /// Dropdown: a fresh session in the active tab's directory, plain or
    /// launching an agent — mirrors the deck's New Session options — plus
    /// the file viewer, which docks beside this tab at the pane's cwd.
    private var newTabMenu: some View {
        Menu {
            NewTabMenuItems(
                newSession: { openNewTab(launching: $0) },
                openFileViewer: { openFileViewer(target: nil) }
            )
        } label: {
            ChassisBadge("TAB", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chassisHover(2)
        .fixedSize()
        .accessibilityLabel("New tab: another session or the file viewer")
    }

    private var deckButton: some View {
        ChassisChip("DECK", systemImage: "square.grid.2x2", action: showDeck)
            .fixedSize()
            .accessibilityLabel("Show Deck")
    }

    private var fontButtons: some View {
        HStack(spacing: 4) {
            ChassisChip("A−") {
                fontSize = max(9, fontSize - 1)
            }
            .fixedSize()
            .accessibilityLabel("Smaller text")
            ChassisChip("A+") {
                fontSize = min(32, fontSize + 1)
            }
            .fixedSize()
            .accessibilityLabel("Larger text")
        }
    }

    /// Other terminal windows this one can swallow as tabs.
    private var mergeMenu: some View {
        Menu {
            ForEach(mergeSources) { entry in
                Button {
                    merge(entry.id)
                } label: {
                    Label(entry.label, systemImage: "macwindow")
                }
            }
            if mergeSources.count > 1 {
                Divider()
                Button {
                    let sources = mergeSources
                    for entry in sources { merge(entry.id) }
                } label: {
                    Label("Merge All Windows", systemImage: "rectangle.stack")
                }
            }
        } label: {
            ChassisBadge("MERGE")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chassisHover(2)
        .fixedSize()
        .accessibilityLabel("Merge another window into this one")
    }
    #endif

    /// Back to the main screen. The deck's stable data value raises the
    /// matching window and creates it only when none exists. Keep this on the
    /// SwiftUI presentation path: direct scene activation on visionOS can
    /// reset a user-resized deck to the scene's default size.
    private func showDeck() {
        if let shell {
            shell.showDeck()
            return
        }
        openWindow(id: "deck", value: DeckWindowRoute.main)
    }

    // MARK: Tab machinery

    /// Idempotent reconciliation, run on appearance and every tabs change:
    /// an emptied window dismisses itself (that's how a merged-away source
    /// closes), otherwise controllers exist for every tab and the window's
    /// directory entry is fresh.
    private func syncTabs() {
        // The auxiliary panes' no-persistence rule: their controllers exist
        // only in the process that summoned them (`openViewport`/
        // `openFileViewer` register before the tab enters any route), so an
        // auxiliary tab without one can only be scene restoration handing
        // back a previous launch's pane — summoned, not restored, it is
        // stripped rather than resurrected. The mutation re-enters here
        // through onChange; the second pass finds nothing to strip.
        let orphanedAuxiliaries = route.tabs.filter { tab in
            tab.isAuxiliaryPane && workspace.auxiliaryController(for: tab.id) == nil
        }
        if !orphanedAuxiliaries.isEmpty {
            let ids = Set(orphanedAuxiliaries.map(\.id))
            route.tabs.removeAll { ids.contains($0.id) }
            if let active = route.activeTabID, ids.contains(active) {
                route.activeTabID = route.tabs.first?.id
            }
            return
        }
        if route.tabs.isEmpty {
            workspace.unregisterWindow(id: route.id)
            if let shell {
                shell.tabsEmptied()
            } else {
                // Plain DismissAction, not dismissWindow(id:value:) — the
                // scene's committed value can lag the just-emptied binding,
                // and a mismatch would silently leave a ghost window behind.
                dismiss()
            }
            return
        }
        for tab in route.tabs where !tab.isAuxiliaryPane {
            // Auxiliary tabs must never mint a TerminalSessionController —
            // a file-viewer route has no PTY to dial.
            _ = workspace.controller(for: tab, store: store)
        }
        workspace.registerWindow(.init(
            id: route.id,
            tabs: route.tabs,
            label: windowLabel,
            reveal: { [route = $route, workspace, shell] tabID in
                route.wrappedValue.activate(tabID)
                if let shell {
                    shell.revealTab(tabID)
                } else {
                    workspace.controller(for: tabID)?.revealWindow()
                }
            },
            surrender: { [route = $route] in
                let tabs = route.wrappedValue.tabs
                route.wrappedValue.tabs = []
                route.wrappedValue.activeTabID = nil
                return tabs
            },
            adopt: { [route = $route] tabs in
                route.wrappedValue.merge(tabs)
            }
        ))
    }

    /// "main, scratch — devbox" in the sibling windows' Merge menus.
    private var windowLabel: String {
        let names = route.tabs.map(\.displayName).joined(separator: ", ")
        var seen = Set<UUID>()
        let hosts = route.tabs.compactMap { tab -> String? in
            guard seen.insert(tab.hostID).inserted else { return nil }
            return store.host(id: tab.hostID)?.name
        }
        return hosts.isEmpty ? names : "\(names) — \(hosts.joined(separator: ", "))"
    }

    private func close(_ tabID: UUID) {
        if shell != nil {
            workspace.controller(for: tabID)?.releaseFocus()
        }
        workspace.closeTab(tabID)
        route.removeTab(id: tabID)
        if shell != nil, route.tabs.isEmpty {
            syncTabs()
        }
    }

    /// Kill the tmux session on the host over its control connection
    /// (fire-and-forget, like the wall's delete), then close the tab.
    private func closeSession(_ tab: TerminalRoute) {
        guard let sessionName = tab.sessionName,
              let host = store.host(id: tab.hostID) else { return }
        let model = hub.model(for: host)
        Task { await model.killSession(named: sessionName) }
        close(tab.id)
    }

    /// Closing the channel detaches the tmux client; tmux keeps the session.
    /// The window follows its last tab out.
    private func detachActiveTab() {
        guard let activeTab else { return }
        close(activeTab.id)
    }

    private func merge(_ windowID: UUID) {
        route.merge(workspace.surrenderTabs(of: windowID))
    }

    private func split(_ tabID: UUID) {
        guard shell == nil else { return }
        guard route.tabs.count > 1, let tab = route.removeTab(id: tabID) else { return }
        openWindow(id: "terminal", value: TerminalWindowRoute(tab: tab))
    }
}

/// One tab's surface: opaque themed gutter, terminal edge to edge, and the
/// tab's own connection lifecycle overlay. Stays alive while hidden so the
/// terminal keeps its state and PTY size.
private struct TerminalPane: View {
    @Environment(ThemeStore.self) private var themes
    /// Terminal themes are selected per chassis appearance; flipping the
    /// scheme re-resolves here and `SwiftTermView` re-skins in place.
    @Environment(\.colorScheme) private var colorScheme

    let controller: TerminalSessionController?
    let hostExists: Bool
    let fontSize: CGFloat
    let bottomChromeHeight: CGFloat
    var contentSafeArea = EdgeInsets()
    var railOwnsBottomSafeArea = false
    let isActive: Bool
    let focusAllowed: Bool
    let close: () -> Void

    @State private var dropTargeted = false
    #if !os(visionOS)
    /// The keyboard key's hold-to-lock state — read here so the badge
    /// appears and clears with the arbiter's lock.
    private let keyboardLock = KeyboardLock.shared
    #endif

    var body: some View {
        let theme = themes.selected(for: colorScheme)
        ZStack {
            // The gutter around the terminal matches its background, so the
            // window reads as one surface in whatever theme is active.
            #if os(visionOS)
            Color(theme.background).ignoresSafeArea()
            #else
            // UIKit keeps rail controls inside the rounded-corner safe
            // boundary. Paint that protected tail as part of the rail, then
            // cover the terminal's ordinary bounds with its selected theme.
            // The stale strip may still be classified as keyboard safe area
            // after a float/window move, so this paint layer ignores both
            // container and keyboard regions. It has no controls or layout.
            Theme.bezel.ignoresSafeArea()
            Color(theme.background)
            #endif
            if let controller {
                SwiftTermView(
                    controller: controller,
                    fontSize: fontSize,
                    theme: theme,
                    bottomChromeHeight: bottomChromeHeight,
                    contentSafeArea: contentSafeArea,
                    railOwnsBottomSafeArea: railOwnsBottomSafeArea,
                    isActive: isActive && focusAllowed,
                    showsTmuxShortcuts: controller.route.sessionName != nil
                )
                if case .finding = controller.historyJump {
                    // The remote find loop owns the pane: the veil makes the
                    // input lock visible and swallows touches until the
                    // search resolves or is cancelled.
                    HistoryFindingVeil()
                }
                statusOverlay(for: controller)
            } else if !hostExists {
                missingHost
            }
        }
        // A shell that (re)connects claims focus outright — if its tab is
        // the one on screen.
        .onChange(of: controller?.status) { _, status in
            if status == .live, isActive, focusAllowed {
                controller?.focusTerminal()
            }
        }
        // Dropped files upload into the pane's cwd, then their paths get
        // typed into the session (never submitted). Unsupported live tabs
        // still accept the intent so the shared controller can explain the
        // SSH-tmux requirement in its status pill.
        .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in
            guard let controller, controller.status == .live else { return false }
            Task { @MainActor in
                controller.deliverDrop(await TerminalDropCatcher.load(providers))
            }
            return true
        }
        .overlay {
            if dropTargeted, controller?.status == .live {
                DropTargetVeil()
            }
        }
        .overlay(alignment: .top) { topContextualBar }
        // Trailing, not centered: the find loop stops on the page where the
        // message entered from the top, so the jumped-to line is usually the
        // FIRST row — a centered bar would sit right on it.
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                #if !os(visionOS)
                // The lock is app-wide (one keyboard), so the tip rides
                // whichever pane is on screen. Its mic restores the
                // dictation affordance the locked software keyboard took
                // away. Once the microphone opens, the full LISTENING bar
                // owns this top slot instead so the two controls never
                // collide at phone width.
                if isActive, let controller, keyboardLock.isLocked,
                   controller.dictation == nil {
                    KeyboardLockedBadge(
                        isDictating: controller.isDictating,
                        toggleDictation: { controller.toggleDictation() }
                    )
                }
                #endif
                if isActive, let controller, !controller.tmuxCopyModeUIActive,
                   let phase = controller.historyJump {
                    HistoryJumpBar(
                        phase: phase,
                        cancel: controller.cancelHistoryJump,
                        backToLive: controller.finishHistoryJump
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let notice = controller?.historyNotice {
                    HistoryNoticePill(text: notice)
                }
                if let dropState = controller?.dropState {
                    DropStatusPill(state: dropState)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// The pane's app-owned interaction states share one slot at the top —
    /// they are alternatives, never simultaneous (copy mode freezes the
    /// pane; dictation is refused while the jump search holds it).
    @ViewBuilder
    private var topContextualBar: some View {
        if isActive, let controller {
            if controller.tmuxCopyModeUIActive {
                TmuxCopyModeBar(done: controller.finishTmuxCopyMode)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            } else {
                dictationBar(for: controller)
            }
        }
    }

    /// Dictation is app-owned recognition, so the pane says that the
    /// microphone is open — and what it has heard but not handed over yet.
    /// Everything before that queue is already typed into the session.
    @ViewBuilder
    private func dictationBar(for controller: TerminalSessionController) -> some View {
        #if !os(visionOS)
        if let state = controller.dictation {
            DictationBar(
                state: state,
                stop: controller.stopDictation,
                cancel: controller.cancelDictation
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        #endif
    }

    @ViewBuilder
    private func statusOverlay(for controller: TerminalSessionController) -> some View {
        switch controller.status {
        case .connecting:
            ChassisPanel {
                ProgressView()
                Text(connectingCaption(for: controller))
                    .font(.mono(14))
                    .foregroundStyle(Theme.signal2)
            }
        case .live:
            EmptyView()
        case .ended(let reason):
            ChassisPanel {
                TallyLamp(caption: reason == nil ? "DETACHED" : "ENDED", color: Theme.signal3)
                if let reason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(Theme.signal2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                HStack(spacing: 12) {
                    ChassisChip("RECONNECT", prominent: true) { controller.reconnect() }
                    ChassisChip("CLOSE TAB") { close() }
                }
                .padding(.top, 4)
            }
        }
    }

    /// Repairing a transport the system killed while the app was suspended
    /// is not a first connection, and a tmux tab's work is still standing on
    /// the host — say which one is happening.
    private func connectingCaption(for controller: TerminalSessionController) -> String {
        guard controller.isResuming else { return "Connecting to \(controller.host.name)…" }
        return controller.route.sessionName == nil
            ? "Reconnecting to \(controller.host.name)…"
            : "Reattaching to \(controller.host.name)…"
    }

    /// A restored tab whose host was removed — say so, never a blank pane.
    private var missingHost: some View {
        ChassisPanel {
            Text("This host was removed")
                .font(.mono(17, weight: .semibold))
                .foregroundStyle(Theme.signal)
            Text("The tab can't reconnect because its host no longer exists in the deck.")
                .font(.subheadline)
                .foregroundStyle(Theme.signal2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            ChassisChip("CLOSE TAB", prominent: true) { close() }
                .padding(.top, 4)
        }
    }
}

#if !os(visionOS)
/// The keyboard key was held: the software keyboard is locked closed and
/// terminal taps won't summon it. The trailing mic keeps dictation reachable
/// without reopening the keyboard — especially on iPhone, where the software
/// keyboard was the only other place that affordance lived. Lock is a chosen
/// mode, not live state, so the tip spends no tally red.
private struct KeyboardLockedBadge: View {
    let isDictating: Bool
    var toggleDictation: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.ui(10, weight: .semibold))
                Text("KEYBOARD LOCKED")
                    .font(.mono(10, weight: .semibold))
                    .kerning(1.1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)

            Rectangle()
                .fill(Theme.bezelHi)
                .frame(width: 1, height: 20)

            Button(action: toggleDictation) {
                Image(systemName: isDictating ? "mic.fill" : "mic")
                    .font(.ui(12, weight: .semibold))
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isDictating ? Theme.chassis : Theme.signal2)
            .background(isDictating ? Theme.signal2 : Color.clear)
            .chassisHover(2)
            .accessibilityLabel(isDictating ? "Stop dictation" : "Dictate")
            .accessibilityHint("Types what you say into the session as you speak, never pressing Return")
        }
        .foregroundStyle(Theme.signal2)
        .background(Theme.bezel, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.bezelHi, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
#endif

/// tmux's native copy-mode marker is a tiny `[position/history]` token inside
/// the terminal grid. This compact contextual bar keeps the mode visible and
/// gives every platform an obvious way back to the shell.
private struct TmuxCopyModeBar: View {
    var done: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            TallyLamp(caption: "COPY MODE", color: Theme.caution)
            ChassisChip("DONE", prominent: true, action: done)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Theme.bezel,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

#if !os(visionOS)
/// The dictation counterpart of `TmuxCopyModeBar`: an open microphone is
/// live state, so it gets a captioned tally lamp. Settled words go into the
/// session as they land, so what sits beside the lamp is the short queue the
/// recognizer is still reconsidering — dimmer than typed text, because it is
/// not in the session yet. STOP types that queue; CANCEL abandons it.
private struct DictationBar: View {
    let state: TerminalSessionController.DictationState
    var stop: () -> Void
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            switch state {
            case .listening(let pending):
                TallyLamp(caption: "LISTENING")
                if !pending.isEmpty {
                    Text(pending)
                        .font(.mono(12))
                        .foregroundStyle(Theme.signal3)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 320, alignment: .leading)
                        .accessibilityLabel("Heard, not typed yet: \(pending)")
                }
                ChassisChip("CANCEL", action: cancel)
                ChassisChip("STOP", prominent: true, action: stop)
            case .failed(let message):
                TallyLamp(caption: "DICTATION", color: Theme.caution)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.signal2)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Theme.bezel,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
#endif

/// Jump-to-message state over the terminal: FINDING while the remote script
/// pages the transcript (input is locked, the veil below explains why), and
/// JUMPED once the message is on screen, with the explicit way back.
private struct HistoryJumpBar: View {
    let phase: TerminalSessionController.HistoryJumpPhase
    var cancel: () -> Void
    var backToLive: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            switch phase {
            case .finding(let preview):
                TallyLamp(caption: "FINDING", color: Theme.caution)
                previewLabel(preview)
                ChassisChip("CANCEL", action: cancel)
            case .jumped(let preview, _):
                TallyLamp(caption: "JUMPED", color: Theme.caution)
                previewLabel(preview)
                ChassisChip("BACK TO LIVE", prominent: true, action: backToLive)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Theme.bezel,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func previewLabel(_ preview: String) -> some View {
        Text(preview)
            .font(.mono(10))
            .foregroundStyle(Theme.signal2)
            .lineLimit(1)
            .frame(maxWidth: 220)
    }
}

/// Dims the pane and swallows touches while the jump search drives the
/// remote pager — the visible face of the controller's input lock.
private struct HistoryFindingVeil: View {
    var body: some View {
        ZStack {
            Theme.screen.opacity(0.72)
            VStack(spacing: 10) {
                ProgressView()
                ChassisLabel("SEARCHING TRANSCRIPT", size: 10, color: Theme.signal2)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Transient jump outcome ("AGENT IS BUSY", "NOT IN THE VISIBLE
/// TRANSCRIPT") — same chassis voice as the drop pill beside it.
private struct HistoryNoticePill: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.caution).frame(width: 5, height: 5)
            Text(text)
                .font(.mono(10))
                .foregroundStyle(Theme.signal2)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.bezel)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

#if os(visionOS)
/// Proposes at most `maxWidth` to its content but reports the content's
/// ACTUAL size. An ornament clips to its reported bounds, so the ordinary
/// `.frame(maxWidth:)` — which caps the report — sliced the console row's
/// key slabs off at the window edges whenever the fixedSize floor tier
/// overflowed the clamp. This keeps the clamp's tier-driving proposal
/// (bounded even when the ornament proposes nothing) while letting the
/// ornament grow to whatever the chosen tier really needs.
private struct OrnamentWidthClamp: Layout {
    var maxWidth: CGFloat

    private func clamped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(
            width: min(proposal.width ?? maxWidth, maxWidth),
            height: proposal.height
        )
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(clamped(proposal))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        content.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: clamped(proposal)
        )
    }
}
#endif

#if DEBUG
#Preview("Copy mode bar") {
    TmuxCopyModeBar(done: {})
        .padding()
        .background(Theme.screen)
}

#Preview("History jump bars") {
    VStack(spacing: 12) {
        HistoryJumpBar(
            phase: .finding(preview: "Fix the probe parser"),
            cancel: {},
            backToLive: {}
        )
        HistoryJumpBar(
            phase: .jumped(preview: "Fix the probe parser", pages: 7),
            cancel: {},
            backToLive: {}
        )
        HistoryNoticePill(text: "NOT IN THE VISIBLE TRANSCRIPT")
    }
    .padding()
    .background(Theme.screen)
}
#endif

#if DEBUG
extension Notification.Name {
    static let multiplexDebugNewTab = Notification.Name("MultiplexDebugNewTab")
    static let multiplexDebugMessageJump = Notification.Name("MultiplexDebugMessageJump")
    static let multiplexDebugMessageJumpBack = Notification.Name(
        "MultiplexDebugMessageJumpBack"
    )
    static let multiplexDebugLink = Notification.Name("MultiplexDebugLink")
    static let multiplexDebugLinkOpen = Notification.Name("MultiplexDebugLinkOpen")
    static let multiplexDebugViewportOpen = Notification.Name("MultiplexDebugViewportOpen")
    static let multiplexDebugLinkRegions = Notification.Name("MultiplexDebugLinkRegions")
    static let multiplexDebugFileViewer = Notification.Name("MultiplexDebugFileViewer")
    static let multiplexDebugPathView = Notification.Name("MultiplexDebugPathView")
    static let multiplexDebugFileViewerRepoDiff = Notification.Name(
        "MultiplexDebugFileViewerRepoDiff"
    )
    static let multiplexDebugFileViewerSelect = Notification.Name(
        "MultiplexDebugFileViewerSelect"
    )
}

/// `….debug.fileviewer` runs the focused window's + TAB ▸ File Viewer
/// action (pane-cwd resolve → controller registration → tab dock);
/// `….debug.pathview` runs the path sheet's ▤ VIEW for the pending path a
/// prior `….debug.link` raised over path-shaped text — together the
/// headless walk of both summon doors. `….debug.fvselect` toggles the
/// active viewer's rendered-markdown SELECT mode (the rail chip the
/// simulator can't tap).
@MainActor
enum FileViewerDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var openToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.fileviewer", &openToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugFileViewer, object: nil)
        }
        var viewToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.pathview", &viewToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugPathView, object: nil)
        }
        var repoDiffToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.fvrepodiff", &repoDiffToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugFileViewerRepoDiff, object: nil
            )
        }
        var selectToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.fvselect", &selectToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugFileViewerSelect, object: nil
            )
        }
    }
}

/// `….debug.link` activates the first link on the focused terminal's visible
/// screen — the same resolve → policy → confirmation path a long press takes,
/// which is the only way to drive it headlessly (no sim tap injection exists,
/// and ornament/gesture input can't be synthesized). `….debug.linkopen` then
/// runs the sheet's OPEN action, so a screenshot shows Safari with the target.
@MainActor
enum TerminalLinkDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var findToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.link", &findToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugLink, object: nil)
        }
        var openToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.linkopen", &openToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugLinkOpen, object: nil)
        }
        var viewportToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.viewportopen", &viewportToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugViewportOpen, object: nil)
        }
        var regionsToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.linkregions", &regionsToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugLinkRegions, object: nil)
        }
    }
}

/// Headless-verification hook, same shape as `AgentChipDebugHook`:
/// `xcrun simctl spawn <udid> notifyutil -p app.multiplexterm.multiplex.debug.newtab`
/// runs the focused window's + TAB New Session action — control-connection
/// exec → new-session in the pane's cwd → tab append → attach, without
/// touching the screen.
@MainActor
enum NewTabDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.newtab", &token, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugNewTab, object: nil)
        }
    }
}

/// `….debug.msgjump` jumps the focused Claude Code terminal to its oldest
/// session-file prompt; `….debug.msgjumpback` runs BACK TO LIVE. Host-side
/// capture-pane proves both: the old prompt appears, then the live tail
/// returns.
@MainActor
enum MessageJumpDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var jumpToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.msgjump", &jumpToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugMessageJump, object: nil
            )
        }
        var backToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.msgjumpback", &backToken, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugMessageJumpBack, object: nil
            )
        }
    }
}
#endif
