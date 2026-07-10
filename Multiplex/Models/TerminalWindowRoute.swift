import Foundation

/// Value handed to the terminal `WindowGroup` — one route per terminal
/// window, holding that window's ordered tabs. Each tab is a `TerminalRoute`
/// (one SSH shell). The tab list lives in the scene value itself so scene
/// restoration brings every tab back; merge/split mutate the value in place
/// (never close-and-reopen windows — controllers keep the live shells).
struct TerminalWindowRoute: Codable, Hashable, Identifiable {
    private enum CodingKeys: String, CodingKey { case id, tabs, activeTabID }

    var id: UUID
    var tabs: [TerminalRoute]
    var activeTabID: UUID?

    init(id: UUID = UUID(), tabs: [TerminalRoute], activeTabID: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id
    }

    init(tab: TerminalRoute) {
        self.init(tabs: [tab], activeTabID: tab.id)
    }

    /// Windows restored from builds where the scene value was a single
    /// `TerminalRoute` decode as one-tab windows instead of failing to restore.
    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let tabs = try? container.decode([TerminalRoute].self, forKey: .tabs) {
            self.init(
                id: try container.decode(UUID.self, forKey: .id),
                tabs: tabs,
                activeTabID: try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
            )
        } else {
            self.init(tab: try TerminalRoute(from: decoder))
        }
    }

    /// The tab whose terminal is visible. Falls back to the first tab if
    /// `activeTabID` ever goes stale.
    var activeTab: TerminalRoute? {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs.first
    }

    mutating func activate(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
    }

    /// Merge: append tabs surrendered by another window. Deduplicates by id
    /// (a tab lives in exactly one window) and keeps the current active tab.
    mutating func merge(_ incoming: [TerminalRoute]) {
        let existing = Set(tabs.map(\.id))
        tabs.append(contentsOf: incoming.filter { !existing.contains($0.id) })
        if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id
        }
    }

    /// Remove a tab (close, or split into its own window). When the active
    /// tab goes, its right neighbor takes over, else the left one.
    @discardableResult
    mutating func removeTab(id tabID: UUID) -> TerminalRoute? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let removed = tabs.remove(at: index)
        if activeTabID == tabID {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        return removed
    }
}
