import SwiftUI

/// Tracks the live deck window's scene so other windows can bring the
/// EXISTING deck forward instead of spawning another one, plus one-shot
/// state that must not repeat per deck window.
@MainActor
enum DeckScene {
    private(set) static weak var session: UISceneSession?
    static var autoAttachFired = false

    static func register(_ newSession: UISceneSession) {
        session = newSession
    }
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
    @Environment(ConnectionHub.self) private var hub
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var addingHost = false
    @State private var editingHost: Host?
    @State private var showingSettings = false

    var body: some View {
        FleetWall(
            addHost: { addingHost = true },
            editHost: { editingHost = $0 },
            openSettings: { showingSettings = true }
        )
        .sheet(isPresented: $addingHost) { AddHostSheet() }
        .sheet(item: $editingHost) { host in AddHostSheet(editing: host) }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .background(DeckSceneReporter())
        // Render the local cache first. Synchronizable Keychain reads may
        // involve securityd/iCloud, so cloud reconciliation begins only once
        // the deck exists instead of blocking App initialization.
        .task { await store.refreshFromCloud() }
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
        .task { await autoAttachIfRequested() }
        #endif
    }

    #if DEBUG
    /// Headless-verification hook: `MULTIPLEX_AUTO_ATTACH=<a,b,…>` opens one
    /// terminal window per comma entry through the same route the Attach
    /// button uses; `+` inside an entry groups sessions as tabs of one window
    /// (`a+b,c` → window[a,b] + window[c]). Once per process — additional
    /// deck windows must not re-fire it.
    private func autoAttachIfRequested() async {
        guard !DeckScene.autoAttachFired,
              let list = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_ATTACH"],
              !list.isEmpty else { return }
        DeckScene.autoAttachFired = true
        try? await Task.sleep(for: .seconds(5))
        // MULTIPLEX_AUTO_ATTACH_HOST names the target host — on devices with
        // iCloud-synced real hosts, `hosts.first` is not the seeded devbox.
        // A named host that's absent bails outright: silently attaching to
        // whatever synced host happens to be first is the failure this
        // variable exists to prevent.
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
            openWindow(id: "terminal", value: TerminalWindowRoute(tabs: tabs))
            try? await Task.sleep(for: .seconds(1))
        }
        // MULTIPLEX_AUTO_MERGE=1: once the windows are up, merge them all
        // into the first — headless exercise of the surrender/adopt path
        // the in-window Merge menu uses.
        if ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_MERGE"] == "1" {
            try? await Task.sleep(for: .seconds(8))
            workspace.mergeAllWindows()
        }
        // MULTIPLEX_AUTO_DROP=<local path>: drop that file into the first
        // auto-attached tab — the simulator shares the Mac's filesystem, so
        // the whole SFTP-upload + typed-path loop runs headlessly.
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
