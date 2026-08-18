import Foundation

/// Text a person composed in an app field on its way into a pane — a custom
/// agent command, a Talkback message. One rule for what may ride: line
/// breaks become LF (CR / CRLF included), tabs stay, every other control
/// character (C0, DEL, C1) is dropped — no Escape, no Ctrl-B, no CSI can
/// travel inside typed text. Callers decide the trimming.
enum ComposedText {
    static func lineNormalized(_ text: String) -> String {
        let lineEndings = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return lineEndings.unicodeScalars.reduce(into: "") { result, scalar in
            let allowedControl = scalar.value == 0x09 || scalar.value == 0x0A
            if allowedControl || !CharacterSet.controlCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
    }
}
