import Foundation

/// One language the dictation mic can listen in: a recognizer-supported
/// locale matched to one of the user's preferred languages.
struct DictationLanguageChoice: Equatable, Identifiable {
    /// The recognizer's own locale identifier (`"zh-TW"`, `"en-US"`) — what
    /// the Speech engines are handed, not necessarily what Settings shows.
    let id: String
    /// The language named in itself — "English", "中文", "日本語" — the way
    /// the system's own language pickers label their rows.
    let name: String
    /// The region tag ("US", "TW") that keeps two variants of one language
    /// apart in the menu; empty when the identifier carries none.
    let region: String

    /// "EN·US" — the compact face of the bar's language chip; the endonym
    /// is the menu's job, where there is room to spell it.
    var tag: String {
        id.uppercased().replacingOccurrences(of: "-", with: "·")
    }
}

/// Builds the dictation language menu the way the system keyboard builds its
/// own: the user's preferred languages (Settings → General → Language &
/// Region), in their order, kept only where the speech recognizer actually
/// supports the language.
enum DictationLanguages {
    /// `preferred` is `Locale.preferredLanguages`; `supported` is the
    /// recognizer's locale identifiers. Order follows `preferred`; languages
    /// the recognizer cannot hear are silently dropped, and two preferred
    /// entries that resolve to the same recognizer locale (zh-Hant beside
    /// zh-Hant-TW) collapse into one.
    static func choices(
        preferred: [String],
        supported: some Sequence<String>
    ) -> [DictationLanguageChoice] {
        // Shorter identifier first, so a language's plain entry ("hi-IN")
        // beats its variant siblings ("hi-IN-translit") when both collapse
        // to the same skeleton — `supported` arrives as an unordered set.
        var supportedBySkeleton: [String: String] = [:]
        for identifier in supported.sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
            let key = skeleton(identifier)
            if supportedBySkeleton[key] == nil { supportedBySkeleton[key] = identifier }
        }

        var taken: Set<String> = []
        return preferred.compactMap { language in
            guard let match = resolve(language, in: supportedBySkeleton),
                  taken.insert(match).inserted
            else { return nil }
            let locale = Locale(identifier: match)
            return DictationLanguageChoice(
                id: match,
                name: displayName(match, in: locale),
                region: locale.region?.identifier ?? ""
            )
        }
    }

    /// One preferred language → the recognizer locale that hears it, or nil.
    ///
    /// A real device tags EVERY preferred language with the device's own
    /// region — a Taiwan-region phone reports "en-TW" and "ja-TW", locales
    /// no recognizer has — so an exact match alone made the menu collapse to
    /// one row on real hardware while seeded simulators looked fine. When
    /// exact fails, the region is dropped and the language retried in its
    /// own home region ("en-TW" → "en" → en-Latn-US → en-US), keeping the
    /// script so zh-Hant can never fall to Simplified. The last resort is
    /// any supported locale of the same language and script, in sorted
    /// order so the answer never depends on set ordering.
    private static func resolve(
        _ language: String,
        in supportedBySkeleton: [String: String]
    ) -> String? {
        if let exact = supportedBySkeleton[skeleton(language)] { return exact }

        var components = Locale.Language.Components(
            identifier: Locale.Language(identifier: language).maximalIdentifier
        )
        components.region = nil
        let regionless = Locale.Language(components: components)
        if let home = supportedBySkeleton[regionless.maximalIdentifier.lowercased()] {
            return home
        }

        // The map's keys ARE lowercased maximal identifiers, so same
        // language + script is a prefix match on them — no re-maximalizing
        // the candidates. Smallest key wins for determinism.
        guard let code = regionless.languageCode?.identifier,
              let script = regionless.script?.identifier
        else { return nil }
        let prefix = "\(code)-\(script)-".lowercased()
        return supportedBySkeleton
            .filter { $0.key.hasPrefix(prefix) }
            .min { $0.key < $1.key }?
            .value
    }

    /// The persisted pick, or nil when nothing valid is stored — the stored
    /// language may have left the preferred list since it was chosen, and a
    /// stale pick must fall back to the system default rather than keep
    /// dictating in a language the user removed.
    static func chosen(
        stored: String?,
        among choices: [DictationLanguageChoice]
    ) -> DictationLanguageChoice? {
        guard let stored else { return nil }
        return choices.first { $0.id == stored }
    }

    /// What the LISTENING bar's chip shows and the menu marks, or nil when
    /// there is no real choice — one preferred language means no chip,
    /// matching the system keyboard's dictation. With nothing stored the
    /// effective language is the top preferred one, which is what the
    /// system-default recognizer listens in.
    static func effective(
        stored: String?,
        among choices: [DictationLanguageChoice]
    ) -> DictationLanguageChoice? {
        guard choices.count > 1 else { return nil }
        return chosen(stored: stored, among: choices) ?? choices.first
    }

    /// Two identifiers name the same dictation language when their maximal
    /// forms agree: "zh-Hant-TW", "zh-Hant", and "zh-TW" all maximize to
    /// zh-Hant-TW, and a bare "en" picks up Latn/US the same way the system
    /// does — one rule covers script-tagged preferred languages, region-less
    /// ones, and the recognizer's script-less identifiers alike.
    private static func skeleton(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).maximalIdentifier.lowercased()
    }

    private static func displayName(_ identifier: String, in locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier,
              let name = locale.localizedString(forLanguageCode: code)
        else { return identifier }
        // Endonyms arrive lowercased in many languages ("français"); the
        // pickers this mirrors show them as titles.
        return name.prefix(1).localizedUppercase + name.dropFirst()
    }
}
