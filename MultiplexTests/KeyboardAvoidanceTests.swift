import XCTest
@testable import Multiplex

final class KeyboardAvoidanceTests: XCTestCase {
    // 13" iPad, landscape.
    private let screen = CGRect(x: 0, y: 0, width: 1366, height: 1024)

    func testDockedKeyboardIsDocked() {
        let keyboard = CGRect(x: 0, y: 1024 - 320, width: 1366, height: 320)
        XCTAssertTrue(KeyboardAvoidance.isDocked(keyboard: keyboard, screen: screen, containerWidth: 1366))
    }

    func testShortcutBarIsDocked() {
        // Hardware-keyboard mode: just the system shortcut bar at the bottom.
        let bar = CGRect(x: 0, y: 1024 - 55, width: 1366, height: 55)
        XCTAssertTrue(KeyboardAvoidance.isDocked(keyboard: bar, screen: screen, containerWidth: 1366))
    }

    func testWindowWideShortcutBarIsDockedInWindowedIPadOS() {
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

    func testFloatingPillParkedAtBottomIsNotDockedInNarrowWindow() {
        // A real floating keyboard can be as wide as a small Stage Manager
        // window. Real keyboard height still requires screen width; only the
        // short accessory rail may use container width as its docked signal.
        let pill = CGRect(x: 500, y: 1024 - 254, width: 320, height: 254)
        XCTAssertFalse(KeyboardAvoidance.isDocked(keyboard: pill, screen: screen, containerWidth: 320))
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

    func testShortcutBarIsNotPresented() {
        // Hardware-keyboard mode: the shortcut bar is not a typable keyboard.
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

    // MARK: - visibilityUpdate (focus-arbiter input-session state)

    func testFloatingFrameShowsInputSession() {
        let pill = CGRect(x: 400, y: 600, width: 320, height: 254)
        XCTAssertEqual(
            KeyboardAvoidance.visibilityUpdate(keyboard: pill, screen: screen),
            .shown
        )
    }

    func testZeroHeightFrameIsAmbiguous() {
        let flat = CGRect(x: 251, y: 860, width: 802.5, height: 0)
        XCTAssertNil(KeyboardAvoidance.visibilityUpdate(
            keyboard: flat,
            screen: screen
        ))
    }

    func testTallOffscreenFrameDefinitivelyHidesInputSession() {
        let gone = CGRect(x: 0, y: 1024, width: 1366, height: 346)
        XCTAssertEqual(
            KeyboardAvoidance.visibilityUpdate(
                keyboard: gone,
                screen: screen
            ),
            .hidden
        )
    }

    // MARK: - presentation (notification hot-path classification)

    func testPresentationClassifiesDockedPanel() {
        let panel = CGRect(x: 0, y: 1024 - 346, width: 1366, height: 346)
        XCTAssertEqual(
            KeyboardAvoidance.presentation(keyboard: panel, screen: screen),
            .docked
        )
    }

    func testPresentationClassifiesFloatingPillInNarrowWindow() {
        let pill = CGRect(x: 500, y: 1024 - 254, width: 320, height: 254)
        XCTAssertEqual(
            KeyboardAvoidance.presentation(keyboard: pill, screen: screen),
            .floating
        )
    }

    func testPresentationClassifiesWindowWideShortcutFrame() {
        let rail = CGRect(x: 100, y: 1024 - 55, width: 500, height: 55)
        XCTAssertEqual(
            KeyboardAvoidance.presentation(keyboard: rail, screen: screen),
            .shortcut
        )
    }

    func testPresentationClassifiesFlatShortcutFrame() {
        let flat = CGRect(x: 100, y: 800, width: 500, height: 0)
        XCTAssertEqual(
            KeyboardAvoidance.presentation(keyboard: flat, screen: screen),
            .shortcut
        )
    }

    func testPresentationClassifiesDismissedFrameAsHidden() {
        let gone = CGRect(x: 0, y: 1024, width: 1366, height: 346)
        XCTAssertEqual(
            KeyboardAvoidance.presentation(keyboard: gone, screen: screen),
            .hidden
        )
    }

    func testRepeatedFloatingFrameChangeDoesNotRequestLayout() {
        XCTAssertFalse(KeyboardAvoidance.shouldReapplyFrameChange(from: .floating, to: .floating))
    }

    func testRepeatedShortcutFrameChangeDoesNotRequestLayout() {
        XCTAssertFalse(KeyboardAvoidance.shouldReapplyFrameChange(from: .shortcut, to: .shortcut))
    }

    func testTransitionIntoShortcutDoesNotRequestLayout() {
        XCTAssertFalse(KeyboardAvoidance.shouldReapplyFrameChange(from: .hidden, to: .shortcut))
    }

    func testTransitionIntoFloatingClearsPreviousDockedLayout() {
        XCTAssertTrue(KeyboardAvoidance.shouldReapplyFrameChange(from: .docked, to: .floating))
    }

    func testRepeatedDockedFrameChangeStillRemeasuresMovingWindow() {
        XCTAssertTrue(KeyboardAvoidance.shouldReapplyFrameChange(from: .docked, to: .docked))
    }
}
