#if !os(visionOS)
import UIKit
import XCTest
@testable import Multiplex

/// The LISTENING bar's language control: a native `UIMenu` behind a chip
/// face. Built and inspected scene-less — menus are introspectable without
/// presenting anything.
@MainActor
final class DictationLanguageMenuUIKitTests: XCTestCase {
    private let english = DictationLanguageChoice(
        id: "en-US", name: "English", region: "US"
    )
    private let chinese = DictationLanguageChoice(
        id: "zh-TW", name: "中文", region: "TW"
    )

    func testTheListeningBarCarriesTheLanguageMenuOnlyWithARealChoice() throws {
        let bar = TerminalContextBarView.dictation(
            .listening(""),
            language: chinese,
            choices: [english, chinese],
            stop: {}, cancel: {}, selectLanguage: { _ in }
        )
        let button = try XCTUnwrap(languageButton(in: bar))
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        XCTAssertEqual(
            button.accessibilityLabel,
            "Dictation language: 中文 TW. Change"
        )
        let actions = try XCTUnwrap(button.menu?.children as? [UIAction])
        XCTAssertEqual(actions.map(\.title), ["English (US)", "中文 (TW)"])
        // The mark sits on the effective language, so the menu tells the
        // truth before any pick exists.
        XCTAssertEqual(actions.map(\.state), [.off, .on])

        // One preferred language means nothing to choose: no chip at all.
        let single = TerminalContextBarView.dictation(
            .listening(""),
            language: nil,
            choices: [english],
            stop: {}, cancel: {}, selectLanguage: { _ in }
        )
        XCTAssertNil(languageButton(in: single))
    }

    func testThePickRoundTripsThroughItsStore() throws {
        let suite = "DictationLanguageMenuUIKitTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        DictationLanguageSetting.setChosen("zh-TW", defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: DictationLanguageSetting.key), "zh-TW"
        )
        DictationLanguageSetting.setChosen(nil, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: DictationLanguageSetting.key))
    }

    private func languageButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton,
           button.accessibilityIdentifier == "terminalPane.dictation.language" {
            return button
        }
        for child in view.subviews {
            if let found = languageButton(in: child) { return found }
        }
        return nil
    }
}
#endif
