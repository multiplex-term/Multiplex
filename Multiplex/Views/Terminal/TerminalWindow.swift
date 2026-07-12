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
    @Environment(HostStore.self) private var store
    @Environment(ConnectionHub.self) private var hub
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    @Binding var route: TerminalWindowRoute

    @State private var fontSize: CGFloat = 17
    /// Agent shown by the helper strip. Trails `detectedAgent` with a short
    /// grace on loss (two probe ticks) so a transient probe miss doesn't
    /// flap the strip — but never across a tab switch.
    @State private var shownAgent: AgentKind?
    @State private var hideAgentTask: Task<Void, Never>?
    @State private var showingPaywall = false
    /// One new-tab exec in flight at a time — a double tap must not mint
    /// two sessions.
    @State private var creatingTab = false
    @State private var newTabFailedHost: String?
    /// Detach long-press picked CLOSE SESSION — destructive, so it confirms
    /// (same policy as the deck's delete and the ended overlay's chip).
    @State private var confirmingCloseActiveSession = false

    /// The wall re-probes only while the deck is open; a terminal window
    /// keeps its own host's probe warm so detection tracks the pane.
    private static let agentPollInterval: Duration = .seconds(5)

    private var activeTab: TerminalRoute? { route.activeTab }
    private var activeController: TerminalSessionController? {
        activeTab.flatMap { workspace.controller(for: $0.id) }
    }
    private var mergeSources: [TerminalWorkspace.WindowEntry] {
        workspace.mergeSources(for: route.id)
    }
    /// Whether the detach control can offer CLOSE SESSION for the active
    /// tab — same rule as the ended overlay: there must be a tmux session
    /// to kill and a host record to kill it on.
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
            .task(id: activeTab?.hostID) { await watchAgentPresence() }
            .onChange(of: route.tabs) { syncTabs() }
            // Keyboard focus follows the visible tab…
            .onChange(of: route.activeTabID) {
                activeController?.focusTerminal()
                // No detection grace across tabs — chips must describe the
                // pane on screen, immediately.
                hideAgentTask?.cancel()
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
                    activeController?.restoreFocusIfOwner()
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

    /// Keep this host's probe fresh while the window is open (the deck only
    /// polls while it's on screen). `refresh()` is single-flight, so several
    /// windows on one host still cost one probe per tick.
    private func watchAgentPresence() async {
        #if DEBUG
        AgentChipDebugHook.install()
        NewTabDebugHook.install()
        #endif
        guard let hostID = activeTab?.hostID, let host = store.host(id: hostID) else { return }
        let model = hub.model(for: host)
        shownAgent = detectedAgent
        while !Task.isCancelled {
            if UIApplication.shared.applicationState == .active {
                model.refresh()
            }
            try? await Task.sleep(for: Self.agentPollInterval)
        }
    }

    /// Type a helper command into the shell. Slash commands submit with a
    /// CR sent as a separate, delayed write: Codex's composer treats Enter
    /// inside one rapid burst as a pasted newline (see
    /// `AgentCommand.submitsAfterPause`); 160 ms clears its burst window
    /// with margin, and Claude Code is indifferent.
    private func send(_ command: AgentCommand, via controller: TerminalSessionController) {
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
              entitlements.isPro,
              controller.status == .live,
              let command = AgentCommandSet.primary(for: agent)
                  .first(where: { $0.label.hasPrefix("/") })
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

    #if os(visionOS)
    private var platformBody: some View {
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
                    helperStrip(floating: true)
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
    #else
    private var platformBody: some View {
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
                paneStack
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        helperStrip(floating: false)
                    }
                    // SwiftUI's automatic keyboard avoidance must not touch
                    // the terminal: its tracker also reserves space for
                    // *floating* keyboards (and goes stale across
                    // dock/float transitions), eating the viewport. The
                    // terminal container's own keyboard-frame handler is the
                    // single owner of keyboard clearance — docked keyboards
                    // and the accessory bar inset, floating pills don't
                    // (`KeyboardAvoidance`). The helper strip rides inside
                    // the opt-out, so a docked keyboard covers it while
                    // typing — the key rail is the input surface then.
                    .ignoresSafeArea(.keyboard)
            }
            .navigationTitle(windowTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.chassis, for: .navigationBar)
            .toolbar { toolbarContent }
        }
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
                    isActive: isActive,
                    close: { close(tab.id) },
                    closeSession: tab.sessionName != nil && store.host(id: tab.hostID) != nil
                        ? { closeSession(tab) } : nil
                )
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
            }
        }
        .background(Theme.screen.ignoresSafeArea())
    }

    /// The agent helper strip, when the active tab's session runs one.
    /// visionOS floats it in the bottom ornament above the UMD (the window's
    /// bottom edge belongs to the ornament, which would overlap an inset);
    /// iPad docks it as a bottom inset under the screen, where appearing
    /// resizes the PTY like a keyboard would.
    @ViewBuilder
    private func helperStrip(floating: Bool) -> some View {
        if let agent = shownAgent,
           let controller = activeController,
           controller.status == .live {
            AgentHelperStrip(
                agent: agent,
                isPro: entitlements.isPro,
                floating: floating,
                send: { send($0, via: controller) },
                openPaywall: { showingPaywall = true }
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
            close: { close($0) }
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
        ToolbarItemGroup(placement: .topBarLeading) {
            deckButton
        }
        ToolbarItemGroup(placement: .primaryAction) {
            newTabMenu
            keyboardButton
            fontButtons
            if !mergeSources.isEmpty {
                mergeMenu
            }
            detachMenu
        }
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
                Text("Detach")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .accessibilityLabel("Detach or close the session")
        } else {
            Button("Detach") { detachActiveTab() }
                .buttonStyle(.bordered)
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
            Image(systemName: "plus")
        }
        .accessibilityLabel("New tab: another session in this window")
    }

    private var deckButton: some View {
        Button(action: showDeck) {
            Image(systemName: "square.grid.2x2")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Show Deck")
    }

    private var keyboardButton: some View {
        Button {
            activeController?.summonKeyboard()
        } label: {
            Image(systemName: "keyboard")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Show keyboard")
    }

    private var fontButtons: some View {
        HStack(spacing: 4) {
            Button {
                fontSize = max(9, fontSize - 1)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .accessibilityLabel("Smaller text")
            Button {
                fontSize = min(32, fontSize + 1)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .accessibilityLabel("Larger text")
        }
        .buttonStyle(.borderless)
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
            Label("Merge", systemImage: "rectangle.stack.badge.plus")
        }
        .accessibilityLabel("Merge another window into this one")
    }
    #endif

    /// Back to the main screen: brings the EXISTING deck window forward —
    /// openWindow on a WindowGroup would mint another deck — and only
    /// creates one when none is alive.
    private func showDeck() {
        if let session = DeckScene.session {
            UIApplication.shared.activateSceneSession(
                for: UISceneSessionActivationRequest(session: session)
            )
        } else {
            openWindow(id: "deck")
        }
    }

    // MARK: Tab machinery

    /// Idempotent reconciliation, run on appearance and every tabs change:
    /// an emptied window dismisses itself (that's how a merged-away source
    /// closes), otherwise controllers exist for every tab and the window's
    /// directory entry is fresh.
    private func syncTabs() {
        if route.tabs.isEmpty {
            workspace.unregisterWindow(id: route.id)
            // Plain DismissAction, not dismissWindow(id:value:) — the scene's
            // committed value can lag the just-emptied binding, and a value
            // mismatch would silently leave a ghost window behind.
            dismiss()
            return
        }
        for tab in route.tabs {
            _ = workspace.controller(for: tab, store: store)
        }
        workspace.registerWindow(.init(
            id: route.id,
            tabs: route.tabs,
            label: windowLabel,
            reveal: { [route = $route, workspace] tabID in
                route.wrappedValue.activate(tabID)
                workspace.controller(for: tabID)?.revealWindow()
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
        workspace.closeTab(tabID)
        route.removeTab(id: tabID)
    }

    /// The ended overlay's CLOSE SESSION: kill the tmux session on the host
    /// over its control connection (fire-and-forget, like the wall's delete),
    /// then close the tab. The tab's own connection is already gone here.
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
    let isActive: Bool
    let close: () -> Void
    /// Kill the remote tmux session, then close the tab. nil when there's
    /// no session to kill (plain shell tab, or the host record is gone).
    let closeSession: (() -> Void)?

    @State private var dropTargeted = false
    @State private var confirmingCloseSession = false

    var body: some View {
        ZStack {
            // The gutter around the terminal matches its background, so the
            // window reads as one surface in whatever theme is active.
            Color(themes.selected.background).ignoresSafeArea()
            if let controller {
                SwiftTermView(
                    controller: controller,
                    fontSize: fontSize,
                    theme: themes.selected,
                    isActive: isActive
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                statusOverlay(for: controller)
            } else if !hostExists {
                missingHost
            }
        }
        // A shell that (re)connects claims focus outright — if its tab is
        // the one on screen.
        .onChange(of: controller?.status) { _, status in
            if status == .live, isActive { controller?.focusTerminal() }
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
                    if closeSession != nil {
                        ChassisChip("CLOSE SESSION") { confirmingCloseSession = true }
                    }
                    ChassisChip("CLOSE TAB") { close() }
                }
                .padding(.top, 4)
                .alert(
                    "Close Session",
                    isPresented: $confirmingCloseSession
                ) {
                    Button("Close Session", role: .destructive) { closeSession?() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Kills “\(controller.route.sessionName ?? "")” on \(controller.host.name) and everything running in it, then closes the tab.")
                }
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

#if DEBUG
extension Notification.Name {
    static let multiplexDebugNewTab = Notification.Name("MultiplexDebugNewTab")
}

/// Headless-verification hook, same shape as `AgentChipDebugHook`:
/// `xcrun simctl spawn <udid> notifyutil -p tools.bricks.multiplex.debug.newtab`
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
            "tools.bricks.multiplex.debug.newtab", &token, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugNewTab, object: nil)
        }
    }
}
#endif
