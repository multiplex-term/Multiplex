import XCTest

/// Real touches on a paned (Rex) tab: a tap moves the tab's focus to the
/// pane under it, and a finger on the line between two panes drags it. No
/// headless tap or drag exists on Xcode 27 simulators, so this is the one
/// road that drives the two gesture recognizers a paned tab adds.
///
/// Needs a host whose `rex` reaches a Rex server with a session to attach —
/// `docs/agents/backends-and-probe.md` has the throwaway-server recipe. Run
/// with, in xcodebuild's environment:
/// - `TEST_RUNNER_MULTIPLEX_SEED_HOST=<abs path to a seed with
///   secondaryBackends: ["rex"]>`
/// - `TEST_RUNNER_MULTIPLEX_REX_SESSION=<the session's label>`
/// Skipped without them. Deliberately outside the unit scheme and CI. What
/// each pane received is read host-side afterwards (`rex capture`): the test
/// types a different line into each.
final class RexPanesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testATapFocusesAPaneAndAFingerDragsTheLineBetweenTwo() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let seed = environment["MULTIPLEX_SEED_HOST"],
              let session = environment["MULTIPLEX_REX_SESSION"]
        else { throw XCTSkip("needs MULTIPLEX_SEED_HOST and MULTIPLEX_REX_SESSION") }

        let app = XCUIApplication()
        app.launchEnvironment["MULTIPLEX_SEED_HOST"] = seed
        app.launchEnvironment["MULTIPLEX_METAL"] = "0"
        app.launchEnvironment["MULTIPLEX_AUTO_ACTION_URL"] =
            "multiplex://open?host=devbox&action=shell&session=\(session)&backend=rex"
        // One pane becomes two, side by side, through the panel's own row.
        app.launchEnvironment["MULTIPLEX_AUTO_PANE_ACTIONS"] = "splitRight"
        app.launch()

        let divider = app.descendants(matching: .any)
            .matching(identifier: "terminalPane.divider").firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 60), "No second pane appeared")
        sleep(2)
        let line = divider.frame
        let split = app.descendants(matching: .any)
            .matching(identifier: "terminalPane.split").firstMatch.frame
        NSLog("RexPanesUITests line %@ split %@", "\(line)", "\(split)")
        let window = app.windows.firstMatch
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
        }
        let row = line.minY + 160

        // The split left the keyboard in the NEW pane, on the right. A tap
        // on the left pane moves it there; what is typed next proves where.
        point(line.minX - 120, row).tap()
        sleep(1)
        app.typeText("echo typed-in-left\n")
        sleep(1)
        point(line.maxX + 120, row).tap()
        sleep(1)
        app.typeText("echo typed-in-right\n")
        sleep(1)
        attach(app, "after-taps")

        // A finger on the line carries it: the line follows.
        point(line.midX, row)
            .press(forDuration: 0.3, thenDragTo: point(line.midX - 180, row))
        sleep(2)
        let moved = divider.frame
        NSLog("RexPanesUITests line after drag %@", "\(moved)")
        attach(app, "after-drag")
        XCTAssertEqual(moved.midX, line.midX - 180, accuracy: 6, "The line should stay under the finger")

        // The pane on the right grew; a tap on it is still its own.
        point(moved.maxX + 120, row).tap()
        sleep(1)
        app.typeText("echo after-drag-right\n")
        sleep(2)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
