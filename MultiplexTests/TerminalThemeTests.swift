import XCTest
@testable import Multiplex

final class TerminalThemeTests: XCTestCase {
    // MARK: ThemeColor hex

    func testHexStringRoundTrip() {
        let amber = ThemeColor(hexString: "#FFB000")
        XCTAssertEqual(amber, ThemeColor(red: 0xFF, green: 0xB0, blue: 0x00))
        XCTAssertEqual(amber?.hexString, "#FFB000")
    }

    func testHexParsingIsLenientAboutCaseAndHash() {
        XCTAssertEqual(ThemeColor(hexString: "0c0e13"), ThemeColor(0x0C0E13))
        XCTAssertEqual(ThemeColor(hexString: " #a9b665 "), ThemeColor(0xA9B665))
    }

    func testInvalidHexIsRejected() {
        XCTAssertNil(ThemeColor(hexString: ""))
        XCTAssertNil(ThemeColor(hexString: "#FFF"))
        XCTAssertNil(ThemeColor(hexString: "#GGGGGG"))
        XCTAssertNil(ThemeColor(hexString: "#FFB000FF"))
    }

    // MARK: Codable

    func testThemeColorEncodesAsHexString() throws {
        let data = try JSONEncoder().encode([ThemeColor(0xFFB000)])
        XCTAssertEqual(String(data: data, encoding: .utf8), ##"["#FFB000"]"##)
    }

    func testThemeRoundTripsThroughJSON() throws {
        let original = TerminalTheme.multiplex.asCustom(named: "Mine")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalTheme.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCorruptColorFailsDecoding() {
        let json = Data(##"{"id":"custom-x","name":"Bad","background":"nope","foreground":"#FFFFFF","cursor":"#FFFFFF","ansi":[]}"##.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalTheme.self, from: json))
    }

    // MARK: Built-ins

    func testBuiltInsAreComplete() {
        XCTAssertGreaterThanOrEqual(TerminalTheme.builtIns.count, 5)
        for theme in TerminalTheme.builtIns {
            XCTAssertTrue(theme.isBuiltIn, "\(theme.id) must not use the custom prefix")
            XCTAssertTrue(theme.isValid, "\(theme.id) must carry all 16 ANSI colors")
            XCTAssertFalse(theme.name.isEmpty)
        }
    }

    func testBuiltInIDsAreUnique() {
        let ids = TerminalTheme.builtIns.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testDefaultThemeMatchesDesignTokens() {
        let theme = TerminalTheme.multiplex
        XCTAssertEqual(theme.background.hexString, "#0C0E13")
        XCTAssertEqual(theme.foreground.hexString, "#E9E4D8")
        XCTAssertEqual(theme.cursor.hexString, "#FFB000")
    }

    // MARK: Dark / light

    func testDarkAndLightDetection() {
        XCTAssertTrue(TerminalTheme.multiplex.isDark)
        XCTAssertTrue(TerminalTheme.dracula.isDark)
        XCTAssertFalse(TerminalTheme.solarizedLight.isDark)
    }

    func testTallyLightFamilyShipsComplete() {
        for theme in [TerminalTheme.tallyPaper, .tallyIvory, .tallyFrost] {
            XCTAssertTrue(TerminalTheme.builtIns.contains(theme), "\(theme.id) must be a built-in")
            XCTAssertTrue(theme.isValid)
            XCTAssertFalse(theme.isDark, "\(theme.id) must read as light (keyboard appearance)")
        }
        XCTAssertEqual(TerminalTheme.lightDefault, .tallyFrost,
                       "the light house default pairs with the Frost chassis")
    }

    /// The light family's design contract (docs in the bake-off record):
    /// foreground ≥ 12:1, workhorse ANSI 1–6 ≥ 4.2:1, bright-black — the
    /// comment color — ≥ 4.3:1, all against that theme's own background.
    func testTallyLightFamilyKeepsReadableContrast() {
        func contrast(_ a: ThemeColor, _ b: ThemeColor) -> Double {
            let bright = max(a.luminance, b.luminance)
            let dim = min(a.luminance, b.luminance)
            return (bright + 0.05) / (dim + 0.05)
        }
        for theme in [TerminalTheme.tallyPaper, .tallyIvory, .tallyFrost] {
            XCTAssertGreaterThanOrEqual(
                contrast(theme.foreground, theme.background), 12, "\(theme.id) foreground")
            for index in 1...6 {
                XCTAssertGreaterThanOrEqual(
                    contrast(theme.ansi[index], theme.background), 4.2,
                    "\(theme.id) ANSI \(index) (\(TerminalTheme.ansiNames[index]))")
            }
            XCTAssertGreaterThanOrEqual(
                contrast(theme.ansi[8], theme.background), 4.3, "\(theme.id) bright black")
        }
    }

    // MARK: Custom copies

    func testAsCustomMintsFreshIdentity() {
        let base = TerminalTheme.nord
        let copy = base.asCustom(named: "Nordish")
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertNotEqual(copy.id, base.id)
        XCTAssertEqual(copy.name, "Nordish")
        XCTAssertEqual(copy.ansi, base.ansi)

        let second = base.asCustom(named: "Nordish")
        XCTAssertNotEqual(copy.id, second.id, "every copy gets its own id")
    }
}
