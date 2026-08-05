import XCTest
@testable import Multiplex

/// Pins the gate that turns a long press into a herdr resize drag: only a
/// Unicode box-drawing cell qualifies, so links, prose, and empty cells keep
/// the long press's existing meanings. The drag itself was verified against
/// herdr 0.7.5 (an SGR press → motion → release on a divider moves the split
/// ratio).
final class HerdrPaneBorderTests: XCTestCase {
    func testDividerGlyphsAreBorderCells() {
        for glyph: Character in ["│", "─", "┃", "━", "║", "═",
                                 "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼",
                                 "╭", "╮", "╰", "╯"] {
            XCTAssertTrue(HerdrPaneBorder.isBorderCell(glyph),
                          "\(glyph) must count as a border cell")
        }
    }

    func testOrdinaryContentIsNotABorderCell() {
        for glyph: Character in ["a", "Z", "0", " ", "|", "-", "_", "+", "/",
                                 "…", "•", "█", "▐", "░", "✳", "π"] {
            XCTAssertFalse(HerdrPaneBorder.isBorderCell(glyph),
                           "\(glyph) must not claim the long press")
        }
        XCTAssertFalse(HerdrPaneBorder.isBorderCell(nil),
                       "an empty cell keeps the selection menu")
    }

    func testBlockElementsStayOutside() {
        // U+2580… Block Elements sit right after Box Drawing — a full-block
        // progress bar must never swallow a long press.
        XCTAssertFalse(HerdrPaneBorder.isBorderCell("▀"))
        XCTAssertFalse(HerdrPaneBorder.isBorderCell("▂"))
    }

    func testVerticalBarsAreTheHeadlessDragTargets() {
        XCTAssertTrue(HerdrPaneBorder.isVerticalBar("│"))
        XCTAssertTrue(HerdrPaneBorder.isVerticalBar("┃"))
        XCTAssertTrue(HerdrPaneBorder.isVerticalBar("║"))
        XCTAssertFalse(HerdrPaneBorder.isVerticalBar("─"),
                       "a horizontal rule is no target for a horizontal drag")
        XCTAssertFalse(HerdrPaneBorder.isVerticalBar("|"),
                       "ASCII pipe is pane content, not a divider")
        XCTAssertFalse(HerdrPaneBorder.isVerticalBar(nil))
    }
}
