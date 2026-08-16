//
//  iOSKeyChord.swift: app-authored key chords.
//
//  Multiplex patch (fourteenth group): a host app that offers saved key
//  chords on its own chrome (Multiplex's hold-CTRL Key Commands) must send
//  exactly the bytes a hardware keyboard would send for the same chord at
//  the same moment — kitty enhancement flags, DECCKM, the backspace mode.
//  Re-deriving those rules app-side would drift from `pressesBegan`; this
//  seam names the chord and lets the view encode it.
//
#if os(iOS) || os(visionOS)
import Foundation

/// One modifier set plus one key, spelled the way a keycap reads.
public struct TerminalKeyChord: Equatable {
    public enum Key: Equatable {
        case enter
        case tab
        case escape
        case backspace
        case space
        case up
        case down
        case left
        case right
        /// One printable character; the encoder takes its lowercase base as
        /// the key and reports the shifted form when `.shift` is held.
        case character(Character)
    }

    public struct Modifiers: OptionSet {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

extension TerminalView {
    /// The bytes a hardware press of `chord` would send right now. Nil when the
    /// chord has no encoding (a bare modifier, an unencodable character).
    ///
    /// With kitty enhancement flags active the chord rides
    /// `KittyKeyboardEncoder` exactly as `pressesBegan` does. Without them the
    /// same encoder's legacy branch applies, plus the three cases the legacy
    /// `pressesBegan` path decides for itself: Shift+Enter is LF (the CLI
    /// agents' insert-newline — see the Return case there), Option+Left/Right
    /// are the readline word motions (`ESC b` / `ESC f`), and Ctrl+Shift+char
    /// is Ctrl+char (there is no legacy spelling for the shift).
    public func bytes(for chord: TerminalKeyChord) -> [UInt8]? {
        let flags = terminal.keyboardEnhancementFlags
        if flags.isEmpty {
            if case .enter = chord.key, chord.modifiers.contains(.shift) {
                return [10]
            }
            if chord.modifiers == [.option] {
                switch chord.key {
                case .left: return EscapeSequences.emacsBack
                case .right: return EscapeSequences.emacsForward
                default: break
                }
            }
        }
        var event = kittyEvent(for: chord)
        if flags.isEmpty, event.modifiers.contains(.ctrl) {
            event.modifiers.remove(.shift)
            event.shiftedKey = nil
        }
        let encoder = KittyKeyboardEncoder(flags: flags,
                                           applicationCursor: terminal.applicationCursor,
                                           backspaceSendsControlH: backspaceSendsControlH)
        return encoder.encode(event)
    }

    /// Encodes `chord` for the terminal's current mode and sends it through
    /// the same delegate path as every other key. Returns false when the chord
    /// has no encoding.
    @discardableResult
    public func send(chord: TerminalKeyChord) -> Bool {
        guard let bytes = bytes(for: chord) else { return false }
        send(bytes)
        return true
    }

    private func kittyEvent(for chord: TerminalKeyChord) -> KittyKeyEvent {
        var modifiers: KittyKeyboardModifiers = []
        if chord.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if chord.modifiers.contains(.control) { modifiers.insert(.ctrl) }
        if chord.modifiers.contains(.option) { modifiers.insert(.alt) }
        let carriesText = !modifiers.contains(.ctrl) && !modifiers.contains(.alt)

        let key: KittyKey
        var text: String?
        var shiftedKey: UnicodeScalar?
        switch chord.key {
        case .enter: key = .functional(.enter)
        case .tab: key = .functional(.tab)
        case .escape: key = .functional(.escape)
        case .backspace: key = .functional(.backspace)
        case .up: key = .functional(.up)
        case .down: key = .functional(.down)
        case .left: key = .functional(.left)
        case .right: key = .functional(.right)
        case .space:
            key = .unicode(32)
            if carriesText { text = " " }
        case .character(let character):
            let lowered = String(character).lowercased()
            let base: UnicodeScalar = lowered.unicodeScalars.first
                ?? String(character).unicodeScalars.first
                ?? UnicodeScalar(32)
            key = .unicode(base.value)
            let shifted = String(character).uppercased()
            let typed = modifiers.contains(.shift) ? shifted : String(character)
            if carriesText { text = typed }
            if modifiers.contains(.shift),
               let shiftedScalar = shifted.unicodeScalars.first,
               shiftedScalar != base {
                shiftedKey = shiftedScalar
            }
        }
        return KittyKeyEvent(key: key,
                             modifiers: modifiers,
                             eventType: .press,
                             text: text,
                             shiftedKey: shiftedKey,
                             baseLayoutKey: nil,
                             composing: false)
    }
}
#endif
