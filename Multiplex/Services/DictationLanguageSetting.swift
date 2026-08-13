#if !os(visionOS)
import Foundation
import Speech

/// The dictation language pick, persisted app-wide: dictation is one feature
/// reachable from two mic controls, and a language chosen at either applies
/// everywhere. Nothing stored — the default — means the system language,
/// exactly the behavior before picking existed.
@MainActor
enum DictationLanguageSetting {
    nonisolated static let key = "MultiplexDictationLanguage"

    /// What the recognizer can hear never changes within a run; the XPC
    /// round trip behind `supportedLocales()` is paid once.
    private static let supportedIdentifiers: [String] =
        SFSpeechRecognizer.supportedLocales().map(\.identifier)

    /// The LISTENING bar re-renders on every hypothesis while someone is
    /// speaking, and building the menu walks ICU for every identifier —
    /// memoized on the preferred-language list, which is also what
    /// invalidates it when Settings change mid-run.
    private static var cache: (preferred: [String], choices: [DictationLanguageChoice])?

    /// The menu: preferred languages the recognizer can hear.
    static func choices() -> [DictationLanguageChoice] {
        let preferred = Locale.preferredLanguages
        if let cache, cache.preferred == preferred { return cache.choices }
        let built = DictationLanguages.choices(
            preferred: preferred,
            supported: supportedIdentifiers
        )
        cache = (preferred, built)
        return built
    }

    /// The persisted pick, resolved against today's menu — nil when nothing
    /// valid is stored, meaning the system default.
    static func chosen(defaults: UserDefaults = .standard) -> DictationLanguageChoice? {
        DictationLanguages.chosen(
            stored: defaults.string(forKey: key),
            among: choices()
        )
    }

    /// The locale handed to the recognition engines, or nil for the system
    /// default (the engines' own no-locale initializers).
    static func chosenLocale(defaults: UserDefaults = .standard) -> Locale? {
        chosen(defaults: defaults).map { Locale(identifier: $0.id) }
    }

    /// What the LISTENING bar's chip shows, resolved against an
    /// already-built menu so a render pays for the list once.
    static func effectiveChoice(
        among choices: [DictationLanguageChoice],
        defaults: UserDefaults = .standard
    ) -> DictationLanguageChoice? {
        DictationLanguages.effective(
            stored: defaults.string(forKey: key),
            among: choices
        )
    }

    nonisolated static func setChosen(
        _ identifier: String?,
        defaults: UserDefaults = .standard
    ) {
        if let identifier {
            defaults.set(identifier, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
#endif
