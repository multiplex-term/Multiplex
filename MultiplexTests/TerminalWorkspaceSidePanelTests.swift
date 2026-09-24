import XCTest
@testable import Multiplex

@MainActor
final class TerminalWorkspaceSidePanelTests: XCTestCase {
    private final class FakeAuxiliaryController: AuxiliaryPaneController {
        var tabLabel = "⌗ test"
        var routeMode: TerminalRoute.Mode { .viewport(urlString: "https://example.com") }
        private(set) var shutdownCount = 0

        func shutdown() {
            shutdownCount += 1
        }
    }

    func testPanelLifecycleUnderItsHostTab() {
        let workspace = TerminalWorkspace()
        let hostTabID = UUID()
        let first = FakeAuxiliaryController()
        let second = FakeAuxiliaryController()

        workspace.openSidePanel(hostTabID: hostTabID, controller: first)
        XCTAssertTrue(workspace.sidePanel(for: hostTabID) === first)
        XCTAssertEqual(first.shutdownCount, 0)

        workspace.openSidePanel(hostTabID: hostTabID, controller: second)
        XCTAssertEqual(first.shutdownCount, 1, "a second open replaces and shuts down the first")
        XCTAssertTrue(workspace.sidePanel(for: hostTabID) === second)

        workspace.closeSidePanel(hostTabID: hostTabID)
        XCTAssertNil(workspace.sidePanel(for: hostTabID))
        XCTAssertEqual(second.shutdownCount, 1)

        let third = FakeAuxiliaryController()
        workspace.openSidePanel(hostTabID: hostTabID, controller: third)
        workspace.closeTab(hostTabID)
        XCTAssertNil(workspace.sidePanel(for: hostTabID), "closing the host tab closes its panel")
        XCTAssertEqual(third.shutdownCount, 1)
    }

    func testDetachAndAdoptMovesTheSameLiveControllerWithoutShutdown() throws {
        let workspace = TerminalWorkspace()
        let hostTabID = UUID()
        let auxiliaryTabID = UUID()
        let controller = FakeAuxiliaryController()
        workspace.openSidePanel(hostTabID: hostTabID, controller: controller)

        let detached = try XCTUnwrap(workspace.detachSidePanel(hostTabID: hostTabID))
        workspace.adoptAuxiliary(detached, tabID: auxiliaryTabID)

        XCTAssertNil(workspace.sidePanel(for: hostTabID))
        XCTAssertTrue(workspace.auxiliaryController(for: auxiliaryTabID) === controller)
        XCTAssertEqual(controller.shutdownCount, 0)
    }
}
