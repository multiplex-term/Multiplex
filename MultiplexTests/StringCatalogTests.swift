import XCTest
@testable import Multiplex

/// The String Catalogs are the localization: a key that lands in the catalog
/// without a zh-Hant and ja value falls back to English silently at runtime.
/// This test makes that fall-back loud instead. `needs_review` counts as
/// translated (a native reviewer's pass is expected, not required to ship);
/// keys marked `shouldTranslate: false` are the TALLY chrome that stays
/// English by design (see docs/agents/i18n.md).
final class StringCatalogTests: XCTestCase {
    private static let locales = ["zh-Hant", "ja"]

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MultiplexTests
        .deletingLastPathComponent()  // repo

    private struct Unit: Decodable { let state: String; let value: String }
    private struct Localization: Decodable {
        let stringUnit: Unit?
        let variations: [String: [String: [String: Unit]]]?
    }
    private struct Entry: Decodable {
        let extractionState: String?
        let shouldTranslate: Bool?
        let localizations: [String: Localization]?
    }
    private struct Catalog: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private func load(_ relative: String) throws -> Catalog {
        let url = Self.repoRoot.appendingPathComponent(relative)
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    private func assertComplete(_ relative: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let catalog = try load(relative)
        XCTAssertEqual(catalog.sourceLanguage, "en", file: file, line: line)
        var missing: [String] = []
        for (key, entry) in catalog.strings {
            if entry.shouldTranslate == false { continue }
            if entry.extractionState == "stale" { continue }
            for locale in Self.locales {
                let localization = entry.localizations?[locale]
                let value = localization?.stringUnit?.value
                    ?? localization?.variations?.values.first?.values.first?.values.first?.value
                if value?.isEmpty ?? true { missing.append("\(locale): \(key)") }
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            "\(relative) has \(missing.count) untranslated keys:\n" + missing.sorted().joined(separator: "\n"),
            file: file, line: line
        )
    }

    func testAppCatalogIsComplete() throws {
        try assertComplete("Multiplex/Localizable.xcstrings")
    }

    func testInfoPlistCatalogIsComplete() throws {
        try assertComplete("Multiplex/InfoPlist.xcstrings")
    }

    func testWidgetCatalogIsComplete() throws {
        try assertComplete("MultiplexWidgets/Localizable.xcstrings")
    }

    /// The compiled bundle carries both languages, so Settings.app offers the
    /// per-app language row (the only language switch Multiplex has).
    func testBundleShipsBothLocalizations() {
        let shipped = Set(Bundle.main.localizations)
        for locale in Self.locales {
            XCTAssertTrue(shipped.contains(locale), "bundle lacks \(locale): \(shipped)")
        }
    }
}
