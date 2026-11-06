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
}
