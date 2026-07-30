import Foundation

/// Token classes the viewer's screens color. Deliberately few: this is a
/// *viewer's* highlighter — enough structure to read a file comfortably,
/// mapped onto the terminal theme's own palette so the screen matches the
/// terminal beside it. (2026 survey: there is no maintained pure-Swift
/// multi-language highlighter, and every alternative — tree-sitter grammars,
/// highlight.js in JSC, Shiki in a web view — means vendoring megabytes of
/// C or JS. This in-repo scanner is the clean-room answer, same instinct as
/// the mosh stack; the tree-sitter route stays on record in
/// local-plan/file-viewer.md as the upgrade path if quality ever outranks
/// the supply-chain cost.)
enum CodeTokenKind: Equatable {
    case plain
    case keyword
    /// Builtin/lowercase type names and — where the language capitalizes
    /// types — capitalized identifiers.
    case type
    case string
    case comment
    case number
    /// An identifier a call site follows: `name(`.
    case function
    /// Keys and members: JSON/YAML keys, shell `$VARS`, markup attributes.
    case property
    /// Attributes, decorators, preprocessor, sections: `@Observable`,
    /// `#if`, `[dependencies]`, `<!DOCTYPE`.
    case meta
}

/// One rendered line: contiguous segments, in order, covering the line.
struct HighlightedLine: Equatable {
    struct Segment: Equatable {
        var text: String
        var kind: CodeTokenKind
    }

    var segments: [Segment]

    var text: String { segments.map(\.text).joined() }
}

/// Line-oriented scanner with a carry state, so block comments, triple
/// quotes, and template literals survive line breaks while every line still
/// highlights independently — which is what lets views render lazily and
/// diffs highlight per-row. Pure and synchronous; callers own threading.
enum CodeHighlighter {
    /// What a line break can carry into the next line.
    enum LineState: Equatable {
        case normal
        /// Inside a block comment; `depth` only moves when the language
        /// nests them (Swift, Rust).
        case blockComment(open: String, close: String, depth: Int, nests: Bool)
        /// Inside a multi-line string: Python/Swift triple quotes, JS
        /// template literals, markup `<!--` handled as comment above.
        /// Backslash escapes always apply — every carrying string form has
        /// them.
        case multilineString(delimiter: String)
    }

    struct Rules {
        var keywords: Set<String> = []
        /// Lowercase builtin types (`int`, `usize`, `string`); capitalized
        /// identifiers classify as types separately when
        /// `capitalizedTypes` is on.
        var builtinTypes: Set<String> = []
        var lineCommentPrefixes: [String] = []
        /// `#` starts a comment only at line start or after whitespace —
        /// keeps `foo#bar` and shell parameter forms intact.
        var hashCommentNeedsBoundary = true
        var blockComment: (open: String, close: String)? = nil
        var nestedBlockComments = false
        /// Plain quote characters with backslash escapes; unterminated ones
        /// end at the line break (single-line strings don't carry).
        var quotes: [Character] = ["\""]
        /// Multi-line string openers, longest first (`"""` before `"`).
        var multilineQuotes: [String] = []
        /// Template-literal style: carries across lines with escapes.
        var backtickTemplate = false
        var capitalizedTypes = false
        /// `@word` / `#word` attribute-style meta.
        var atMeta = false
        var hashMetaAtLineStart = false
        /// `$name` / `${…}` / `$(…)` as property (shell, makefile).
        var dollarVariables = false
        /// `key:` at the start of a member position → property (JSON/YAML).
        var propertyBeforeColon = false
        /// `[section]` alone on a line → meta (TOML/INI).
        var sectionHeaders = false
        var caseInsensitiveKeywords = false
        /// Markup mode replaces the identifier scanner: tags, attributes,
        /// entities (XML/HTML).
        var markup = false
    }

