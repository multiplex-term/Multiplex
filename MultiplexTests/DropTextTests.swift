import XCTest
@testable import Multiplex

final class DropTextTests: XCTestCase {
    // MARK: Photo names

    func testPhotoNameUsesCaptureTimestampAndContentExtension() {
        let epoch = Date(timeIntervalSince1970: 0)
        let utc = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(
            DropText.photoName(at: epoch, timeZone: utc),
            "photo-19700101-000000.jpg"
        )
        XCTAssertEqual(
            DropText.photoName(
                at: epoch,
                filenameExtension: ".HEIC",
                timeZone: utc
            ),
            "photo-19700101-000000.heic"
        )
    }

    // MARK: Sanitizing

    func testSanitizedNamePassesNormalNamesThrough() {
        XCTAssertEqual(DropText.sanitizedName("report.pdf"), "report.pdf")
        XCTAssertEqual(DropText.sanitizedName("スクリーンショット 2026.png"), "スクリーンショット 2026.png")
    }

    func testSanitizedNameNeutralizesPathsAndControlChars() {
        XCTAssertEqual(DropText.sanitizedName("a/b.txt"), "a_b.txt")
        XCTAssertEqual(DropText.sanitizedName("..\\evil"), "_.._evil")
        XCTAssertEqual(DropText.sanitizedName("bad\u{1B}name"), "bad_name")
        XCTAssertEqual(DropText.sanitizedName("tab\tname"), "tab_name")
    }

    func testSanitizedNameBlocksFlagAndHiddenNames() {
        XCTAssertEqual(DropText.sanitizedName("-rf"), "_-rf")
        XCTAssertEqual(DropText.sanitizedName(".env"), "_.env")
        XCTAssertEqual(DropText.sanitizedName(""), "drop")
        XCTAssertEqual(DropText.sanitizedName("   "), "drop")
    }

    // MARK: Collision candidates

    func testCandidateNames() {
        XCTAssertEqual(DropText.candidate("report.pdf", attempt: 0), "report.pdf")
        XCTAssertEqual(DropText.candidate("report.pdf", attempt: 1), "report-2.pdf")
        XCTAssertEqual(DropText.candidate("report.pdf", attempt: 2), "report-3.pdf")
        // Counter sits before the LAST extension.
        XCTAssertEqual(DropText.candidate("archive.tar.gz", attempt: 1), "archive.tar-2.gz")
        // No extension → plain suffix.
        XCTAssertEqual(DropText.candidate("Makefile", attempt: 1), "Makefile-2")
        // Sanitized dotfiles start with "_" — the leading dot is not an ext.
        XCTAssertEqual(DropText.candidate("_.env", attempt: 1), "_-2.env")
    }

    // MARK: Typed text

    func testTypedQuotesOnlyWhenNeeded() {
        XCTAssertEqual(DropText.typed(path: "report.pdf"), "report.pdf")
        XCTAssertEqual(DropText.typed(path: "docs/spec-v2.md"), "docs/spec-v2.md")
        // The git corral path types clean, unquoted.
        XCTAssertEqual(
            DropText.typed(path: DropText.dropsDirectoryName + "/shot.png"),
            ".multiplex-drops/shot.png")
        XCTAssertEqual(DropText.typed(path: "my file.png"), "'my file.png'")
        XCTAssertEqual(DropText.typed(path: "it's.png"), "'it'\\''s.png'")
        XCTAssertEqual(DropText.typed(path: "a$(x).txt"), "'a$(x).txt'")
    }

    func testTypedPathsJoinWithTrailingSpaceAndNoReturn() {
        let text = DropText.typedPaths(["a.txt", "my file.png"])
        XCTAssertEqual(text, "a.txt 'my file.png' ")
        // Never submits — submission is always the user's.
        XCTAssertFalse(text.contains("\r"))
        XCTAssertFalse(text.contains("\n"))
        XCTAssertEqual(DropText.typedPaths([]), "")
    }
}
