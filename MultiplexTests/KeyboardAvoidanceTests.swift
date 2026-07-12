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

    // MARK: - accessoryIsDocked (the rendered key rail's own classifier)

    func testFullscreenRailIsDocked() {
        // Geometry measured on the iPad simulator: rail's UIInputView frame
        // extends behind the home indicator to the exact screen bottom.
        let screen = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        let container = CGRect(x: 10, y: 94, width: 1012, height: 1254)
        let rail = CGRect(x: 0, y: 1328, width: 1032, height: 48)
        XCTAssertTrue(KeyboardAvoidance.accessoryIsDocked(
            accessory: rail, container: container, screen: screen))
    }

    func testWindowBottomRailIsDockedInWindowedIPadOS() {
        // Stage Manager: the rail can pin to the *window* bottom, well above
        // the screen edge — bottom-pinning is judged against the container.
        let container = CGRect(x: 100, y: 200, width: 500, height: 600)
        let rail = CGRect(x: 100, y: 752, width: 500, height: 48)
        XCTAssertTrue(KeyboardAvoidance.accessoryIsDocked(
            accessory: rail, container: container, screen: screen))
    }

    func testRailRidingFloatingPillIsNotDocked() {
        // A floating keyboard carries its rail around mid-screen; reserving
        // under it would resize the PTY (tmux reflow) on every drag frame.
        let container = CGRect(x: 10, y: 94, width: 1346, height: 900)
        let rail = CGRect(x: 400, y: 600 - 48, width: 320, height: 48)
        XCTAssertFalse(KeyboardAvoidance.accessoryIsDocked(
            accessory: rail, container: container, screen: screen))
    }

    func testRailAboveDockedKeyboardIsNotDocked() {
        // Full width but sitting on top of the keyboard, above the container
        // bottom: the keyboard end frame already includes the rail, so the
        // keyboard-frame path owns this inset.
        let container = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        let rail = CGRect(x: 0, y: 1024 - 320 - 48, width: 1366, height: 48)
        XCTAssertFalse(KeyboardAvoidance.accessoryIsDocked(
            accessory: rail, container: container, screen: screen))
    }

    func testRailBelowShortWindowIsDocked() {
        // A Stage Manager window floating above the screen-bottom rail: the
        // rail is docked (no overlap — the caller's inset math yields zero).
        let container = CGRect(x: 100, y: 100, width: 700, height: 500)
        let rail = CGRect(x: 0, y: 1024 - 48, width: 1366, height: 48)
        XCTAssertTrue(KeyboardAvoidance.accessoryIsDocked(
            accessory: rail, container: container, screen: screen))
    }

    func testEmptyRailIsNotDocked() {
        let container = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        XCTAssertFalse(KeyboardAvoidance.accessoryIsDocked(
            accessory: .zero, container: container, screen: screen))
    }

    // MARK: - isPresented (typable-keyboard visibility, floating included)

    func testDockedPanelIsPresented() {
        let panel = CGRect(x: 0, y: 1024 - 346, width: 1366, height: 346)
        XCTAssertTrue(KeyboardAvoidance.isPresented(keyboard: panel, screen: screen))
    }

    func testFloatingPillIsPresented() {
        // Floating keyboards post no didShow/didHide — geometry is the only
        // visibility signal, and a mid-screen pill is a typable keyboard.
        let pill = CGRect(x: 400, y: 600, width: 320, height: 254)
        XCTAssertTrue(KeyboardAvoidance.isPresented(keyboard: pill, screen: screen))
    }

    func testAccessoryOnlyRailIsNotPresented() {
        // Hardware-keyboard mode: the rail alone is not a typable keyboard.
        let rail = CGRect(x: 0, y: 1024 - 55, width: 1366, height: 55)
        XCTAssertFalse(KeyboardAvoidance.isPresented(keyboard: rail, screen: screen))
    }

    func testOffscreenFrameIsNotPresented() {
        // A dismissed keyboard's end frame parks at/below the screen bottom.
        let gone = CGRect(x: 0, y: 1024, width: 1366, height: 346)
        XCTAssertFalse(KeyboardAvoidance.isPresented(keyboard: gone, screen: screen))
    }

    func testZeroHeightFrameIsNotPresented() {
        let flat = CGRect(x: 0, y: 1024, width: 1366, height: 0)
        XCTAssertFalse(KeyboardAvoidance.isPresented(keyboard: flat, screen: screen))
    }
}
