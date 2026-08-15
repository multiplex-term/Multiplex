import Foundation

/// The languages the viewer's highlighter has rule tables for. The raw
/// value is the badge the file header shows.
enum CodeLanguage: String, Equatable, CaseIterable {
    case swift = "SWIFT"
    case typescript = "TYPESCRIPT"
    case javascript = "JAVASCRIPT"
    case rust = "RUST"
    case python = "PYTHON"
    case go = "GO"
    case c = "C"
    case cpp = "C++"
    case objectiveC = "OBJ-C"
    case java = "JAVA"
    case kotlin = "KOTLIN"
    case ruby = "RUBY"
    case php = "PHP"
    case shell = "SHELL"
    case json = "JSON"
    case yaml = "YAML"
    case toml = "TOML"
    case xml = "XML"
    case html = "HTML"
    case css = "CSS"
    case sql = "SQL"
    case dockerfile = "DOCKERFILE"
    case makefile = "MAKEFILE"
    case ini = "CONF"
    case lua = "LUA"
    case dart = "DART"
    case csharp = "C#"
    case zig = "ZIG"
    case elixir = "ELIXIR"
    case markdown = "MARKDOWN"
}

/// How the content screen renders a file, decided from its name — the
/// cheap verdict. Binary-vs-text is a *content* question layered on top
/// (`FileKind.looksBinary`), because extensions lie in both directions.
enum FileRenderKind: Equatable {
    /// Monospace grid + syntax color; nil language = plain text.
    case code(CodeLanguage?)
    /// Rendered document with a RAW flip.
    case markdown
    /// Fit-to-screen image.
    case image
    /// Paged document on the PDFKit screen.
    case pdf
    /// A sound file behind the transport panel (play/pause, scrub, clock).
    /// Membership is by extension only — whether THIS device can decode it
    /// is the player's verdict, and an honest CAN'T PLAY beats a BINARY
    /// panel for a format that is plainly audio.
    case audio
    /// Known-opaque formats (archives, databases, executables): never read
    /// as text, the header says BINARY and the size.
    case binary
}

enum FileKind {
    /// Name-based classification. Full-name matches (Dockerfile, Makefile)
    /// win over extensions; unknown extensions fall to plain text — the
    /// honest default for a viewer (the binary sniff still runs on bytes).
    static func classify(fileName: String) -> FileRenderKind {
        let name = fileName.lowercased()
        if let kind = fullNameKinds[name] { return kind }
        // Compound extensions the simple split would misread.
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tar.xz") || name.hasSuffix(".tar.zst") {
            return .binary
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return .code(nil)
        }
        let ext = String(name[name.index(after: dot)...])
        if let language = languageByExtension[ext] { return .code(language) }
        if markdownExtensions.contains(ext) { return .markdown }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if audioExtensions.contains(ext) { return .audio }
        if binaryExtensions.contains(ext) { return .binary }
        return .code(nil)
    }

    /// The language a markdown fence's info string names (```swift), for
    /// the renderer's embedded highlighting. Forgiving: first word, common
    /// aliases folded.
    static func fenceLanguage(_ info: String) -> CodeLanguage? {
        let word = info.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        guard !word.isEmpty else { return nil }
        if let language = languageByExtension[word] { return language }
        return fenceAliases[word]
    }

    /// The text/binary sniff: a NUL in the head is the classic verdict —
    /// no text encoding the viewer renders contains one.
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    private static let fullNameKinds: [String: FileRenderKind] = [
        "dockerfile": .code(.dockerfile),
        "containerfile": .code(.dockerfile),
        "makefile": .code(.makefile),
        "gnumakefile": .code(.makefile),
        "cmakelists.txt": .code(nil),
        "gemfile": .code(.ruby),
        "rakefile": .code(.ruby),
        "podfile": .code(.ruby),
        "fastfile": .code(.ruby),
        "brewfile": .code(.ruby),
        "justfile": .code(.makefile),
        "license": .code(nil),
        "readme": .markdown,
        ".gitignore": .code(.ini),
        ".gitattributes": .code(.ini),
        ".gitmodules": .code(.ini),
        ".editorconfig": .code(.ini),
        ".env": .code(.shell),
        ".zshrc": .code(.shell),
        ".bashrc": .code(.shell),
        ".bash_profile": .code(.shell),
        ".profile": .code(.shell),
        ".tmux.conf": .code(.ini),
        ".vimrc": .code(nil),
    ]

    private static let languageByExtension: [String: CodeLanguage] = [
        "swift": .swift,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "rs": .rust,
        "py": .python, "pyi": .python,
        "go": .go,
        "c": .c, "h": .c,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "m": .objectiveC, "mm": .objectiveC,
        "java": .java,
        "kt": .kotlin, "kts": .kotlin,
        "rb": .ruby, "erb": .ruby,
        "php": .php,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "json": .json, "jsonc": .json, "json5": .json, "jsonl": .json,
        "storekit": .json, "webmanifest": .json,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml, "lock": .toml,
        "xml": .xml, "plist": .xml, "svg": .xml, "xib": .xml, "storyboard": .xml,
        "entitlements": .xml, "xcprivacy": .xml,
        "html": .html, "htm": .html, "vue": .html, "svelte": .html, "astro": .html,
        "css": .css, "scss": .css, "less": .css,
        "sql": .sql,
        "ini": .ini, "cfg": .ini, "conf": .ini, "properties": .ini, "gitconfig": .ini,
        "lua": .lua,
        "dart": .dart,
        "cs": .csharp,
        "zig": .zig,
        "ex": .elixir, "exs": .elixir,
        "mod": .go, "sum": .ini,
        "gradle": .kotlin,
        "diff": .ini, "patch": .ini,
    ]

    private static let fenceAliases: [String: CodeLanguage] = [
        "typescript": .typescript, "javascript": .javascript,
        "swift": .swift, "rust": .rust, "python": .python, "golang": .go,
        "shell": .shell, "console": .shell, "terminal": .shell,
        "objc": .objectiveC, "objective-c": .objectiveC,
        "kotlin": .kotlin, "ruby": .ruby, "csharp": .csharp,
        "dockerfile": .dockerfile, "makefile": .makefile, "make": .makefile,
        "elixir": .elixir, "markdown": .markdown, "md": .markdown,
    ]

    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mdx",
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "ico",
    ]

    /// What Core Audio reads on these devices, plus the Ogg family — the
    /// player decides Vorbis vs Opus at decode time and says CAN'T PLAY
    /// rather than pretending a `.ogg` is opaque bytes. Video containers
    /// stay binary: this is a sound panel, not a media player.
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc",
        "caf", "flac", "alac", "au", "amr", "ogg", "oga", "opus",
    ]

    private static let binaryExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "sqlite", "sqlite3", "db", "realm",
        "a", "o", "so", "dylib", "dll", "exe", "bin", "wasm", "class", "jar",
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "wma",
        "ttf", "otf", "woff", "woff2",
        "car", "ipa", "apk", "dmg", "iso",
        "psd", "sketch", "fig", "afdesign",
        "pyc", "beam", "keystore", "p12", "mobileprovision",
    ]
}
