import SwiftUI
import UniformTypeIdentifiers
#if DEBUG
import notify
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
    @Environment(CustomAgentCommandStore.self) private var customAgentCommands
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

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
    private var terminalFocusAllowed: Bool {
        shell?.terminalFocusAllowed ?? true
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

    /// Agent in the pane this tab's keystrokes reach, per the latest probe.
    private var detectedAgent: AgentKind? {
        guard let activeTab,
              let sessionName = activeTab.sessionName,
              let host = store.host(id: activeTab.hostID)
        else { return nil }
        return hub.model(for: host).tmux.sessions
            .first { $0.name == sessionName }?
            .activeAgent
    }

    var body: some View {
        platformBody
            .task { syncTabs() }
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
            .onChange(of: route.activeTabID) {
                if terminalFocusAllowed {
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
                    entitlements.refreshSlashChipMeter()
                    activeController?.restoreFocusIfOwner(
                        allowed: terminalFocusAllowed
                    )
                    for tab in route.tabs {
                        workspace.controller(for: tab.id)?.transportForegrounded()
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) { ProPaywallView() }
            .alert(
                "Couldn't Create Session",
                isPresented: Binding(
                    get: { newTabFailedHost != nil },
                    set: { if !$0 { newTabFailedHost = nil } }
                )
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
            #endif
    }

    /// Keep this host's full wall state fresh while a terminal window is
    /// open. Periodic callers share the model and skip a snapshot completed
    /// in the previous four seconds, preventing staggered windows plus the
    /// deck from multiplying the expensive host-wide pass.
    private func keepHostProbeWarm() async {
        #if DEBUG
        AgentChipDebugHook.install()
        NewTabDebugHook.install()
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
              let sessionName = activeTab.sessionName,
              let host = store.host(id: activeTab.hostID)
        else {
            activePaneFingerprint = nil
            shownAgent = nil
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
              let agent = shownAgent,
              entitlements.isPro || entitlements.canUseSlashChip,
              controller.status == .live,
              let command = AgentCommandSet.commands(
                  in: .bar,
                  for: agent,
                  placementOverrides: customAgentCommands.builtInPlacements(for: agent)
              ).first(where: { $0.label.hasPrefix("/") })
        else { return }
        send(command, via: controller)
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
    #endif

    /// The + TAB button: mint a fresh tmux session next to the active tab —
    /// same host, same directory as its pane (an agent variant also types
    /// its launch command into the new shell) — and attach it as a new tab
    /// of this window. The session exists before the tab appears, so the
    /// attach can't race it.
    private func openNewTab(launching agent: AgentKind?) {
        guard !creatingTab,
              let activeTab,
              let host = store.host(id: activeTab.hostID)
        else { return }
        creatingTab = true
        // A plain shell tab has no pane to inherit a directory from —
        // the new session starts in $HOME, named after the host's habit.
        let source = activeTab.sessionName
        Task {
            defer { creatingTab = false }
            guard let name = await hub.model(for: host).createSession(
                base: agent?.launchCommand ?? source ?? "main",
                inDirectoryOf: source,
                typing: agent?.launchCommand
            ) else {
                newTabFailedHost = host.name
                return
            }
            let tab = TerminalRoute(hostID: host.id, mode: .attach(sessionName: name))
            route.tabs.append(tab)
            route.activate(tab.id)
        }
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
                .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .center) {
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
                        HStack(spacing: 10) {
                            // The floating visionOS keyboard has no ESC/CTRL/TAB;
                            // the chrome carries them (same send path as typing).
                            TerminalKeyCluster(controller: activeController)
                            UMDBar(
                                controller: activeController,
                                title: umdTitle,
                                mergeSources: mergeSources,
                                showDeck: showDeck,
                                summonKeyboard: { activeController?.summonKeyboard() },
                                fontDown: { fontSize = max(9, fontSize - 1) },
                                fontUp: { fontSize = min(32, fontSize + 1) },
                                newSession: { openNewTab(launching: $0) },
                                merge: { merge($0) },
                                detach: { detachActiveTab() },
                                closeSession: activeTabHasSession
                                    ? { confirmingCloseActiveSession = true } : nil
                            )
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
            UMDBar(
                controller: activeController,
                title: umdTitle,
                mergeSources: [],
                showDeck: configuration.showDeck,
                summonKeyboard: { activeController?.summonKeyboard() },
                fontDown: { fontSize = max(9, fontSize - 1) },
                fontUp: { fontSize = min(32, fontSize + 1) },
                newSession: { openNewTab(launching: $0) },
                merge: { _ in },
                detach: { detachActiveTab() },
                closeSession: activeTabHasSession
                    ? { confirmingCloseActiveSession = true } : nil,
                style: .shell,
                deckControlLabel: configuration.deckControlLabel,
                availableWidth: configuration.availableWidth,
                contentSafeArea: configuration.contentSafeArea
            )
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
                    VStack(spacing: 8) {
                        helperStrip(
                            floating: true,
                            floatingMaximumWidth: max(
                                1,
                                configuration.availableWidth - 24
                            )
                        )
                        TerminalKeyCluster(controller: activeController)
                    }
                    .padding(.bottom, 10)
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
        if let agent = shownAgent,
           let controller = activeController,
           controller.status == .live {
            AgentHelperStrip(
                agent: agent,
                canShowCommands: entitlements.isPro || entitlements.canUseSlashChip,
                builtInPlacements: customAgentCommands.builtInPlacements(for: agent),
                customCommands: customAgentCommands.commands(for: agent),
                floating: floating,
                floatingMaximumWidth: floatingMaximumWidth,
                contentSafeArea: floating ? EdgeInsets() : contentSafeArea,
                send: { send($0, via: controller) },
                saveCommandConfiguration: { commands, placements in
                    customAgentCommands.replace(
                        commands,
                        builtInPlacements: placements,
                        for: agent
                    )
                },
                openPaywall: { showingPaywall = true },
                isFocusOwner: {
                    guard let terminalView = controller.terminalView else { return false }
                    return TerminalFocusArbiter.current === terminalView
                }
            )
        }
    }

    private var tabItems: [TerminalTabStrip.Item] {
        let multiHost = Set(route.tabs.map(\.hostID)).count > 1
        return route.tabs.map { tab in
            .init(
                id: tab.id,
                title: tab.displayName,
                hostName: multiHost ? store.host(id: tab.hostID)?.name : nil,
                controller: workspace.controller(for: tab.id),
                isActive: tab.id == activeTab?.id
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
        if let activeTab { return activeTab.displayName }
        return "terminal"
    }

    /// "MAIN · DEVBOX" — the UMD source label.
    private var umdTitle: String {
        guard let activeTab else { return windowTitle }
        let host = store.host(id: activeTab.hostID)?.name
        return host.map { "\(activeTab.displayName) · \($0)" } ?? activeTab.displayName
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
        newTabMenu
        keyboardButton
        fontButtons
        if !mergeSources.isEmpty {
            mergeMenu
        }
        detachMenu
            .padding(.trailing, trailingPadding)
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
    /// launching an agent — mirrors the deck's New Session options.
    private var newTabMenu: some View {
        Menu {
            Button("New Session") { openNewTab(launching: nil) }
            Button(AgentKind.claudeCode.displayName) { openNewTab(launching: .claudeCode) }
            Button(AgentKind.codex.displayName) { openNewTab(launching: .codex) }
        } label: {
            ChassisBadge("TAB", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chassisHover(2)
        .fixedSize()
        .accessibilityLabel("New tab: another session in this window")
    }

    private var deckButton: some View {
        ChassisChip("DECK", systemImage: "square.grid.2x2", action: showDeck)
            .fixedSize()
            .accessibilityLabel("Show Deck")
    }

    private var keyboardButton: some View {
        ChassisChip("KBD", systemImage: "keyboard") {
            activeController?.summonKeyboard()
        }
        .fixedSize()
        .accessibilityLabel("Show keyboard")
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

    /// Back to the main screen. visionOS activates the registered scene;
    /// iPad uses the deck's stable data value, which raises the matching
    /// window and creates it only when none exists.
    private func showDeck() {
        if let shell {
            shell.showDeck()
            return
        }
        #if os(visionOS)
        if let session = DeckScene.session {
            UIApplication.shared.activateSceneSession(
                for: UISceneSessionActivationRequest(session: session)
            )
        } else {
            openWindow(id: "deck")
        }
        #else
        openWindow(id: "deck", value: DeckWindowRoute.main)
        #endif
    }

    // MARK: Tab machinery

    /// Idempotent reconciliation, run on appearance and every tabs change:
    /// an emptied window dismisses itself (that's how a merged-away source
    /// closes), otherwise controllers exist for every tab and the window's
    /// directory entry is fresh.
    private func syncTabs() {
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
        for tab in route.tabs {
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

    var body: some View {
        ZStack {
            // The gutter around the terminal matches its background, so the
            // window reads as one surface in whatever theme is active.
            #if os(visionOS)
            Color(themes.selected.background).ignoresSafeArea()
            #else
            // UIKit keeps rail controls inside the rounded-corner safe
            // boundary. Paint that protected tail as part of the rail, then
            // cover the terminal's ordinary bounds with its selected theme.
            // The stale strip may still be classified as keyboard safe area
            // after a float/window move, so this paint layer ignores both
            // container and keyboard regions. It has no controls or layout.
            Theme.bezel.ignoresSafeArea()
            Color(themes.selected.background)
            #endif
            if let controller {
                SwiftTermView(
                    controller: controller,
                    fontSize: fontSize,
                    theme: themes.selected,
                    bottomChromeHeight: bottomChromeHeight,
                    contentSafeArea: contentSafeArea,
                    railOwnsBottomSafeArea: railOwnsBottomSafeArea,
                    isActive: isActive && focusAllowed
                )
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
        // typed into the session (never submitted). tmux tabs only — a
        // plain shell has no pane to ask for a cwd.
        .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in
            guard let controller,
                  controller.status == .live,
                  controller.route.sessionName != nil
            else { return false }
            Task { @MainActor in
                controller.deliverDrop(await TerminalDropCatcher.load(providers))
            }
            return true
        }
        .overlay {
            if dropTargeted, controller?.status == .live,
               controller?.route.sessionName != nil {
                DropTargetVeil()
            }
        }
        .overlay(alignment: .top) {
            if isActive, let controller, controller.tmuxCopyModeUIActive {
                TmuxCopyModeBar(done: controller.finishTmuxCopyMode)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }
        }
        .overlay(alignment: .bottom) {
            if let dropState = controller?.dropState {
                DropStatusPill(state: dropState)
                    .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func statusOverlay(for controller: TerminalSessionController) -> some View {
        switch controller.status {
        case .connecting:
            chassisPanel {
                ProgressView()
                Text("Connecting to \(controller.host.name)…")
                    .font(.mono(14))
                    .foregroundStyle(Theme.signal2)
            }
        case .live:
            EmptyView()
        case .ended(let reason):
            chassisPanel {
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

    /// A restored tab whose host was removed — say so, never a blank pane.
    private var missingHost: some View {
        chassisPanel {
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

    private func chassisPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) {
            content()
        }
        .padding(30)
        .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1))
    }
}

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

#if DEBUG
#Preview("Copy mode bar") {
    TmuxCopyModeBar(done: {})
        .padding()
        .background(Theme.screen)
}
#endif

#if DEBUG
extension Notification.Name {
    static let multiplexDebugNewTab = Notification.Name("MultiplexDebugNewTab")
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
#endif
