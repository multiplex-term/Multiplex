import UIKit
import XCTest
@testable import Multiplex

/// iPhone Duo geometry through the shell's pure layout seam (facts in
/// docs/agents/iphone-duo.md).
final class SingleWindowShellDuoLayoutTests: XCTestCase {
    private let sideColumn = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84)
    private let innerPortrait = UIEdgeInsets(top: 82, left: 0, bottom: 34, right: 0)

    func testClosedLandscapeStaysSinglePane() {
        let metrics = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 678, height: 466),
            safeArea: sideColumn,
            verticalSizeClass: .compact,
            idiom: .phone,
            deckRailVisible: true,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false
        )
        XCTAssertFalse(metrics.expanded, "278 pt beside the rail is under the TMUX tier")
        XCTAssertEqual(
            metrics.terminalFrame,
            CGRect(x: 0, y: 0, width: 678, height: 466),
            "compact like any iPhone landscape: flush chrome, no bare-top padding"
        )
        XCTAssertEqual(metrics.terminalRailChrome.cornerInset, 0, "the closed corner is 6 pt: title flush")
        XCTAssertEqual(metrics.deckHeaderChrome.cornerInset, 0)
        XCTAssertEqual(metrics.terminalAvailableWidth, 594)
        XCTAssertNil(metrics.consoleFrame)
    }

    func testOpenLandscapeExpandsWithTheTerminalAboveTheTmuxTier() {
        let metrics = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 951, height: 669),
            safeArea: sideColumn,
            verticalSizeClass: .regular,
            horizontalSizeClass: .regular,
            idiom: .phone,
            deckRailVisible: true,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false,
            foldable: true
        )
        XCTAssertTrue(metrics.expanded)
        XCTAssertEqual(metrics.deckFrame.width, 316)
        XCTAssertEqual(metrics.deckFrame.minY, 8, "bare top edge: 8 pt padding")
        XCTAssertTrue(metrics.railOwnsBottomSafeArea)
        XCTAssertEqual(metrics.terminalFrame.maxY, 669, "the key rail spends the home strip")
        XCTAssertEqual(metrics.deckHeaderChrome.cornerInset, 24, "the deck owns the bare corner")
        XCTAssertEqual(metrics.terminalRailChrome.cornerInset, 0)
        XCTAssertEqual(metrics.terminalFrame.minX, 316)
        XCTAssertEqual(metrics.terminalAvailableWidth, 551)
        XCTAssertGreaterThanOrEqual(
            metrics.terminalAvailableWidth,
            SingleWindowShellLayout.phoneTerminalMinimumWidth
        )
    }

    func testHiddenDeckHandsTheCornerInsetToTheTerminal() {
        let metrics = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 951, height: 669),
            safeArea: sideColumn,
            verticalSizeClass: .regular,
            horizontalSizeClass: .regular,
            idiom: .phone,
            deckRailVisible: false,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false
        )
        XCTAssertTrue(metrics.expanded)
        XCTAssertEqual(metrics.deckFrame.width, 0)
        XCTAssertEqual(metrics.terminalFrame, CGRect(x: 0, y: 8, width: 951, height: 627))
        XCTAssertEqual(metrics.terminalAvailableWidth, 867)
        XCTAssertEqual(metrics.terminalRailChrome.cornerInset, 24)
        XCTAssertEqual(metrics.deckHeaderChrome.cornerInset, 0)
    }

    func testOpenPortraitStaysSinglePane() {
        let metrics = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 669, height: 951),
            safeArea: innerPortrait,
            verticalSizeClass: .regular,
            horizontalSizeClass: .regular,
            idiom: .phone,
            deckRailVisible: true,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false
        )
        XCTAssertFalse(metrics.expanded, "353 pt beside the rail is under the TMUX tier")
        XCTAssertEqual(metrics.terminalFrame.width, 669)
        // The 82 pt status band is the terminal's: its rail rides inside it.
        XCTAssertEqual(metrics.terminalFrame.minY, 0)
        XCTAssertEqual(metrics.terminalRailChrome.bandHeight, 82)
        XCTAssertEqual(metrics.terminalRailChrome.bandTrailingClearance, 128)
        XCTAssertEqual(metrics.terminalRailChrome.cornerInset, 0, "the status bar already clears the corner")
        XCTAssertNil(metrics.consoleFrame)
    }

    func testBookPoseGivesOnePageEachAndTheFoldIsTheDivider() {
        let fold = DuoFoldGeometry.syntheticDivision(in: CGSize(width: 951, height: 669))
        XCTAssertEqual(fold, CGRect(x: 455.5, y: 0, width: 40, height: 669))
        for railVisible in [true, false] {
            let metrics = SingleWindowShellNativeLayout.resolve(
                size: CGSize(width: 951, height: 669),
                safeArea: sideColumn,
                verticalSizeClass: .regular,
                idiom: .phone,
                division: fold,
                deckRailVisible: railVisible,
                compactShowsTerminal: true,
                compactBackSwipeOffset: 0,
                compactBackSwipeActive: false
            )
            XCTAssertTrue(metrics.expanded, "railVisible=\(railVisible)")
            XCTAssertEqual(metrics.deckFrame.width, 455.5)
            XCTAssertEqual(metrics.terminalFrame.minX, 495.5)
            XCTAssertEqual(metrics.terminalFrame.width, 455.5)
            XCTAssertEqual(metrics.terminalAvailableWidth, 371.5)
            XCTAssertEqual(metrics.dividerFrame.minX, 455.5)
            XCTAssertEqual(metrics.dividerFrame.width, 40)
            XCTAssertTrue(metrics.deckInteractive)
        }
    }

    func testLaptopPoseStopsTheTerminalAtTheFoldAndHandsTheRestToTheConsole() {
        let fold = DuoFoldGeometry.syntheticDivision(in: CGSize(width: 669, height: 951))
        XCTAssertEqual(fold, CGRect(x: 0, y: 455.5, width: 669, height: 40))
        let metrics = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 669, height: 951),
            safeArea: innerPortrait,
            verticalSizeClass: .regular,
            idiom: .phone,
            division: fold,
            deckRailVisible: true,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false
        )
        XCTAssertFalse(metrics.expanded)
        XCTAssertEqual(metrics.terminalFrame.minY, 82)
        XCTAssertEqual(metrics.terminalFrame.maxY, 455.5)
        XCTAssertEqual(metrics.consoleFrame, CGRect(x: 0, y: 495.5, width: 669, height: 455.5))
        // The console region is the deck's (a column panel takes it over).
        XCTAssertEqual(metrics.deckFrame, metrics.consoleFrame)
        XCTAssertEqual(metrics.deckAlpha, 1)
        XCTAssertTrue(metrics.deckInteractive)
        XCTAssertTrue(metrics.terminalInteractive)
        XCTAssertEqual(metrics.deckSafeArea.bottom, 34)
        XCTAssertEqual(metrics.deckHeaderChrome.cornerInset, 0)
    }

    func testTheDeckAloneMaySpanTheFold() {
        let fold = DuoFoldGeometry.syntheticDivision(in: CGSize(width: 669, height: 951))
        let metrics = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 669, height: 951),
            safeArea: innerPortrait,
            verticalSizeClass: .regular,
            idiom: .phone,
            division: fold,
            deckRailVisible: true,
            compactShowsTerminal: false,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false
        )
        XCTAssertEqual(metrics.deckFrame.height, 951 - 82)
        XCTAssertNil(metrics.consoleFrame)
    }
}
