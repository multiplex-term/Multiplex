import SwiftTerm
import XCTest

/// Locks the fork's split-pane implicit link detection (`Multiplex patch`
/// in Terminal.swift: `paneSegment` / `buildPaneSegmentLineMap`). A
/// multiplexer composites side-by-side panes into ONE client row, so a
/// path that wraps at the pane border wraps mid-row (never `isWrapped`),
/// and the whole-row join heuristic looks at the terminal's right edge —
/// where the NEIGHBOUR pane's text sits. The segment-scoped map joins at
/// the border instead and must never carry another pane's text.
final class TerminalSplitPaneLinkTests: XCTestCase {
    private func makeTerminal(cols: Int = 80, rows: Int = 24) -> Terminal {
        Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: cols, rows: rows, scrollback: 100)
        )
    }

    /// One composited row painted the way a multiplexer redraws: cursor
    /// addressing, no wrap flags (1-based row).
    private func paint(_ terminal: Terminal, row: Int, _ text: String) {
        terminal.feed(text: "\u{1b}[\(row);1H\u{1b}[2K" + text)
    }

    private func match(
        _ terminal: Terminal, row: Int, col: Int
    ) -> (text: String, rowTexts: [String])? {
        terminal.linkWithRowTexts(
            at: .screen(Position(col: col, row: row)),
            mode: .explicitAndImplicit
        )
    }

    private func pad(_ text: String, to width: Int) -> String {
        text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private let border = "\u{2502}"

    func testPathWrappedAtThePaneBorderRejoinsFromEitherFragment() {
        let terminal = makeTerminal()
        let full = "/Users/dev/workspace/Multiplex/docs/agents/architecture.md"
        let head = String(full.prefix(40))
        let tail = String(full.dropFirst(40))
        paint(terminal, row: 5, head + border + " right pane text here")
        paint(terminal, row: 6, pad(tail, to: 40) + border + " more right pane")

        let upper = match(terminal, row: 4, col: 10)
        XCTAssertEqual(upper?.text, full)
        XCTAssertEqual(
            upper?.rowTexts, [head, tail],
            "the seam fragments must carry only the pane's own columns"
        )
        XCTAssertEqual(match(terminal, row: 5, col: 5)?.text, full,
                       "the lower fragment is the same press target")
    }

    func testPathWrappedInsideTheRightPaneRejoins() {
        let terminal = makeTerminal()
        let full = "/Users/dev/workspace/Multiplex/docs/agents/mosh.md"
        // Right pane spans cols 41..79 — its head fills to the terminal
        // edge, and its continuation starts after the border.
        let head = String(full.prefix(39))
        let tail = String(full.dropFirst(39))
        paint(terminal, row: 5, pad("left pane text", to: 40) + border + head)
        paint(terminal, row: 6, pad("more left text", to: 40) + border + tail)

        XCTAssertEqual(match(terminal, row: 4, col: 50)?.text, full)
        XCTAssertEqual(match(terminal, row: 5, col: 45)?.text, full)
    }

    func testShortPathsAndNeighbourTextStayIndependent() {
        let terminal = makeTerminal()
        paint(
            terminal, row: 5,
            pad("cat docs/agents/mosh.md", to: 40) + border + " vim Sources/App/Main.swift"
        )
        XCTAssertEqual(match(terminal, row: 4, col: 8)?.text, "docs/agents/mosh.md")
        XCTAssertEqual(match(terminal, row: 4, col: 50)?.text, "Sources/App/Main.swift")
    }

    func testProseAboveThePathNeverGlues() {
        let terminal = makeTerminal()
        // The upper row's segment ends mid-pane — no wrap happened there,
        // so the path below it is its own press target.
        paint(terminal, row: 5, pad("reading the docs and", to: 40) + border + " right")
        paint(terminal, row: 6, pad("docs/agents/mosh.md", to: 40) + border + " right")
        XCTAssertEqual(match(terminal, row: 5, col: 5)?.text, "docs/agents/mosh.md")
    }

    func testJoinStopsWhereTheBorderStops() {
        let terminal = makeTerminal()
        // The row above the split spans the full terminal width and ends in
        // path-shaped text at the right edge — the whole-row heuristic's
        // bait. Without the border on that row, the segment join must not
        // reach it.
        paint(terminal, row: 5, pad("full width row ending in docs", to: 76) + "/x.md")
        paint(terminal, row: 6, pad("local-plan/notes.md", to: 40) + border + " right pane")
        XCTAssertEqual(match(terminal, row: 5, col: 5)?.text, "local-plan/notes.md")
    }

    func testTableColumnContentStillMatches() {
        let terminal = makeTerminal()
        // TUI tables draw the same glyph; a path inside a cell keeps
        // matching, scoped to its column.
        paint(terminal, row: 5, "\(border) docs/agents/mosh.md \(border) some description \(border)")
        XCTAssertEqual(match(terminal, row: 4, col: 8)?.text, "docs/agents/mosh.md")
    }

    func testPressingTheBorderItselfMatchesNothing() {
        let terminal = makeTerminal()
        paint(terminal, row: 5, pad("cat docs/agents/mosh.md", to: 40) + border + " right")
        XCTAssertNil(match(terminal, row: 4, col: 40))
    }
}
