import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class ShortcutPanelUIKitTests: XCTestCase {
    func testNativePanelRendersEveryGroupedShortcutWithTallySizingAndAccessibility() throws {
        let controller = ShortcutPanelViewController(content: .tmux, select: { _ in })
        controller.loadViewIfNeeded()

        let controls = descendants(of: UIControl.self, in: controller.view)
            .filter { $0.accessibilityIdentifier?.hasPrefix("tmuxShortcut.") == true }
        XCTAssertEqual(controls.count, TmuxShortcut.allCases.count)

        let headers = descendants(of: UIKitChassisLabel.self, in: controller.view)
            .filter { $0.accessibilityTraits.contains(.header) }
            .compactMap(\.accessibilityLabel)
        XCTAssertEqual(headers, ["TMUX SHORTCUTS", "Panes", "Resize Pane", "Windows"])

        let size = controller.fittingContentSize()
        XCTAssertEqual(size.width, ShortcutPanelViewController.preferredWidth)
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

        // Resize is a compact row: an arrow-to-bar SF Symbol face, with the
        // full story left to assistive tech.
        let resizeLeft = try XCTUnwrap(
            control("tmuxShortcut.resizeLeft", in: controller.view)
        )
        XCTAssertEqual(
            resizeLeft.accessibilityLabel,
            "Resize Left, resize-pane -L, ⌃B ⌃←"
        )
        XCTAssertEqual(
            descendants(of: UIImageView.self, in: resizeLeft).first?.image,
            UIImage(systemName: "arrow.left.to.line")
        )
    }

    func testSafeShortcutSelectsImmediatelyAndDestructiveShortcutRequiresSecondPress() throws {
        var selected: [ShortcutPanelItem] = []
        let controller = ShortcutPanelViewController(content: .tmux) {
            selected.append($0)
        }
        controller.loadViewIfNeeded()

        let copyMode = try XCTUnwrap(control("tmuxShortcut.copyMode", in: controller.view))
        copyMode.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected.map(\.payload), [.tmux(.copyMode)])

        // A resize press selects immediately — repeated taps keep nudging.
        let resizeUp = try XCTUnwrap(control("tmuxShortcut.resizeUp", in: controller.view))
        resizeUp.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected.map(\.payload), [.tmux(.copyMode), .tmux(.resizeUp)])
        selected = []

        let closeWindow = try XCTUnwrap(
            control("tmuxShortcut.closeWindow", in: controller.view)
        )
        closeWindow.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, [])
        XCTAssertEqual(
            closeWindow.accessibilityLabel,
            "Close Window, press again to close"
        )
        XCTAssertTrue(renderedText(in: closeWindow).contains("press again to close"))
        XCTAssertTrue(renderedText(in: closeWindow).contains("AGAIN"))

        closeWindow.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected.map(\.payload), [.tmux(.closeWindow)])
        XCTAssertEqual(
            closeWindow.accessibilityLabel,
            "Close Window, kill-window, press twice to confirm"
        )
    }

    func testHoldingAResizeRowRepeatsCoarseStepsAndSwallowsItsRelease() async throws {
        var selected: [ShortcutPanelItem] = []
        var coarse: [ShortcutPanelItem] = []
        let controller = ShortcutPanelViewController(
            content: .tmux,
            select: { selected.append($0) },
            selectCoarse: { coarse.append($0) }
        )
        controller.loadViewIfNeeded()
        let resizeUp = try XCTUnwrap(control("tmuxShortcut.resizeUp", in: controller.view))

        // Hold: one coarse step after the delay, another after the repeat
        // interval, and the release adds no fine step on top.
        resizeUp.sendActions(for: .touchDown)
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(coarse.map(\.payload), [.tmux(.resizeUp)])
        try await Task.sleep(nanoseconds: 1_250_000_000)
        XCTAssertEqual(coarse.count, 2)
        resizeUp.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, [])

        // A quick tap still nudges one fine cell and never goes coarse.
        resizeUp.sendActions(for: .touchDown)
        resizeUp.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected.map(\.payload), [.tmux(.resizeUp)])
        XCTAssertEqual(coarse.count, 2)
    }

    func testHerdrCloseRowsCarryTheirPayloadThroughTheSameConfirmation() throws {
        var selected: [ShortcutPanelItem] = []
        let controller = ShortcutPanelViewController(content: .herdr) {
            selected.append($0)
        }
        controller.loadViewIfNeeded()

        let closeTab = try XCTUnwrap(control("herdrShortcut.closeTab", in: controller.view))
        closeTab.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, [])
        closeTab.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected.map(\.payload), [.herdr(.closeTab)])
    }

    func testWindowChoicesOnlyRenderWhenSwitchingIsUsefulAndSelectionDisarmsClose() throws {
        var selectedChoice: TmuxWindowChoice?
        let controller = ShortcutPanelViewController(
            content: .tmux,
            select: { _ in },
            selectChoice: { selectedChoice = $0 }
        )
        controller.loadViewIfNeeded()
        let baseHeight = controller.fittingContentSize().height

        controller.applyChoices([
            TmuxWindowChoice(tmuxID: "@1", index: 0, isActive: true, name: "main")
        ])
        XCTAssertNil(control("tmuxWindow.@1", in: controller.view))
        XCTAssertEqual(controller.fittingContentSize().height, baseHeight)

        let choices = [
            TmuxWindowChoice(tmuxID: "@1", index: 0, isActive: true, name: "main"),
            TmuxWindowChoice(tmuxID: "@2", index: 1, isActive: false, name: "deploy"),
        ]
        controller.applyChoices(choices)
        XCTAssertGreaterThan(controller.fittingContentSize().height, baseHeight)

        let active = try XCTUnwrap(control("tmuxWindow.@1", in: controller.view))
        XCTAssertEqual(active.accessibilityLabel, "Window 0, main, current window")
        let deploy = try XCTUnwrap(control("tmuxWindow.@2", in: controller.view))
        XCTAssertEqual(deploy.accessibilityLabel, "Switch to window 1, deploy")

        let closePane = try XCTUnwrap(control("tmuxShortcut.closePane", in: controller.view))
        closePane.sendActions(for: .touchUpInside)
        XCTAssertEqual(closePane.accessibilityLabel, "Close Pane, press again to close")

        deploy.sendActions(for: .touchUpInside)
        XCTAssertEqual(selectedChoice, choices[1])
        XCTAssertEqual(
            closePane.accessibilityLabel,
            "Close Pane, kill-pane, press twice to confirm"
        )

        // The panel survives a switch, so the ACTIVE marker has to move with
        // the selection rather than wait for a reopen.
        XCTAssertEqual(deploy.accessibilityLabel, "Window 1, deploy, current window")
        XCTAssertEqual(active.accessibilityLabel, "Switch to window 0, main")
        XCTAssertEqual(visibleText(in: deploy).filter { $0 == "ACTIVE" }.count, 1)
        XCTAssertTrue(visibleText(in: active).allSatisfy { $0 != "ACTIVE" })
    }

    func testManyWindowsUseCappedInternalScrollRegion() {
        let controller = ShortcutPanelViewController(content: .tmux, select: { _ in })
        controller.loadViewIfNeeded()
        controller.applyChoices((0..<9).map {
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

    private func visibleText(in root: UIView) -> [String] {
        descendants(of: UILabel.self, in: root)
            .filter { !$0.isHidden }
            .compactMap { $0.text ?? $0.attributedText?.string }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }
}
