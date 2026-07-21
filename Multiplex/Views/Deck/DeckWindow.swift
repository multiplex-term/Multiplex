import SwiftUI

/// Tracks the live deck window's scene plus one-shot state that must not
/// repeat per window. The data-driven scene identity prevents new duplicates;
/// this registry removes any second deck restored from legacy or raced
/// relaunch state.
@MainActor
enum DeckScene {
    private static var sessions = SingletonSceneRegistry<UISceneSession, String>()
    static var autoAttachFired = false

    static func register(_ newSession: UISceneSession) {
        guard sessions.register(
            newSession,
            id: newSession.persistentIdentifier
        ) == .duplicate else { return }

        // WindowGroup restoration can reconnect more than one old deck
        // session before SwiftUI has enough value state to coalesce them.
        // Permanently discard the later session so it cannot return on the
        // next launch or remain in the system's window history.
        UIApplication.shared.requestSceneSessionDestruction(
            newSession,
            options: nil
        )
    }

    #if DEBUG
    /// Launch automation is shared by deck and terminal roots. iPadOS may
    /// restore a terminal scene without constructing the deck, so keeping
    /// this only on `DeckWindow` makes real-device verification silently
    /// skip its requested attach.
    static func autoAttachIfRequested(
        store: HostStore,
        workspace: TerminalWorkspace,
        openTerminalWindow: (TerminalWindowRoute) -> Void
    ) async {
        guard !autoAttachFired,
              let list = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_ATTACH"],
              !list.isEmpty else { return }
        autoAttachFired = true
        try? await Task.sleep(for: .seconds(5))
        // MULTIPLEX_AUTO_ATTACH_HOST names the target host — on devices with
        // iCloud-synced real hosts, `hosts.first` is not the seeded devbox.
        let host: Host?
        if let name = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_ATTACH_HOST"] {
            host = store.hosts.first(where: { $0.name == name })
        } else {
            host = store.hosts.first
        }
        guard let host else { return }
        var firstTabID: UUID?
        for entry in list.split(separator: ",") {
            let tabs = entry.split(separator: "+").map {
                TerminalRoute(hostID: host.id, mode: .attach(sessionName: String($0)))
            }
            guard !tabs.isEmpty else { continue }
            if firstTabID == nil { firstTabID = tabs.first?.id }
            openTerminalWindow(TerminalWindowRoute(tabs: tabs))
            try? await Task.sleep(for: .seconds(1))
        }
        // MULTIPLEX_AUTO_TMUX_COPY=1 enters through SwiftTerm's real
        // send/delegate path; the harness observes `#{pane_in_mode}` = 1.
        if ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_TMUX_COPY"] == "1",
           let tabID = firstTabID {
            for _ in 0..<100 {
                if workspace.controller(for: tabID)?
                    .debugSendTmuxShortcutThroughTerminal(.copyMode) == true {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        // MULTIPLEX_AUTO_TMUX_CLOSE=pane|window runs the confirmed close
        // action through the same controller entry point as the dropdown's
        // second press. A physical-device proof can therefore attach only to
        // a disposable session and observe its pane/window count from the
        // host, without synthesizing a screen tap or entering tmux's prompt.
        if let closeTarget = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_TMUX_CLOSE"],
           let shortcut: TmuxShortcut = switch closeTarget {
               case "pane": .closePane
               case "window": .closeWindow
               default: nil
           },
           let tabID = firstTabID {
            for _ in 0..<100 {
                if let controller = workspace.controller(for: tabID),
                   controller.status == .live {
                    controller.performTmuxShortcut(shortcut)
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_MERGE"] == "1" {
            try? await Task.sleep(for: .seconds(8))
            workspace.mergeAllWindows()
        }
        if let dropPath = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_DROP"],
           let tabID = firstTabID {
            try? await Task.sleep(for: .seconds(8))
            if let controller = workspace.controller(for: tabID),
               let data = FileManager.default.contents(atPath: dropPath) {
                controller.deliverDrop([DroppedFile(
                    name: (dropPath as NSString).lastPathComponent,
                    data: data
                )])
            }
        }
    }
    #endif
}

/// Reports the hosting window's scene session to `DeckScene`.
private struct DeckSceneReporter: UIViewRepresentable {
    final class ReporterView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let session = window?.windowScene?.session {
                DeckScene.register(session)
            }
        }
    }

    func makeUIView(context: Context) -> ReporterView { ReporterView() }
    func updateUIView(_ view: ReporterView, context: Context) {}
}

/// The deck window: the fleet wall plus the sheets it opens (add/edit host,
/// settings). Scene bookkeeping and the DEBUG auto-attach hook live here.
struct DeckWindow: View {
    @Environment(HostStore.self) private var store
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(ConnectionHub.self) private var hub
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(LocalNetworkAccessMonitor.self) private var localNetworkAccess
    @Environment(NetworkChangeMonitor.self) private var networkChanges
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    let terminalOpener: TerminalRouteOpener
    var wallPresentation: FleetWall.Presentation = .standard
    var selectedTerminal: TerminalRoute? = nil
    var shellSafeArea = EdgeInsets()

    @State private var addingHost = false
    @State private var editingHost: Host?
    @State private var showingSettings = false
    @State private var showingFAQ = false
    @State private var showingPaywall = false
    @State private var showingLocalNetworkAlert = false

    private struct LocalNetworkCheckID: Hashable {
        let hosts: [Host]
        let active: Bool
    }

    var body: some View {
        FleetWall(
            terminalOpener: terminalOpener,
            presentation: wallPresentation,
            selectedTerminal: selectedTerminal,
            shellSafeArea: shellSafeArea,
            addHost: requestAddHost,
            editHost: { editingHost = $0 },
            openSettings: { showingSettings = true },
            openFAQ: { showingFAQ = true }
        )
        // Explicitly bridge Observation environments across the scene sheet
        // boundary. iOS 27 can otherwise present this sheet from the shell's
        // nested deck host without carrying HostStore, causing a fatal lookup.
        .sheet(isPresented: $addingHost) {
            AddHostSheet()
                .environment(store)
                .environment(entitlements)
        }
        .sheet(item: $editingHost) { host in
            AddHostSheet(editing: host)
                .environment(store)
                .environment(entitlements)
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingFAQ) { FAQView() }
        .sheet(isPresented: $showingPaywall) { ProPaywallView() }
        .alert("Local Network Access Is Off", isPresented: $showingLocalNetworkAlert) {
            Button("Open Settings") { openAppSettings() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Multiplex can’t reach SSH hosts on your local network. Turn on Local Network access in Settings.")
        }
        .background(DeckSceneReporter())
        // Render the local cache first. Synchronizable Keychain reads may
        // involve securityd/iCloud, so cloud reconciliation begins only once
        // the deck exists instead of blocking App initialization.
        .task { await store.refreshFromCloud() }
        // Keep the widget process's App Group snapshot in step with the host
        // list (adds, removes, renames — and the first appearance); settled
        // probes republish it through the hub's snapshot hook.
        .task(id: store.hosts) { hub.publishWidgetState(hosts: store.hosts) }
        .task(
            id: LocalNetworkCheckID(
                hosts: store.hosts,
                active: scenePhase == .active
            )
        ) {
            if scenePhase == .active {
                localNetworkAccess.check(hosts: store.hosts)
            } else {
                localNetworkAccess.suspend()
            }
        }
        // Watch the network path while the deck is active. A settled change
        // (Wi-Fi ↔ cellular, VPN toggle, connectivity returning — including
        // one that happened while backgrounded) rebuilds every host's
        // control link at once instead of letting each probe burn its exec
        // deadline on a socket bound to the old path.
        .task(id: scenePhase == .active) {
            if scenePhase == .active {
                networkChanges.begin()
            } else {
                networkChanges.suspend()
            }
        }
        .onChange(of: networkChanges.reconnectRevision) { _, _ in
            guard scenePhase == .active else { return }
            hub.reconnectAfterNetworkChange()
        }
        .onChange(of: localNetworkAccess.denialRevision) { _, revision in
            guard revision > 0, scenePhase == .active else { return }
            showingLocalNetworkAlert = true
        }
        .onChange(of: localNetworkAccess.isDenied) { _, denied in
            if !denied { showingLocalNetworkAlert = false }
        }
        // iCloud Keychain sync has no change notification; re-merge the host
        // mirror whenever the deck comes back to the foreground. Leaving it,
        // flush the wall snapshots — suspension freezes their debounce timer.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshFromCloud() }
            } else {
                hub.flushSnapshots()
            }
        }
        #if DEBUG
        .task { presentPaywallForReviewCaptureIfRequested() }
        .task { presentSettingsForVerificationIfRequested() }
        .task { presentFAQForVerificationIfRequested() }
        .task { await presentHostSettingsForVerificationIfRequested() }
        .task {
            await DeckScene.autoAttachIfRequested(
                store: store,
                workspace: workspace,
                openTerminalWindow: { terminalOpener($0) }
            )
        }
        #endif
    }

    /// The free tier may create up to two hosts; Pro may create any number.
    /// This is intentionally only an add-flow intent check. HostStore stays
    /// ungated so existing records and hosts arriving through Keychain sync
    /// are never hidden, deleted, or prevented from connecting.
    private var canAddHost: Bool {
        entitlements.canAddHost(existingHostCount: store.hosts.count)
    }

    private func requestAddHost() {
        if canAddHost {
            addingHost = true
        } else {
            showingPaywall = true
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    #if DEBUG
    /// Launch with `MULTIPLEX_AUTO_SETTINGS=1|theme` to open the global
    /// Settings sheet for deterministic layout and entitlement-gate screenshots.
    private func presentSettingsForVerificationIfRequested() {
        guard let request = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_SETTINGS"],
              ["1", "theme"].contains(request) else { return }
        showingSettings = true
    }

    /// Launch with `MULTIPLEX_AUTO_FAQ=1` to open the deck's FAQ sheet for
    /// deterministic layout capture.
    private func presentFAQForVerificationIfRequested() {
        guard ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_FAQ"] == "1"
        else { return }
        showingFAQ = true
    }

    /// Headless regression hook for the Observation environment crossing the
    /// deck's sheet boundary. A missing HostStore used to fatal as Host
    /// Settings opened from the compact shell.
    private func presentHostSettingsForVerificationIfRequested() async {
        guard ProcessInfo.processInfo.environment[
            "MULTIPLEX_AUTO_HOST_SETTINGS"
        ] == "1" else { return }
        for _ in 0..<50 {
            if let host = store.hosts.first {
                editingHost = host
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Launch with `MULTIPLEX_AUTO_PAYWALL=1` to render the real locked
    /// paywall immediately for its App Review screenshot. simctl launches do
    /// not inherit Xcode's StoreKit test session, so EntitlementStore supplies
    /// the deterministic review price in this DEBUG-only path.
    private func presentPaywallForReviewCaptureIfRequested() {
        guard ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_PAYWALL"] == "1"
        else { return }
        entitlements.prepareDebugPaywallPreview()
        showingPaywall = true
    }

    #endif
}
