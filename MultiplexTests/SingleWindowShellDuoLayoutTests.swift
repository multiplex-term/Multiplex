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

    private func bookPose(deckRailVisible: Bool) -> SingleWindowShellLayoutMetrics {
        SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 951, height: 669),
            safeArea: sideColumn,
            verticalSizeClass: .regular,
            horizontalSizeClass: .regular,
            idiom: .phone,
            division: DuoFoldGeometry.syntheticDivision(in: CGSize(width: 951, height: 669)),
            deckRailVisible: deckRailVisible,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false,
            foldable: true
        )
    }

    func testBookPoseGivesOnePageEachAndTheFoldIsTheDivider() {
        XCTAssertEqual(
            DuoFoldGeometry.syntheticDivision(in: CGSize(width: 951, height: 669)),
            CGRect(x: 455.5, y: 0, width: 40, height: 669)
        )
        let metrics = bookPose(deckRailVisible: true)
        XCTAssertTrue(metrics.expanded)
        XCTAssertTrue(metrics.deckToggles)
        XCTAssertEqual(metrics.deckFrame.width, 455.5)
        XCTAssertEqual(metrics.terminalFrame.minX, 495.5)
        XCTAssertEqual(metrics.terminalFrame.width, 455.5)
        XCTAssertEqual(metrics.terminalAvailableWidth, 371.5)
        XCTAssertEqual(metrics.dividerFrame.minX, 455.5)
        XCTAssertEqual(metrics.dividerFrame.width, 40)
        XCTAssertTrue(metrics.deckInteractive)
        XCTAssertTrue(metrics.hasDeckColumn)
    }

    func testBookPoseHidesTheDeckAndTheTerminalSpansTheFold() {
        let metrics = bookPose(deckRailVisible: false)
        XCTAssertTrue(metrics.expanded)
        XCTAssertTrue(metrics.deckToggles)
        XCTAssertEqual(metrics.deckFrame.width, 0)
        XCTAssertEqual(metrics.terminalFrame, CGRect(x: 0, y: 8, width: 951, height: 661))
        XCTAssertEqual(metrics.terminalAvailableWidth, 867)
        XCTAssertFalse(metrics.hasDeckColumn, "no divider on the fold")
        XCTAssertFalse(metrics.deckInteractive)
        XCTAssertFalse(metrics.columnAvailable)
    }

    func testLaptopPoseKeepsTheStatusBandOffTheConsoleDeck() {
        let metrics = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 669, height: 951),
            safeArea: innerPortrait,
            verticalSizeClass: .regular,
            horizontalSizeClass: .regular,
            idiom: .phone,
            division: DuoFoldGeometry.syntheticDivision(in: CGSize(width: 669, height: 951)),
            deckRailVisible: true,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false
        )
        XCTAssertEqual(metrics.terminalRailChrome.bandHeight, 82)
        XCTAssertEqual(metrics.deckHeaderChrome.bandHeight, 0, "the console deck is below the fold")
        XCTAssertTrue(metrics.deckHeaderChrome.flushTop)
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
        XCTAssertTrue(metrics.deckToggles)
        XCTAssertTrue(metrics.deckInteractive)
        XCTAssertTrue(metrics.terminalInteractive)
        XCTAssertEqual(metrics.deckSafeArea.bottom, 34)
        XCTAssertEqual(metrics.deckHeaderChrome.cornerInset, 0)
    }

    func testLaptopPoseHidesTheConsoleDeckAndTheTerminalSpansTheFold() {
        let metrics = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 669, height: 951),
            safeArea: innerPortrait,
            verticalSizeClass: .regular,
            horizontalSizeClass: .regular,
            idiom: .phone,
            division: DuoFoldGeometry.syntheticDivision(in: CGSize(width: 669, height: 951)),
            deckRailVisible: false,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false,
            foldable: true
        )
        XCTAssertTrue(metrics.deckToggles)
        XCTAssertNil(metrics.consoleFrame)
        XCTAssertEqual(metrics.terminalFrame, CGRect(x: 0, y: 0, width: 669, height: 951))
        XCTAssertEqual(metrics.deckAlpha, 0)
        XCTAssertFalse(metrics.deckInteractive)
        XCTAssertFalse(metrics.columnAvailable)
    }

    func testAFoldCountsOnlyWhenItCrossesTheWindow() {
        let screen = CGSize(width: 951, height: 669)
        XCTAssertEqual(
            DuoFoldGeometry.syntheticDivision(screen: screen, window: CGRect(origin: .zero, size: screen)),
            CGRect(x: 455.5, y: 0, width: 40, height: 669),
            "the whole display: the book fold"
        )
        XCTAssertNil(
            DuoFoldGeometry.syntheticDivision(screen: screen, window: CGRect(x: 0, y: 0, width: 455.5, height: 669)),
            "Split View's left half ends at the fold"
        )
        let rightHalf = CGRect(x: 495.5, y: 0, width: 455.5, height: 669)
        XCTAssertNil(
            DuoFoldGeometry.syntheticDivision(screen: screen, window: rightHalf),
            "and the right half starts after it"
        )
        let runsOff = CGRect(x: 440, y: 0, width: 40, height: 669)
        XCTAssertNil(
            DuoFoldGeometry.division(runsOff, in: CGRect(x: 0, y: 0, width: 455, height: 669)),
            "a reported band that runs off the window is not a fold across it"
        )
        XCTAssertNil(
            DuoFoldGeometry.division(
                CGRect(x: 0, y: 0, width: 13.5, height: 669),
                in: CGRect(x: 0, y: 0, width: 469, height: 669)
            ),
            "the right half is reported the band clipped to its edge"
        )
        XCTAssertEqual(
            DuoFoldGeometry.division(
                CGRect(x: 455.5, y: 0, width: 40, height: 669),
                in: CGRect(x: 0, y: 0, width: 951, height: 669)
            ),
            CGRect(x: 455.5, y: 0, width: 40, height: 669)
        )
    }

    func testSplitViewHalfOnTheInnerDisplayIsASinglePaneShell() {
        let metrics = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 455, height: 669),
            safeArea: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0),
            verticalSizeClass: .regular,
            horizontalSizeClass: .compact,
            idiom: .phone,
            division: nil,
            deckRailVisible: true,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false,
            foldable: true
        )
        XCTAssertFalse(metrics.expanded)
        XCTAssertFalse(metrics.deckToggles, "‹ DECK, the iPhone's back control")
        XCTAssertEqual(metrics.terminalFrame.width, 455, "the terminal takes the whole half")
        XCTAssertEqual(metrics.terminalAlpha, 1)
    }

    func testTheLeftSplitHalfOwnsTheDisplayCornerTheRightHalfDoesNot() {
        func half(ownsCorner: Bool) -> SingleWindowShellLayoutMetrics {
            SingleWindowShellNativeLayout.resolve(
                size: CGSize(width: 469, height: 669),
                safeArea: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: ownsCorner ? 0 : 84),
                verticalSizeClass: .regular,
                horizontalSizeClass: .compact,
                idiom: .phone,
                deckRailVisible: true,
                compactShowsTerminal: true,
                compactBackSwipeOffset: 0,
                compactBackSwipeActive: false,
                foldable: true,
                displayHorizontalSizeClass: .regular,
                ownsLeadingDisplayCorner: ownsCorner
            )
        }
        let left = half(ownsCorner: true)
        XCTAssertEqual(left.terminalRailChrome.cornerInset, 24, "the rail clears the rounded corner")
        XCTAssertEqual(left.terminalFrame.minY, 8, "the display's bare top edge")
        let right = half(ownsCorner: false)
        XCTAssertEqual(right.terminalRailChrome.cornerInset, 0, "its leading edge is the fold")
        XCTAssertEqual(right.terminalFrame.minY, 8)
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
        XCTAssertFalse(metrics.deckToggles, "‹ BACK, not ◧ SHOW: no terminal to return to")
    }
}
