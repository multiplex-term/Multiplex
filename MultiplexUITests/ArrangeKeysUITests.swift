import notify
import XCTest

/// Real touches through XCUITest — the one route that drives the Arrange
/// Keys drag and drop end to end (no headless tap injection exists on Xcode
/// 27 simulators). Needs the dev sshd harness for the seeded host; run with
/// `TEST_RUNNER_MULTIPLEX_SEED_HOST=<abs path to state/seed.json>` in
/// xcodebuild's environment. Deliberately outside the unit scheme and CI.
final class ArrangeKeysUITests: XCTestCase {
    private let bundleID = "app.multiplexterm.multiplex"
    #if os(visionOS)
    private let prefix = "terminal.keyCluster."
    #else
    private let prefix = "terminal.keybar."
    #endif

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPressAndDragReordersTheKeys() throws {
        let app = XCUIApplication()
        if let seed = ProcessInfo.processInfo.environment["MULTIPLEX_SEED_HOST"] {
            app.launchEnvironment["MULTIPLEX_SEED_HOST"] = seed
        }
        app.launchEnvironment["MULTIPLEX_AUTO_ATTACH"] = "main"
        app.launchEnvironment["MULTIPLEX_METAL"] = "0"
        app.launch()

        let escape = app.buttons[prefix + "escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 60), "No key rail / cluster appeared")
        sleep(3)
        notify_post(bundleID + ".debug.summon")
        sleep(1)
        notify_post(bundleID + ".debug.arrangekeys")
        let done = app.buttons["terminalPane.context.arrangeKeys.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Arrange mode did not present its bar")

        // A previous run (or a headless proof) may have left a custom order
        // in this simulator's container: start from the shipped one.
        let reset = app.buttons["terminalPane.context.arrangeKeys.reset"]
        if reset.exists {
            reset.tap()
            sleep(1)
        }
        XCTAssertEqual(Array(keyOrder(app).prefix(3)), ["escape", "control", "tab"])
        #if os(visionOS)
        // The visionOS simulator cannot synthesize a lift for a drag
        // interaction; the mode and the bar are proved above, the drop
        // plumbing by the fake-session unit tests.
        throw XCTSkip("visionOS simulator cannot synthesize a lift for the key's drag interaction")
        #endif

        // The gesture itself — a system drag and drop, the tab strip's:
        // press ESC until it lifts, carry it onto TAB, hold there so the
        // target resolves, release. ESC lands after TAB.
        let tab = app.buttons[prefix + "tab"].firstMatch
        XCTAssertTrue(tab.exists)
        escape.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 1.0,
                thenDragTo: tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                withVelocity: .default,
                thenHoldForDuration: 0.8
            )
        sleep(2)
        XCTAssertEqual(
            Array(keyOrder(app).prefix(3)),
            ["control", "tab", "escape"],
            "ESC dropped on TAB should land right after it"
        )
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "RESET should appear off the shipped order")

        reset.tap()
        sleep(1)
        XCTAssertEqual(Array(keyOrder(app).prefix(3)), ["escape", "control", "tab"])
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }

    /// Every key on screen, left to right, by the part of its identifier
    /// after the prefix. Identifier and frame are read from ONE snapshot
    /// each, and the row is logged with its frames so a surprising order
    /// can be read off the xcodebuild log.
    private func keyOrder(_ app: XCUIApplication) -> [String] {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        let snapshot = app.buttons.matching(predicate).allElementsBoundByIndex.map { element in
            (identifier: element.identifier, frame: element.frame)
        }
        // XCUITest reports each key twice (one accessibility element, two
        // paths to it); one entry per identifier is the row.
        var seen = Set<String>()
        let row = snapshot
            .filter { $0.frame.width > 0 && seen.insert($0.identifier).inserted }
            .sorted { $0.frame.midX < $1.frame.midX }
        NSLog(
            "ArrangeKeysUITests row: %@",
            row.map { "\($0.identifier.dropFirst(prefix.count))@\(Int($0.frame.minX))" }
                .joined(separator: " ")
        )
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        return row.map { String($0.identifier.dropFirst(prefix.count)) }
    }
}
