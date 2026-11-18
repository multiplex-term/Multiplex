import XCTest
@testable import Multiplex

final class FileViewerFindTests: XCTestCase {
    func testMatchesAreLiteralCaseInsensitiveAndNonOverlapping() {
        let text = "Foo.bar(foo) FOO aaaa"
        let result = FileViewerFind.matches(of: "foo", in: text)
        XCTAssertEqual(result.ranges.map(\.location), [0, 8, 13])
        XCTAssertFalse(result.truncated)
        // A pattern character is just a character.
        XCTAssertEqual(FileViewerFind.matches(of: ".", in: text).ranges.count, 1)
        XCTAssertEqual(FileViewerFind.matches(of: "(foo)", in: text).ranges.map(\.location), [7])
        // `aa` in `aaaa` is two hits, not three.
        XCTAssertEqual(FileViewerFind.matches(of: "aa", in: text).ranges.map(\.location), [17, 19])
    }

    func testRangesCountUTF16SoTheyIndexTheScreensText() {
        // 🙂 is two UTF-16 units; TextKit offsets count units, not characters.
        let text = "🙂 needle"
        let range = FileViewerFind.matches(of: "needle", in: text).ranges.first
        XCTAssertEqual(range, NSRange(location: 3, length: 6))
        XCTAssertEqual((text as NSString).substring(with: range!), "needle")
    }

    func testEmptyQueryMatchesNothingAndTheLimitTruncatesHonestly() {
        XCTAssertEqual(FileViewerFind.matches(of: "", in: "anything"), .empty)
        let text = String(repeating: "x", count: 50)
        let capped = FileViewerFind.matches(of: "x", in: text, limit: 10)
        XCTAssertEqual(capped.ranges.count, 10)
        XCTAssertTrue(capped.truncated)
        let exact = FileViewerFind.matches(of: "x", in: String(repeating: "x", count: 10), limit: 10)
        XCTAssertEqual(exact.ranges.count, 10)
        XCTAssertFalse(exact.truncated, "exactly the limit is the whole answer")
    }

    func testLandingAndSteppingWrapAtBothEnds() {
        let ranges = [5, 20, 40].map { NSRange(location: $0, length: 3) }
        XCTAssertEqual(FileViewerFind.index(atOrAfter: 0, in: ranges), 0)
        XCTAssertEqual(FileViewerFind.index(atOrAfter: 20, in: ranges), 1)
        XCTAssertEqual(FileViewerFind.index(atOrAfter: 21, in: ranges), 2)
        XCTAssertEqual(FileViewerFind.index(atOrAfter: 41, in: ranges), 0, "past the last wraps")
        XCTAssertNil(FileViewerFind.index(atOrAfter: 0, in: []))

        XCTAssertEqual(FileViewerFind.step(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(FileViewerFind.step(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(FileViewerFind.step(from: nil, by: 1, count: 3), 0)
        XCTAssertEqual(FileViewerFind.step(from: nil, by: -1, count: 3), 2)
        XCTAssertNil(FileViewerFind.step(from: 1, by: 1, count: 0))
    }

    func testReadout() {
        let two = FileViewerFind.Result(
            ranges: [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)],
            truncated: false
        )
        XCTAssertEqual(FileViewerFind.countText(current: 1, result: two, query: "a"), "2/2")
        XCTAssertEqual(FileViewerFind.countText(current: nil, result: two, query: "a"), "–/2")
        var capped = two
        capped.truncated = true
        XCTAssertEqual(FileViewerFind.countText(current: 0, result: capped, query: "a"), "1/2+")
        XCTAssertEqual(FileViewerFind.countText(current: nil, result: .empty, query: "a"), "NO MATCH")
        XCTAssertEqual(FileViewerFind.countText(current: nil, result: .empty, query: ""), "")
    }

    func testCorpusHitsNeverSpanTwoRunsAndLocateBackIntoTheirRun() throws {
        // `ab` would match across "...a" + "\n" + "b..." only if runs leaked.
        let corpus = FileViewerFindCorpus(runs: ["xa", "bx", "🙂ab"])
        XCTAssertEqual(corpus.text, "xa\nbx\n🙂ab")
        XCTAssertEqual(corpus.runStarts, [0, 3, 6])
        XCTAssertEqual(corpus.matches(of: "ab").ranges, [NSRange(location: 8, length: 2)])
        XCTAssertEqual(corpus.matches(of: "a\nb").ranges, [], "a separator is not text")
        let located = try XCTUnwrap(corpus.locate(NSRange(location: 8, length: 2)))
        XCTAssertEqual(located.run, 2)
        XCTAssertEqual(located.range, NSRange(location: 2, length: 2))
        XCTAssertNil(corpus.locate(NSRange(location: 1, length: 3)), "a range across runs has no home")

        let capped = FileViewerFindCorpus(runs: ["xx", "xx", "xx"]).matches(of: "x", limit: 4)
        XCTAssertEqual(capped.ranges.count, 4)
        XCTAssertTrue(capped.truncated, "the cap holds across runs")
        XCTAssertFalse(FileViewerFindCorpus(runs: ["xx", "xx"]).matches(of: "x", limit: 4).truncated)
        XCTAssertEqual(FileViewerFindCorpus(text: "one").runStarts, [0])
    }

    func testMarkdownRunsSpellThePreviewNotTheSource() {
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, inlines: [.text("Setup", [.bold])]),
            .paragraph(inlines: [
                .text("Run ", []), .code("make"), .text(" — see ", []),
                .link(text: "the guide", destination: "docs/guide.md"),
                .image(alt: "shot", destination: "shot.png"),
            ]),
            .rule,
            .quote(blocks: [.listItem(marker: "•", level: 0, inlines: [])]),
            .table(header: [[.text("Key", [])], [.text("Value", [])]], rows: [[[.text("a", [])]]]),
        ]
        let runs = MarkdownFindText.runs(for: blocks)
        XCTAssertEqual(runs.map(\.text), [
            "Setup",
            "Run make — see the guide⟨image: shot⟩",
            " ", // an empty list item draws one space
            "Key", "Value", "a", " ",
        ])
        XCTAssertEqual(runs.map(\.block), [0, 1, 3, 4, 4, 4, 4], "a rule has no run")
        XCTAssertEqual(
            MarkdownFindText.runs(for: [blocks[1]], shownImages: ["shot.png"]).first?.text,
            "Run make — see the guide⌄ image: shot"
        )
        // Markup the preview hides is not searchable there.
        XCTAssertTrue(FileViewerFindCorpus(runs: runs.map(\.text)).matches(of: "](").ranges.isEmpty)
    }

    func testMarkdownFenceRunKeepsTheFencesLineBreaks() {
        XCTAssertEqual(MarkdownFindText.fence(language: nil, lines: ["a", "", "b"]), "a\n \nb")
        XCTAssertEqual(MarkdownFindText.fence(language: .swift, lines: ["let a", "", "}"]), "let a\n \n}")
        XCTAssertEqual(MarkdownFindText.fence(language: nil, lines: ["a", ""]), "a", "a trailing blank line is dropped")
        XCTAssertEqual(MarkdownFindText.fence(language: nil, lines: []), " ")
    }
}
