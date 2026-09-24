import XCTest
@testable import Multiplex

final class DictationTextTests: XCTestCase {
    // MARK: Typed text

    func testOrdinarySpeechIsTypedVerbatim() {
        XCTAssertEqual(
            DictationText.typed("run the tests again"),
            "run the tests again"
        )
    }

    func testNothingHeardTypesNothing() {
        XCTAssertNil(DictationText.typed(""))
        XCTAssertNil(DictationText.typed("   \n\t "))
    }

    func testSurroundingAndRepeatedWhitespaceCollapses() {
        XCTAssertEqual(DictationText.typed("  hello   world  "), "hello world")
    }

    /// A spoken "new line" must never become a submit in a shell prompt or
    /// an agent composer — it is a word break like any other.
    func testLineBreaksBecomeWordBreaks() {
        let typed = DictationText.typed("line one\nline two")
        XCTAssertEqual(typed, "line one line two")
        XCTAssertEqual(typed?.contains("\n"), false)
        XCTAssertEqual(typed?.contains("\r"), false)
    }

    func testControlBytesCanNeverReachThePane() {
        XCTAssertEqual(DictationText.typed("before\u{1B}[Aafter"), "before [Aafter")
        XCTAssertEqual(DictationText.typed("a\u{0D}b"), "a b")
        XCTAssertEqual(DictationText.typed("a\u{02}b"), "a b")
    }

    /// Dictated text is the user's own words, not a generated path — quoting
    /// it the way `DropText` quotes a filename would make it useless.
    func testPunctuationShellCharactersAndNonASCIISurvive() {
        XCTAssertEqual(
            DictationText.typed("git commit -m \"fix: retry\""),
            "git commit -m \"fix: retry\""
        )
        XCTAssertEqual(DictationText.typed("重新執行測試"), "重新執行測試")
        XCTAssertEqual(DictationText.typed("rm -rf $HOME/tmp"), "rm -rf $HOME/tmp")
    }

    // MARK: Words

    /// The unit `DictationStream` commits at: the same sanitizing, kept
    /// unjoined so a settled prefix can go out without its tail.
    func testWordsSplitOnEverythingThatIsNotSpeech() {
        XCTAssertEqual(
            DictationText.words("run the\u{1B}tests\nagain"),
            ["run", "the", "tests", "again"]
        )
        XCTAssertEqual(DictationText.words("  "), [])
    }

    // MARK: Bar preview

    func testPreviewKeepsTheTailStillBeingRefined() {
        let long = String(repeating: "word ", count: 40)
        let preview = DictationText.preview(long, limit: 20)
        XCTAssertTrue(preview.hasPrefix("…"))
        XCTAssertEqual(preview.count, 21)
        XCTAssertEqual(DictationText.preview("short one", limit: 20), "short one")
        XCTAssertEqual(DictationText.preview("  ", limit: 20), "")
    }
}
