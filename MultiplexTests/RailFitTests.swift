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
        func placement(compact: Bool, landscape: Bool, trailing: Bool) -> RailFit.ColumnPlacement {
            RailFit.columnPlacement(compactWidth: compact, landscape: landscape, trailingEdge: trailing)
        }
        XCTAssertEqual(placement(compact: false, landscape: true, trailing: true), .init(top: 120, bottom: 0))
        XCTAssertEqual(
            placement(compact: true, landscape: false, trailing: true), .init(top: 160, bottom: 0),
            "closed portrait: glyphs under the camera"
        )
        XCTAssertEqual(placement(compact: true, landscape: true, trailing: false), .init(top: 80, bottom: 12))
        XCTAssertFalse(placement(compact: true, landscape: true, trailing: false).anchoredToBottom, "camera top")
        XCTAssertEqual(placement(compact: true, landscape: true, trailing: true), .init(top: 12, bottom: 80))
        XCTAssertTrue(placement(compact: true, landscape: true, trailing: true).anchoredToBottom, "camera bottom")
    }

    private func items(_ offered: [RailItem], height: CGFloat) -> [RailItem] {
        RailFit.columnItems(offered: offered, capacity: RailFit.capacity(availableHeight: height))
    }

    func testEverythingFitsOnTheInnerDisplay() {
        XCTAssertEqual(items(column, height: 549), column)
    }

    func testClosedLandscapeWithTheKeyboardUpKeepsDeckAndOverflow() {
        // Closed landscape: 466 − 193 keyboard − 160 top = 113 pt: two chips.
        let visible = items(column, height: 113)
        XCTAssertEqual(visible, [.deck, .overflow])
        XCTAssertEqual(
            RailFit.overflowing(offered: column, visible: visible),
            [.fontDown, .fontUp, .newTab, .file, .shortcut, .detach]
        )
    }

    func testColumnFontPairLeavesTogether() {
        // Seven offered (no shortcut), room for six: A− would go alone.
        let offered: [RailItem] = [.deck, .fontDown, .fontUp, .newTab, .file, .overflow, .detach]
        let visible = items(offered, height: 322)
        XCTAssertEqual(visible, [.deck, .newTab, .file, .overflow, .detach])
        XCTAssertEqual(RailFit.overflowing(offered: offered, visible: visible), [.fontDown, .fontUp])
    }

    func testFourChipsKeepDeckShortcutOverflowDetach() {
        XCTAssertEqual(
            items(column, height: 200),
            [.deck, .shortcut, .overflow, .detach]
        )
    }

    func testDroppingAddsTheOverflowChipWhenNoneWasOffered() {
        let offered: [RailItem] = [.deck, .fontDown, .fontUp, .newTab, .detach]
        let visible = items(offered, height: 140)
        XCTAssertEqual(visible, [.deck, .overflow, .detach])
        XCTAssertEqual(RailFit.overflowing(offered: offered, visible: visible), [.fontDown, .fontUp, .newTab])
    }

    func testDeckAndOverflowSurviveAnyHeight() {
        XCTAssertEqual(items(column, height: 44), [.deck, .overflow])
        XCTAssertEqual(items(column, height: 0), [.deck, .overflow])
    }
}
