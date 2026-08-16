import SwiftTerm
import UIKit
import XCTest
@testable import Multiplex

/// The rail's CTRL key carries the Key Commands hold on both platforms —
/// shorter than the keyboard key's lock hold, and separate from the tap
/// that latches.
@MainActor
final class KeyCommandRailHookTests: XCTestCase {
    private func assertControlKeyHoldsIntoKeyCommands(
        control: TerminalTallyKeyControl?,
        escape: TerminalTallyKeyControl?
    ) {
        XCTAssertNotNil(control?.longPressAction, "Hold CTRL opens Key Commands")
        XCTAssertNil(escape?.longPressAction)
        let hold = KeyCommandPanelViewController.controlHoldDuration
        XCTAssertEqual(control?.longPressDuration, hold)
        XCTAssertLessThan(hold, 0.5, "Shorter than the keyboard key's lock hold")
        XCTAssertGreaterThanOrEqual(hold, 0.25)
        // UIKit installs recognizers of its own on a UIControl; the key's is
        // the one carrying the hold it was given.
        let holds = (control?.gestureRecognizers ?? [])
            .compactMap { $0 as? UILongPressGestureRecognizer }
            .map(\.minimumPressDuration)
        XCTAssertTrue(holds.contains(hold), "The hold recognizer follows longPressDuration: \(holds)")
    }

    #if os(visionOS)
    func testClusterControlKeyHoldsIntoKeyCommands() {
        let context = TerminalKeyClusterContext()
        let group = TerminalKeyClusterGroupView(role: .leading, metric: .regular, context: context)
        assertControlKeyHoldsIntoKeyCommands(
            control: group.keys.first { $0.accessibilityIdentifier == "terminal.keyCluster.control" },
            escape: group.keys.first { $0.accessibilityIdentifier == "terminal.keyCluster.escape" }
        )
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
        assertControlKeyHoldsIntoKeyCommands(
            control: control,
            escape: bar.renderedKeys.first { $0.accessibilityIdentifier == "terminal.keybar.escape" }
        )
        XCTAssertEqual(control?.accessibilityLabel, "Control", "The tap's label is unchanged")
    }
    #endif
}
