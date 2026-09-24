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
/// `../x`, `.config/x`), bare relative with a slash (`src/foo.ts`), and a
/// local-authority `file:` URI naming an absolute path on the SSH host.
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

    /// The text as pressed, before any cleanup. Used for activation identity;
    /// the confirmation field starts at `spelling`, the path VIEW will use.
    var raw: String
    /// The path with the base marker kept (`~/x` stays `~/x`) and any
    /// trailing `:line[:column]` / `:start-end[:column]` suffix removed.
    var path: String
    var base: Base
    /// From a `path:12`, `path:12:5`, or `path:12-18` suffix — compilers,
    /// tool calls, and agents cite lines constantly, and the viewer scrolls
    /// to the first while highlighting the whole requested range.
    var line: Int?
    var endLine: Int?

    init(
        raw: String,
        path: String,
        base: Base,
        line: Int?,
        endLine: Int? = nil
    ) {
        self.raw = raw
        self.path = path
        self.base = base
        self.line = line
        self.endLine = endLine
    }

    var id: String { raw }

    var lineRange: ClosedRange<Int>? {
        guard let line else { return nil }
        let end = endLine ?? line
        guard end >= line else { return nil }
        return line...end
    }

    /// The canonical field spelling — the path plus its line/range suffix —
    /// i.e. the text that re-resolves to this same target. The sheet's
    /// editable field starts here, and its OPENS row compares against it.
    var spelling: String {
        guard let line else { return path }
        if let endLine, endLine > line { return "\(path):\(line)-\(endLine)" }
        return "\(path):\(line)"
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
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 1024 else { return nil }
        if hasFileScheme(text) { return resolveFileURL(raw) }
        // Other URLs belong to TerminalLink; anything scheme-shaped is not
        // a path. `file:` is the one deliberate exception above.
        if text.contains("://") { return nil }
        return resolvePath(raw: raw, text: text, syntax: .implicitMatch)
    }

    /// A path supplied deliberately by app automation rather than inferred
    /// from terminal prose. Explicit input may be a bare file name or contain
    /// spaces and colons; relative paths resolve against the host's configured
    /// working directory. `line` is separate so ordinary colon-bearing names
    /// remain names; the deliberate exception is tool-call-style `:10-15`.
    static func resolveExplicit(_ raw: String, line: Int?) -> TerminalPathTarget? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1024,
              line.map({ $0 > 0 }) ?? true,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }

        if hasFileScheme(text) {
            guard var target = resolveFileURL(text) else { return nil }
            if let line {
                target.line = line
                target.endLine = nil
            }
            return target
        }
        guard !text.contains("://"), text != "/", !text.hasPrefix("//") else { return nil }

        // A range suffix is explicit enough to recognize even here; unlike a
        // lone `:42`, it does not steal common colon-bearing file names from
        // an input that also offers a separate Line Number field.
        let split = splittingLineSuffix(text)
        let usesRangeSuffix = line == nil && split.endLine != nil
        let path = usesRangeSuffix ? split.path : text
        let resolvedLine = usesRangeSuffix ? split.line : line
        let endLine = usesRangeSuffix ? split.endLine : nil

        let base: Base
        if path.hasPrefix("/") {
            base = .absolute
        } else if path == "~" || path.hasPrefix("~/")
                    || path == "$HOME" || path.hasPrefix("$HOME/") {
            base = .home
        } else {
            guard !path.hasPrefix("$") else { return nil }
            base = .workingDirectory
        }
        return TerminalPathTarget(
            raw: raw, path: path, base: base,
            line: resolvedLine, endLine: endLine
        )
    }

    /// Resolves the `file:` shape before `TerminalLink` gets first refusal in
    /// a terminal pane. Only an empty/localhost authority is meaningful: the
    /// URI came from this SSH host, and the viewer cannot honestly follow a
    /// URI naming some other machine. Query and fragment components are not
    /// filename bytes; percent-encode them when they are part of the path.
    ///
    /// Invalid or non-local file URIs return nil here, then remain blocked,
    /// copyable links under `TerminalLink` rather than opening the wrong file.
    static func resolveFileURL(_ raw: String) -> TerminalPathTarget? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 1024, hasFileScheme(text) else { return nil }
        // URI whitespace must be escaped. The decoded absolute path may
        // contain ordinary spaces; `resolvePath` admits those below.
        guard !text.contains(where: \.isWhitespace),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              // URLComponents repairs stray percent signs. Validate first so
              // a malformed URI never silently changes into a different path.
              text.removingPercentEncoding != nil,
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "file",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }

        if let authority = components.host,
           !authority.isEmpty,
           authority.caseInsensitiveCompare("localhost") != .orderedSame {
            return nil
        }
        // Parse the compiler-style suffix while it is still encoded. A `%3A`
        // is filename data, whereas a literal trailing `:42[:5]` is the line
        // convention the ordinary path resolver supports.
        let encoded = splittingLineSuffix(components.percentEncodedPath)
        guard let path = encoded.path.removingPercentEncoding,
              path.hasPrefix("/")
        else { return nil }
        // URI syntax already proves every decoded space, colon, and trailing
        // mark is part of the path. Do not apply the implicit matcher's prose
        // cleanup (`file:///tmp/My%20Folder` must keep "Folder").
        return resolvePath(
            raw: raw,
            text: path,
            syntax: .fileURL(line: encoded.line, endLine: encoded.endLine)
        )
    }

    private enum PathSyntax {
        case implicitMatch
        case fileURL(line: Int?, endLine: Int?)
    }

    private static func resolvePath(
        raw: String,
        text input: String,
        syntax: PathSyntax
    ) -> TerminalPathTarget? {
        var text = input
        guard !text.isEmpty, text.count <= 1024,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        // One pass: non-space whitespace (tabs, line breaks, Unicode spaces)
        // is never part of a target; plain spaces are judged by the marker
        // gate below.
        var hasSpace = false
        for character in text {
            if character == " " { hasSpace = true; continue }
            if character.isWhitespace { return nil }
        }

        // A spaced target is admitted only when it roots itself with a
        // base marker (`/x y`, `~/x y`, `./x y`, `$HOME/x y`): the marker
        // is what says "path" when whitespace no longer can. Bare-relative
        // keeps the prose guard — "see src/foo.ts and lib/bar.rs" must not
        // classify as one spaced path.
        if hasSpace, !hasBaseMarker(text) { return nil }
        let line: Int?
        let endLine: Int?
        switch syntax {
        case .implicitMatch:
            // Shed trailing sentence punctuation, and — because the
            // matcher's space-segment branches swallow trailing prose when
            // the first chunk is dot-free ("/etc/hosts is missing" arrives
            // whole) — prose-shaped tail chunks too.
            text = trimmingProseTail(text)
            guard !text.isEmpty else { return nil }
            text = strippingWrappedProseHead(text)
            let split = splittingLineSuffix(text)
            text = split.path
            line = split.line
            endLine = split.endLine
        case .fileURL(let targetLine, let targetEndLine):
            line = targetLine
            endLine = targetEndLine
        }

        guard !text.isEmpty, text != "/" else { return nil }
        if case .implicitMatch = syntax {
            // A colon that survives suffix-stripping is prose ("warning:")
            // or a scheme-ish shape — legal in a unix filename, but too
            // ambiguous in an implicit match. An explicit file URI may keep
            // one because its syntax already proved the whole target.
            guard !text.contains(":") else { return nil }
        }
        return classified(
            raw: raw, path: text, line: line, endLine: endLine
        )
    }

    /// `path:line[:column]` or `path:start-end[:column]`: columns do not
    /// affect a line-oriented viewer, but stripping one makes compiler and
    /// tool-call references useful. Run this on a file URI's *encoded* path
    /// so `%3A42` remains filename data while a literal suffix is navigation.
    private static func splittingLineSuffix(
        _ text: String
    ) -> (path: String, line: Int?, endLine: Int?) {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard let last = pieces.last else { return (text, nil, nil) }

        if let range = lineRange(String(last)) {
            return (
                pieces.dropLast().joined(separator: ":"),
                range.lowerBound,
                range.upperBound
            )
        }
        guard let lastNumber = Int(last) else { return (text, nil, nil) }
        if pieces.count >= 3 {
            let previous = String(pieces[pieces.count - 2])
            if let range = lineRange(previous) {
                return (
                    pieces.dropLast(2).joined(separator: ":"),
                    range.lowerBound,
                    range.upperBound
                )
            }
            if let line = Int(previous) {
                return (pieces.dropLast(2).joined(separator: ":"), line, nil)
            }
        }
        return (pieces.dropLast().joined(separator: ":"), lastNumber, nil)
    }

    private static func lineRange(_ suffix: String) -> ClosedRange<Int>? {
        let bounds = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int(bounds[0]), let end = Int(bounds[1]),
              start > 0, end >= start
        else { return nil }
        return start...end
    }

    private static func hasFileScheme(_ text: String) -> Bool {
        text.range(of: "file:", options: [.anchored, .caseInsensitive]) != nil
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
        line: Int?,
        endLine: Int?
    ) -> TerminalPathTarget? {
        let base: Base
        if path.hasPrefix("/") {
            guard !path.hasPrefix("//") else { return nil }
            base = .absolute
        } else if path == "~" || path.hasPrefix("~/") {
            base = .home
        } else if path.hasPrefix("$") {
            // Only $HOME is knowable from here; other variables live in the
            // remote's environment and stay unresolved (→ selection).
            guard path == "$HOME" || path.hasPrefix("$HOME/") else { return nil }
            base = .home
        } else if path.hasPrefix("./") || path.hasPrefix("../") {
            base = .workingDirectory
        } else {
            // Bare relative: needs an interior slash to look like a path at
            // all ("README" alone is prose the matcher wouldn't send anyway).
            guard path.contains("/") else { return nil }
            base = .workingDirectory
        }
        return TerminalPathTarget(
            raw: raw, path: path, base: base,
            line: line, endLine: endLine
        )
    }
}
