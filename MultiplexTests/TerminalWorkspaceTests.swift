import XCTest
@testable import Multiplex

/// The deck's press-to-focus lookup: which open window (if any) already
/// holds a tab for a tmux session, and that focusing reveals the right
/// tab. Entries are registered directly — no scenes or controllers.
@MainActor
final class TerminalWorkspaceTests: XCTestCase {
    @discardableResult
    private func register(
        _ workspace: TerminalWorkspace,
        tabs: [TerminalRoute],
        reveal: @escaping @MainActor (UUID) -> Void = { _ in }
    ) -> UUID {
        let id = UUID()
        workspace.registerWindow(.init(
            id: id,
            tabs: tabs,
            label: "test",
            reveal: reveal,
            surrender: { [] },
            adopt: { _ in }
        ))
        return id
    }

    func testFocusTabRevealsTheMatchingTab() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        let main = TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))
        let scratch = TerminalRoute(hostID: host, mode: .create(sessionName: "scratch"))
        var revealed: [UUID] = []
        register(workspace, tabs: [main, scratch]) { revealed.append($0) }

        XCTAssertTrue(workspace.focusTab(hostID: host, sessionName: "scratch"))
        XCTAssertEqual(revealed, [scratch.id], "create-mode tabs are bound to their session too")
    }

    func testFocusTabSearchesEveryWindow() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        let deploy = TerminalRoute(hostID: host, mode: .attach(sessionName: "deploy"))
        var revealed: [UUID] = []
        register(workspace, tabs: [TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))])
        register(workspace, tabs: [deploy]) { revealed.append($0) }

        XCTAssertTrue(workspace.focusTab(hostID: host, sessionName: "deploy"))
        XCTAssertEqual(revealed, [deploy.id])
    }

    func testFocusTabMatchesHostAndSessionTogether() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        let otherHost = UUID()
        register(workspace, tabs: [TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))])

        XCTAssertFalse(
            workspace.focusTab(hostID: otherHost, sessionName: "main"),
            "the same session name on another host is a different session")
        XCTAssertFalse(workspace.focusTab(hostID: host, sessionName: "missing"))
        XCTAssertTrue(workspace.hasTab(hostID: host, sessionName: "main"))
        XCTAssertFalse(workspace.hasTab(hostID: otherHost, sessionName: "main"))
    }

    func testShellTabsNeverMatch() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        register(workspace, tabs: [TerminalRoute(hostID: host, mode: .shell)])

        XCTAssertFalse(workspace.hasTab(hostID: host, sessionName: "shell"))
    }

    func testUnregisteredWindowStopsMatching() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        let id = register(
            workspace,
            tabs: [TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))])

        workspace.unregisterWindow(id: id)

        XCTAssertFalse(workspace.hasTab(hostID: host, sessionName: "main"))
    }
}
