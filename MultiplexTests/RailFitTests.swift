import XCTest
@testable import Multiplex

final class RailFitTests: XCTestCase {
    // MARK: Row

    private let widths: [RailItem: CGFloat] = [
        .fontDown: 34, .fontUp: 34, .newTab: 60, .file: 52, .shortcut: 56,
        .merge: 60, .guide: 58, .overflow: 30, .detach: 70,
    ]
    private let row: [RailItem] = [.fontDown, .fontUp, .newTab, .file, .shortcut, .merge, .guide, .detach]

    func testEverythingFitsWhenThereIsRoom() {
        XCTAssertEqual(RailFit.rowItems(offered: row, widths: widths, spacing: 8, available: 1_000), row)
    }

    func testRowDropsInPriorityOrderAndAddsOverflowOnce() {
        // 8 chips + 7 gaps = 480; at 400 MERGE and GUIDE leave, ⋯ joins before DETACH.
        let kept = RailFit.rowItems(offered: row, widths: widths, spacing: 8, available: 400)
        XCTAssertEqual(kept, [.fontDown, .fontUp, .newTab, .file, .shortcut, .overflow, .detach])
        XCTAssertEqual(RailFit.overflowing(offered: row, visible: kept), [.merge, .guide])
    }

    func testRowFontPairLeavesTogether() {
        let kept = RailFit.rowItems(offered: row, widths: widths, spacing: 8, available: 300)
        XCTAssertFalse(kept.contains(.fontDown))
        XCTAssertFalse(kept.contains(.fontUp))
        XCTAssertTrue(kept.contains(.overflow))
        XCTAssertTrue(kept.contains(.detach), "DETACH outlives the font pair, + TAB and FILE")
        XCTAssertGreaterThan(kept.count, 2, "a Duo band this wide must not collapse to ⋯ alone")
    }

    func testNarrowestRowKeepsOnlyOverflow() {
        XCTAssertEqual(RailFit.rowItems(offered: row, widths: widths, spacing: 8, available: 40), [.overflow])
    }

    // MARK: Column

    private let column: [RailItem] = [
        .deck, .fontDown, .fontUp, .newTab, .file, .shortcut, .overflow, .detach,
    ]

    func testCapacityCountsWholeChipsWithGaps() {
        XCTAssertEqual(RailFit.capacity(availableHeight: 0), 0)
        XCTAssertEqual(RailFit.capacity(availableHeight: 43.9), 0)
        XCTAssertEqual(RailFit.capacity(availableHeight: 44), 1)
        XCTAssertEqual(RailFit.capacity(availableHeight: 91.9), 1)
        XCTAssertEqual(RailFit.capacity(availableHeight: 92), 2)
        // The inner display's full column: 669 − 120 top inset.
        XCTAssertEqual(RailFit.capacity(availableHeight: 549), 11)
    }

    func testTheClosedDisplayKeepsTheColumnOffItsGlyphsAndCamera() {
        func insets(compact: Bool, landscape: Bool, trailing: Bool) -> [CGFloat] {
            let insets = RailFit.columnInsets(compactWidth: compact, landscape: landscape, trailingEdge: trailing)
            return [insets.top, insets.bottom]
        }
        XCTAssertEqual(insets(compact: false, landscape: true, trailing: true), [120, 0], "inner: glyphs at the top")
        XCTAssertEqual(
            insets(compact: true, landscape: false, trailing: true), [160, 0],
            "closed portrait: glyphs under the camera"
        )
        XCTAssertEqual(insets(compact: true, landscape: true, trailing: false), [80, 12], "camera top-left")
        XCTAssertEqual(insets(compact: true, landscape: true, trailing: true), [12, 80], "camera bottom-right")
    }

    func testEverythingFitsOnTheInnerDisplay() {
        XCTAssertEqual(RailFit.columnItems(offered: column, availableHeight: 549), column)
    }

    func testClosedLandscapeWithTheKeyboardUpKeepsDeckAndOverflow() {
        // Closed landscape: 466 − 193 keyboard − 160 top = 113 pt: two chips.
        let visible = RailFit.columnItems(offered: column, availableHeight: 113)
        XCTAssertEqual(visible, [.deck, .overflow])
        XCTAssertEqual(
            RailFit.overflowing(offered: column, visible: visible),
            [.fontDown, .fontUp, .newTab, .file, .shortcut, .detach]
        )
    }

    func testColumnFontPairLeavesTogether() {
        // Seven offered (no shortcut), room for six: A− would go alone.
        let offered: [RailItem] = [.deck, .fontDown, .fontUp, .newTab, .file, .overflow, .detach]
        let visible = RailFit.columnItems(offered: offered, availableHeight: 322)
        XCTAssertEqual(visible, [.deck, .newTab, .file, .overflow, .detach])
        XCTAssertEqual(RailFit.overflowing(offered: offered, visible: visible), [.fontDown, .fontUp])
    }

    func testFourChipsKeepDeckShortcutOverflowDetach() {
        XCTAssertEqual(
            RailFit.columnItems(offered: column, availableHeight: 200),
            [.deck, .shortcut, .overflow, .detach]
        )
    }

    func testDroppingAddsTheOverflowChipWhenNoneWasOffered() {
        let offered: [RailItem] = [.deck, .fontDown, .fontUp, .newTab, .detach]
        let visible = RailFit.columnItems(offered: offered, availableHeight: 140)
        XCTAssertEqual(visible, [.deck, .overflow, .detach])
        XCTAssertEqual(RailFit.overflowing(offered: offered, visible: visible), [.fontDown, .fontUp, .newTab])
    }

    func testDeckAndOverflowSurviveAnyHeight() {
        XCTAssertEqual(RailFit.columnItems(offered: column, availableHeight: 44), [.deck, .overflow])
        XCTAssertEqual(RailFit.columnItems(offered: column, availableHeight: 0), [.deck, .overflow])
    }
}
