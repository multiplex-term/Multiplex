import SwiftUI

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
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    @Binding var route: TerminalWindowRoute

    @State private var fontSize: CGFloat = 14

    private var activeTab: TerminalRoute? { route.activeTab }
    private var activeController: TerminalSessionController? {
        activeTab.flatMap { workspace.controller(for: $0.id) }
    }
    private var mergeSources: [TerminalWorkspace.WindowEntry] {
        workspace.mergeSources(for: route.id)
    }

    var body: some View {
        platformBody
            .task { syncTabs() }
            .onChange(of: route.tabs) { syncTabs() }
            // Keyboard focus follows the visible tab…
            .onChange(of: route.activeTabID) {
                activeController?.focusTerminal()
            }
            // …and the window: restore the owner when the scene reactivates.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { activeController?.restoreFocusIfOwner() }
            }
            .onDisappear {
                // Scene is gone (close button / dismiss): tabs still here are
                // really closing. A merged-away window is already empty, so
                // its moved tabs never detach.
                workspace.unregisterWindow(id: route.id)
                for tab in route.tabs { workspace.closeTab(tab.id) }
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
                UMDBar(
                    controller: activeController,
                    title: umdTitle,
                    mergeSources: mergeSources,
                    showDeck: showDeck,
                    summonKeyboard: { activeController?.summonKeyboard() },
                    fontDown: { fontSize = max(9, fontSize - 1) },
                    fontUp: { fontSize = min(24, fontSize + 1) },
                    merge: { merge($0) },
                    detach: { detachActiveTab() }
                )
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
                    close: { close(tab.id) }
                )
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
            }
        }
        .background(Theme.screen.ignoresSafeArea())
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
            keyboardButton
            fontButtons
            if !mergeSources.isEmpty {
                mergeMenu
            }
            Button("Detach") { detachActiveTab() }
                .buttonStyle(.bordered)
        }
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
                fontSize = min(24, fontSize + 1)
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
