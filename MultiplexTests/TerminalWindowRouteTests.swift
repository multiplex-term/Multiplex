import XCTest
@testable import Multiplex

final class TerminalWindowRouteTests: XCTestCase {
    private func tab(_ name: String, host: UUID = UUID()) -> TerminalRoute {
        TerminalRoute(hostID: host, mode: .attach(sessionName: name))
    }

    // MARK: Active tab

    func testInitDefaultsActiveToFirstTab() {
        let tabs = [tab("main"), tab("scratch")]
        let route = TerminalWindowRoute(tabs: tabs)
        XCTAssertEqual(route.activeTabID, tabs[0].id)
        XCTAssertEqual(route.activeTab, tabs[0])
    }

    func testActivateSwitchesAndIgnoresUnknownID() {
        let tabs = [tab("main"), tab("scratch")]
        var route = TerminalWindowRoute(tabs: tabs)

        route.activate(tabs[1].id)
        XCTAssertEqual(route.activeTab, tabs[1])

        route.activate(UUID())
        XCTAssertEqual(route.activeTab, tabs[1], "unknown id must not change the active tab")
    }

    func testActiveTabFallsBackToFirstWhenIDIsStale() {
        let tabs = [tab("main"), tab("scratch")]
        var route = TerminalWindowRoute(tabs: tabs)
        route.activeTabID = UUID()
        XCTAssertEqual(route.activeTab, tabs[0])
    }

    // MARK: Reordering

    func testMoveTabIntoTargetSlotInEitherDirectionAndKeepActive() {
        let tabs = [tab("a"), tab("b"), tab("c"), tab("d")]
        var route = TerminalWindowRoute(tabs: tabs, activeTabID: tabs[1].id)

        route.moveTab(id: tabs[1].id, to: tabs[3].id)
        XCTAssertEqual(route.tabs, [tabs[0], tabs[2], tabs[3], tabs[1]])
        XCTAssertEqual(route.activeTabID, tabs[1].id)

        route.moveTab(id: tabs[3].id, to: tabs[0].id)
        XCTAssertEqual(route.tabs, [tabs[3], tabs[0], tabs[2], tabs[1]])
        XCTAssertEqual(route.activeTabID, tabs[1].id)
    }

    func testMoveTabIgnoresSelfAndUnknownIDs() {
        let tabs = [tab("a"), tab("b")]
        var route = TerminalWindowRoute(tabs: tabs)

        route.moveTab(id: tabs[0].id, to: tabs[0].id)
        route.moveTab(id: UUID(), to: tabs[1].id)
        route.moveTab(id: tabs[0].id, to: UUID())

        XCTAssertEqual(route.tabs, tabs)
        XCTAssertEqual(route.activeTabID, tabs[0].id)
    }

    // MARK: Removal (close / split)

    func testRemoveActiveTabActivatesRightNeighbor() {
        let tabs = [tab("a"), tab("b"), tab("c")]
        var route = TerminalWindowRoute(tabs: tabs, activeTabID: tabs[1].id)

        let removed = route.removeTab(id: tabs[1].id)

        XCTAssertEqual(removed, tabs[1])
        XCTAssertEqual(route.tabs, [tabs[0], tabs[2]])
        XCTAssertEqual(route.activeTabID, tabs[2].id)
    }

    func testRemoveActiveTailTabActivatesPrevious() {
        let tabs = [tab("a"), tab("b")]
        var route = TerminalWindowRoute(tabs: tabs, activeTabID: tabs[1].id)

        route.removeTab(id: tabs[1].id)

        XCTAssertEqual(route.activeTabID, tabs[0].id)
    }

    func testRemoveInactiveTabKeepsActive() {
        let tabs = [tab("a"), tab("b"), tab("c")]
        var route = TerminalWindowRoute(tabs: tabs, activeTabID: tabs[2].id)

        route.removeTab(id: tabs[0].id)

        XCTAssertEqual(route.activeTabID, tabs[2].id)
    }

    func testRemoveLastTabEmptiesWindow() {
        let only = tab("solo")
        var route = TerminalWindowRoute(tab: only)

        let removed = route.removeTab(id: only.id)

        XCTAssertEqual(removed, only)
        XCTAssertTrue(route.tabs.isEmpty)
        XCTAssertNil(route.activeTabID)
        XCTAssertNil(route.activeTab)
    }

    func testRemoveUnknownTabIsNoOp() {
        let tabs = [tab("a")]
        var route = TerminalWindowRoute(tabs: tabs)

        XCTAssertNil(route.removeTab(id: UUID()))
        XCTAssertEqual(route.tabs, tabs)
        XCTAssertEqual(route.activeTabID, tabs[0].id)
    }

    // MARK: Merge

    func testMergeAppendsInOrderAndKeepsActive() {
        let mine = [tab("a"), tab("b")]
        let theirs = [tab("c"), tab("d")]
        var route = TerminalWindowRoute(tabs: mine, activeTabID: mine[1].id)

        route.merge(theirs)

        XCTAssertEqual(route.tabs, mine + theirs)
        XCTAssertEqual(route.activeTabID, mine[1].id)
    }

    func testMergeDeduplicatesByID() {
        let shared = tab("dup")
        var route = TerminalWindowRoute(tabs: [shared])

        route.merge([shared, tab("new")])

        XCTAssertEqual(route.tabs.count, 2)
        XCTAssertEqual(route.tabs.first, shared)
    }

    func testMergeIntoEmptyWindowAdoptsFirstAsActive() {
        var route = TerminalWindowRoute(tabs: [])
        let theirs = [tab("a"), tab("b")]

        route.merge(theirs)

        XCTAssertEqual(route.activeTabID, theirs[0].id)
    }

    // MARK: Coding (scene restoration)

    func testRoundTripCoding() throws {
        let tabs = [tab("main"), tab("scratch")]
        let route = TerminalWindowRoute(tabs: tabs, activeTabID: tabs[1].id)

        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(TerminalWindowRoute.self, from: data)

        XCTAssertEqual(decoded, route)
    }

    func testDecodesLegacySingleRouteValue() throws {
        // A window persisted by a build where the scene value was one
        // TerminalRoute must restore as a one-tab window.
        let legacy = TerminalRoute(hostID: UUID(), mode: .create(sessionName: "deploy"))

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(TerminalWindowRoute.self, from: data)

        XCTAssertEqual(decoded.tabs, [legacy])
        XCTAssertEqual(decoded.activeTabID, legacy.id)
    }

    func testDecodesCreateModePersistedBeforeDirectoriesExisted() throws {
        // A scene value written by a build where .create had no directory
        // must restore (directory absent → nil), not drop the window.
        let json = """
        {
          "id": "6F1E9A3C-4B4C-4B7B-9A57-2B9E2E64A222",
          "hostID": "6F1E9A3C-4B4C-4B7B-9A57-2B9E2E64A111",
          "mode": { "create": { "sessionName": "deploy" } }
        }
        """
        let decoded = try JSONDecoder().decode(TerminalRoute.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.mode, .create(sessionName: "deploy"))
        XCTAssertTrue(decoded.remoteCommand?.contains(
            "multiplex_tmux new-session -d -s 'deploy'") == true)
        XCTAssertTrue(decoded.remoteCommand?.hasSuffix(
            "exec tmux attach-session -t 'deploy'") == true)
    }
}
