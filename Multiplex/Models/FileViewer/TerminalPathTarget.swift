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
        // Interior whitespace is the prose guard, same rule as
        // TerminalLink: "see src/foo.ts and lib/bar.rs" must not classify.
        // Paths with spaces lose this trade — a wrong open costs more.
        guard !text.contains(where: \.isWhitespace) else { return nil }
        guard !text.contains(where: { $0.asciiValue.map { $0 < 0x20 } == true })
        else { return nil }

        // Trailing prose punctuation the matcher can leave on a path.
        while let last = text.last, ".,;)".contains(last) {
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }

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
            } else if let only = Int(pieces.last!), pieces.count >= 2 {
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
