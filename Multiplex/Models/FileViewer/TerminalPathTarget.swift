import Foundation

/// A filesystem path pressed in a terminal pane — the file viewer's twin of
/// `TerminalLink`. SwiftTerm's implicit detection (ghostty-derived) matches
/// path shapes as readily as URLs; `TerminalLink` deliberately resolves them
/// to nil, and historically the press fell through to text selection. Now a
/// path-shaped press confirms into the file viewer the way a URL confirms
/// into the viewport: same gate (a sheet naming the host), same "shown,
/// never followed" discipline — pane bytes are untrusted, so nothing opens
/// without the person seeing the resolved target first.
///
/// Pure classification. What it accepts mirrors what the fork's matcher can
/// hand it: rooted (`/x`), home (`~/x`, `$HOME/x`), dot-relative (`./x`,
/// `../x`, `.config/x`), and bare relative with a slash (`src/foo.ts`).
/// Other `$VAR/…` shapes resolve to nil — the app cannot know the remote's
/// environment, and a wrong guess opens the wrong file — so those keep
/// falling through to selection.
struct TerminalPathTarget: Equatable, Identifiable {
    enum Base: Equatable {
        /// Starts at `/` — used verbatim.
        case absolute
        /// `~/…` or `$HOME/…` — resolved against the remote home.
        case home
        /// Everything else — resolved against the pane's cwd (or home when
        /// no pane can answer, which the sheet says).
        case workingDirectory
    }

    /// The text as pressed, before any cleanup — what COPY copies.
    var raw: String
    /// The path with the base marker kept (`~/x` stays `~/x`) and any
    /// trailing `:line[:column]` suffix removed.
    var path: String
    var base: Base
    /// From a `path:12` / `path:12:5` suffix — compilers and agents cite
    /// lines constantly, and the viewer scrolls there.
    var line: Int?

    var id: String { raw }

    /// The canonical field spelling — the path plus its `:line` suffix —
    /// i.e. the text that re-resolves to this same target. The sheet's
    /// editable field starts here, and its OPENS row compares against it.
    var spelling: String {
        line.map { "\(path):\($0)" } ?? path
    }

    /// The path relative to its base, ready for remote resolution:
    /// absolute stays absolute, home drops the `~/`/`$HOME/` marker,
    /// working-directory keeps its relative spelling (minus `./`).
    var relativePart: String {
        switch base {
        case .absolute:
            return path
        case .home:
            if path.hasPrefix("~/") { return String(path.dropFirst(2)) }
            if path.hasPrefix("$HOME/") { return String(path.dropFirst(6)) }
            return path == "~" || path == "$HOME" ? "" : path
        case .workingDirectory:
            if path.hasPrefix("./") { return String(path.dropFirst(2)) }
            return path
        }
    }

    static func resolve(_ raw: String) -> TerminalPathTarget? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 1024 else { return nil }
        // URLs belong to TerminalLink; anything scheme-shaped is not a path.
        if text.contains("://") { return nil }
        // One pass: controls and non-space whitespace (tabs, line breaks,
        // Unicode spaces) are never part of a target; plain spaces are
        // judged by the marker gate below.
        var hasSpace = false
        for character in text {
            if character == " " { hasSpace = true; continue }
            if character.isWhitespace { return nil }
            if character.asciiValue.map({ $0 < 0x20 }) == true { return nil }
        }

        // A spaced target is admitted only when it roots itself with a
        // base marker (`/x y`, `~/x y`, `./x y`, `$HOME/x y`): the marker
        // is what says "path" when whitespace no longer can. Bare-relative
        // keeps the prose guard — "see src/foo.ts and lib/bar.rs" must not
        // classify as one spaced path.
        if hasSpace, !hasBaseMarker(text) { return nil }
        // Shed trailing sentence punctuation, and — because the matcher's
        // space-segment branches swallow trailing prose whenever the first
        // chunk is dot-free ("/etc/hosts is missing" arrives whole) —
        // prose-shaped tail chunks too. A spaced directory whose last
        // segment is markerless ("~/My Folder") loses that segment to the
        // same rule; the sheet's editable field is the recovery.
        text = trimmingProseTail(text)
        guard !text.isEmpty else { return nil }
        text = strippingWrappedProseHead(text)

