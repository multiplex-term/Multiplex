import CoreGraphics

/// Bottom-aligns a whole-row terminal grid without changing its PTY size.
///
/// SwiftTerm truncates a view's height to whole text rows and renders those
/// rows from the top, leaving the fractional remainder below the last row.
/// Removing all but one physical pixel of that remainder moves tmux's status
/// row to the lower chrome while keeping the post-adjustment height safely
/// inside the same row-count bucket.
enum TerminalGridAlignment {
    static func bottomNudge(
        rawHeight: CGFloat,
        cellHeight: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat {
        guard rawHeight > 0, cellHeight > 0 else { return 0 }

        let wholeRows = floor(rawHeight / cellHeight)
        guard wholeRows >= 1 else { return 0 }

        let remainder = max(0, rawHeight - wholeRows * cellHeight)
        let rowSafety = 1 / max(displayScale, 1)
        guard remainder > rowSafety else { return 0 }
        return remainder - rowSafety
    }
}
