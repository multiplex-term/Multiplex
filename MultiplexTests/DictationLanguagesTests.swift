import XCTest
@testable import Multiplex

final class DictationLanguagesTests: XCTestCase {
    /// The recognizer identifiers that matter for these cases, as
    /// `SFSpeechRecognizer.supportedLocales()` reports them (script-less,
    /// hyphenated, unordered).
    private let supported: Set<String> = [
        "en-US", "en-GB", "en-AU", "ja-JP", "ko-KR",
        "zh-TW", "zh-CN", "zh-HK", "yue-CN", "fr-FR", "es-419",
        "hi-IN", "hi-IN-translit", "hi-Latn",
    ]

    // MARK: Building the menu

    func testMenuKeepsSettingsOrderAndDropsUnheardLanguages() {
        let choices = DictationLanguages.choices(
            preferred: ["ja-JP", "en-US", "en-GB", "eo"],
            supported: supported
        )
        XCTAssertEqual(choices.map(\.id), ["ja-JP", "en-US", "en-GB"])
    }

    /// Settings spells languages the recognizer doesn't: script tags
    /// ("zh-Hant-TW" for Speech's "zh-TW"), region-less entries ("en",
    /// "zh-Hant"), and two spellings of one language. All must land on one
    /// recognizer locale each, in Settings order.
    func testSettingsSpellingsCollapseOntoRecognizerLocales() {
        let choices = DictationLanguages.choices(
            preferred: ["zh-Hant", "zh-Hant-TW", "en"],
            supported: supported
        )
        XCTAssertEqual(choices.map(\.id), ["zh-TW", "en-US"])
    }

    /// A real device tags EVERY preferred language with the device's own
    /// region: a Taiwan phone reports "en-TW" and "ja-TW", locales no
    /// recognizer has — those must land on the language's home locale, not
    /// vanish (shipped-and-caught: the menu collapsed to one row on every
    /// real device). The fallback must also never cross scripts:
    /// "zh-Hant-US" is zh-TW, never Simplified.
    func testDeviceRegionTaggedLanguagesLandOnTheLanguagesHomeLocale() {
        let choices = DictationLanguages.choices(
            preferred: ["zh-Hant-US", "en-TW", "ja-TW"],
            supported: supported
        )
        XCTAssertEqual(choices.map(\.id), ["zh-TW", "en-US", "ja-JP"])
    }

    /// The recognizer ships variant siblings of one language (hi-IN beside
    /// hi-IN-translit). The plain identifier must win deterministically —
    /// `supportedLocales()` is a set, and hash order changing the language a
    /// user dictates in would be a ghost bug.
    func testPlainIdentifierBeatsItsVariantSiblings() {
        let choices = DictationLanguages.choices(
            preferred: ["hi-IN"],
            supported: supported
        )
        XCTAssertEqual(choices.map(\.id), ["hi-IN"])
    }

    func testRowsCarryEndonymRegionAndTag() {
        let choices = DictationLanguages.choices(
            preferred: ["ja-JP", "fr-FR"],
            supported: supported
        )
        XCTAssertEqual(choices.map(\.name), ["日本語", "Français"])
        XCTAssertEqual(choices.map(\.region), ["JP", "FR"])
        XCTAssertEqual(choices.map(\.tag), ["JA·JP", "FR·FR"])
    }

    // MARK: Resolving the pick

    /// The pick outlives Settings changes: it resolves while its language
    /// stays preferred, and a language removed from the list must stop
    /// being dictated rather than linger via the stale stored identifier.
    func testStoredPickResolvesOnlyWhileItsLanguageStaysPreferred() {
        let both = DictationLanguages.choices(
            preferred: ["en-US", "ja-JP"],
            supported: supported
        )
        XCTAssertEqual(
            DictationLanguages.chosen(stored: "ja-JP", among: both)?.id, "ja-JP"
        )
        XCTAssertNil(DictationLanguages.chosen(stored: nil, among: both))

        let englishOnly = DictationLanguages.choices(
            preferred: ["en-US"],
            supported: supported
        )
        XCTAssertNil(DictationLanguages.chosen(stored: "ja-JP", among: englishOnly))
    }

    /// What the chip shows: the stored pick, else the top preferred
    /// language (what the system-default recognizer listens in) — and nil
    /// with a single choice, where no chip appears at all.
    func testEffectiveLanguageIsStoredPickOrTopPreferredAndNeedsARealChoice() {
        let both = DictationLanguages.choices(
            preferred: ["en-US", "ja-JP"],
            supported: supported
        )
        XCTAssertEqual(DictationLanguages.effective(stored: nil, among: both)?.id, "en-US")
        XCTAssertEqual(DictationLanguages.effective(stored: "ja-JP", among: both)?.id, "ja-JP")

        let englishOnly = DictationLanguages.choices(
            preferred: ["en-US"],
            supported: supported
        )
        XCTAssertNil(DictationLanguages.effective(stored: "en-US", among: englishOnly))
    }
}
