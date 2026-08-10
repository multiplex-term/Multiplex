import SwiftTerm
import XCTest

/// Locks the mosh tab's no-scrollback contract
/// (`TerminalSessionController.localScrollbackLines` — mosh syncs ONE
/// live screen, so anything archived above it is junk; full record in
/// docs/agents/mosh.md) and the fork's content-coordinate selection rect
/// (`Multiplex patch` in `selectionUIRect`).
final class TerminalMoshScreenTests: XCTestCase {
    /// One herdr-like frame: rows drawn by cursor addressing, the cursor
    /// parked where the focused pane's input line sits.
    private func paint(_ terminal: Terminal, rows: Int, parkRow: Int) {
        for row in 1...rows {
            terminal.feed(text: "\u{1b}[\(row);1H\u{1b}[2Krow \(row) content")
        }
        terminal.feed(text: "\u{1b}[\(parkRow);1H")
    }

    func testMoshTabAccumulatesNoScrollbackThroughScrollsResetsAndResizes() {
        let sink = SilentTerminalDelegate()
        let terminal = Terminal(
            delegate: sink,
            options: TerminalOptions(cols: 40, rows: 12, scrollback: 5000)
        )
        terminal.changeScrollback(nil)

        paint(terminal, rows: 12, parkRow: 12)
        for _ in 0..<3 {
            // Scroll-op diffs from streamed output at the bottom row.
            terminal.feed(text: "\u{1b}[12;1H\n\n\n")
            // A resync reset (mosh state-0 recovery renders as RIS).
            terminal.feed(text: "\u{1b}c")
            paint(terminal, rows: 12, parkRow: 12)
            // One keyboard show/hide cycle.
            terminal.resize(cols: 40, rows: 6)
            paint(terminal, rows: 6, parkRow: 3)
            terminal.resize(cols: 40, rows: 12)
            paint(terminal, rows: 12, parkRow: 12)
        }

        XCTAssertEqual(
            terminal.buffer.yDisp, 0,
            "no stale frames may accumulate above the live screen"
        )
        let top = terminal.getLine(row: 0)?.translateToString() ?? ""
        XCTAssertTrue(
            top.hasPrefix("row 1 content"),
            "the live screen survives the cycles, got: \(top)"
        )
    }

    @MainActor
    func testSelectionUIRectAnswersContentCoordinatesWhenScrolled() {
        // Subview frames live in the scroll view's content space, so a
        // displayed row's y is its ABSOLUTE buffer row × cell height —
        // viewport-relative answers anchored the HUD one content-offset
        // short (the "keyboard height" offset reported 2026-08-10).
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        view.changeScrollback(500)
        for row in 1...80 {
            view.getTerminal().feed(text: "line \(row) word\r\n")
        }
        let buffer = view.getTerminal().buffer
        XCTAssertGreaterThan(buffer.yDisp, 0, "the screen scrolled into scrollback")

        let lowRow = buffer.yDisp + 2
        let highRow = buffer.yDisp + 5
        view.seedWordSelection(atBufferPosition: Position(col: 1, row: lowRow))
        let low = view.selectionUIRect()
        view.seedWordSelection(atBufferPosition: Position(col: 1, row: highRow))
        let high = view.selectionUIRect()

        guard let lowY = low?.minY, let highY = high?.minY else {
            return XCTFail("selection rects missing")
        }
        let cellHeight = (highY - lowY) / CGFloat(highRow - lowRow)
        XCTAssertGreaterThan(cellHeight, 0)
        XCTAssertEqual(
            lowY, CGFloat(lowRow) * cellHeight, accuracy: 0.5,
            "the rect anchors at the absolute buffer row, not the viewport row"
        )
    }
}
