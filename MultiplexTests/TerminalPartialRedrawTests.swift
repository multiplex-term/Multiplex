import CoreGraphics
import SwiftTerm
import XCTest

/// Locks the row-narrowing math behind the fork's damage-strip redraw
/// (`Multiplex patch` in AppleTerminalView): a well-formed sub-viewport
/// dirty rect narrows the CG row loop; every anomalous shape — the
/// scroll-coalesced y=0 rects the upstream workaround exists for, empty
/// rects, viewport-spanning rects — must return nil so the caller keeps
/// the full-screen redraw. A wrong nil costs performance; a wrong range
/// draws garbage rows, which is why the fallback side is the one under
/// test the hardest.
final class TerminalPartialRedrawTests: XCTestCase {
    private let cell: CGFloat = 20

    private func viewport(offsetY: CGFloat = 0) -> CGRect {
        CGRect(x: 0, y: offsetY, width: 800, height: 600)
    }

    func testMidViewportStripNarrowsToItsRows() {
        let rows = TerminalView.partialRedrawRows(
            dirtyRect: CGRect(x: 0, y: 100, width: 800, height: 60),
            viewport: viewport(),
            cellHeight: cell
        )
        XCTAssertEqual(rows, 5...7)
    }

    func testScrolledViewportStripStaysInAbsoluteBufferRows() {
        let rows = TerminalView.partialRedrawRows(
            dirtyRect: CGRect(x: 0, y: 500, width: 800, height: 40),
            viewport: viewport(offsetY: 400),
            cellHeight: cell
        )
        XCTAssertEqual(rows, 25...26)
    }

    func testScrollCoalescedRectAnchoredAtZeroFallsBackToFullRedraw() {
        // The exact shape the upstream workaround exists for: UIKit hands a
        // rect at y=0 while the view is scrolled to 400.
        XCTAssertNil(TerminalView.partialRedrawRows(
            dirtyRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            viewport: viewport(offsetY: 400),
            cellHeight: cell
        ))
    }

    func testViewportSpanningRectFallsBackToFullRedraw() {
        XCTAssertNil(TerminalView.partialRedrawRows(
            dirtyRect: viewport(),
            viewport: viewport(),
            cellHeight: cell
        ))
    }

    func testRectHangingPastTheViewportBottomFallsBackToFullRedraw() {
        XCTAssertNil(TerminalView.partialRedrawRows(
            dirtyRect: CGRect(x: 0, y: 580, width: 800, height: 40),
            viewport: viewport(),
            cellHeight: cell
        ))
    }

    func testDegenerateInputsFallBackToFullRedraw() {
        XCTAssertNil(TerminalView.partialRedrawRows(
            dirtyRect: CGRect(x: 0, y: 100, width: 800, height: 0),
            viewport: viewport(),
            cellHeight: cell
        ))
        XCTAssertNil(TerminalView.partialRedrawRows(
            dirtyRect: CGRect(x: 0, y: 100, width: 800, height: 40),
            viewport: viewport(),
            cellHeight: 0
        ))
        XCTAssertNil(TerminalView.partialRedrawRows(
            dirtyRect: .null,
            viewport: viewport(),
            cellHeight: cell
        ))
    }

    func testSingleRowEchoStripCoversExactlyItsPaddedBand() {
        // updateDisplay pads the damaged row by one row each side; the
        // narrowing must hand those three rows back, no more.
        let rows = TerminalView.partialRedrawRows(
            dirtyRect: CGRect(x: 0, y: 4 * cell, width: 800, height: 3 * cell),
            viewport: viewport(),
            cellHeight: cell
        )
        XCTAssertEqual(rows, 4...6)
    }
}
