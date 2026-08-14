import XCTest
@testable import Multiplex

final class TmuxShortcutTests: XCTestCase {
    func testCommonShortcutsUseDefaultPrefixAndExpectedBindings() {
        let expected: [TmuxShortcut: UInt8] = [
            .splitLeftRight: Character("%").asciiValue!,
            .splitTopBottom: Character("\"").asciiValue!,
            .nextPane: Character("o").asciiValue!,
            .togglePaneZoom: Character("z").asciiValue!,
            .copyMode: Character("[").asciiValue!,
            .newWindow: Character("c").asciiValue!,
            .chooseWindow: Character("w").asciiValue!,
            .nextWindow: Character("n").asciiValue!,
            .previousWindow: Character("p").asciiValue!,
            .lastWindow: Character("l").asciiValue!,
            .renameWindow: Character(",").asciiValue!,
        ]

        let safeShortcuts = TmuxShortcut.allCases.filter {
            !$0.requiresDoubleActivation && $0.group != .resize
        }
        XCTAssertEqual(safeShortcuts.count, expected.count)
        for shortcut in safeShortcuts {
            XCTAssertEqual(shortcut.bindingInput, [0x02, expected[shortcut]!])
            XCTAssertFalse(shortcut.command.isEmpty)
        }
    }

    func testResizeRowsNudgeOneCellThroughTheControlPlaneOnly() throws {
        // No count suffix: resize-pane's default adjustment is one cell.
        XCTAssertEqual(
            TmuxShortcut.shortcuts(in: .resize).map(\.command),
            ["resize-pane -L", "resize-pane -D", "resize-pane -U", "resize-pane -R"]
        )
        // The stock chord is prefix + a multi-byte ⌃-arrow, so resize never
        // travels as terminal input — only the active-pane control command.
        XCTAssertNil(TmuxShortcut.resizeLeft.bindingInput)
        XCTAssertEqual(TmuxShortcut.resizeLeft.bindingLabel, "⌃B ⌃←")
        let delivery = try XCTUnwrap(TmuxProbe.shortcutDelivery(
            .resizeLeft, sessionName: "my project"
        ))
        guard case .controlCommand(let command) = delivery else {
            return XCTFail("Panel resize must use its control command")
        }
        XCTAssertTrue(command.contains("tmux -u list-panes -t '=my project'"))
        XCTAssertTrue(command.contains("tmux -u resize-pane -L -t \"$target\""))
        XCTAssertFalse(command.contains("$target\" 1"))

        // The held press goes coarse: tmux's own M-arrow step, as the
        // trailing positional adjustment.
        XCTAssertEqual(TmuxShortcut.coarseResizeCells, 5)
        let coarse = try XCTUnwrap(TmuxProbe.directShortcutCommand(
            .resizeLeft, sessionName: "my project", resizeCells: 5
        ))
        XCTAssertTrue(coarse.contains("tmux -u resize-pane -L -t \"$target\" 5"))
    }

    func testCloseActionsHaveNoTerminalInputAfterUIConfirmation() {
        XCTAssertNil(TmuxShortcut.closePane.bindingInput)
        XCTAssertNil(TmuxShortcut.closeWindow.bindingInput)
        XCTAssertTrue(TmuxShortcut.closePane.requiresDoubleActivation)
        XCTAssertTrue(TmuxShortcut.closeWindow.requiresDoubleActivation)
        XCTAssertEqual(TmuxShortcut.closePane.bindingLabel, "2×")
        XCTAssertEqual(TmuxShortcut.closeWindow.bindingLabel, "2×")
    }

