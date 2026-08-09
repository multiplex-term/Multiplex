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

        XCTAssertTrue(workspace.focusTab(
            hostID: host, sessionName: "scratch", backend: .tmux))
        XCTAssertEqual(revealed, [scratch.id], "create-mode tabs are bound to their session too")
    }

    func testFocusTabSearchesEveryWindow() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        let deploy = TerminalRoute(hostID: host, mode: .attach(sessionName: "deploy"))
        var revealed: [UUID] = []
        register(workspace, tabs: [TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))])
        register(workspace, tabs: [deploy]) { revealed.append($0) }

        XCTAssertTrue(workspace.focusTab(
            hostID: host, sessionName: "deploy", backend: .tmux))
        XCTAssertEqual(revealed, [deploy.id])
    }

    func testFocusTabMatchesHostAndSessionTogether() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        let otherHost = UUID()
        register(workspace, tabs: [TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))])

        XCTAssertFalse(
            workspace.focusTab(
                hostID: otherHost, sessionName: "main", backend: .tmux),
            "the same session name on another host is a different session")
        XCTAssertFalse(workspace.focusTab(
            hostID: host, sessionName: "missing", backend: .tmux))
        XCTAssertTrue(workspace.hasTab(
            hostID: host, sessionName: "main", backend: .tmux))
        XCTAssertFalse(workspace.hasTab(
            hostID: otherHost, sessionName: "main", backend: .tmux))
    }

    func testSameNamedSessionsInDifferentBackendsNeverCrossFocus() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        let tmux = TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))
        let herdr = TerminalRoute(
            hostID: host, mode: .herdrAttach(sessionName: "main"))
        var revealed: [UUID] = []
        register(workspace, tabs: [tmux, herdr]) { revealed.append($0) }

        XCTAssertTrue(workspace.focusTab(
            hostID: host, sessionName: "main", backend: .herdr))
        XCTAssertEqual(revealed, [herdr.id])
        XCTAssertTrue(workspace.hasTab(
            hostID: host, sessionName: "main", backend: .tmux))
        XCTAssertTrue(workspace.hasTab(
            hostID: host, sessionName: "main", backend: .herdr))
    }

    func testShellTabsNeverMatch() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        register(workspace, tabs: [TerminalRoute(hostID: host, mode: .shell)])

        XCTAssertFalse(workspace.hasTab(
            hostID: host, sessionName: "shell", backend: .tmux))
    }

    func testFileViewerRegistersRequestedPresentationBeforeItsRouteArrives() {
        let workspace = TerminalWorkspace()
        let host = Host(
            name: "devbox",
            hostname: "127.0.0.1",
            username: "tester"
        )
        let path = "/srv/app/App.swift"
        let tab = TerminalRoute(hostID: host.id, mode: .fileViewer(path: path))
        workspace.openFileViewer(
            tab: tab,
            host: host,
            startDirectory: "/srv/app",
            anchorSession: SessionKey(backend: .herdr, name: "work"),
            target: TerminalPathTarget(
                raw: path,
                path: path,
                base: .absolute,
                line: nil
            ),
            targetPresentation: .diff
        )

        let controller = workspace.fileViewerController(for: tab.id)
        XCTAssertEqual(controller?.filePresentation, .diff)
        XCTAssertEqual(
            controller?.anchorSession,
            SessionKey(backend: .herdr, name: "work")
        )
        workspace.closeTab(tab.id)
    }

    func testFileViewerMoshAnchorDispatchesBySessionBackend() throws {
        let tmux = SessionKey(backend: .tmux, name: "main")
        XCTAssertEqual(
            FileViewerController.anchorDirectoryCommand(for: tmux),
            TmuxProbe.dropDestinationCommand(sessionName: "main")
        )
        XCTAssertEqual(
            FileViewerController.parseAnchorDirectory(
                "/srv/project\nMULTIPLEX_GIT\n", backend: .tmux
            ),
            "/srv/project"
        )

        let herdr = SessionKey(backend: .herdr, name: "work")
        XCTAssertEqual(
            FileViewerController.anchorDirectoryCommand(for: herdr),
            HerdrProbe.snapshotCommand(sessionName: "work")
        )
        let fixtureURL = try XCTUnwrap(
            Bundle(for: TerminalWorkspaceTests.self).url(
                forResource: "herdr-snapshot-v0-7-5", withExtension: "json"
            )
        )
        let snapshot = try String(contentsOf: fixtureURL, encoding: .utf8)
        XCTAssertEqual(
            FileViewerController.parseAnchorDirectory(snapshot, backend: .herdr),
            "/Users/jhen"
        )
    }

    func testUnregisteredWindowStopsMatching() {
        let workspace = TerminalWorkspace()
        let host = UUID()
        let id = register(
            workspace,
            tabs: [TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))])

        workspace.unregisterWindow(id: id)

        XCTAssertFalse(workspace.hasTab(
            hostID: host, sessionName: "main", backend: .tmux))
    }
}
