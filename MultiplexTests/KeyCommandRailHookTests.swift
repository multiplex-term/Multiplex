import SwiftTerm
import UIKit
import XCTest
@testable import Multiplex

/// The rail's CTRL key carries the Key Commands hold on both platforms —
/// shorter than the keyboard key's lock hold, and separate from the tap
/// that latches.
@MainActor
final class KeyCommandRailHookTests: XCTestCase {
    #if os(visionOS)
    func testClusterControlKeyHoldsIntoKeyCommands() {
        let context = TerminalKeyClusterContext()
        let group = TerminalKeyClusterGroupView(role: .leading, metric: .regular, context: context)
        let control = group.keys.first { $0.accessibilityIdentifier == "terminal.keyCluster.control" }
        XCTAssertNotNil(control?.longPressAction, "Hold CTRL opens Key Commands")
        XCTAssertEqual(
            control?.longPressDuration,
            KeyCommandPanelViewController.controlHoldDuration
        )
        let escape = group.keys.first { $0.accessibilityIdentifier == "terminal.keyCluster.escape" }
        XCTAssertNil(escape?.longPressAction)
    }
    #else
    func testRailControlKeyHoldsIntoKeyCommands() {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let bar = TerminalKeyBar(
            terminal: terminal,
            controller: nil,
            performShortcut: { _ in },
            finishTmuxCopyMode: {},
            shortcutBackend: .tmux
        )
        bar.frame = CGRect(x: 0, y: 0, width: 600, height: TerminalKeyBar.barHeight)
        bar.layoutIfNeeded()
        let control = bar.renderedKeys.first { $0.accessibilityIdentifier == "terminal.keybar.control" }
        XCTAssertNotNil(control?.longPressAction, "Hold CTRL opens Key Commands")
        XCTAssertEqual(
            control?.longPressDuration,
            KeyCommandPanelViewController.controlHoldDuration
        )
        let escape = bar.renderedKeys.first { $0.accessibilityIdentifier == "terminal.keybar.escape" }
        XCTAssertNil(escape?.longPressAction)
        XCTAssertEqual(control?.accessibilityLabel, "Control", "The tap's label is unchanged")
    }
    #endif

    func testControlHoldIsShorterThanTheKeyboardLockHold() {
        XCTAssertLessThan(KeyCommandPanelViewController.controlHoldDuration, 0.5)
        XCTAssertGreaterThanOrEqual(KeyCommandPanelViewController.controlHoldDuration, 0.25)
        let key = TerminalTallyKeyControl(
            face: .text("CTRL", font: UIKitChassis.monoFont(11, weight: .semibold), kerning: 1.1),
            width: 46,
            height: 34,
            accessibilityLabel: "Control",
            accessibilityIdentifier: "test.control",
            longPressAction: {},
            action: {}
        )
        XCTAssertEqual(key.longPressDuration, 0.5, "The default hold is the keyboard key's lock hold")
        key.longPressDuration = KeyCommandPanelViewController.controlHoldDuration
        // UIKit installs recognizers of its own on a UIControl; the key's is
        // the one carrying the hold it was given.
        let holds = (key.gestureRecognizers ?? [])
            .compactMap { $0 as? UILongPressGestureRecognizer }
            .map(\.minimumPressDuration)
        XCTAssertTrue(
            holds.contains(KeyCommandPanelViewController.controlHoldDuration),
            "The hold recognizer follows longPressDuration: \(holds)"
        )
    }
}
