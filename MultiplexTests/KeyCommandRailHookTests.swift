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
        let holdRecognizers = (control?.gestureRecognizers ?? [])
            .compactMap { $0 as? UILongPressGestureRecognizer }
        let holdRecognizer = holdRecognizers.first { $0.minimumPressDuration == hold }
        XCTAssertNotNil(
            holdRecognizer,
            "The hold recognizer follows longPressDuration: \(holdRecognizers.map(\.minimumPressDuration))"
        )
        XCTAssertTrue(
            holdRecognizer?.cancelsTouchesInView == true,
            "Once the hold wins, UIKit must cancel the CTRL tap at its source"
        )
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

    func testKeyCommandsRetireAnOpenQuickCombo() throws {
        let context = TerminalKeyClusterContext()
        let group = TerminalKeyClusterGroupView(
            role: .leading,
            metric: .regular,
            context: context
        )
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.addSubview(group)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        group.showCtrlCombos()
        XCTAssertTrue(group.ctrlCombosArePresentedForTesting)
        group.showKeyCommands()
        XCTAssertFalse(
            group.ctrlCombosArePresentedForTesting,
            "The held-CTRL surface replaces the tap's C / B surface"
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

    func testKeyCommandsRetireAnOpenQuickCombo() throws {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let bar = TerminalKeyBar(
            terminal: terminal,
            controller: nil,
            performShortcut: { _ in },
            finishTmuxCopyMode: {},
            shortcutBackend: .tmux
        )
        bar.frame = CGRect(x: 0, y: 0, width: 600, height: TerminalKeyBar.barHeight)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.addSubview(bar)
        bar.layoutIfNeeded()
        let control = try XCTUnwrap(
            bar.renderedKeys.first {
                $0.accessibilityIdentifier == "terminal.keybar.control"
            }
        )

        control.sendActions(for: .touchDown)
        control.sendActions(for: .touchUpInside)
        XCTAssertTrue(bar.ctrlCombosArePresentedForTesting)
        control.longPressAction?()
        XCTAssertFalse(
            bar.ctrlCombosArePresentedForTesting,
            "The held-CTRL surface replaces the tap's C / B surface"
        )
    }
    #endif
}