        // `path:12` / `path:12:5` — strip, keep the line.
        var line: Int?
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count >= 2 {
            let tail = pieces.suffix(2)
            let numbers = tail.compactMap { Int($0) }
            if numbers.count == tail.count, pieces.count >= 3, let first = numbers.first {
                // path:line:column
                line = first
                text = pieces.dropLast(2).joined(separator: ":")
            } else if let only = Int(pieces.last!) {
                line = only
                text = pieces.dropLast().joined(separator: ":")
            }
        }
        guard !text.isEmpty, text != "/" else { return nil }
        // A colon that survives suffix-stripping is prose ("warning:") or a
        // scheme-ish shape — a colon is legal in a unix filename, but rare
        // enough that guessing wrong (and opening the wrong file) costs
        // more than declining into text selection.
        guard !text.contains(":") else { return nil }
        return classified(raw: raw, path: text, line: line)
    }

    /// The self-rooting first characters — absolute, home, dot-relative,
    /// `$HOME` — one definition for the spaced-target gate and the
    /// prose-head stripper's early return.
    private static func hasBaseMarker(_ text: String) -> Bool {
        text.first.map { "/~.$".contains($0) } ?? false
    }

    /// Sheds trailing sentence punctuation and space-chunks that read as
    /// prose, one at a time from the end (`WrappedRowGlue.isProseChunk` is
    /// the shared tell: no `/`, no `.` — "is", "missing", "now").
    /// Punctuation is re-examined after every cut so "…/app.log failed."
    /// sheds cleanly. One index walks backward; the string is copied once.
    private static func trimmingProseTail(_ input: String) -> String {
        var end = input.endIndex
        while true {
            while end > input.startIndex, ".,;) ".contains(input[input.index(before: end)]) {
                end = input.index(before: end)
            }
            guard let cut = input[input.startIndex..<end].lastIndex(of: " "),
                  WrappedRowGlue.isProseChunk(input[input.index(after: cut)..<end])
            else { break }
            end = cut
        }
        return end == input.endIndex ? input : String(input[input.startIndex..<end])
    }

    /// Drops a sentence's tail that a *row join* glued to the front of a
    /// path. The fork reassembles wrapped rows before matching, and a hard
    /// wrap puts no space at the seam: a line ending `…changed the file.`
    /// followed by a line starting `/Users/me/x.swift` reaches the matcher
    /// as `file./Users/me/x.swift`, which the ghostty pattern happily reads
    /// as one bare-relative path — the reported `.`-prefixed path.
    ///
    /// The tell is a segment ending in `.` immediately before a slash: real
    /// paths spell that `.` and `..` alone, and only at the front (`./x`,
    /// `../x`) or after a slash (`a/./b`). So the cut is taken at the first
    /// `X./` whose `X` is neither, and only when the text does NOT already
    /// start with a base marker — an absolute, home, or dot-relative match
    /// began at its own root and is nobody's suffix.
    ///
    /// What remains starts at the slash, i.e. an absolute path. A join whose
    /// lower row carried a *relative* path is unrecoverable by construction
    /// (`word.src/foo.ts` cannot be told from a real `word.src/foo.ts`) —
    /// that is what the confirmation sheet's editable field is for.
    private static func strippingWrappedProseHead(_ text: String) -> String {
        guard !hasBaseMarker(text) else { return text }
        let characters = Array(text)
        for index in 1..<max(1, characters.count - 1)
        where characters[index] == "." && characters[index + 1] == "/" {
            let previous = characters[index - 1]
            guard previous != "/", previous != "." else { continue }
            return String(characters[(index + 1)...])
        }
        return text
    }

    private static func classified(
        raw: String,
        path: String,
        line: Int?
    ) -> TerminalPathTarget? {
        if path.hasPrefix("/") {
            guard !path.hasPrefix("//") else { return nil }
            return TerminalPathTarget(raw: raw, path: path, base: .absolute, line: line)
        }
        if path == "~" || path.hasPrefix("~/") {
            return TerminalPathTarget(raw: raw, path: path, base: .home, line: line)
        }
        if path.hasPrefix("$") {
            // Only $HOME is knowable from here; other variables live in the
            // remote's environment and stay unresolved (→ selection).
            guard path == "$HOME" || path.hasPrefix("$HOME/") else { return nil }
            return TerminalPathTarget(raw: raw, path: path, base: .home, line: line)
        }
        if path.hasPrefix("./") || path.hasPrefix("../") {
            return TerminalPathTarget(raw: raw, path: path, base: .workingDirectory, line: line)
        }
        // Bare relative: needs an interior slash to look like a path at
        // all ("README" alone is prose the matcher wouldn't send anyway).
        guard path.contains("/") else { return nil }
        return TerminalPathTarget(raw: raw, path: path, base: .workingDirectory, line: line)
    }
}
