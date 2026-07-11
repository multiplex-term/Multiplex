import XCTest
@testable import Multiplex

final class KeyboardAvoidanceTests: XCTestCase {
    // 13" iPad, landscape.
    private let screen = CGRect(x: 0, y: 0, width: 1366, height: 1024)

    func testDockedKeyboardIsDocked() {
        let keyboard = CGRect(x: 0, y: 1024 - 320, width: 1366, height: 320)
        XCTAssertTrue(KeyboardAvoidance.isDocked(keyboard: keyboard, screen: screen, containerWidth: 1366))
    }

    func testAccessoryOnlyBarIsDocked() {
        // Hardware-keyboard mode: just the accessory rail at the bottom.
        let bar = CGRect(x: 0, y: 1024 - 55, width: 1366, height: 55)
        XCTAssertTrue(KeyboardAvoidance.isDocked(keyboard: bar, screen: screen, containerWidth: 1366))
    }

    func testWindowWideAccessoryBarIsDockedInWindowedIPadOS() {
        // Stage Manager: the bar tracks a 500 pt window, not the screen.
        let bar = CGRect(x: 100, y: 1024 - 55, width: 500, height: 55)
        XCTAssertTrue(KeyboardAvoidance.isDocked(keyboard: bar, screen: screen, containerWidth: 500))
    }

    func testFloatingPillIsNotDocked() {
        let pill = CGRect(x: 400, y: 600, width: 320, height: 254)
        XCTAssertFalse(KeyboardAvoidance.isDocked(keyboard: pill, screen: screen, containerWidth: 1366))
    }

    func testFloatingPillParkedAtBottomIsNotDocked() {
        // Pinned to the bottom edge but far narrower than the content.
        let pill = CGRect(x: 500, y: 1024 - 254, width: 320, height: 254)
        XCTAssertFalse(KeyboardAvoidance.isDocked(keyboard: pill, screen: screen, containerWidth: 1366))
    }

    func testSplitKeyboardIsNotDocked() {
        // Full width but raised off the bottom edge.
        let split = CGRect(x: 0, y: 600, width: 1366, height: 320)
        XCTAssertFalse(KeyboardAvoidance.isDocked(keyboard: split, screen: screen, containerWidth: 1366))
    }

    func testCollapsedShortcutsPillIsNotDocked() {
        let pill = CGRect(x: 1366 - 160, y: 1024 - 55, width: 150, height: 55)
        XCTAssertFalse(KeyboardAvoidance.isDocked(keyboard: pill, screen: screen, containerWidth: 1366))
    }

    func testEmptyFrameIsNotDocked() {
        XCTAssertFalse(KeyboardAvoidance.isDocked(keyboard: .zero, screen: screen, containerWidth: 1366))
    }
}
