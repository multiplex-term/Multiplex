import Foundation
import Observation
import UIKit

/// What every auxiliary (non-terminal) pane controller owes the window
/// system: a live tab label and a teardown. Construction stays per-type —
/// a viewport takes an admitted offer, a file viewer a start directory —
/// but lookup, label, and close dispatch through this one seam, so
/// `syncTabs`' restored-corpse strip, the tab strip's titles, and
/// `closeTab` don't grow per-type branches when the next auxiliary pane
/// type arrives (missing the strip branch would leave an invisible zombie
/// tab; missing close would leak the pane's resources).
@MainActor
protocol AuxiliaryPaneController: AnyObject {
    /// The live tab-cell/UMD label (mark + subject) — follows what the pane
    /// is showing NOW, where the route only knows the summons.
    var tabLabel: String { get }
    func shutdown()
}

/// App-wide terminal state that outlives any single window scene:
///
/// - **Controllers** are keyed by tab id and owned here, not by window views,
///   so a tab moving between windows (merge / split) keeps its live SSH
///   connection and terminal buffer. `closeTab` is the only path that
///   detaches — a moved tab is never closed.
/// - **The window directory** lets a terminal window list its siblings for
///   the Merge menu and take over their tabs: each window registers a
///   `surrender` closure that empties the source window (which then
///   dismisses itself) and hands back its tabs.
@MainActor
@Observable
final class TerminalWorkspace {
    // MARK: Controllers (one per tab)

    private var controllers: [UUID: TerminalSessionController] = [:]
    /// Handed to each controller so attached tabs can surface in-band
    /// bells. Weak both ways — the center holds this workspace weakly too.
    private weak var attention: AttentionCenter?

    /// Suspension repair (`SessionResumePolicy`) is observed once, app-wide,
    /// and fanned out to every tab: the app is suspended as a whole, and a
    /// tab whose window is not currently mounted must be repaired too.
    /// Rides UIApplication rather than a scene phase for the same reason.
    private nonisolated(unsafe) var backgroundObserver: NSObjectProtocol?
    private nonisolated(unsafe) var foregroundObserver: NSObjectProtocol?

    init(attention: AttentionCenter? = nil) {
        self.attention = attention
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forEachController { $0.applicationDidEnterBackground() }
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forEachController { $0.applicationWillEnterForeground() }
            }
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    private func forEachController(_ body: (TerminalSessionController) -> Void) {
        for controller in controllers.values { body(controller) }
    }

    /// Get-or-create the controller for a tab, starting its connection on
    /// first sight. Returns nil when the tab's host no longer exists.
    func controller(for tab: TerminalRoute, store: HostStore) -> TerminalSessionController? {
        if let existing = controllers[tab.id] { return existing }
        guard let host = store.host(id: tab.hostID) else { return nil }
        let controller = TerminalSessionController(route: tab, host: host, attention: attention)
        controllers[tab.id] = controller
        controller.start()
        return controller
    }

    func controller(for tabID: UUID) -> TerminalSessionController? {
        controllers[tabID]
    }

    // MARK: Auxiliary controllers (one per ⌗ / ▤ tab)

    /// Transport-less controllers for auxiliary tabs, keyed like terminal
    /// controllers so merge/split re-parent the live pane the same way.
    /// Deliberately in-memory only — this dictionary *is* the auxiliary
    /// no-persistence rule: `TerminalWindowRoot.syncTabs` strips any
    /// auxiliary tab it cannot find here, which is exactly a tab restored
    /// from a dead process. Summoned, not restored.
    private var auxiliaryControllers: [UUID: any AuxiliaryPaneController] = [:]

    /// Register the controller BEFORE the tab enters any route — the strip
    /// above runs on every tabs change, and an auxiliary tab that arrives
    /// without its controller is indistinguishable from a restored corpse.
    func openViewport(tab: TerminalRoute, offer: ViewportOffer, host: Host) {
        guard tab.isViewport, auxiliaryControllers[tab.id] == nil else { return }
        auxiliaryControllers[tab.id] = ViewportController(
            tabID: tab.id,
            offer: offer,
            host: host
        )
    }

    func openFileViewer(
        tab: TerminalRoute,
        host: Host,
        startDirectory: String?,
        anchorSessionName: String?,
        target: TerminalPathTarget?
    ) {
        guard tab.isFileViewer, auxiliaryControllers[tab.id] == nil else { return }
        auxiliaryControllers[tab.id] = FileViewerController(
            tabID: tab.id,
            host: host,
            startDirectory: startDirectory,
            anchorSessionName: anchorSessionName,
            target: target
        )
    }