    /// Highlight a whole text. `language: nil` is the plain-text fast path.
    static func highlight(_ text: String, language: CodeLanguage?) -> [HighlightedLine] {
        var pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
        if pieces.last == "" { pieces.removeLast() }
        guard let language, let rules = rules(for: language) else {
            return pieces.map {
                HighlightedLine(segments: [.init(text: String($0), kind: .plain)])
            }
        }
        var state = LineState.normal
        return pieces.map { highlightLine(String($0), state: &state, rules: rules) }
    }

    /// One line, one entry state, one exit state — the diff renderer calls
    /// this directly so each side of a hunk can carry its own state.
    static func highlightLine(
        _ line: String,
        state: inout LineState,
        rules: Rules
    ) -> HighlightedLine {
        var segments: [HighlightedLine.Segment] = []
        let characters = Array(line)
        var index = 0

        func emit(_ text: String, _ kind: CodeTokenKind) {
            guard !text.isEmpty else { return }
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1].text += text
            } else {
                segments.append(.init(text: text, kind: kind))
            }
        }

        func remainder(from start: Int) -> String {
            String(characters[start...])
        }

        func matches(_ needle: String, at position: Int) -> Bool {
            let needleChars = Array(needle)
            guard position + needleChars.count <= characters.count else { return false }
            for (offset, character) in needleChars.enumerated()
            where characters[position + offset] != character {
                return false
            }
            return true
        }

        // Resume a carried state.
        carried: while index < characters.count {
            switch state {
            case .normal:
                break carried
            case .blockComment(let open, let close, let depth, let nests):
                let scan = scanBlockComment(
                    characters, from: index,
                    open: Array(open), close: Array(close),
                    depth: depth, nests: nests
                )
                emit(String(characters[index..<scan.end]), .comment)
                index = scan.end
                if scan.depth == 0 {
                    state = .normal
                } else {
                    state = .blockComment(open: open, close: close, depth: scan.depth, nests: nests)
                    return HighlightedLine(segments: segments)
                }
            case .multilineString(let delimiter):
                let scan = scanToDelimiter(characters, from: index, delimiter: Array(delimiter))
                emit(String(characters[index..<scan.end]), .string)
                index = scan.end
                if scan.closed {
                    state = .normal
                } else {
                    return HighlightedLine(segments: segments)
                }
            }
        }

        if rules.markup {
            scanMarkup(characters, from: &index, emit: emit, state: &state)
            return HighlightedLine(segments: segments.isEmpty && line.isEmpty
                ? [.init(text: "", kind: .plain)]
                : segments)
        }

        // TOML/INI section header: the whole (trimmed) line is [section].
        if rules.sectionHeaders {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 {
                emit(line, .meta)
                return HighlightedLine(segments: segments)
            }
        }

        var lineStart = true
        while index < characters.count {
            let character = characters[index]

            // Whitespace passes through and preserves "line start" until
            // real content shows up.
            if character == " " || character == "\t" {
                var end = index
                while end < characters.count,
                      characters[end] == " " || characters[end] == "\t" { end += 1 }
                emit(String(characters[index..<end]), .plain)
                index = end
                continue
            }

            // Line comments.
            var commented = false
            for prefix in rules.lineCommentPrefixes where matches(prefix, at: index) {
                if prefix == "#", rules.hashCommentNeedsBoundary,
                   !lineStart, index > 0,
                   characters[index - 1] != " ", characters[index - 1] != "\t" {
                    continue
                }
                emit(remainder(from: index), .comment)
                index = characters.count
                commented = true
                break
            }
            if commented { break }

            // Block comment open.
            if let block = rules.blockComment, matches(block.open, at: index) {
                let scan = scanBlockComment(
                    characters, from: index + block.open.count,
                    open: Array(block.open), close: Array(block.close),
                    depth: 1, nests: rules.nestedBlockComments
                )
                emit(String(characters[index..<scan.end]), .comment)
                index = scan.end
                if scan.depth > 0 {
                    state = .blockComment(
                        open: block.open, close: block.close,
                        depth: scan.depth, nests: rules.nestedBlockComments
                    )
                    return HighlightedLine(segments: segments)
                }
                lineStart = false
                continue
            }

            // Multi-line quotes (longest first by construction of the rule).
            var openedMultiline = false
            for delimiter in rules.multilineQuotes where matches(delimiter, at: index) {
                let scan = scanToDelimiter(
                    characters, from: index + delimiter.count, delimiter: Array(delimiter)
                )
                emit(String(characters[index..<scan.end]), .string)
                index = scan.end
                if !scan.closed {
                    state = .multilineString(delimiter: delimiter)
                    return HighlightedLine(segments: segments)
                }
                openedMultiline = true
                break
            }
            if openedMultiline { lineStart = false; continue }

            // Template literal.
            if rules.backtickTemplate, character == "`" {
                let scan = scanToDelimiter(characters, from: index + 1, delimiter: ["`"])
                emit(String(characters[index..<scan.end]), .string)
                index = scan.end
                if !scan.closed {
                    state = .multilineString(delimiter: "`")
                    return HighlightedLine(segments: segments)
                }
                lineStart = false
                continue
            }

            // Single-line strings. Unterminated → string to end of line,
            // no carry: most languages' plain strings cannot span lines,
            // and carrying one would paint the rest of the file green.
            if rules.quotes.contains(character) {
                let scan = scanToDelimiter(characters, from: index + 1, delimiter: [character])
                emit(String(characters[index..<scan.end]), .string)
                index = scan.end
                lineStart = false
                continue
            }

            // $variables (shell, makefile).
            if rules.dollarVariables, character == "$" {
                var cursor = index + 1
                if cursor < characters.count,
                   characters[cursor] == "{" || characters[cursor] == "(" {
                    let close: Character = characters[cursor] == "{" ? "}" : ")"
                    cursor += 1
                    while cursor < characters.count, characters[cursor] != close {
                        cursor += 1
                    }
                    if cursor < characters.count { cursor += 1 }
                } else {
                    while cursor < characters.count, isIdentifier(characters[cursor]) {
                        cursor += 1
                    }
                }
                emit(String(characters[index..<cursor]), .property)
                index = cursor
                lineStart = false
                continue
            }

            // @attribute / #directive meta.
            if (rules.atMeta && character == "@")
                || (rules.hashMetaAtLineStart && character == "#" && lineStart) {
                var cursor = index + 1
                while cursor < characters.count, isIdentifier(characters[cursor]) {
                    cursor += 1
                }
                if cursor > index + 1 {
                    emit(String(characters[index..<cursor]), .meta)
                    index = cursor
                    lineStart = false
                    continue
                }
            }

            // Numbers.
            if character.isNumber
                || (character == "." && index + 1 < characters.count
                    && characters[index + 1].isNumber) {
                var cursor = index + 1
                while cursor < characters.count, isNumberBody(characters[cursor]) {
                    cursor += 1
                }
                emit(String(characters[index..<cursor]), .number)
                index = cursor
                lineStart = false
                continue
            }

            // Identifiers.
            if isIdentifierStart(character) {
                var cursor = index + 1
                while cursor < characters.count, isIdentifier(characters[cursor]) {
                    cursor += 1
                }
                let word = String(characters[index..<cursor])
                let lookup = rules.caseInsensitiveKeywords ? word.lowercased() : word
                var kind = CodeTokenKind.plain
                if rules.keywords.contains(lookup) {
                    kind = .keyword
                } else if rules.builtinTypes.contains(lookup) {
                    kind = .type
                } else if rules.propertyBeforeColon,
                          nextContentCharacter(characters, from: cursor) == ":" {
                    kind = .property
                } else if rules.capitalizedTypes, word.first?.isUppercase == true {
                    kind = .type
                } else if nextContentCharacter(characters, from: cursor) == "(" {
                    kind = .function
                }
                emit(word, kind)
                index = cursor
                lineStart = false
                continue
            }

            // JSON/YAML string keys: a closed string we just emitted
            // followed by ":" is handled by propertyBeforeColon at emit
            // time only for bare words; quoted keys keep string color —
            // acceptable, the colon still separates.

            emit(String(character), .plain)
            index += 1
            lineStart = false
        }

        if segments.isEmpty {
            segments = [.init(text: line, kind: .plain)]
        }
        return HighlightedLine(segments: segments)
    }

    // MARK: Shared scan loops

    /// Walk block-comment content from `start` until the comment closes or
    /// the line ends. Returns the index just past the scan (never beyond the
    /// line) and the nesting depth still open — 0 means it closed here.
    private static func scanBlockComment(
        _ characters: [Character],
        from start: Int,
        open: [Character],
        close: [Character],
        depth: Int,
        nests: Bool
    ) -> (end: Int, depth: Int) {
        var cursor = start
        var level = depth
        while cursor < characters.count {
            if nests, matches(characters, open, at: cursor) {
                level += 1
                cursor += open.count
                continue
            }
            if matches(characters, close, at: cursor) {
                level -= 1
                cursor += close.count
                if level == 0 { break }
                continue
            }
            cursor += 1
        }
        return (cursor, level)
    }

    /// Walk string content from `start` until the delimiter closes it or the
    /// line ends; a backslash escapes the next character. `end` sits just
    /// past the closing delimiter when `closed`.
    private static func scanToDelimiter(
        _ characters: [Character],
        from start: Int,
        delimiter: [Character]
    ) -> (end: Int, closed: Bool) {
        var cursor = start
        while cursor < characters.count {
            if characters[cursor] == "\\", cursor + 1 < characters.count {
                cursor += 2
                continue
            }
            if matches(characters, delimiter, at: cursor) {
                return (cursor + delimiter.count, true)
            }
            cursor += 1
        }
        return (cursor, false)
    }

    /// Needle pre-converted to `[Character]` so the per-character scan loops
    /// above never re-allocate it. (The `String` closure in `highlightLine`
    /// stays for once-per-token checks, where the conversion is cheap.)
    private static func matches(
        _ characters: [Character], _ needle: [Character], at position: Int
    ) -> Bool {
        guard position + needle.count <= characters.count else { return false }
        for (offset, character) in needle.enumerated()
        where characters[position + offset] != character {
            return false
        }
        return true
    }

    // MARK: Markup scanning (XML/HTML)

    private static let markupCommentOpen: [Character] = Array("<!--")
    private static let markupCommentClose: [Character] = Array("-->")

    private static func scanMarkup(
        _ characters: [Character],
        from index: inout Int,
        emit: (String, CodeTokenKind) -> Void,
        state: inout LineState
    ) {
        while index < characters.count {
            if matches(characters, markupCommentOpen, at: index) {
                let scan = scanBlockComment(
                    characters, from: index + markupCommentOpen.count,
                    open: markupCommentOpen, close: markupCommentClose,
                    depth: 1, nests: false
                )
                emit(String(characters[index..<scan.end]), .comment)
                index = scan.end
                if scan.depth > 0 {
                    state = .blockComment(open: "<!--", close: "-->", depth: 1, nests: false)
                    return
                }
                continue
            }
            if characters[index] == "<" {
                // <tag, </tag, <!DOCTYPE, <?xml
                var cursor = index + 1
                if cursor < characters.count,
                   characters[cursor] == "/" || characters[cursor] == "!" || characters[cursor] == "?" {
                    cursor += 1
                }
                var nameEnd = cursor
                while nameEnd < characters.count,
                      isIdentifier(characters[nameEnd]) || characters[nameEnd] == "-" {
                    nameEnd += 1
                }
                emit(String(characters[index..<nameEnd]), .keyword)
                index = nameEnd
                // Attributes until '>'.
                while index < characters.count, characters[index] != ">" {
                    let character = characters[index]
                    if character == "\"" || character == "'" {
                        var end = index + 1
                        while end < characters.count, characters[end] != character {
                            end += 1
                        }
                        if end < characters.count { end += 1 }
                        emit(String(characters[index..<end]), .string)
                        index = end
                        continue
                    }
                    if isIdentifierStart(character) {
                        var end = index + 1
                        while end < characters.count,
                              isIdentifier(characters[end]) || characters[end] == "-" {
                            end += 1
                        }
                        emit(String(characters[index..<end]), .property)
                        index = end
                        continue
                    }
                    emit(String(character), .plain)
                    index += 1
                }
                if index < characters.count {
                    emit(">", .keyword)
                    index += 1
                }
                continue
            }
            var end = index
            while end < characters.count, characters[end] != "<" { end += 1 }
            emit(String(characters[index..<end]), .plain)
            index = end
        }
    }

    // MARK: Character classes

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private static func isNumberBody(_ character: Character) -> Bool {
        character.isHexDigit || character == "_" || character == "."
            || character == "x" || character == "X" || character == "o" || character == "O"
            || character == "b" || character == "B" || character == "e" || character == "E"
            || character == "p" || character == "P" || character == "+" || character == "-"
            || character == "u" || character == "U" || character == "l" || character == "L"
            || character == "f" || character == "F" || character == "i"
    }

    private static func nextContentCharacter(
        _ characters: [Character],
        from index: Int
    ) -> Character? {
        var cursor = index
        while cursor < characters.count {
            let character = characters[cursor]
            if character != " " && character != "\t" { return character }
            cursor += 1
        }
        return nil
    }

    // MARK: Rule tables

    /// nil = render plain (markdown raw mode uses its own renderer; CONF
    /// falls through to the INI profile). Tables are built once — diff rows
    /// look rules up per row, so this must never rebuild the keyword sets.
    static func rules(for language: CodeLanguage) -> Rules? {
        rulesCache[language]
    }

    private static let rulesCache: [CodeLanguage: Rules] = {
        var cache: [CodeLanguage: Rules] = [:]
        for language in CodeLanguage.allCases {
            cache[language] = makeRules(for: language)
        }
        return cache
    }()

    private static func makeRules(for language: CodeLanguage) -> Rules? {
        switch language {
        case .swift:
            var rules = cFamily(keywords: [
                "func", "let", "var", "if", "else", "guard", "return", "switch", "case",
                "default", "for", "while", "repeat", "break", "continue", "struct",
                "class", "enum", "protocol", "extension", "import", "init", "deinit",
                "self", "Self", "super", "nil", "true", "false", "throws", "rethrows",
                "throw", "do", "try", "catch", "as", "is", "in", "where", "defer",
                "static", "final", "private", "fileprivate", "internal", "public",
                "open", "mutating", "nonmutating", "override", "required",
                "convenience", "lazy", "weak", "unowned", "indirect", "associatedtype",
                "typealias", "subscript", "operator", "inout", "some", "any", "await",
                "async", "actor", "nonisolated", "isolated", "consuming", "borrowing",
                "package", "willSet", "didSet", "get", "set",
            ])
            rules.nestedBlockComments = true
            rules.multilineQuotes = ["\"\"\""]
            rules.atMeta = true
            rules.hashMetaAtLineStart = true
            return rules
        case .typescript, .javascript:
            var rules = cFamily(keywords: [
                "const", "let", "var", "function", "return", "if", "else", "for",
                "while", "do", "switch", "case", "default", "break", "continue", "new",
                "delete", "typeof", "instanceof", "in", "of", "class", "extends",
                "implements", "interface", "type", "enum", "namespace", "import",
                "export", "from", "as", "async", "await", "yield", "this", "super",
                "null", "undefined", "true", "false", "try", "catch", "finally",
                "throw", "void", "public", "private", "protected", "readonly",
                "static", "get", "set", "declare", "abstract", "satisfies", "keyof",
                "infer", "is", "asserts", "never", "require", "module",
            ])
            rules.builtinTypes = [
                "string", "number", "boolean", "any", "unknown", "object", "symbol",
                "bigint",
            ]
            rules.quotes = ["\"", "'"]
            rules.backtickTemplate = true
            rules.atMeta = true
            return rules
        case .rust:
            var rules = cFamily(keywords: [
                "fn", "let", "mut", "const", "static", "if", "else", "match", "loop",
                "while", "for", "in", "break", "continue", "return", "struct", "enum",
                "trait", "impl", "mod", "pub", "use", "crate", "super", "self", "Self",
                "where", "as", "dyn", "ref", "move", "async", "await", "unsafe",
                "extern", "type", "true", "false", "box", "macro_rules",
            ])
            rules.builtinTypes = [
                "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64",
                "u128", "usize", "f32", "f64", "bool", "char", "str",
            ]
            rules.nestedBlockComments = true
            rules.hashMetaAtLineStart = true
            return rules
        case .python:
            var rules = Rules()
            rules.keywords = [
                "def", "class", "return", "if", "elif", "else", "for", "while",
                "break", "continue", "pass", "import", "from", "as", "with", "try",
                "except", "finally", "raise", "lambda", "global", "nonlocal", "yield",
                "assert", "del", "in", "is", "not", "and", "or", "None", "True",
                "False", "async", "await", "match", "case", "self",
            ]
            rules.lineCommentPrefixes = ["#"]
            rules.hashCommentNeedsBoundary = false
            rules.quotes = ["\"", "'"]
            rules.multilineQuotes = ["\"\"\"", "'''"]
            rules.capitalizedTypes = true
            rules.atMeta = true
            return rules
        case .go:
            var rules = cFamily(keywords: [
                "func", "package", "import", "var", "const", "type", "struct",
                "interface", "map", "chan", "if", "else", "for", "range", "switch",
                "case", "default", "break", "continue", "return", "go", "defer",
                "select", "fallthrough", "goto", "nil", "true", "false", "iota",
            ])
            rules.builtinTypes = [
                "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8",
                "uint16", "uint32", "uint64", "uintptr", "byte", "rune", "float32",
                "float64", "complex64", "complex128", "bool", "error",
            ]
            rules.quotes = ["\"", "'"]
            rules.backtickTemplate = true
            return rules
        case .c, .cpp, .objectiveC:
            var rules = cFamily(keywords: [
                "if", "else", "for", "while", "do", "switch", "case", "default",
                "break", "continue", "return", "goto", "struct", "union", "enum",
                "typedef", "sizeof", "static", "extern", "const", "volatile",
                "register", "inline", "restrict", "auto",
                // C++
                "class", "namespace", "template", "typename", "public", "private",
                "protected", "virtual", "override", "final", "new", "delete", "this",
                "nullptr", "true", "false", "try", "catch", "throw", "using",
                "constexpr", "consteval", "constinit", "decltype", "operator",
                "friend", "mutable", "explicit", "noexcept", "co_await", "co_return",
                // Obj-C
                "id", "nil", "YES", "NO", "self", "super", "instancetype",
            ])
            rules.builtinTypes = [
                "void", "char", "short", "int", "long", "float", "double", "signed",
                "unsigned", "bool", "size_t", "ssize_t", "wchar_t", "int8_t",
                "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
                "uint64_t", "intptr_t", "uintptr_t", "NSInteger", "NSUInteger",
                "CGFloat", "BOOL",
            ]
            rules.quotes = ["\"", "'"]
            rules.hashMetaAtLineStart = true
            rules.atMeta = true
            return rules
        case .java, .kotlin, .dart, .csharp:
            var rules = cFamily(keywords: [
                "class", "interface", "enum", "extends", "implements", "import",
                "package", "public", "private", "protected", "static", "final", "void",
                "new", "return", "if", "else", "for", "while", "do", "switch", "case",
                "default", "break", "continue", "try", "catch", "finally", "throw",
                "throws", "this", "super", "null", "true", "false", "abstract",
                "synchronized", "instanceof",
                // Kotlin
                "fun", "val", "var", "when", "object", "companion", "data", "sealed",
                "suspend", "override", "lateinit", "by", "in", "out", "is", "as",
                // C#
                "namespace", "using", "async", "await", "readonly", "struct", "record",
                "get", "set", "internal", "sealed", "partial",
                // Dart
                "late", "required", "factory", "extension", "mixin", "typedef",
            ])
            rules.builtinTypes = [
                "int", "long", "short", "byte", "float", "double", "boolean", "char",
                "string", "bool", "num", "dynamic",
            ]
            rules.quotes = ["\"", "'"]
            rules.multilineQuotes = ["\"\"\""]
            rules.capitalizedTypes = true
            rules.atMeta = true
            return rules
        case .ruby:
            var rules = Rules()
            rules.keywords = [
                "def", "end", "class", "module", "if", "elsif", "else", "unless",
                "while", "until", "for", "in", "do", "case", "when", "then", "break",
                "next", "redo", "retry", "return", "yield", "begin", "rescue",
                "ensure", "raise", "require", "require_relative", "include", "extend",
                "attr_accessor", "attr_reader", "attr_writer", "new", "self", "nil",
                "true", "false", "and", "or", "not", "lambda", "proc", "puts", "p",
            ]
            rules.lineCommentPrefixes = ["#"]
            rules.hashCommentNeedsBoundary = false
            rules.quotes = ["\"", "'"]
            rules.capitalizedTypes = true
            rules.atMeta = true
            rules.dollarVariables = true
            return rules
        case .php:
            var rules = cFamily(keywords: [
                "function", "class", "interface", "trait", "extends", "implements",
                "namespace", "use", "public", "private", "protected", "static",
                "const", "return", "if", "else", "elseif", "for", "foreach", "while",
                "do", "switch", "case", "default", "break", "continue", "try",
                "catch", "finally", "throw", "new", "echo", "print", "require",
                "include", "require_once", "include_once", "null", "true", "false",
                "array", "fn", "match", "readonly", "as",
            ])
            rules.lineCommentPrefixes = ["//", "#"]
            rules.quotes = ["\"", "'"]
            rules.capitalizedTypes = true
            rules.dollarVariables = true
            rules.atMeta = true
            return rules
        case .shell:
            var rules = Rules()
            rules.keywords = [
                "if", "then", "elif", "else", "fi", "for", "while", "until", "do",
                "done", "case", "esac", "in", "function", "select", "time", "local",
                "export", "readonly", "return", "exit", "break", "continue", "shift",
                "unset", "eval", "exec", "set", "source", "alias", "trap", "echo",
                "printf", "read", "cd", "test",
            ]
            rules.lineCommentPrefixes = ["#"]
            rules.quotes = ["\"", "'"]
            rules.backtickTemplate = true
            rules.dollarVariables = true
            return rules
        case .json:
            var rules = Rules()
            rules.keywords = ["true", "false", "null"]
            rules.lineCommentPrefixes = ["//"]
            rules.quotes = ["\""]
            rules.propertyBeforeColon = true
            return rules
        case .yaml:
            var rules = Rules()
            rules.keywords = ["true", "false", "null", "yes", "no", "on", "off"]
            rules.caseInsensitiveKeywords = true
            rules.lineCommentPrefixes = ["#"]
            rules.quotes = ["\"", "'"]
            rules.propertyBeforeColon = true
            return rules
        case .toml, .ini:
            var rules = Rules()
            rules.keywords = ["true", "false"]
            rules.lineCommentPrefixes = ["#", ";"]
            rules.hashCommentNeedsBoundary = false
            rules.quotes = ["\"", "'"]
            rules.multilineQuotes = ["\"\"\""]
            rules.sectionHeaders = true
            return rules
        case .xml, .html:
            var rules = Rules()
            rules.markup = true
            return rules
        case .css:
            var rules = Rules()
            rules.keywords = ["important", "inherit", "initial", "unset", "auto", "none"]
            rules.blockComment = ("/*", "*/")
            rules.quotes = ["\"", "'"]
            rules.propertyBeforeColon = true
            rules.atMeta = true
            return rules
        case .sql:
            var rules = Rules()
            rules.keywords = [
                "select", "from", "where", "insert", "into", "values", "update",
                "set", "delete", "create", "table", "index", "view", "drop", "alter",
                "add", "join", "left", "right", "inner", "outer", "full", "on", "as",
                "and", "or", "not", "null", "is", "in", "like", "between", "order",
                "by", "group", "having", "limit", "offset", "distinct", "union",
                "all", "exists", "case", "when", "then", "else", "end", "primary",
                "key", "foreign", "references", "default", "unique", "constraint",
                "begin", "commit", "rollback", "transaction", "if", "returning",
            ]
            rules.caseInsensitiveKeywords = true
            rules.lineCommentPrefixes = ["--"]
            rules.blockComment = ("/*", "*/")
            rules.quotes = ["'", "\""]
            return rules
        case .dockerfile:
            var rules = Rules()
            rules.keywords = [
                "from", "run", "cmd", "entrypoint", "copy", "add", "env", "arg",
                "expose", "volume", "workdir", "user", "label", "onbuild",
                "healthcheck", "shell", "stopsignal", "maintainer",
            ]
            rules.caseInsensitiveKeywords = true
            rules.lineCommentPrefixes = ["#"]
            rules.hashCommentNeedsBoundary = false
            rules.quotes = ["\"", "'"]
            rules.dollarVariables = true
            return rules
        case .makefile:
            var rules = Rules()
            rules.keywords = [
                "ifeq", "ifneq", "ifdef", "ifndef", "endif", "include", "define",
                "endef", "export", "unexport", "override", ".PHONY",
            ]
            rules.lineCommentPrefixes = ["#"]
            rules.hashCommentNeedsBoundary = false
            rules.quotes = ["\"", "'"]
            rules.dollarVariables = true
            return rules
        case .lua:
            var rules = Rules()
            rules.keywords = [
                "and", "break", "do", "else", "elseif", "end", "false", "for",
                "function", "goto", "if", "in", "local", "nil", "not", "or",
                "repeat", "return", "then", "true", "until", "while", "require",
            ]
            rules.lineCommentPrefixes = ["--"]
            rules.quotes = ["\"", "'"]
            return rules
        case .zig:
            var rules = cFamily(keywords: [
                "const", "var", "fn", "pub", "return", "if", "else", "while", "for",
                "switch", "defer", "errdefer", "try", "catch", "orelse", "struct",
                "enum", "union", "error", "comptime", "inline", "export", "extern",
                "test", "unreachable", "null", "undefined", "true", "false", "and",
                "or", "break", "continue", "usingnamespace", "async", "await",
            ])
            rules.builtinTypes = [
                "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize",
                "isize", "f32", "f64", "bool", "void", "anytype", "type",
            ]
            rules.atMeta = true
            return rules
        case .elixir:
            var rules = Rules()
            rules.keywords = [
                "def", "defp", "defmodule", "defmacro", "defstruct", "do", "end",
                "if", "else", "unless", "case", "cond", "with", "for", "when", "fn",
                "receive", "after", "raise", "rescue", "try", "catch", "import",
                "alias", "require", "use", "quote", "unquote", "nil", "true",
                "false", "and", "or", "not", "in",
            ]
            rules.lineCommentPrefixes = ["#"]
            rules.hashCommentNeedsBoundary = false
            rules.quotes = ["\"", "'"]
            rules.multilineQuotes = ["\"\"\""]
            rules.capitalizedTypes = true
            rules.atMeta = true
            return rules
        case .markdown:
            // Raw markdown gets the rendered surface instead; RAW mode
            // shows plain text.
            return nil
        }
    }

    private static func cFamily(keywords: Set<String>) -> Rules {
        var rules = Rules()
        rules.keywords = keywords
        rules.lineCommentPrefixes = ["//"]
        rules.blockComment = ("/*", "*/")
        rules.quotes = ["\""]
        rules.capitalizedTypes = true
        return rules
    }
}
