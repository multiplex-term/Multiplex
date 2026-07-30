import XCTest
@testable import Multiplex

final class MarkdownDocumentTests: XCTestCase {
    func testHeadingsAndParagraphJoin() {
        let blocks = MarkdownDocument.parse("""
        # Title

        First line
        continues here.

        ## Section ##
        """)
        XCTAssertEqual(blocks.count, 3)
        guard case .heading(1, let title) = blocks[0] else { return XCTFail("h1") }
        XCTAssertEqual(title, [.text("Title", [])])
        guard case .paragraph(let inlines) = blocks[1] else { return XCTFail("para") }
        XCTAssertEqual(inlines, [.text("First line continues here.", [])])
        guard case .heading(2, let section) = blocks[2] else { return XCTFail("h2") }
        XCTAssertEqual(section, [.text("Section", [])])
    }

    func testFenceKeepsBodyVerbatimAndLanguage() {
        let blocks = MarkdownDocument.parse("""
        ```swift
        let x = 1  // keep  spacing
        # not a heading
        ```
        after
        """)
        guard case .code(let language, let info, let lines) = blocks[0] else {
            return XCTFail("fence")
        }
        XCTAssertEqual(language, .swift)
        XCTAssertEqual(info, "swift")
        XCTAssertEqual(lines, ["let x = 1  // keep  spacing", "# not a heading"])
        guard case .paragraph = blocks[1] else { return XCTFail("after") }
    }

    func testUnclosedFenceRunsToEnd() {
        let blocks = MarkdownDocument.parse("```\ncode\nmore")
        guard case .code(_, _, let lines) = blocks[0] else { return XCTFail("fence") }
        XCTAssertEqual(lines, ["code", "more"])
        XCTAssertEqual(blocks.count, 1)
    }

    func testQuoteRecursion() {
        let blocks = MarkdownDocument.parse("> # Inside\n> body text")
        guard case .quote(let inner) = blocks[0] else { return XCTFail("quote") }
        guard case .heading(1, _) = inner[0] else { return XCTFail("inner heading") }
        guard case .paragraph = inner[1] else { return XCTFail("inner para") }
    }

    func testListsWithTasksAndOrder() {
        let blocks = MarkdownDocument.parse("""
        - plain
        - [ ] open task
        - [x] done task
          wrapped continuation
        3. third
        """)
        guard case .listItem("•", 0, _) = blocks[0] else { return XCTFail("bullet") }
        guard case .listItem("□", 0, _) = blocks[1] else { return XCTFail("open task") }
        guard case .listItem("▣", 0, let done) = blocks[2] else { return XCTFail("done task") }
        // The continuation folded into the done task's inlines.
        XCTAssertTrue(done.contains { inline in
            if case .text(let value, _) = inline { return value.contains("wrapped continuation") }
            return false
        })
        guard case .listItem("3.", 0, _) = blocks[3] else { return XCTFail("ordered") }
    }

    func testNestedListLevel() {
        let blocks = MarkdownDocument.parse("- top\n  - nested")
        guard case .listItem(_, 0, _) = blocks[0] else { return XCTFail("top") }
        guard case .listItem(_, 1, _) = blocks[1] else { return XCTFail("nested") }
    }

    func testTable() {
        let blocks = MarkdownDocument.parse("""
        | Name | Count |
        | ---- | ----: |
        | a    | 1     |
        | b    | 2     |
        """)
        guard case .table(let header, let rows) = blocks[0] else { return XCTFail("table") }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][0], [.text("b", [])])
    }

    func testRule() {
        let blocks = MarkdownDocument.parse("---")
        XCTAssertEqual(blocks, [.rule])
    }

    // MARK: Inlines

    func testInlineEmphasisAndCode() {
        let inlines = MarkdownDocument.parseInlines("mix **bold** and *italic* and `code` and ~~gone~~")
        XCTAssertTrue(inlines.contains(.text("bold", .bold)))
        XCTAssertTrue(inlines.contains(.text("italic", .italic)))
        XCTAssertTrue(inlines.contains(.code("code")))
        XCTAssertTrue(inlines.contains(.text("gone", .strikethrough)))
    }

    func testNestedEmphasis() {
        let inlines = MarkdownDocument.parseInlines("**bold *both* bold**")
        XCTAssertTrue(inlines.contains(.text("both", [.bold, .italic])))
    }

    func testLinkImageAutolink() {
        let inlines = MarkdownDocument.parseInlines(
            "see [docs](https://example.com/x) and ![shot](img.png) and <https://a.dev>"
        )
        XCTAssertTrue(inlines.contains(.link(text: "docs", destination: "https://example.com/x")))
        XCTAssertTrue(inlines.contains(.image(alt: "shot")))
        XCTAssertTrue(inlines.contains(.link(text: "https://a.dev", destination: "https://a.dev")))
    }

    func testUnmatchedDelimitersStayPlain() {
        let inlines = MarkdownDocument.parseInlines("2 * 3 = 6 and a_b_c stays")
        // "* 3 = 6…" has a space after the opener — not emphasis.
        XCTAssertEqual(inlines.count, 1)
        if case .text(let value, let style) = inlines[0] {
            XCTAssertEqual(style, [])
            XCTAssertTrue(value.contains("2 * 3 = 6"))
        } else {
            XCTFail("expected plain text")
        }
    }

    func testCodeSpanSwallowsMarkers() {
        let inlines = MarkdownDocument.parseInlines("`let *x* = 1`")
        XCTAssertEqual(inlines, [.code("let *x* = 1")])
    }
}