    /// Register the Agent Gallery tab's controller BEFORE the tab enters
    /// any route — the same ordering rule as the viewport, which is what
    /// lets `syncTabs` strip restored corpses without ever touching a live
    /// summons.
    func openAgentGallery(tab: TerminalRoute, host: Host) {
        guard tab.isAgentGallery, auxiliaryControllers[tab.id] == nil else { return }
        auxiliaryControllers[tab.id] = AgentGalleryController(tabID: tab.id, host: host)
    }

    /// The general question — "does this auxiliary tab have a live pane,
    /// and what does it call itself" — for the strip and the tab titles.
    func auxiliaryController(for tabID: UUID) -> (any AuxiliaryPaneController)? {
        auxiliaryControllers[tabID]
    }

    func agentGalleryController(for tabID: UUID) -> AgentGalleryController? {
        auxiliaryControllers[tabID] as? AgentGalleryController
    }

    func viewportController(for tabID: UUID) -> ViewportController? {
        auxiliaryControllers[tabID] as? ViewportController
    }

    func fileViewerController(for tabID: UUID) -> FileViewerController? {
        auxiliaryControllers[tabID] as? FileViewerController
    }

    /// Close a tab for real: detach the SSH channel (or shut the auxiliary
    /// pane down) and drop the controller. Never called when a tab merely
    /// moves.
    func closeTab(_ tabID: UUID) {
        controllers.removeValue(forKey: tabID)?.detach()
        auxiliaryControllers.removeValue(forKey: tabID)?.shutdown()
    }

    func resumeConnectionsWaitingForKeyPassphrase(hostID: UUID) {
        for controller in controllers.values where controller.host.id == hostID {
            controller.resumeAfterKeyPassphraseUpdate()
        }
    }

    // MARK: Window directory (merge sources)

    struct WindowEntry: Identifiable {
        let id: UUID
        var tabs: [TerminalRoute]
        var label: String
        /// Brings the window's scene forward and makes this tab its active one.
        var reveal: @MainActor (UUID) -> Void
        /// Empties the source window (which auto-dismisses) and returns its tabs.
        var surrender: @MainActor () -> [TerminalRoute]
        /// Appends tabs to the window — the receiving half of a merge.
        var adopt: @MainActor ([TerminalRoute]) -> Void
    }

    private(set) var windows: [WindowEntry] = []

    func registerWindow(_ entry: WindowEntry) {
        if let index = windows.firstIndex(where: { $0.id == entry.id }) {
            windows[index] = entry
        } else {
            windows.append(entry)
        }
    }

    func unregisterWindow(id: UUID) {
        windows.removeAll { $0.id == id }
    }

    /// The windows `windowID` could merge into itself.
    func mergeSources(for windowID: UUID) -> [WindowEntry] {
        windows.filter { $0.id != windowID && !$0.tabs.isEmpty }
    }

    /// True when an open terminal window already has a tab bound to this
    /// tmux session — pressing that session's deck tile focuses it.
    func hasTab(hostID: UUID, sessionName: String) -> Bool {
        openTab(hostID: hostID, sessionName: sessionName) != nil
    }

    /// Bring the window already attached to (host, session) forward and make
    /// that tab active — the deck tile's press. False when no open window
    /// has such a tab (the deck then attaches in a new window).
    @discardableResult
    func focusTab(hostID: UUID, sessionName: String) -> Bool {
        guard let (entry, tabID) = openTab(hostID: hostID, sessionName: sessionName)
        else { return false }
        entry.reveal(tabID)
        return true
    }

    /// First-registered window holding a tab for this session — attach and
    /// create tabs alike; plain shells have no session name and never match.
    private func openTab(hostID: UUID, sessionName: String) -> (WindowEntry, UUID)? {
        for entry in windows {
            if let tab = entry.tabs.first(where: {
                $0.hostID == hostID && $0.sessionName == sessionName
            }) {
                return (entry, tab.id)
            }
        }
        return nil
    }

    /// Take every tab out of a sibling window; the source closes itself.
    func surrenderTabs(of sourceID: UUID) -> [TerminalRoute] {
        guard let entry = windows.first(where: { $0.id == sourceID }) else { return [] }
        unregisterWindow(id: sourceID)
        return entry.surrender()
    }

    /// Merge every terminal window into the earliest-registered one — the
    /// same surrender/adopt path the in-window Merge menu drives.
    func mergeAllWindows() {
        guard let target = windows.first else { return }
        let sourceIDs = windows.dropFirst().map(\.id)
        for id in sourceIDs {
            target.adopt(surrenderTabs(of: id))
        }
    }
}
