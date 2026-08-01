import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class TmuxShortcutPanelUIKitTests: XCTestCase {
    func testNativePanelRendersEveryGroupedShortcutWithTallySizingAndAccessibility() throws {
        let controller = TmuxShortcutPanelViewController(select: { _ in })
        controller.loadViewIfNeeded()

        let controls = descendants(of: UIControl.self, in: controller.view)
            .filter { $0.accessibilityIdentifier?.hasPrefix("tmuxShortcut.") == true }
        XCTAssertEqual(controls.count, TmuxShortcut.allCases.count)

        let headers = descendants(of: UIKitChassisLabel.self, in: controller.view)
            .filter { $0.accessibilityTraits.contains(.header) }
            .compactMap(\.accessibilityLabel)
        XCTAssertEqual(headers, ["TMUX SHORTCUTS", "Panes", "Windows"])

        let size = controller.fittingContentSize()
        XCTAssertEqual(size.width, TmuxShortcutPanelViewController.preferredWidth)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertEqual(controller.preferredContentSize, size)

        let copyMode = try XCTUnwrap(control("tmuxShortcut.copyMode", in: controller.view))
        XCTAssertEqual(
            copyMode.accessibilityLabel,
            "Copy Mode, copy-mode, ⌃B ["
        )
        XCTAssertTrue(copyMode.accessibilityTraits.contains(.button))

        let closePane = try XCTUnwrap(control("tmuxShortcut.closePane", in: controller.view))
        XCTAssertEqual(
            closePane.accessibilityLabel,
            "Close Pane, kill-pane, press twice to confirm"
        )
    }

    func testSafeShortcutSelectsImmediatelyAndDestructiveShortcutRequiresSecondPress() throws {
        var selected: [TmuxShortcut] = []
        let controller = TmuxShortcutPanelViewController {
            selected.append($0)
        }
        controller.loadViewIfNeeded()

        let copyMode = try XCTUnwrap(control("tmuxShortcut.copyMode", in: controller.view))
        copyMode.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, [.copyMode])

        let closeWindow = try XCTUnwrap(
            control("tmuxShortcut.closeWindow", in: controller.view)
        )
        closeWindow.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, [.copyMode])
        XCTAssertEqual(
            closeWindow.accessibilityLabel,
            "Close Window, press again to close"
        )
        XCTAssertTrue(renderedText(in: closeWindow).contains("press again to close"))
        XCTAssertTrue(renderedText(in: closeWindow).contains("AGAIN"))

        closeWindow.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, [.copyMode, .closeWindow])
        XCTAssertEqual(
            closeWindow.accessibilityLabel,
            "Close Window, kill-window, press twice to confirm"
        )
    }

    func testWindowChoicesOnlyRenderWhenSwitchingIsUsefulAndSelectionDisarmsClose() throws {
        var selectedWindow: TmuxWindowChoice?
        let controller = TmuxShortcutPanelViewController(
            select: { _ in },
            selectWindow: { selectedWindow = $0 }
        )
        controller.loadViewIfNeeded()
        let baseHeight = controller.fittingContentSize().height

        controller.applyWindows([
            TmuxWindowChoice(tmuxID: "@1", index: 0, isActive: true, name: "main")
        ])
        XCTAssertNil(control("tmuxWindow.@1", in: controller.view))
        XCTAssertEqual(controller.fittingContentSize().height, baseHeight)

        let choices = [
            TmuxWindowChoice(tmuxID: "@1", index: 0, isActive: true, name: "main"),
            TmuxWindowChoice(tmuxID: "@2", index: 1, isActive: false, name: "deploy"),
        ]
        controller.applyWindows(choices)
        XCTAssertGreaterThan(controller.fittingContentSize().height, baseHeight)

        let active = try XCTUnwrap(control("tmuxWindow.@1", in: controller.view))
        XCTAssertEqual(active.accessibilityLabel, "Window 0, main, current window")
        let deploy = try XCTUnwrap(control("tmuxWindow.@2", in: controller.view))
        XCTAssertEqual(deploy.accessibilityLabel, "Switch to window 1, deploy")

        let closePane = try XCTUnwrap(control("tmuxShortcut.closePane", in: controller.view))
        closePane.sendActions(for: .touchUpInside)
        XCTAssertEqual(closePane.accessibilityLabel, "Close Pane, press again to close")

        deploy.sendActions(for: .touchUpInside)
        XCTAssertEqual(selectedWindow, choices[1])
        XCTAssertEqual(
            closePane.accessibilityLabel,
            "Close Pane, kill-pane, press twice to confirm"
        )
    }

    func testManyWindowsUseCappedInternalScrollRegion() {
        let controller = TmuxShortcutPanelViewController(select: { _ in })
        controller.loadViewIfNeeded()
        controller.applyWindows((0..<9).map {
            TmuxWindowChoice(
                tmuxID: "@\($0)",
                index: $0,
                isActive: $0 == 0,
                name: "window-\($0)"
            )
        })

        let scroll = descendants(of: UIScrollView.self, in: controller.view)
            .first { $0.accessibilityIdentifier == "tmuxWindowSection.scroll" }
        XCTAssertNotNil(scroll)
        XCTAssertEqual(
            descendants(of: UIControl.self, in: controller.view)
                .filter { $0.accessibilityIdentifier?.hasPrefix("tmuxWindow.") == true }
                .count,
            9
        )
        XCTAssertTrue(scroll?.constraints.contains {
            $0.firstAttribute == .height && $0.constant == 200 && $0.isActive
        } == true)
    }

    private func control(_ identifier: String, in root: UIView) -> UIControl? {
        descendants(of: UIControl.self, in: root).first {
            $0.accessibilityIdentifier == identifier
        }
    }

    private func renderedText(in root: UIView) -> [String] {
        descendants(of: UILabel.self, in: root).compactMap { $0.text ?? $0.attributedText?.string }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }
}
