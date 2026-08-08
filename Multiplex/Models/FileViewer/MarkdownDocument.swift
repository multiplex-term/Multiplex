import Foundation

/// The file viewer's Markdown model — a deliberate GFM *subset*, parsed by
/// hand for the same reason the highlighter is hand-rolled: every real
/// renderer (swift-markdown/cmark, MarkdownUI) is a vendored C library this
/// feature doesn't need yet, and SwiftUI's built-in
/// `AttributedString(markdown:)` cannot lay out block structure at all
/// (headings render as body text; tables, lists, and fences don't render).
///
/// Covered: ATX headings, paragraphs, fenced code (with language info),
/// block quotes, flat-ish lists (two indent levels), GFM tables, thematic
/// breaks, inline emphasis/code/links/images. Not covered, on purpose:
/// setext headings, reference links, HTML blocks, footnotes — a README
/// renders honestly without them, and RAW mode is one chip away.
enum MarkdownBlock: Equatable {
    case heading(level: Int, inlines: [MarkdownInline])
    case paragraph(inlines: [MarkdownInline])
    case code(language: CodeLanguage?, info: String, lines: [String])
    case quote(blocks: [MarkdownBlock])
    /// Flat list item; `level` is nesting depth (0 or 1 — deeper indents
    /// clamp), `marker` is what the renderer draws ("•", "3.").
    case listItem(marker: String, level: Int, inlines: [MarkdownInline])
    case table(header: [[MarkdownInline]], rows: [[[MarkdownInline]]])
    case rule
}

struct MarkdownEmphasis: OptionSet, Equatable {
    let rawValue: Int
    static let bold = MarkdownEmphasis(rawValue: 1 << 0)
    static let italic = MarkdownEmphasis(rawValue: 1 << 1)
    static let strikethrough = MarkdownEmphasis(rawValue: 1 << 2)
}

enum MarkdownInline: Equatable {
    case text(String, MarkdownEmphasis)
    case code(String)
    /// The destination is untrusted remote text: the renderer offers it
    /// through the link sheet's confirm discipline, never follows it.
    case link(text: String, destination: String)
    /// Rendering an image is still a captioned placeholder — fetching a
    /// document's images over SFTP (or the network!) is not a side effect of
    /// reading the prose around them. The destination rides along so a
    /// *press* can make that decision explicitly: a document-relative path
    /// opens as its own file-viewer screen, a web URL goes through the link
    /// sheet like any other untrusted destination.
    case image(alt: String, destination: String)
}

