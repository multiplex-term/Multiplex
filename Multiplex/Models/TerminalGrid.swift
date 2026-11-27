import CoreGraphics

/// A terminal's size in cells.
struct TerminalGrid: Equatable, Sendable {
    var cols: Int
    var rows: Int
}

/// Fitting someone else's grid into this tab's pane.
///
/// A Rex terminal has ONE size, its owner's. While another client owns it —
/// the Rex app on the Mac, the moment someone works there — a tab still has
/// to draw it, and an emulator can only draw a terminal correctly at that
/// terminal's own grid. So the tab takes the grid as given and makes it
/// fit: the text shrinks until the whole grid is inside the pane, and
/// whatever room is left over stays empty to the right and below. Typing in
/// the tab claims the size back and the pane is its own again.
enum TerminalGridFit {
    /// Text never shrinks below this; a grid still too large at it runs
    /// off the pane's right and bottom edges rather than becoming specks.
    static let minimumFontSize: CGFloat = 5

    /// The largest font size, in half points and no larger than the tab's
    /// own, at which `grid` fits `available`. `cellPerPoint` is one cell's
    /// size at a 1 pt font — cell size is close to linear in font size, and
    /// the caller checks the result against the real cell and steps down.
    static func fontSize(
        for grid: TerminalGrid, in available: CGSize,
        cellPerPoint: CGSize, preferred: CGFloat
    ) -> CGFloat {
        guard grid.cols > 0, grid.rows > 0,
              cellPerPoint.width > 0, cellPerPoint.height > 0
        else { return preferred }
        let widest = available.width / (CGFloat(grid.cols) * cellPerPoint.width)
        let tallest = available.height / (CGFloat(grid.rows) * cellPerPoint.height)
        let fitting = (min(widest, tallest) * 2).rounded(.down) / 2
        return max(min(preferred, minimumFontSize), min(preferred, fitting))
    }

    /// The frame that makes an emulator measure exactly `grid`: the cells
    /// plus one physical pixel each way, which keeps the division that
    /// turns points back into cells from landing one short.
    static func frameSize(
        for grid: TerminalGrid, cell: CGSize, displayScale: CGFloat
    ) -> CGSize {
        let safety = 1 / max(displayScale, 1)
        return CGSize(
            width: CGFloat(grid.cols) * cell.width + safety,
            height: CGFloat(grid.rows) * cell.height + safety)
    }

    /// Whether `grid` fits `available` at this cell size.
    static func fits(
        _ grid: TerminalGrid, cell: CGSize, in available: CGSize, displayScale: CGFloat
    ) -> Bool {
        let frame = frameSize(for: grid, cell: cell, displayScale: displayScale)
        return frame.width <= available.width && frame.height <= available.height
    }
}
