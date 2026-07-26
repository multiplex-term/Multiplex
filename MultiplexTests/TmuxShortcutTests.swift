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

        let safeShortcuts = TmuxShortcut.allCases.filter { !$0.requiresDoubleActivation }
        XCTAssertEqual(safeShortcuts.count, expected.count)
        for shortcut in safeShortcuts {
            XCTAssertEqual(shortcut.bindingInput, [0x02, expected[shortcut]!])
            XCTAssertFalse(shortcut.command.isEmpty)
        }
    }

    func testCloseActionsHaveNoTerminalInputAfterUIConfirmation() {
        XCTAssertNil(TmuxShortcut.closePane.bindingInput)
        XCTAssertNil(TmuxShortcut.closeWindow.bindingInput)
        XCTAssertTrue(TmuxShortcut.closePane.requiresDoubleActivation)
        XCTAssertTrue(TmuxShortcut.closeWindow.requiresDoubleActivation)
        XCTAssertEqual(TmuxShortcut.closePane.bindingLabel, "2×")
        XCTAssertEqual(TmuxShortcut.closeWindow.bindingLabel, "2×")
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

    func testEveryShortcutAppearsInExactlyOneMenuGroup() {
        let grouped = TmuxShortcut.Group.allCases.flatMap(TmuxShortcut.shortcuts(in:))

        XCTAssertEqual(TmuxShortcut.Group.allCases, [.panes, .windows])
        XCTAssertEqual(grouped.count, TmuxShortcut.allCases.count)
        XCTAssertEqual(Set(grouped), Set(TmuxShortcut.allCases))
        XCTAssertEqual(TmuxShortcut.copyMode.group, .panes)
    }
}