enum MarkdownDocument {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        return parseLines(lines)
    }

    /// A quoted line can carry one `>` per column, and the file is remote
    /// bytes, so nesting is bounded — past the limit the run renders as the
    /// plain text it is rather than walking the stack over.
    static let maxQuoteDepth = 16
    /// Table budgets — see the table branch below.
    static let maxTableRows = 500
    static let maxTableColumns = 32

    private static func parseLines(
        _ lines: [String], quoteDepth: Int = 0
    ) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            blocks.append(.paragraph(inlines: parseInlines(joined)))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Fenced code.
            if let fence = fenceOpener(trimmed) {
                flushParagraph()
                var body: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker),
                       candidate.allSatisfy({ $0 == fence.marker.first }) {
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(
                    language: FileKind.fenceLanguage(fence.info),
                    info: fence.info,
                    lines: body
                ))
                continue
            }

            // ATX heading.
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6 {
                    let rest = trimmed.dropFirst(level)
                    if rest.isEmpty || rest.first == " " {
                        flushParagraph()
                        var content = rest.trimmingCharacters(in: .whitespaces)
                        // Trailing closing hashes are decoration.
                        while content.hasSuffix("#") { content.removeLast() }
                        blocks.append(.heading(
                            level: level,
                            inlines: parseInlines(content.trimmingCharacters(in: .whitespaces))
                        ))
                        index += 1
                        continue
                    }
                }
            }

            // Thematic break (also swallows what CommonMark would call a
            // setext underline — documented simplification).
            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // Block quote: collect the run, strip one marker, recurse.
            if trimmed.hasPrefix(">"), quoteDepth < maxQuoteDepth {
                flushParagraph()
                var inner: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    var stripped = String(quoteLine.dropFirst())
                    if stripped.hasPrefix(" ") { stripped.removeFirst() }
                    inner.append(stripped)
                    index += 1
                }
                blocks.append(.quote(
                    blocks: parseLines(inner, quoteDepth: quoteDepth + 1)))
                continue
            }

            // Table: a pipe row whose next line is the separator row.
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                // The renderer builds real views per cell, so the table's
                // cardinality — not just the file's byte count — decides how
                // much work a remote document can ask for. Rows past the cap
                // are left to render as the paragraphs they came from.
                let header = Array(tableCells(trimmed).prefix(maxTableColumns))
                    .map(parseInlines)
                index += 2
                var rows: [[[MarkdownInline]]] = []
                while index < lines.count, rows.count < maxTableRows {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowLine.contains("|"), !rowLine.isEmpty else { break }
                    rows.append(Array(tableCells(rowLine).prefix(maxTableColumns))
                        .map(parseInlines))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // List item.
            if let item = listItem(line) {
                flushParagraph()
                blocks.append(.listItem(
                    marker: item.marker,
                    level: item.level,
                    inlines: parseInlines(item.content)
                ))
                index += 1
                // Continuation lines (indented, not themselves items) fold
                // into the item so wrapped bullets read as one row.
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !nextTrimmed.isEmpty,
                          next.hasPrefix("  "),
                          listItem(next) == nil,
                          fenceOpener(nextTrimmed) == nil
                    else { break }
                    if case .listItem(let marker, let level, var inlines) = blocks.removeLast() {
                        inlines.append(.text(" ", []))
                        inlines.append(contentsOf: parseInlines(nextTrimmed))
                        blocks.append(.listItem(marker: marker, level: level, inlines: inlines))
                    }
                    index += 1
                }
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Block helpers

    private static func fenceOpener(_ line: String) -> (marker: String, info: String)? {
        for character in ["`", "~"] {
            let run = line.prefix(while: { String($0) == character })
            if run.count >= 3 {
                let info = line.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
                // CommonMark: an info string on a backtick fence cannot
                // contain backticks (that's an inline code span).
                if character == "`", info.contains("`") { return nil }
                return (String(run), info)
            }
        }
        return nil
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        guard let first = line.first, "-*_".contains(first) else { return false }
        var count = 0
        for character in line {
            if character == first { count += 1 } else if character != " " { return false }
        }
        return count >= 3
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard !stripped.isEmpty else { return false }
        return stripped.allSatisfy { "|:-".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // A leading/trailing pipe produces empty edge cells — decoration,
        // not data. Interior empties are real (an empty cell).
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    private static func listItem(
        _ line: String
    ) -> (marker: String, level: Int, content: String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = min(indent / 2, 1)
        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            var content = String(trimmed.dropFirst(2))
            var marker = "•"
            // Task list marker.
            if content.hasPrefix("[ ] ") {
                marker = "□"
                content = String(content.dropFirst(4))
            } else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                marker = "▣"
                content = String(content.dropFirst(4))
            }
            return (marker, level, content)
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return ("\(digits).", level, String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    // MARK: Inline parsing

    static func parseInlines(_ text: String) -> [MarkdownInline] {
        parseInlines(Substring(text), emphasis: [])
    }

    private static func parseInlines(
        _ text: Substring,
        emphasis: MarkdownEmphasis
    ) -> [MarkdownInline] {
        var inlines: [MarkdownInline] = []
        var plain = ""
        var index = text.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            inlines.append(.text(plain, emphasis))
            plain = ""
        }

        while index < text.endIndex {
            let character = text[index]

            // Code span: a backtick run closed by an equal run.
            if character == "`" {
                let runEnd = text[index...].prefix(while: { $0 == "`" }).endIndex
                let fence = text[index..<runEnd]
                if let close = text.range(of: String(fence), range: runEnd..<text.endIndex) {
                    flushPlain()
                    inlines.append(.code(
                        String(text[runEnd..<close.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                    ))
                    index = close.upperBound
                    continue
                }
            }

            // Image / link.
            if character == "!" || character == "[" {
                let isImage = character == "!"
                var cursor = index
                if isImage {
                    cursor = text.index(after: cursor)
                    guard cursor < text.endIndex, text[cursor] == "[" else {
                        plain.append(character)
                        index = text.index(after: index)
                        continue
                    }
                }
                if let parsed = parseBracketed(text, from: cursor) {
                    flushPlain()
                    if isImage {
                        inlines.append(.image(
                            alt: parsed.label, destination: parsed.destination))
                    } else {
                        inlines.append(.link(text: parsed.label, destination: parsed.destination))
                    }
                    index = parsed.end
                    continue
                }
            }

            // Autolink <https://…>.
            if character == "<" {
                if let close = text[index...].firstIndex(of: ">") {
                    let inner = text[text.index(after: index)..<close]
                    if inner.hasPrefix("https://") || inner.hasPrefix("http://") {
                        flushPlain()
                        inlines.append(.link(text: String(inner), destination: String(inner)))
                        index = text.index(after: close)
                        continue
                    }
                }
            }

            // Emphasis delimiters: **, __, *, _, ~~. Underscores follow the
            // intraword rule: `snake_case_names` fill READMEs, and an
            // opener glued to a word (letter/digit before it) is prose,
            // not emphasis.
            if character == "*" || character == "_" || character == "~" {
                let runEnd = text[index...].prefix(while: { $0 == character }).endIndex
                var runLength = text.distance(from: index, to: runEnd)
                if character == "~", runLength < 2 { runLength = 0 }
                if character == "_",
                   let previous = plain.last ?? previousCharacter(text, before: index),
                   previous.isLetter || previous.isNumber {
                    runLength = 0
                }
                if runLength > 0 {
                    let useLength = min(runLength, 2)
                    let delimiterEnd = text.index(index, offsetBy: useLength)
                    let delimiter = String(text[index..<delimiterEnd])
                    // Opener must press against content.
                    if delimiterEnd < text.endIndex, text[delimiterEnd] != " ",
                       let close = matchingClose(
                           text,
                           delimiter: delimiter,
                           from: delimiterEnd,
                           intraword: character != "_"
                       ) {
                        flushPlain()
                        var style = emphasis
                        switch delimiter {
                        case "**", "__": style.insert(.bold)
                        case "~~": style.insert(.strikethrough)
                        default: style.insert(.italic)
                        }
                        inlines.append(contentsOf: parseInlines(
                            text[delimiterEnd..<close.lowerBound],
                            emphasis: style
                        ))
                        index = close.upperBound
                        continue
                    }
                }
            }

            plain.append(character)
            index = text.index(after: index)
        }
        flushPlain()
        return inlines
    }

    /// The closing delimiter run, preceded by non-space content. With
    /// `intraword` off (underscores), a closer glued into a word
    /// (letter/digit right after it) doesn't count either.
    private static func matchingClose(
        _ text: Substring,
        delimiter: String,
        from start: Substring.Index,
        intraword: Bool
    ) -> Range<Substring.Index>? {
        var search = start
        while let range = text.range(of: delimiter, range: search..<text.endIndex) {
            if range.lowerBound > text.startIndex {
                let before = text[text.index(before: range.lowerBound)]
                let after = range.upperBound < text.endIndex ? text[range.upperBound] : " "
                if before != " ", intraword || !(after.isLetter || after.isNumber) {
                    return range
                }
            }
            search = range.upperBound
        }
        return nil
    }

    private static func previousCharacter(
        _ text: Substring,
        before index: Substring.Index
    ) -> Character? {
        guard index > text.startIndex else { return nil }
        return text[text.index(before: index)]
    }

    /// `[label](destination)` starting at `open` (which must point at `[`).
    private static func parseBracketed(
        _ text: Substring,
        from open: Substring.Index
    ) -> (label: String, destination: String, end: Substring.Index)? {
        guard text[open] == "[" else { return nil }
        var depth = 0
        var cursor = open
        var closeBracket: Substring.Index?
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { closeBracket = cursor; break }
            }
            cursor = text.index(after: cursor)
        }
        guard let closeBracket else { return nil }
        let afterBracket = text.index(after: closeBracket)
        guard afterBracket < text.endIndex, text[afterBracket] == "(" else { return nil }
        var parenDepth = 0
        var scan = afterBracket
        while scan < text.endIndex {
            let character = text[scan]
            if character == "(" { parenDepth += 1 }
            if character == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    let label = flattenedLabel(text[text.index(after: open)..<closeBracket])
                    let destination = linkDestination(
                        text[text.index(after: afterBracket)..<scan]
                    )
                    return (label, destination, text.index(after: scan))
                }
            }
            scan = text.index(after: scan)
        }
        return nil
    }

    /// The destination inside `(…)`, stripped of the two decorations
    /// CommonMark allows around it: an optional title after the target
    /// (`![shot](shot.png "Figure 1")`) and the angle brackets that let a
    /// target carry spaces (`[docs](<my docs.md>)`). Both are common enough
    /// in real READMEs that leaving them in would make an otherwise valid
    /// press miss the file it names.
    private static func linkDestination(_ raw: Substring) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where value.hasSuffix(quote) {
            let body = value.dropLast()
            if let open = body.lastIndex(of: Character(quote)),
               open > body.startIndex,
               body[body.index(before: open)] == " " {
                value = String(body[..<open]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Link labels render as plain text — emphasis markers inside are
    /// stripped rather than styled (a viewer's simplification).
    private static func flattenedLabel(_ text: Substring) -> String {
        parseInlines(text, emphasis: []).map { inline in
            switch inline {
            case .text(let value, _): value
            case .code(let value): value
            case .link(let value, _): value
            case .image(let alt, _): alt
            }
        }.joined()
    }
}
