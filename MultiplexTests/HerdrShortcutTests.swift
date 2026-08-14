import XCTest
@testable import Multiplex

/// Pins the HRDR panel's shortcut set to herdr 0.7.5's default keybindings
/// (`herdr --default-config`; split/zoom/detach exercised against a real TUI
/// attach 2026-08-02). herdr's default prefix is Control-B — the same 0x02
/// tmux uses — and Shift-modified defaults ride as the uppercase byte.
final class HerdrShortcutTests: XCTestCase {
    func testShortcutsUseTheDefaultPrefixAndVerifiedBindings() {
        let expected: [HerdrShortcut: UInt8] = [
            .splitLeftRight: Character("v").asciiValue!,
            .splitTopBottom: Character("-").asciiValue!,
            .newTab: Character("c").asciiValue!,
            .newWorkspace: Character("N").asciiValue!,
            .renameWorkspace: Character("W").asciiValue!,
        ]

        let safeShortcuts = HerdrShortcut.allCases.filter { !$0.requiresDoubleActivation }
        XCTAssertEqual(safeShortcuts.count, expected.count)
        for shortcut in safeShortcuts {
            XCTAssertEqual(shortcut.bindingInput, [0x02, expected[shortcut]!],
                           "\(shortcut) must send prefix + its stock key")
            XCTAssertFalse(shortcut.command.isEmpty)
        }
    }

    func testBindingLabelsSpellShiftHonestly() {
        XCTAssertEqual(HerdrShortcut.splitLeftRight.bindingLabel, "⌃B V")
        XCTAssertEqual(HerdrShortcut.splitTopBottom.bindingLabel, "⌃B -")
        XCTAssertEqual(HerdrShortcut.newWorkspace.bindingLabel, "⌃B ⇧N")
        XCTAssertEqual(HerdrShortcut.renameWorkspace.bindingLabel, "⌃B ⇧W")
    }

    func testCloseActionsHaveNoTerminalInputAfterUIConfirmation() {
        for (shortcut, scope) in [
            (HerdrShortcut.closePane, HerdrShortcut.CloseScope.pane),
            (.closeTab, .tab),
            (.closeWorkspace, .workspace),
        ] {
            XCTAssertNil(shortcut.bindingInput)
            XCTAssertTrue(shortcut.requiresDoubleActivation)
            XCTAssertEqual(shortcut.bindingLabel, "2×")
            XCTAssertEqual(shortcut.closeScope, scope)
        }
        XCTAssertNil(HerdrShortcut.splitLeftRight.closeScope)
    }

    func testCommandsAreTheConfigActionNames() {
        // The subtext doubles as the `[keys]` rebinding reference — it must
        // spell herdr's own action names, not invented prose.
        XCTAssertEqual(HerdrShortcut.splitLeftRight.command, "split_vertical")
        XCTAssertEqual(HerdrShortcut.splitTopBottom.command, "split_horizontal")
        XCTAssertEqual(HerdrShortcut.renameWorkspace.command, "rename_workspace")
        XCTAssertEqual(HerdrShortcut.closeWorkspace.command, "close_workspace")
    }

    func testCuratedRowsDismissThePanel() {
        XCTAssertTrue(HerdrShortcut.allCases.allSatisfy { !$0.keepsPanelOpen })
        XCTAssertFalse(ShortcutPanelItem(HerdrShortcut.newTab).keepsPanelOpen)
        XCTAssertFalse(ShortcutPanelItem(HerdrShortcut.closeTab).keepsPanelOpen)
    }

    func testEveryShortcutAppearsInExactlyOneMenuGroup() {
        let grouped = HerdrShortcut.Group.allCases.flatMap(HerdrShortcut.shortcuts(in:))

        XCTAssertEqual(HerdrShortcut.Group.allCases, [.panes, .tabs, .workspaces])
        XCTAssertEqual(grouped.count, HerdrShortcut.allCases.count)
        XCTAssertEqual(Set(grouped), Set(HerdrShortcut.allCases))
        XCTAssertEqual(HerdrShortcut.splitLeftRight.group, .panes)
        XCTAssertEqual(HerdrShortcut.newTab.group, .tabs)
        XCTAssertEqual(HerdrShortcut.renameWorkspace.group, .workspaces)
    }
}
