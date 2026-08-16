import Foundation
import SwiftTerm

/// Sends a Key Command through a terminal view. Every byte goes through
/// `TerminalView.send` — the same delegate → ordered-pump path a rail key
/// takes — and every chord is encoded by the view at send time
/// (`TerminalView.bytes(for:)`), so it matches what a hardware press of the
/// same chord would send in the terminal's current mode.
@MainActor
enum KeyCommandDispatcher {
    /// The slash-chip shape: a text row's Enter is a separate write this long
    /// after the text (Codex treats a same-burst CR as a pasted newline).
    static let submitDelay: Duration = .milliseconds(160)

    /// Starts the send (or the repeat burst) and returns its task; nil when
    /// the command has nothing to send in this terminal's mode. The burst
    /// runs to its guard-bounded end even if the panel that pressed it has
    /// already dropped; a terminal that goes away ends it.
    @discardableResult
    static func perform(_ command: KeyCommand, on terminal: TerminalView) -> Task<Void, Never>? {
        let command = command.normalized
        let step: (TerminalView) -> Bool
        switch command.kind {
        case .chord(let chord):
            let terminalChord = chord.terminalChord
            guard terminal.bytes(for: terminalChord) != nil else { return nil }
            step = { $0.send(chord: terminalChord) }
        case .text(let snippet):
            let text = snippet.normalizedText
            guard !text.isEmpty else { return nil }
            step = { view in
                view.send(txt: text)
                return true
            }
        }
        let submits = command.textSnippet?.submits ?? false
        let repeats = command.repeatCount
        let gap = Duration.milliseconds(command.repeatGapMilliseconds)
        return Task { @MainActor [weak terminal] in
            for index in 0..<repeats {
                guard let live = terminal, !Task.isCancelled else { return }
                guard step(live) else { return }
                if submits {
                    try? await Task.sleep(for: submitDelay)
                    guard let live = terminal, !Task.isCancelled else { return }
                    live.send([0x0D])
                }
                if index < repeats - 1 {
                    try? await Task.sleep(for: gap)
                }
            }
        }
    }

    /// The composer's SENDS readout for the terminal's current mode: the
    /// chord's bytes in plain words, or the text row's shape.
    static func describe(_ command: KeyCommand, on terminal: TerminalView?) -> String {
        switch command.kind {
        case .chord(let chord):
            guard let terminal, let bytes = terminal.bytes(for: chord.terminalChord) else {
                return "NO ENCODING"
            }
            var text = KeyBytesNotation.describe(bytes)
            if !terminal.getTerminal().keyboardEnhancementFlags.isEmpty {
                text += " · KITTY KEYS ON"
            }
            return text
        case .text(let snippet):
            return snippet.submits ? "TEXT · THEN CR 160 MS LATER" : "TEXT · NO ENTER"
        }
    }
}

extension KeyChord {
    /// The fork's spelling of this chord.
    var terminalChord: TerminalKeyChord {
        var modifiers: TerminalKeyChord.Modifiers = []
        if self.modifiers.contains(.control) { modifiers.insert(.control) }
        if self.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if self.modifiers.contains(.option) { modifiers.insert(.option) }
        let key: TerminalKeyChord.Key = switch self.key {
        case .enter: .enter
        case .tab: .tab
        case .escape: .escape
        case .delete: .backspace
        case .space: .space
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .character(let character): .character(character.first ?? " ")
        }
        return TerminalKeyChord(key: key, modifiers: modifiers)
    }
}
