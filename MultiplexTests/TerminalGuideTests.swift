import XCTest
@testable import Multiplex

final class TerminalGuideTests: XCTestCase {
    func testDeckIntegrityAndCanonicalFigures() {
        let entries = TerminalGuide.allEntries
        XCTAssertEqual(entries.count, 14)

        let figures = entries.compactMap(\.figure)
        XCTAssertEqual(figures, Array(1...13))
        XCTAssertEqual(Set(figures).count, 13)
        for entry in entries {
            XCTAssertFalse(entry.title.isEmpty, entry.id)
            XCTAssertFalse(entry.body.isEmpty, entry.id)
            XCTAssertFalse(entry.bodyText.isEmpty, entry.id)
        }
    }

    func testVisionTmuxFiltering() {
        let entries = TerminalGuide.entries(for: TerminalGuideContext(
            platform: .vision,
            backendIsHerdr: false
        ))
        XCTAssertEqual(entries.map(\.id), [
            "doubletap", "longpress", "rightclick", "pan",
            "link", "path", "shiftreturn", "shortcutkey",
        ])
    }

    func testPhoneTmuxFiltering() {
        let entries = TerminalGuide.entries(for: TerminalGuideContext(
            platform: .phone,
            backendIsHerdr: false
        ))
        XCTAssertTrue(entries.map(\.id).contains("edgeswipe"))
        XCTAssertFalse(entries.contains { $0.bank == .herdrPanes })
    }

    func testPadHerdrFiltering() {
        let entries = TerminalGuide.entries(for: TerminalGuideContext(
            platform: .pad,
            backendIsHerdr: true
        ))
        let ids = entries.map(\.id)
        XCTAssertFalse(ids.contains("edgeswipe"))
        XCTAssertTrue(ids.contains("resize"))
        XCTAssertTrue(ids.contains("panemenu"))
        XCTAssertTrue(ids.contains("paste"))
    }

    func testFilteringPreservesCanonicalFigureNumbers() throws {
        let entries = TerminalGuide.entries(for: TerminalGuideContext(
            platform: .vision,
            backendIsHerdr: false
        ))
        let link = try XCTUnwrap(entries.first { $0.id == "link" })
        XCTAssertEqual(link.figure, 6)
        XCTAssertEqual(entries.compactMap(\.figure), [1, 2, 3, 4, 6, 7, 10, 11])
    }

    func testBankOrder() {
        XCTAssertEqual(TerminalGuideBank.allCases, [
            .touchPointer,
            .linksPaths,
            .keyboard,
            .herdrPanes,
            .clipboard,
        ])
    }
}
