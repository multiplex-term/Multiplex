import XCTest
@testable import Multiplex

final class FileKindTests: XCTestCase {
    func testExtensionClassification() {
        XCTAssertEqual(FileKind.classify(fileName: "App.swift"), .code(.swift))
        XCTAssertEqual(FileKind.classify(fileName: "probe.ts"), .code(.typescript))
        XCTAssertEqual(FileKind.classify(fileName: "Widget.tsx"), .code(.typescript))
        XCTAssertEqual(FileKind.classify(fileName: "main.rs"), .code(.rust))
        XCTAssertEqual(FileKind.classify(fileName: "README.md"), .markdown)
        XCTAssertEqual(FileKind.classify(fileName: "shot.PNG"), .image)
        XCTAssertEqual(FileKind.classify(fileName: "bundle.zip"), .binary)
        XCTAssertEqual(FileKind.classify(fileName: "no-extension"), .code(nil))
        XCTAssertEqual(FileKind.classify(fileName: "weird.xyzzy"), .code(nil))
    }

    func testFullNameClassification() {
        XCTAssertEqual(FileKind.classify(fileName: "Dockerfile"), .code(.dockerfile))
        XCTAssertEqual(FileKind.classify(fileName: "Makefile"), .code(.makefile))
        XCTAssertEqual(FileKind.classify(fileName: ".gitignore"), .code(.ini))
        XCTAssertEqual(FileKind.classify(fileName: "Gemfile"), .code(.ruby))
        XCTAssertEqual(FileKind.classify(fileName: "README"), .markdown)
    }

    func testCompoundArchiveExtensions() {
        XCTAssertEqual(FileKind.classify(fileName: "release.tar.gz"), .binary)
    }

    func testDotfileIsNotAnExtension() {
        // ".zshrc" — the leading dot is a hidden-file marker, not an
        // extension separator.
        XCTAssertEqual(FileKind.classify(fileName: ".zshrc"), .code(.shell))
    }

    func testFenceLanguage() {
        XCTAssertEqual(FileKind.fenceLanguage("swift"), .swift)
        XCTAssertEqual(FileKind.fenceLanguage("ts"), .typescript)
        XCTAssertEqual(FileKind.fenceLanguage("typescript title=\"x\""), .typescript)
        XCTAssertEqual(FileKind.fenceLanguage("objective-c"), .objectiveC)
        XCTAssertNil(FileKind.fenceLanguage(""))
        XCTAssertNil(FileKind.fenceLanguage("madeup"))
    }

    func testBinarySniff() {
        XCTAssertTrue(FileKind.looksBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        XCTAssertFalse(FileKind.looksBinary(Data("plain utf8 ✳ text".utf8)))
        XCTAssertFalse(FileKind.looksBinary(Data()))
    }
}

final class TerminalPathTargetTests: XCTestCase {
    func testAbsoluteHomeAndRelative() {
        XCTAssertEqual(TerminalPathTarget.resolve("/etc/hosts")?.base, .absolute)
        XCTAssertEqual(TerminalPathTarget.resolve("~/notes/todo.md")?.base, .home)
        XCTAssertEqual(TerminalPathTarget.resolve("$HOME/notes.md")?.base, .home)
        XCTAssertEqual(TerminalPathTarget.resolve("./src/main.rs")?.base, .workingDirectory)
        XCTAssertEqual(TerminalPathTarget.resolve("../lib/util.ts")?.base, .workingDirectory)
        XCTAssertEqual(TerminalPathTarget.resolve("src/foo.ts")?.base, .workingDirectory)
    }

    func testRelativePart() {
        XCTAssertEqual(TerminalPathTarget.resolve("~/notes/todo.md")?.relativePart, "notes/todo.md")
        XCTAssertEqual(TerminalPathTarget.resolve("$HOME/notes.md")?.relativePart, "notes.md")
        XCTAssertEqual(TerminalPathTarget.resolve("./src/main.rs")?.relativePart, "src/main.rs")
        XCTAssertEqual(TerminalPathTarget.resolve("/etc/hosts")?.relativePart, "/etc/hosts")
        XCTAssertEqual(TerminalPathTarget.resolve("../x/y.c")?.relativePart, "../x/y.c")
    }

    func testLineSuffixes() {
        let single = TerminalPathTarget.resolve("src/app.ts:42")
        XCTAssertEqual(single?.path, "src/app.ts")
        XCTAssertEqual(single?.line, 42)
        let pair = TerminalPathTarget.resolve("Multiplex/App.swift:120:15")
        XCTAssertEqual(pair?.path, "Multiplex/App.swift")
        XCTAssertEqual(pair?.line, 120)
    }

    func testDeclines() {
        // URLs belong to TerminalLink.
        XCTAssertNil(TerminalPathTarget.resolve("https://example.com/a/b"))
        // Unknown environment variables can't be resolved from here.
        XCTAssertNil(TerminalPathTarget.resolve("$WORKDIR/src/main.rs"))
        // Colon prose ("warning:") and non-suffix colons.
        XCTAssertNil(TerminalPathTarget.resolve("warning:"))
        XCTAssertNil(TerminalPathTarget.resolve("a/b:c/d"))
        // A bare word is not a path.
        XCTAssertNil(TerminalPathTarget.resolve("README"))
        // Root alone and protocol-relative shapes.
        XCTAssertNil(TerminalPathTarget.resolve("/"))
        XCTAssertNil(TerminalPathTarget.resolve("//cdn.example.com/x"))
        XCTAssertNil(TerminalPathTarget.resolve(""))
    }

