import Foundation

/// A parsed `git diff` — the file viewer's DIFF render and the repo-wide
/// review surface both stand on this. Pure: text in, structure out, no
/// networking and no git knowledge beyond the unified format itself.
///
/// The input is always produced by our own command builder
/// (`GitCommands.diff…`: `--no-color --no-ext-diff` under
/// `-c core.quotepath=false`), so ANSI sequences and octal-escaped
/// non-ASCII paths never reach the parser; quoted paths are still handled
/// because git quotes controls regardless of quotepath.
struct GitDiff: Equatable {
    var files: [GitDiffFile] = []

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// Parses `git diff` output. Unknown header lines are skipped rather
    /// than failed — the render must survive git versions growing new
    /// extended headers.
    static func parse(_ text: String) -> GitDiff {
        var files: [GitDiffFile] = []
        var current: GitDiffFile?
        var hunk: GitDiffHunk?
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            if let done = hunk, var file = current {
                for line in done.lines {
                    switch line.kind {
                    case .addition: file.additions += 1
                    case .deletion: file.deletions += 1
                    case .context: break
                    }
                }
                file.hunks.append(done)
                current = file
                hunk = nil
            }
        }
        func closeFile() {
            closeHunk()
            if let done = current { files.append(done) }
            current = nil
        }

        // Split keeping empty lines: a context line can be empty (" " is
        // trimmed to "" by data transports that strip trailing spaces), and
        // dropping it would shift every line number after it. The one empty
        // piece a trailing newline produces is not a line, though — parsing
        // it would append a phantom context row to the final hunk.
        var pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
        if pieces.last == "" { pieces.removeLast() }
        for rawLine in pieces {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                closeFile()
                current = GitDiffFile(headerPaths: String(line.dropFirst("diff --git ".count)))
                continue
            }
            guard current != nil else { continue }

            if hunk != nil {
                // Inside a hunk until the next header. Order matters: a
                // context line legitimately starts with anything after its
                // marker column, so headers are recognized first.
                if line.hasPrefix("@@") {
                    closeHunk()
                    // fall through to the hunk-open branch below
                } else if line.hasPrefix("\\") {
                    // "\ No newline at end of file" — annotate the previous
                    // line rather than rendering a phantom row.
                    if var h = hunk, !h.lines.isEmpty {
                        h.lines[h.lines.count - 1].noTrailingNewline = true
                        hunk = h
                    }
                    continue
                } else {
                    let marker = line.first
                    let body = String(line.dropFirst())
                    switch marker {
                    case "+":
                        hunk?.lines.append(GitDiffLine(
                            kind: .addition, text: body,
                            oldNumber: nil, newNumber: newLine
                        ))
                        newLine += 1
                    case "-":
                        hunk?.lines.append(GitDiffLine(
                            kind: .deletion, text: body,
                            oldNumber: oldLine, newNumber: nil
                        ))
                        oldLine += 1
                    case " ", nil:
                        // nil: a completely empty line is a context line
                        // whose single space was stripped in transit.
                        hunk?.lines.append(GitDiffLine(
                            kind: .context, text: body,
                            oldNumber: oldLine, newNumber: newLine
                        ))
                        oldLine += 1
                        newLine += 1
                    default:
                        // An unrecognized marker ends the hunk (git never
                        // emits one mid-hunk; this is a truncated diff).
                        closeHunk()
                    }
                    if hunk != nil { continue }
                }
            }

            if line.hasPrefix("@@") {
                guard let header = GitDiffHunk.parseHeader(line) else { continue }
                hunk = header
                oldLine = header.oldStart
                newLine = header.newStart
                continue
            }
            if line.hasPrefix("--- ") {
                if line == "--- /dev/null" { current?.kind = .added }
                continue
            }
            if line.hasPrefix("+++ ") {
                let path = GitDiffFile.stripPathPrefix(String(line.dropFirst(4)))
                if path == nil { current?.kind = .deleted } // +++ /dev/null
                else if let path { current?.newPath = path }
                continue
            }
            if line.hasPrefix("rename from ") {
                current?.oldPath = GitDiffFile.unquote(String(line.dropFirst("rename from ".count)))
                current?.kind = .renamed
                continue
            }
            if line.hasPrefix("rename to ") {
                current?.newPath = GitDiffFile.unquote(String(line.dropFirst("rename to ".count)))
                current?.kind = .renamed
                continue
            }
            if line.hasPrefix("new file mode ") { current?.kind = .added; continue }
            if line.hasPrefix("deleted file mode ") { current?.kind = .deleted; continue }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.isBinary = true
                continue
            }
            // "index …", "old mode …", "similarity index …" and future
            // extended headers: skipped.
        }
        closeFile()
        return GitDiff(files: files)
    }
}

struct GitDiffFile: Equatable {
    enum Kind: Equatable {
        case modified, added, deleted, renamed
    }

    var oldPath: String = ""
    var newPath: String = ""
    var kind: Kind = .modified
    var isBinary = false
    var hunks: [GitDiffHunk] = []
    /// Counted once as hunks close during parse — headers re-read these on
    /// every render, and a repo-wide diff's line count is unbounded.
    var additions = 0
    var deletions = 0

