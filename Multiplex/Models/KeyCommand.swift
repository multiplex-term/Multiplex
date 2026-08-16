import Foundation

/// One saved Key Command — what the CTRL key's hold panel can send in a
/// press: a key chord (modifiers + one key) or a text snippet, repeated
/// under a fixed guard, with a rule for whether the panel closes on press.
///
/// Pure model: no encoding lives here. A chord is encoded by the terminal
/// view at press time (`TerminalView.bytes(for:)`), so it always matches what
/// a hardware keyboard would send in the terminal's current mode.
struct KeyCommand: Identifiable, Codable, Hashable {
    enum Kind: Codable, Hashable {
        case chord(KeyChord)
        case text(KeyTextSnippet)
    }

    var id: UUID
    var kind: Kind
    /// How many times one press sends the command. Clamped by
    /// `KeyCommandRepeatGuard`.
    var repeatCount: Int
    /// The gap between repeated sends. Meaningless at `repeatCount == 1` but
    /// kept so a row remembers its setting when the count comes back.
    var repeatGapMilliseconds: Int
    /// CLOSE ON PRESS: the panel drops with the send. Off keeps it up so a
    /// key like Option+Backspace can be pressed again without reopening.
    var closesPanel: Bool
    /// One of the three shipped defaults (never wears the custom ink).
    var isShipped: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        repeatCount: Int = 1,
        repeatGapMilliseconds: Int = KeyCommandRepeatGuard.defaultGapMilliseconds,
        closesPanel: Bool = true,
        isShipped: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.repeatCount = repeatCount
        self.repeatGapMilliseconds = repeatGapMilliseconds
        self.closesPanel = closesPanel
        self.isShipped = isShipped
    }

    var isRepeating: Bool { repeatCount > 1 }

    var chord: KeyChord? {
        if case .chord(let chord) = kind { return chord }
        return nil
    }

    var textSnippet: KeyTextSnippet? {
        if case .text(let snippet) = kind { return snippet }
        return nil
    }

    /// The derived label — there is no name field. Chords spell their keys
    /// (SHIFT ENTER · CTRL C); text rows are their own text, one line,
    /// truncated like an agent bar label.
    var name: String {
        switch kind {
        case .chord(let chord): chord.name
        case .text(let snippet): snippet.label
        }
    }

    /// The keycap faces the COMMANDS grid and setup rows draw.
    var faces: [KeyCapFace] {
        switch kind {
        case .chord(let chord): chord.faces
        case .text(let snippet): [.text(snippet.label)]
        }
    }

    /// The three voices of "everything the face doesn't say" — the setup
    /// row's caps readout, the grid cell's quieter hint (defaults omitted),
    /// and the spoken form — from one walk over the same fields.
    enum ReadoutStyle {
        case row
        case cellHint
        case spoken
    }

    /// The row's readout of everything the face doesn't say.
    var readout: String { readout(.row) }

    func readout(_ style: ReadoutStyle) -> String {
        let submits = textSnippet?.submits == true
        switch style {
        case .row:
            var parts: [String] = []
            if submits { parts.append("SUBMITS") }
            parts.append(isRepeating ? "×\(repeatCount) · \(repeatGapMilliseconds) MS" : "×1")
            parts.append(closesPanel ? "CLOSES" : "STAYS")
            return parts.joined(separator: " · ")
        case .cellHint:
            var parts: [String] = []
            if submits { parts.append("submits") }
            if isRepeating { parts.append("×\(repeatCount) · \(repeatGapMilliseconds) ms") }
            if !closesPanel { parts.append("stays open") }
            return parts.joined(separator: " · ")
        case .spoken:
            var text: String
            switch kind {
            case .chord(let chord): text = chord.accessibilityName
            case .text(let snippet): text = "Type \(snippet.normalizedText)"
            }
            if submits { text += ", then Enter" }
            if isRepeating { text += ", \(repeatCount) times" }
            text += closesPanel ? ", closes the panel" : ", panel stays open"
            return text
        }
    }

    /// True when the command can be sent: a chord always can; a text row
    /// needs text.
    var isSendable: Bool {
        switch kind {
        case .chord: true
        case .text(let snippet): !snippet.normalizedText.isEmpty
        }
    }

    /// The command with its repeat under the guard and its text normalized.
    var normalized: KeyCommand {
        var command = self
        let clamped = KeyCommandRepeatGuard.clamp(
            count: repeatCount,
            gapMilliseconds: repeatGapMilliseconds
        )
        command.repeatCount = clamped.count
        command.repeatGapMilliseconds = clamped.gapMilliseconds
        if case .text(var snippet) = kind {
            snippet.text = snippet.normalizedText
            command.kind = .text(snippet)
        }
        return command
    }
}