    func testTrailingPunctuationTrimmed() {
        XCTAssertEqual(TerminalPathTarget.resolve("src/foo.ts.")?.path, "src/foo.ts")
        XCTAssertEqual(TerminalPathTarget.resolve("src/foo.ts,")?.path, "src/foo.ts")
    }

    func testInteriorWhitespaceIsProse() {
        // Bare-relative keeps the prose guard: without a base marker,
        // whitespace is what separates a path from a sentence about one.
        XCTAssertNil(TerminalPathTarget.resolve("(see src/foo.ts)"))
        XCTAssertNil(TerminalPathTarget.resolve("path with space/file.txt"))
        // Tabs and line breaks never resolve, marker or not.
        XCTAssertNil(TerminalPathTarget.resolve("/tmp/a\tb"))
        XCTAssertNil(TerminalPathTarget.resolve("/tmp/a\nb"))
    }

    func testSpacedPathsBehindABaseMarkerResolve() {
        let absolute = TerminalPathTarget.resolve("/Users/me/My Documents/file.txt")
        XCTAssertEqual(absolute?.base, .absolute)
        XCTAssertEqual(absolute?.path, "/Users/me/My Documents/file.txt")
        let home = TerminalPathTarget.resolve("~/My Folder/notes.md")
        XCTAssertEqual(home?.base, .home)
        XCTAssertEqual(home?.relativePart, "My Folder/notes.md")
        XCTAssertEqual(
            TerminalPathTarget.resolve("./My File.md")?.base,
            .workingDirectory
        )
        XCTAssertEqual(
            TerminalPathTarget.resolve("$HOME/My Docs/x.txt")?.relativePart,
            "My Docs/x.txt"
        )
    }

    func testSpacedProseTailIsShed() {
        // The matcher's space-segment branches swallow trailing prose
        // whenever the first chunk is dot-free — "/etc/hosts is missing"
        // arrives whole — so prose-shaped tail chunks are shed.
        XCTAssertEqual(
            TerminalPathTarget.resolve("/etc/hosts is missing")?.path,
            "/etc/hosts"
        )
        XCTAssertEqual(
            TerminalPathTarget.resolve("/Users/me/My Documents/file.txt now really")?.path,
            "/Users/me/My Documents/file.txt"
        )
        XCTAssertEqual(
            TerminalPathTarget.resolve("/tmp/a b c/d.log ok")?.path,
            "/tmp/a b c/d.log"
        )
        XCTAssertEqual(
            TerminalPathTarget.resolve("~/My Folder/notes.md today, fine.")?.path,
            "~/My Folder/notes.md"
        )
    }

    func testSpacedLineSuffixSurvives() {
        let target = TerminalPathTarget.resolve("/tmp/My Dir/app.swift:42")
        XCTAssertEqual(target?.path, "/tmp/My Dir/app.swift")
        XCTAssertEqual(target?.line, 42)
    }

    /// A hard-wrapped row glues a sentence's tail to the path below it (no
    /// space at the seam), and the ghostty matcher reads the pair as one
    /// bare-relative path — the `.`-prefixed path users see. The segment
    /// ending in `.` right before a slash is the tell.
    func testWrappedProseHeadStripped() {
        XCTAssertEqual(
            TerminalPathTarget.resolve("sentence./Users/jhen/x.swift")?.path,
            "/Users/jhen/x.swift"
        )
        XCTAssertEqual(
            TerminalPathTarget.resolve("sentence./Users/jhen/x.swift")?.base,
            .absolute
        )
        // The suffix survives the cut.
        let numbered = TerminalPathTarget.resolve("docs.md./etc/hosts:12")
        XCTAssertEqual(numbered?.path, "/etc/hosts")
        XCTAssertEqual(numbered?.line, 12)
    }

    func testRealPathsSurviveTheProseCut() {
        // Base markers are their own root — never a prose suffix.
        XCTAssertEqual(TerminalPathTarget.resolve("./src/main.rs")?.path, "./src/main.rs")
        XCTAssertEqual(TerminalPathTarget.resolve("../lib/util.ts")?.path, "../lib/util.ts")
        XCTAssertEqual(TerminalPathTarget.resolve("/var/./log/x")?.path, "/var/./log/x")
        XCTAssertEqual(TerminalPathTarget.resolve("~/notes/todo.md")?.path, "~/notes/todo.md")
        // A dot inside a segment is ordinary.
        XCTAssertEqual(TerminalPathTarget.resolve("src/foo.ts")?.path, "src/foo.ts")
        XCTAssertEqual(TerminalPathTarget.resolve("a.b/c.d")?.path, "a.b/c.d")
        XCTAssertEqual(TerminalPathTarget.resolve("dir/./file")?.path, "dir/./file")
        XCTAssertEqual(TerminalPathTarget.resolve("dir/../file")?.path, "dir/../file")
    }

    func testTimeIsNotAPath() {
        XCTAssertNil(TerminalPathTarget.resolve("12:30"))
    }
}