    /// The path the viewer shows and keys by: where the file lives NOW —
    /// the old path only when the new side is gone.
    var displayPath: String {
        if kind == .deleted { return oldPath.isEmpty ? newPath : oldPath }
        return newPath.isEmpty ? oldPath : newPath
    }

    init() {}

    /// Seeds both paths from the `diff --git a/X b/Y` line. The line is
    /// ambiguous for paths containing " b/", so `---`/`+++`/`rename` headers
    /// overwrite these when present — this is only the fallback (mode-only
    /// changes have no `---` line at all).
    init(headerPaths: String) {
        let (old, new) = Self.splitHeaderPaths(headerPaths)
        oldPath = old
        newPath = new
    }

    static func splitHeaderPaths(_ text: String) -> (String, String) {
        // Quoted spellings are unambiguous: "a/…" "b/…".
        if text.hasPrefix("\"") {
            var paths: [String] = []
            var index = text.startIndex
            while index < text.endIndex, paths.count < 2 {
                guard text[index] == "\"" else { index = text.index(after: index); continue }
                var cursor = text.index(after: index)
                var raw = "\""
                while cursor < text.endIndex {
                    let character = text[cursor]
                    raw.append(character)
                    if character == "\\" {
                        let next = text.index(after: cursor)
                        if next < text.endIndex {
                            raw.append(text[next])
                            cursor = text.index(after: next)
                            continue
                        }
                    }
                    cursor = text.index(after: cursor)
                    if character == "\"" { break }
                }
                paths.append(raw)
                index = cursor
            }
            if paths.count == 2 {
                return (
                    stripPathPrefix(paths[0]) ?? "",
                    stripPathPrefix(paths[1]) ?? ""
                )
            }
        }
        // Unquoted: split at the LAST " b/" — an interior " b/" in the old
        // path is possible but the last occurrence is the boundary whenever
        // both sides are the same path (the overwhelmingly common case).
        if let range = text.range(of: " b/", options: .backwards) {
            let old = String(text[..<range.lowerBound])
            let new = String(text[range.upperBound...])
            return (stripPathPrefix(old) ?? old, new)
        }
        return (text, text)
    }

    /// Drops the `a/`/`b/` prefix and unquotes; nil for `/dev/null`.
    static func stripPathPrefix(_ raw: String) -> String? {
        var text = unquote(raw)
        if text == "/dev/null" { return nil }
        if text.hasPrefix("a/") || text.hasPrefix("b/") {
            text = String(text.dropFirst(2))
        }
        return text
    }

    /// Reverses git's C-style path quoting (controls and, with quotepath
    /// on, non-ASCII as octal escapes). Unquoted input passes through.
    static func unquote(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return raw }
        var bytes: [UInt8] = []
        let scalars = Array(raw.dropFirst().dropLast().utf8)
        var index = 0
        while index < scalars.count {
            let byte = scalars[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < scalars.count else {
                bytes.append(byte)
                index += 1
                continue
            }
            let escape = scalars[index + 1]
            index += 2
            switch escape {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "\\"): bytes.append(0x5C)
            case UInt8(ascii: "\""): bytes.append(0x22)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Up to three octal digits.
                var value = Int(escape - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, index < scalars.count,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(scalars[index]) {
                    value = value * 8 + Int(scalars[index] - UInt8(ascii: "0"))
                    index += 1
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default:
                bytes.append(escape)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct GitDiffHunk: Equatable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    /// The `@@ … @@ context` trailer, often a function name.
    var heading: String
    var lines: [GitDiffLine] = []

    var header: String {
        var text = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        if !heading.isEmpty { text += " \(heading)" }
        return text
    }

    /// `@@ -41,8 +41,11 @@ enum AgentKind` → starts, counts, heading.
    /// Counts default to 1 when omitted (`@@ -1 +1 @@`).
    static func parseHeader(_ line: String) -> GitDiffHunk? {
        guard line.hasPrefix("@@ ") else { return nil }
        guard let close = line.range(of: " @@", range: line.index(line.startIndex, offsetBy: 3)..<line.endIndex)
        else { return nil }
        let ranges = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]
        let heading = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        let parts = ranges.split(separator: " ")
        guard parts.count == 2,
              parts[0].hasPrefix("-"), parts[1].hasPrefix("+"),
              let old = parseRange(parts[0].dropFirst()),
              let new = parseRange(parts[1].dropFirst())
        else { return nil }
        return GitDiffHunk(
            oldStart: old.0, oldCount: old.1,
            newStart: new.0, newCount: new.1,
            heading: heading
        )
    }

    private static func parseRange(_ text: Substring) -> (Int, Int)? {
        let parts = text.split(separator: ",")
        guard let start = Int(parts.first ?? "") else { return nil }
        let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        return (start, count)
    }
}

struct GitDiffLine: Equatable {
    enum Kind: Equatable {
        case context, addition, deletion
    }

    var kind: Kind
    var text: String
    /// Line numbers on each side; an addition has no old number, a deletion
    /// no new one.
    var oldNumber: Int?
    var newNumber: Int?
    var noTrailingNewline = false
}