    func testSplitActionsUseDirectIDTargetedControlCommandsOnEveryTransport() throws {
        let leftRight = try XCTUnwrap(TmuxProbe.directShortcutCommand(
            .splitLeftRight, sessionName: "my project"
        ))
        XCTAssertTrue(leftRight.contains("tmux -u list-panes -t '=my project'"))
        XCTAssertTrue(leftRight.contains("#{?pane_active,#{pane_id},}"))
        XCTAssertTrue(leftRight.contains("tmux -u split-window -h -t \"$target\""))
        XCTAssertTrue(leftRight.contains("-c '#{pane_current_path}'"))
        XCTAssertFalse(leftRight.contains("send-keys"))

        let topBottom = try XCTUnwrap(TmuxProbe.directShortcutCommand(
            .splitTopBottom, sessionName: "my project"
        ))
        XCTAssertTrue(topBottom.contains("tmux -u split-window -t \"$target\""))
        XCTAssertFalse(topBottom.contains("split-window -h"))
        XCTAssertTrue(topBottom.contains("-c '#{pane_current_path}'"))

        // These stock bindings remain useful as documentation and for physical
        // keyboard input, but panel dispatch must prefer the commands above.
        XCTAssertNotNil(TmuxShortcut.splitLeftRight.bindingInput)
        XCTAssertNotNil(TmuxShortcut.splitTopBottom.bindingInput)

        let leftDelivery = try XCTUnwrap(TmuxProbe.shortcutDelivery(
            .splitLeftRight, sessionName: "my project"
        ))
        guard case .controlCommand(let deliveredLeftRight) = leftDelivery else {
            return XCTFail("Panel split must prefer its control command")
        }
        XCTAssertEqual(deliveredLeftRight, leftRight)

        let topDelivery = try XCTUnwrap(TmuxProbe.shortcutDelivery(
            .splitTopBottom, sessionName: "my project"
        ))
        guard case .controlCommand(let deliveredTopBottom) = topDelivery else {
            return XCTFail("Panel split must prefer its control command")
        }
        XCTAssertEqual(deliveredTopBottom, topBottom)
    }

    func testOnlySplitsResizesAndConfirmedClosesHaveDirectControlCommands() {
        let expected: Set<TmuxShortcut> = [
            .splitLeftRight, .splitTopBottom, .closePane, .closeWindow,
            .resizeLeft, .resizeDown, .resizeUp, .resizeRight,
        ]
        let actual = Set(TmuxShortcut.allCases.filter {
            TmuxProbe.directShortcutCommand($0, sessionName: "main") != nil
        })
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(
            TmuxProbe.shortcutDelivery(.copyMode, sessionName: "main"),
            .terminalInput([0x02, Character("[").asciiValue!])
        )
    }

    func testCloseActionsUseDirectIDTargetedControlCommands() throws {
        let pane = try XCTUnwrap(TmuxProbe.directShortcutCommand(
            .closePane, sessionName: "my project"
        ))
        XCTAssertTrue(pane.contains("tmux -u list-panes -t '=my project'"))
        XCTAssertTrue(pane.contains("#{?pane_active,#{pane_id},}"))
        XCTAssertTrue(pane.contains("tmux -u kill-pane -t \"$target\""))
        XCTAssertFalse(pane.contains("send-keys"))

        let window = try XCTUnwrap(TmuxProbe.directShortcutCommand(
            .closeWindow, sessionName: "my project"
        ))
        XCTAssertTrue(window.contains("tmux -u list-windows -t '=my project'"))
        XCTAssertTrue(window.contains("#{?window_active,#{window_id},}"))
        XCTAssertTrue(window.contains("tmux -u kill-window -t \"$target\""))
        XCTAssertFalse(window.contains("send-keys"))

        XCTAssertNil(TmuxProbe.directShortcutCommand(
            .copyMode, sessionName: "main"
        ))
    }

    func testOnlyMovementRowsLeaveThePanelOpen() {
        XCTAssertEqual(
            Set(TmuxShortcut.allCases.filter(\.keepsPanelOpen)),
            [
                .nextPane, .togglePaneZoom, .nextWindow, .previousWindow, .lastWindow,
                .resizeLeft, .resizeDown, .resizeUp, .resizeRight,
            ]
        )
        // Anything that leaves you looking at the terminal — a new pane, a
        // prompt, a mode, a close — must uncover it.
        for shortcut in [
            TmuxShortcut.splitLeftRight, .splitTopBottom, .copyMode, .closePane,
            .newWindow, .chooseWindow, .renameWindow, .closeWindow,
        ] {
            XCTAssertFalse(shortcut.keepsPanelOpen, "\(shortcut) should dismiss")
            XCTAssertFalse(
                ShortcutPanelItem(shortcut).keepsPanelOpen,
                "\(shortcut) should dismiss through the panel item too"
            )
        }
        XCTAssertTrue(ShortcutPanelItem(TmuxShortcut.nextWindow).keepsPanelOpen)
    }

    func testEveryShortcutAppearsInExactlyOneMenuGroup() {
        let grouped = TmuxShortcut.Group.allCases.flatMap(TmuxShortcut.shortcuts(in:))

        XCTAssertEqual(TmuxShortcut.Group.allCases, [.panes, .resize, .windows])
        XCTAssertEqual(grouped.count, TmuxShortcut.allCases.count)
        XCTAssertEqual(Set(grouped), Set(TmuxShortcut.allCases))
        XCTAssertEqual(TmuxShortcut.copyMode.group, .panes)
    }
}
