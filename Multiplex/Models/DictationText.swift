import Foundation

/// Dictated speech is composer input, not a command: it is typed into the
/// pane exactly like a dropped file's path and never submitted (see
/// `DropText`). The recognizer hands back prose, so the only work here is
/// making it safe to hand to a shell that may be sitting at a prompt.
///
/// Nothing is quoted or escaped — unlike a generated path, this text is the
/// user's own words, and a shell-quoted sentence would be useless in an
/// agent composer. What *is* removed is anything that would act rather than
/// read: control bytes (an ESC would start an escape sequence, a CR would
/// submit the line the user is still dictating into) and the line breaks a
/// spoken "new line" can produce.
enum DictationText {
    /// The bytes to type for one finished dictation, or nil if the
    /// recognizer heard nothing worth sending.
    static func typed(_ raw: String) -> String? {
        var words: [String] = []
        var current = ""
        for scalar in raw.unicodeScalars {
            // Control characters and every line/paragraph separator collapse
            // to a word break rather than being dropped outright, so
            // "line one\nline two" cannot become "line oneline two".
            if scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                continue
            }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { words.append(current) }
        let text = words.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// The live partial shown in the dictation bar. Same sanitizing, but a
    /// long dictation must not push the bar past the window, so the tail is
    /// kept — that is the part still being refined.
    static func preview(_ raw: String, limit: Int = 60) -> String {
        guard let text = typed(raw) else { return "" }
        guard text.count > limit else { return text }
        return "…" + String(text.suffix(limit))
    }
}