/// Modifiers plus one key. Letters and digits arrive as one character; the
/// terminal view lowercases the base and reports the shifted form itself.
struct KeyChord: Codable, Hashable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: Int

        static let control = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)

        /// Canonical keycap order — ⌃ ⇧ ⌥ — the order macOS prints chords.
        static let ordered: [Modifiers] = [.control, .shift, .option]
    }

    enum Key: Codable, Hashable {
        case enter, tab, escape, delete, space
        case up, down, left, right
        /// One printable character (a letter, digit, or symbol).
        case character(String)

        /// The composer's fixed key set: the editing keys, then the direction
        /// keys (a phone popover puts the two on separate lines).
        static let composerEditingSet: [Key] = [.enter, .tab, .escape, .delete, .space]
        static let composerArrowSet: [Key] = [.up, .down, .left, .right]

        var face: KeyCapFace {
            switch self {
            case .enter: .symbol("return", glyph: "↩")
            case .tab: .symbol("arrow.right.to.line", glyph: "⇥")
            case .escape: .symbol("escape", glyph: "⎋")
            case .delete: .symbol("delete.left", glyph: "⌫")
            case .space: .symbol("space", glyph: "␣")
            case .up: .symbol("arrow.up", glyph: "↑")
            case .down: .symbol("arrow.down", glyph: "↓")
            case .left: .symbol("arrow.left", glyph: "←")
            case .right: .symbol("arrow.right", glyph: "→")
            case .character(let character): .text(character.uppercased())
            }
        }

        var word: String {
            switch self {
            case .enter: "ENTER"
            case .tab: "TAB"
            case .escape: "ESC"
            case .delete: "DELETE"
            case .space: "SPACE"
            case .up: "UP"
            case .down: "DOWN"
            case .left: "LEFT"
            case .right: "RIGHT"
            case .character(let character): character.uppercased()
            }
        }

        var accessibilityWord: String {
            switch self {
            case .escape: "Escape"
            case .character(let character): character.uppercased()
            default: word.capitalized
            }
        }

        /// A composer field accepts exactly one printable character; anything
        /// else (paste, control bytes, an emoji cluster) is refused. Letters
        /// are kept lowercase — the base key — so a chord without ⇧ types
        /// the lowercase letter; the face and name uppercase for display.
        static func fromFieldText(_ text: String) -> Key? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count == 1,
                  let scalar = trimmed.unicodeScalars.first,
                  trimmed.unicodeScalars.count == 1,
                  scalar.isASCII,
                  !CharacterSet.controlCharacters.contains(scalar)
            else { return nil }
            return .character(trimmed.lowercased())
        }
    }

    var modifiers: Modifiers
    var key: Key

    init(modifiers: Modifiers = [], key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    var faces: [KeyCapFace] {
        Modifiers.ordered.filter { modifiers.contains($0) }.map(\.face) + [key.face]
    }

    /// SHIFT ENTER · CTRL C · OPTION UP — modifiers in keycap order, then the
    /// key.
    var name: String {
        (Modifiers.ordered.filter { modifiers.contains($0) }.map(\.word) + [key.word])
            .joined(separator: " ")
    }

    var accessibilityName: String {
        (Modifiers.ordered.filter { modifiers.contains($0) }.map(\.accessibilityWord)
            + [key.accessibilityWord])
            .joined(separator: " ")
    }
}

extension KeyChord.Modifiers {
    var face: KeyCapFace {
        switch self {
        case .control: .symbol("control", glyph: "⌃")
        case .shift: .symbol("shift", glyph: "⇧")
        case .option: .symbol("option", glyph: "⌥")
        default: .text("?")
        }
    }

    var word: String {
        switch self {
        case .control: "CTRL"
        case .shift: "SHIFT"
        case .option: "OPTION"
        default: ""
        }
    }

    var accessibilityWord: String {
        switch self {
        case .control: "Control"
        case .shift: "Shift"
        case .option: "Option"
        default: ""
        }
    }
}

/// One line of text the panel types, optionally followed by Enter (a CR
/// sent ~160 ms after the text — the slash-chip shape).
struct KeyTextSnippet: Codable, Hashable {
    static let maximumLabelLength = 12

    var text: String
    var submits: Bool

    init(text: String, submits: Bool = true) {
        self.text = text
        self.submits = submits
    }

    /// One line, no terminal control bytes (a pasted Ctrl-B would arm the
    /// remote prefix), trimmed at both ends.
    var normalizedText: String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let safe = flattened.unicodeScalars.reduce(into: "") { result, scalar in
            if scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar) {
                result.append(Character(scalar))
            }
        }
        return safe.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The face and name: the first characters of the text, `...` when cut.
    var label: String {
        let text = normalizedText.replacingOccurrences(of: "\t", with: "⇥")
        guard text.count > Self.maximumLabelLength else { return text }
        return String(text.prefix(Self.maximumLabelLength)) + "..."
    }
}

/// What a keycap draws: an SF Symbol with a plain-text fallback, or text.
struct KeyCapFace: Hashable {
    var symbolName: String?
    var text: String

    static func symbol(_ name: String, glyph: String) -> KeyCapFace {
        KeyCapFace(symbolName: name, text: glyph)
    }

