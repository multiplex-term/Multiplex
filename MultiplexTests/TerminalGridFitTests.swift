import CoreGraphics
import XCTest
@testable import Multiplex

/// Fitting a terminal another client sized into this tab's pane
/// (`TerminalGridFit`): the text shrinks until the whole grid is inside,
/// never grows past the tab's own size, and the frame handed to the
/// emulator measures back to exactly the grid.
final class TerminalGridFitTests: XCTestCase {
    /// A monospaced cell at 1 pt, close to the system font's.
    private let perPoint = CGSize(width: 0.6, height: 1.2)
    private let pane = CGSize(width: 1056, height: 704) // 132 x 44 at 13.33 pt

    func testAGridThatAlreadyFitsKeepsTheTabsOwnTextSize() {
        let size = TerminalGridFit.fontSize(
            for: TerminalGrid(cols: 100, rows: 30), in: pane,
            cellPerPoint: perPoint, preferred: 13)
        XCTAssertEqual(size, 13)
    }

    func testALargerGridShrinksTheTextToTheTighterDimensionInHalfPoints() {
        // 170 columns need 1056 / (170 * 0.6) = 10.35 pt; 50 rows would
        // allow 11.7. The width decides, rounded DOWN to a half point.
        let size = TerminalGridFit.fontSize(
            for: TerminalGrid(cols: 170, rows: 50), in: pane,
            cellPerPoint: perPoint, preferred: 13)
        XCTAssertEqual(size, 10)

        let tall = TerminalGridFit.fontSize(
            for: TerminalGrid(cols: 80, rows: 100), in: pane,
            cellPerPoint: perPoint, preferred: 13)
        XCTAssertEqual(tall, 5.5) // 704 / (100 * 1.2) = 5.87
    }

    func testTextStopsShrinkingAtTheFloorAndNeverGrowsPastTheTabsOwn() {
        let huge = TerminalGridFit.fontSize(
            for: TerminalGrid(cols: 1000, rows: 300), in: pane,
            cellPerPoint: perPoint, preferred: 13)
        XCTAssertEqual(huge, TerminalGridFit.minimumFontSize)

        // A tab whose own text is already below the floor keeps it.
        let tiny = TerminalGridFit.fontSize(
            for: TerminalGrid(cols: 1000, rows: 300), in: pane,
            cellPerPoint: perPoint, preferred: 4)
        XCTAssertEqual(tiny, 4)

        // Unusable measurements change nothing.
        XCTAssertEqual(TerminalGridFit.fontSize(
            for: TerminalGrid(cols: 0, rows: 50), in: pane,
            cellPerPoint: perPoint, preferred: 13), 13)
        XCTAssertEqual(TerminalGridFit.fontSize(
            for: TerminalGrid(cols: 170, rows: 50), in: pane,
            cellPerPoint: .zero, preferred: 13), 13)
    }

    func testTheFrameMeasuresBackToExactlyTheGrid() {
        let grid = TerminalGrid(cols: 170, rows: 50)
        for scale: CGFloat in [1, 2, 3] {
            // Cells as the emulator snaps them: whole pixels.
            let cell = CGSize(
                width: (6.21 * scale).rounded() / scale,
                height: ceil(12.4 * scale) / scale)
            let frame = TerminalGridFit.frameSize(for: grid, cell: cell, displayScale: scale)
            // SwiftTerm's own arithmetic (`processSizeChange`).
            XCTAssertEqual(Int(frame.width / cell.width), 170, "scale \(scale)")
            XCTAssertEqual(Int(frame.height / cell.height), 50, "scale \(scale)")
            // And not a pixel more than one over.
            XCTAssertLessThanOrEqual(
                frame.width - CGFloat(grid.cols) * cell.width, 1 / scale + 0.0001)
        }
    }

    func testFitsComparesTheWholeFrameAgainstThePane() {
        let grid = TerminalGrid(cols: 170, rows: 50)
        XCTAssertTrue(TerminalGridFit.fits(
            grid, cell: CGSize(width: 6, height: 12), in: pane, displayScale: 2))
        // 170 * 6.25 = 1062.5 > 1056.
        XCTAssertFalse(TerminalGridFit.fits(
            grid, cell: CGSize(width: 6.25, height: 12), in: pane, displayScale: 2))
        // Exactly the cells but no room for the safety pixel.
        XCTAssertFalse(TerminalGridFit.fits(
            TerminalGrid(cols: 176, rows: 50), cell: CGSize(width: 6, height: 12),
            in: pane, displayScale: 2))
    }
}
