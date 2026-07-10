import Foundation

/// A file caught by a terminal-pane drop: a filename and its bytes.
struct DroppedFile {
    var name: String
    var data: Data
}

/// Drop failure with a message fit for the status pill.
struct DropError: Error {
    let message: String
}

/// Pure text/naming logic for file drops. Everything that becomes a remote
/// filename or gets typed into the session goes through here — the typed
/// text is *composer input*, never shell input, but it's sanitized and
/// quoted anyway so it stays inert even if it lands at a shell prompt
/// (stale agent detection).
enum DropText {
    /// v1 cap — the payload passes through memory and one SFTP session.
    static let maxBytes = 64 * 1024 * 1024

    /// Inside a git worktree, drops are corralled here instead of littering
    /// the working tree. The folder self-ignores (it gets a `*` .gitignore),
    /// so it never shows up in `git status`.
    static let dropsDirectoryName = ".multiplex-drops"

    /// A name safe to create remotely and to type: path separators and
    /// control characters collapse to "_", a leading "-" or "." gets a "_"
    /// prefix (no flag-looking or hidden files), empty becomes "drop".
    static func sanitizedName(_ raw: String) -> String {
        var name = String(raw.map { character -> Character in
            if character == "/" || character == "\\" { return "_" }
            let scalar = character.unicodeScalars.first?.value ?? 0
            if scalar < 0x20 || scalar == 0x7F { return "_" }
            return character
        }).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "drop" }
        if name.hasPrefix("-") || name.hasPrefix(".") { name = "_" + name }
        return name
    }

    /// The nth collision candidate: 0 → "a.txt", 1 → "a-2.txt", 2 → "a-3.txt".
    /// The counter lands before the last extension ("t.tar.gz" → "t.tar-2.gz").
    static func candidate(_ name: String, attempt: Int) -> String {
        guard attempt > 0 else { return name }
        let counter = attempt + 1
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return "\(name[..<dot])-\(counter)\(name[dot...])"
        }
        return "\(name)-\(counter)"
    }

    /// A path as typed into the session — single-quoted only when it
    /// contains characters that would split words or glob.
    static func typed(path: String) -> String {
        let plain = !path.isEmpty && path.allSatisfy { character in
            character.isLetter || character.isNumber || "._-/+@%=:,~".contains(character)
        }
        return plain ? path : path.shellQuoted
    }

    /// What lands in the composer: space-joined typed paths plus one
    /// trailing space, so the user keeps writing their prompt. No Enter —
    /// submission is always the user's.
    static func typedPaths(_ paths: [String]) -> String {
        paths.isEmpty ? "" : paths.map(typed).joined(separator: " ") + " "
    }
}
