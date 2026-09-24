import XCTest
@testable import Multiplex

final class CodeHighlighterTests: XCTestCase {
    private func kinds(
        _ line: String,
        _ language: CodeLanguage
    ) -> [(String, CodeTokenKind)] {
        let lines = CodeHighlighter.highlight(line, language: language)
        return lines.first?.segments.map { ($0.text, $0.kind) } ?? []
    }

    private func kind(
        of word: String,
        in line: String,
        _ language: CodeLanguage
    ) -> CodeTokenKind? {
        kinds(line, language).first { $0.0 == word }?.1
    }

    // MARK: The invariant: segments always rebuild the exact line

    func testSegmentsRejoinToOriginalText() {
        let samples: [(CodeLanguage, String)] = [
            (.swift, "func probe(_ x: Int) -> String { return \"\\(x)\" } // trailing"),
            (.typescript, "const url = `https://${host}:${port}/api`; // template"),
            (.python, "def f(x): return {'a': 1, \"b\": x}  # dict"),
            (.rust, "let mut v: Vec<u32> = vec![1, 0xFF, 2_000];"),
            (.go, "func main() { fmt.Println(`raw`) }"),
            (.shell, "if [ -n \"$HOME\" ]; then echo ${PATH}; fi # done"),
            (.json, "{\"key\": [1, 2.5, true, null], \"s\": \"v\"}"),
            (.yaml, "key: value # comment"),
            (.html, "<div class=\"row\" data-x='1'>text &amp; more</div>"),
            (.sql, "SELECT id, name FROM users WHERE age > 21 -- adults"),
            (.css, "body { color: #fff; margin: 0 auto; } /* base */"),
        ]
        for (language, line) in samples {
            let highlighted = CodeHighlighter.highlight(line, language: language)
            XCTAssertEqual(highlighted.count, 1, line)
            XCTAssertEqual(highlighted[0].text, line, "segments must cover the line exactly")
        }
    }

    // MARK: Basic classification

    func testSwiftBasics() {
        let line = "func probe(name: String) -> Int { return 42 } // answer"
        XCTAssertEqual(kind(of: "func", in: line, .swift), .keyword)
        XCTAssertEqual(kind(of: "probe", in: line, .swift), .function)
        XCTAssertEqual(kind(of: "String", in: line, .swift), .type)
        XCTAssertEqual(kind(of: "return", in: line, .swift), .keyword)
        XCTAssertEqual(kind(of: "42", in: line, .swift), .number)
        XCTAssertEqual(kind(of: "// answer", in: line, .swift), .comment)
    }

    func testSwiftAttributeAndDirective() {
        XCTAssertEqual(kind(of: "@Observable", in: "@Observable final class X {}", .swift), .meta)
        XCTAssertEqual(kind(of: "#if", in: "#if os(visionOS)", .swift), .meta)
    }

    func testStringWithEscapes() {
        // Adjacent same-kind segments merge, so plain text around the
        // string coalesces — assert containment, not exact splits.
        let segments = kinds("let s = \"a \\\" quote\" + tail", .swift)
        XCTAssertTrue(segments.contains { $0.0 == "\"a \\\" quote\"" && $0.1 == .string })
        XCTAssertTrue(segments.contains { $0.0.hasSuffix("tail") && $0.1 == .plain })
    }

