import XCTest
@testable import Multiplex

final class GitDiffTests: XCTestCase {
    func testModifiedFileWithOneHunk() {
        let diff = GitDiff.parse("""
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 3f9c1a2..8b0d221 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,4 +10,5 @@ struct App {
             let name: String
        -    let old: Int
        +    let new: Int
        +    let extra: Bool
             let tail: String
        """)
        XCTAssertEqual(diff.files.count, 1)
        let file = diff.files[0]
        XCTAssertEqual(file.displayPath, "Sources/App.swift")
        XCTAssertEqual(file.kind, .modified)
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 1)
        let hunk = file.hunks[0]
        XCTAssertEqual(hunk.heading, "struct App {")
        XCTAssertEqual(hunk.oldStart, 10)
        XCTAssertEqual(hunk.newStart, 10)
        XCTAssertEqual(hunk.lines.count, 5)
        // Line numbering: context advances both sides, +/- one side each.
        XCTAssertEqual(hunk.lines[0].oldNumber, 10)
        XCTAssertEqual(hunk.lines[0].newNumber, 10)
        XCTAssertEqual(hunk.lines[1].kind, .deletion)
        XCTAssertEqual(hunk.lines[1].oldNumber, 11)
        XCTAssertNil(hunk.lines[1].newNumber)
        XCTAssertEqual(hunk.lines[2].kind, .addition)
        XCTAssertEqual(hunk.lines[2].newNumber, 11)
        XCTAssertNil(hunk.lines[2].oldNumber)
        XCTAssertEqual(hunk.lines[4].kind, .context)
        XCTAssertEqual(hunk.lines[4].oldNumber, 12)
        XCTAssertEqual(hunk.lines[4].newNumber, 13)
    }

    func testAddedAndDeletedFiles() {
        let diff = GitDiff.parse("""
        diff --git a/new.ts b/new.ts
        new file mode 100644
        index 0000000..2b5e1a0
        --- /dev/null
        +++ b/new.ts
        @@ -0,0 +1,2 @@
        +const a = 1;
        +export default a;
        diff --git a/gone.rb b/gone.rb
        deleted file mode 100644
        index 9daeafb..0000000
        --- a/gone.rb
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -puts "bye"
        """)
        XCTAssertEqual(diff.files.count, 2)
        XCTAssertEqual(diff.files[0].kind, .added)
        XCTAssertEqual(diff.files[0].displayPath, "new.ts")
        XCTAssertEqual(diff.files[0].additions, 2)
        XCTAssertEqual(diff.files[1].kind, .deleted)
        XCTAssertEqual(diff.files[1].displayPath, "gone.rb")
        XCTAssertEqual(diff.files[1].deletions, 1)
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
    }

    func testRenameWithoutHunks() {
        let diff = GitDiff.parse("""
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt
        """)
        XCTAssertEqual(diff.files.count, 1)
        XCTAssertEqual(diff.files[0].kind, .renamed)
        XCTAssertEqual(diff.files[0].oldPath, "old name.txt")
        XCTAssertEqual(diff.files[0].newPath, "new name.txt")
        XCTAssertEqual(diff.files[0].displayPath, "new name.txt")
        XCTAssertTrue(diff.files[0].hunks.isEmpty)
    }

    func testBinaryFile() {
        let diff = GitDiff.parse("""
        diff --git a/icon.png b/icon.png
        index 1111111..2222222 100644
        Binary files a/icon.png and b/icon.png differ
        """)
        XCTAssertEqual(diff.files.count, 1)
        XCTAssertTrue(diff.files[0].isBinary)
        XCTAssertTrue(diff.files[0].hunks.isEmpty)
    }

    func testQuotedPathsUnquote() {
        // git C-quotes controls; with core.quotepath=false non-ASCII stays
        // raw, but tabs still escape.
        let diff = GitDiff.parse("""
        diff --git "a/we\\tird.txt" "b/we\\tird.txt"
        index 1111111..2222222 100644
        --- "a/we\\tird.txt"
        +++ "b/we\\tird.txt"
        @@ -1 +1 @@
        -a
        +b
        """)
        XCTAssertEqual(diff.files[0].displayPath, "we\tird.txt")
    }

    func testOctalEscapeUnquote() {
        XCTAssertEqual(GitDiffFile.unquote(#""caf\303\251.md""#), "café.md")
        XCTAssertEqual(GitDiffFile.unquote("plain.md"), "plain.md")
    }

    func testNoNewlineMarkerAnnotatesPreviousLine() {
        let diff = GitDiff.parse("""
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """)
        let lines = diff.files[0].hunks[0].lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].noTrailingNewline)
        XCTAssertTrue(lines[1].noTrailingNewline)
    }

    func testEmptyContextLineSurvives() {
        // Transports can strip the single space a blank context line is
        // made of; the row must still count on both sides.
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n a\n\n b\n"
        let diff = GitDiff.parse(text)
        let lines = diff.files[0].hunks[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].kind, .context)
        XCTAssertEqual(lines[2].oldNumber, 3)
        XCTAssertEqual(lines[2].newNumber, 3)
    }

    func testTrailingNewlineAddsNoPhantomRow() {
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"
        let diff = GitDiff.parse(text)
        XCTAssertEqual(diff.files[0].hunks[0].lines.count, 2)
    }

    func testUntrackedNoIndexShape() {
        // `git diff --no-index -- /dev/null path` — the all-additions render
        // for untracked files.
        let diff = GitDiff.parse("""
        diff --git a/dev/null b/probe.ts
        new file mode 100644
        index 0000000..f2a9b1c
        --- /dev/null
        +++ b/probe.ts
        @@ -0,0 +1,2 @@
        +export const x = 1;
        +export const y = 2;
        """)
        XCTAssertEqual(diff.files[0].kind, .added)
        XCTAssertEqual(diff.files[0].displayPath, "probe.ts")
        XCTAssertEqual(diff.files[0].additions, 2)
    }

    func testCountOmittedDefaultsToOne() {
        guard let hunk = GitDiffHunk.parseHeader("@@ -5 +7 @@") else {
            return XCTFail("header should parse")
        }
        XCTAssertEqual(hunk.oldStart, 5)
        XCTAssertEqual(hunk.oldCount, 1)
        XCTAssertEqual(hunk.newStart, 7)
        XCTAssertEqual(hunk.newCount, 1)
    }

    func testGarbageDoesNotCrashAndYieldsNothing() {
        XCTAssertTrue(GitDiff.parse("").files.isEmpty)
        XCTAssertTrue(GitDiff.parse("not a diff at all\n@@ stray @@\n+x").files.isEmpty)
    }
}
