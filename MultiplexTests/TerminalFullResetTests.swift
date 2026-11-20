import SwiftTerm
import XCTest

/// The fork's full reset (`Multiplex patch` in `Terminal.setup`): RIS
/// empties the alternate screen as well as the normal one.
///
/// A Rex tab redraws from a rendering behind an RIS — on attach, when the
/// tab switches to another terminal of its session, when the terminal's
/// size changes hands. Upstream's reset left the alternate buffer's rows in
/// place, and a buffer that has rows is not blanked on the way back in, so
/// switching from one full-screen program to another drew the second over
/// the first (user-reported 2026-11-20: stray characters after switching
/// between two Rex terminals, both running an agent).
final class TerminalFullResetTests: XCTestCase {
    private func row(_ terminal: Terminal, _ index: Int) -> String {
        (terminal.getLine(row: index)?.translateToString() ?? "")
            // An untouched cell reads as NUL, an erased one as a space.
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    func testAFullResetEmptiesTheAlternateScreenToo() {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 40, rows: 6, scrollback: 100)
        )
        // One full-screen program paints every row…
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[2J\u{1b}[H")
        for index in 1...6 {
            terminal.feed(text: "\u{1b}[\(index);1HFIRST PROGRAM ROW \(index)")
        }
        XCTAssertEqual(row(terminal, 0), "FIRST PROGRAM ROW 1")

        // …the tab is redrawn for another, which paints one cell.
        terminal.feed(text: "\u{1b}c\u{1b}[?1049h\u{1b}[3;5HSECOND")

        XCTAssertEqual(
            (0..<6).map { row(terminal, $0) },
            ["", "", "SECOND", "", "", ""])
    }

    /// The normal screen and its scrollback were always reset; pinned here
    /// so the patch above cannot be "fixed" by trading one for the other.
    func testAFullResetStillEmptiesTheNormalScreenAndItsScrollback() {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 40, rows: 4, scrollback: 100)
        )
        for index in 1...12 { terminal.feed(text: "line \(index)\r\n") }
        terminal.feed(text: "\u{1b}cfresh")

        XCTAssertEqual(terminal.buffer.yDisp, 0)
        XCTAssertEqual((0..<4).map { row(terminal, $0) }, ["fresh", "", "", ""])
    }
}