    func testBlockCommentCarriesAcrossLines() {
        let lines = CodeHighlighter.highlight("let a = 1 /* start\nstill inside\nend */ let b = 2", language: .swift)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].segments.allSatisfy { $0.kind == .comment })
        XCTAssertTrue(lines[2].segments.contains { $0.text.contains("end */") && $0.kind == .comment })
        XCTAssertTrue(lines[2].segments.contains { $0.text == "let" && $0.kind == .keyword })
    }

    func testSwiftNestedBlockComments() {
        let lines = CodeHighlighter.highlight("/* outer /* inner */ still */ let x = 1", language: .swift)
        let segments = lines[0].segments
        XCTAssertEqual(segments.first?.kind, .comment)
        XCTAssertTrue(segments.first!.text.hasSuffix("still */"))
        XCTAssertTrue(segments.contains { $0.text == "let" && $0.kind == .keyword })
    }

    func testPythonTripleQuoteCarries() {
        let lines = CodeHighlighter.highlight("x = \"\"\"doc\nline two\n\"\"\" + y", language: .python)
        XCTAssertTrue(lines[1].segments.allSatisfy { $0.kind == .string })
        XCTAssertTrue(lines[2].segments.contains { $0.text.hasSuffix("y") && $0.kind == .plain })
    }

    func testTemplateLiteralCarries() {
        let lines = CodeHighlighter.highlight("const s = `one\ntwo` + x", language: .typescript)
        XCTAssertTrue(lines[0].segments.contains { $0.text == "`one" && $0.kind == .string })
        XCTAssertTrue(lines[1].segments.contains { $0.text == "two`" && $0.kind == .string })
        XCTAssertTrue(lines[1].segments.contains { $0.text.hasSuffix("x") && $0.kind == .plain })
    }

    func testUnterminatedPlainStringDoesNotCarry() {
        let lines = CodeHighlighter.highlight("let s = \"open\nlet t = 2", language: .swift)
        // Next line must highlight normally, not drown in string color.
        XCTAssertTrue(lines[1].segments.contains { $0.text == "let" && $0.kind == .keyword })
    }

    func testJSONKeysAreProperties() {
        let segments = kinds("{stable: true, other: 2}", .json)
        XCTAssertTrue(segments.contains { $0.0 == "stable" && $0.1 == .property })
        XCTAssertTrue(segments.contains { $0.0 == "true" && $0.1 == .keyword })
    }

    func testYAMLCommentNeedsBoundary() {
        // In-word # must not start a comment...
        let inWord = kinds("url: http://x/a#anchor", .yaml)
        XCTAssertFalse(inWord.contains { $0.1 == .comment })
        // ...but a spaced one does.
        let spaced = kinds("key: value # note", .yaml)
        XCTAssertTrue(spaced.contains { $0.0 == "# note" && $0.1 == .comment })
    }

    func testShellVariables() {
        let segments = kinds("echo $HOME ${PATH} $(pwd)", .shell)
        XCTAssertTrue(segments.contains { $0.0 == "$HOME" && $0.1 == .property })
        XCTAssertTrue(segments.contains { $0.0 == "${PATH}" && $0.1 == .property })
        XCTAssertTrue(segments.contains { $0.0 == "$(pwd)" && $0.1 == .property })
    }

    func testSQLKeywordsCaseInsensitive() {
        XCTAssertEqual(kind(of: "select", in: "select id from t", .sql), .keyword)
        XCTAssertEqual(kind(of: "SELECT", in: "SELECT id FROM t", .sql), .keyword)
    }

    func testTOMLSectionHeader() {
        let lines = CodeHighlighter.highlight("[dependencies]\nname = \"serde\"", language: .toml)
        XCTAssertEqual(lines[0].segments.first?.kind, .meta)
        XCTAssertTrue(lines[1].segments.contains { $0.text == "\"serde\"" && $0.kind == .string })
    }

    func testMarkupTagsAttributesAndCommentCarry() {
        let lines = CodeHighlighter.highlight("<div class=\"row\">\n<!-- note\nstill -->\n</div>", language: .html)
        XCTAssertTrue(lines[0].segments.contains { $0.text == "<div" && $0.kind == .keyword })
        XCTAssertTrue(lines[0].segments.contains { $0.text == "class" && $0.kind == .property })
        XCTAssertTrue(lines[0].segments.contains { $0.text == "\"row\"" && $0.kind == .string })
        XCTAssertTrue(lines[1].segments.allSatisfy { $0.kind == .comment })
        XCTAssertTrue(lines[2].segments.allSatisfy { $0.kind == .comment })
        // "</div" and ">" are both keyword ink, so they merge into one run.
        XCTAssertTrue(lines[3].segments.contains { $0.text == "</div>" && $0.kind == .keyword })
    }

    func testPlainLanguageFastPath() {
        let lines = CodeHighlighter.highlight("anything at all // not a comment", language: nil)
        XCTAssertEqual(lines[0].segments.count, 1)
        XCTAssertEqual(lines[0].segments[0].kind, .plain)
    }

    func testHexAndUnderscoreNumbers() {
        XCTAssertEqual(kind(of: "0xFF", in: "let x = 0xFF", .swift), .number)
        XCTAssertEqual(kind(of: "1_000_000", in: "let y = 1_000_000", .swift), .number)
    }

    func testEmptyLinesKeepOneSegment() {
        let lines = CodeHighlighter.highlight("a\n\nb", language: .swift)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].text, "")
    }
}
