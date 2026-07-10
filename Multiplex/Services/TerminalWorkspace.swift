import Foundation
import Observation

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

    /// Get-or-create the controller for a tab, starting its connection on
    /// first sight. Returns nil when the tab's host no longer exists.
    func controller(for tab: TerminalRoute, store: HostStore) -> TerminalSessionController? {
        if let existing = controllers[tab.id] { return existing }
        guard let host = store.host(id: tab.hostID) else { return nil }
        let controller = TerminalSessionController(route: tab, host: host)
        controllers[tab.id] = controller
        controller.start()
        return controller
    }

    func controller(for tabID: UUID) -> TerminalSessionController? {
        controllers[tabID]
    }

    /// Close a tab for real: detach the SSH channel and drop the controller
    /// (and with it the terminal view). Never called when a tab merely moves.
    func closeTab(_ tabID: UUID) {
        controllers.removeValue(forKey: tabID)?.detach()
    }

    // MARK: Window directory (merge sources)

    struct WindowEntry: Identifiable {
        let id: UUID
        var tabs: [TerminalRoute]
        var label: String
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