    static func text(_ text: String) -> KeyCapFace {
        KeyCapFace(symbolName: nil, text: text)
    }
}

/// The fixed ceiling on repeats. Values clamp; the composer says so instead
/// of erroring.
enum KeyCommandRepeatGuard {
    static let maximumCount = 5
    static let gapRange = 50...500
    static let defaultGapMilliseconds = 150
    /// Whole burst — the last send lands within this of the first.
    static let burstLimitMilliseconds = 2000
    static let gapStep = 50

    struct Clamped: Equatable {
        var count: Int
        var gapMilliseconds: Int
        var wasClamped: Bool
    }

    static func burstMilliseconds(count: Int, gapMilliseconds: Int) -> Int {
        max(0, count - 1) * gapMilliseconds
    }

    static func clamp(count: Int, gapMilliseconds: Int) -> Clamped {
        var clampedCount = min(max(1, count), maximumCount)
        var clampedGap = min(max(gapRange.lowerBound, gapMilliseconds), gapRange.upperBound)
        var wasClamped = clampedCount != count || clampedGap != gapMilliseconds
        // The burst limit gives way on the gap first (a repeat you asked for
        // is worth more than the exact spacing), then on the count.
        while burstMilliseconds(count: clampedCount, gapMilliseconds: clampedGap)
            > burstLimitMilliseconds {
            wasClamped = true
            if clampedGap - gapStep >= gapRange.lowerBound {
                clampedGap -= gapStep
            } else if clampedCount > 1 {
                clampedCount -= 1
            } else {
                break
            }
        }
        return Clamped(count: clampedCount, gapMilliseconds: clampedGap, wasClamped: wasClamped)
    }
}

/// The whole persisted set, ordered as the grid shows it.
struct KeyCommandSet: Codable, Equatable {
    static let maximumCount = 12

    var commands: [KeyCommand]
    var updatedAt: Date

    /// Stable IDs so a device that never edited the set and one that did
    /// merge to the same three rows.
    static let shiftEnterID = UUID(uuidString: "5B2E4C1A-0001-4E6B-9F52-9A5C0F0E0001")!
    static let doubleControlCID = UUID(uuidString: "5B2E4C1A-0002-4E6B-9F52-9A5C0F0E0002")!
    static let optionDeleteID = UUID(uuidString: "5B2E4C1A-0003-4E6B-9F52-9A5C0F0E0003")!

    /// ⇧↩ (closes) · ⌃C ×2 at 150 ms (closes) · ⌥⌫ delete-word (stays —
    /// the point of a staying key is pressing it a few times without
    /// reopening).
    static let shipped: [KeyCommand] = [
        KeyCommand(
            id: shiftEnterID,
            kind: .chord(KeyChord(modifiers: [.shift], key: .enter)),
            isShipped: true
        ),
        KeyCommand(
            id: doubleControlCID,
            kind: .chord(KeyChord(modifiers: [.control], key: .character("c"))),
            repeatCount: 2,
            repeatGapMilliseconds: 150,
            isShipped: true
        ),
        KeyCommand(
            id: optionDeleteID,
            kind: .chord(KeyChord(modifiers: [.option], key: .delete)),
            closesPanel: false,
            isShipped: true
        ),
    ]

    static var initial: KeyCommandSet {
        KeyCommandSet(commands: shipped, updatedAt: .distantPast)
    }

    /// Repeats under the guard, text trimmed, empty text rows dropped,
    /// duplicate IDs made unique, and the cap applied.
    static func normalized(_ commands: [KeyCommand]) -> [KeyCommand] {
        var seen = Set<UUID>()
        var result: [KeyCommand] = []
        for command in commands {
            var normalized = command.normalized
            guard normalized.isSendable else { continue }
            if seen.contains(normalized.id) { normalized.id = UUID() }
            seen.insert(normalized.id)
            result.append(normalized)
            if result.count == maximumCount { break }
        }
        return result
    }
}

/// Plain-words spelling of a byte sequence for the composer's SENDS readout:
/// control bytes by name, escapes as `ESC`, everything printable as itself.
enum KeyBytesNotation {
    static func describe(_ bytes: [UInt8]) -> String {
        var words: [String] = []
        var run: [UInt8] = []
        func flush() {
            guard !run.isEmpty else { return }
            words.append(String(decoding: run, as: UTF8.self))
            run.removeAll()
        }
        for byte in bytes {
            let named: String? = switch byte {
            case 0x1B: "ESC"
            case 0x0D: "CR"
            case 0x0A: "LF"
            case 0x09: "TAB"
            case 0x7F: "DEL"
            case 0x00: "NUL"
            case 0x20: "SPACE"
            case 0x01...0x1F: "^" + String(UnicodeScalar(byte + 0x40))
            default: nil
            }
            if let named {
                flush()
                words.append(named)
            } else {
                run.append(byte)
            }
        }
        flush()
        return words.joined(separator: " ")
    }
}
