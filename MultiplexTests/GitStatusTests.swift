import XCTest
@testable import Multiplex

final class GitStatusTests: XCTestCase {
    func testPorcelainZBasics() {
        let output = " M Multiplex/App.swift\0?? probe.ts\0A  added.md\0 D gone.txt\0"
        let entries = GitFileStatus.parse(porcelainZ: output)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].path, "Multiplex/App.swift")
        XCTAssertEqual(entries[0].badge, .modified)
        XCTAssertEqual(entries[1].badge, .untracked)
        XCTAssertEqual(entries[2].badge, .added)
        XCTAssertEqual(entries[3].badge, .deleted)
    }

    func testRenameCarriesOriginFromNextToken() {
        let output = "R  new/name.swift\0old/name.swift\0 M other.txt\0"
        let entries = GitFileStatus.parse(porcelainZ: output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].badge, .renamed)
        XCTAssertEqual(entries[0].path, "new/name.swift")
        XCTAssertEqual(entries[0].originPath, "old/name.swift")
        // The origin token must not be misread as its own entry.
        XCTAssertEqual(entries[1].path, "other.txt")
    }

    func testConflictBadges() {
        let output = "UU both.swift\0AA added-both.txt\0DD deleted-both.txt\0"
        let entries = GitFileStatus.parse(porcelainZ: output)
        XCTAssertEqual(entries.map(\.badge), [.conflicted, .conflicted, .conflicted])
    }

    func testPathsWithSpacesAndNewlinesSurviveZ() {
        // -z's whole point: no quoting, NUL separation — a newline is just
        // a filename byte.
        let output = " M has space.txt\0?? has\nnewline.txt\0"
        let entries = GitFileStatus.parse(porcelainZ: output)
        XCTAssertEqual(entries[0].path, "has space.txt")
        XCTAssertEqual(entries[1].path, "has\nnewline.txt")
    }

    func testShortStatVariants() {
        XCTAssertEqual(
            GitShortStat.parse(" 3 files changed, 42 insertions(+), 17 deletions(-)\n"),
            GitShortStat(filesChanged: 3, insertions: 42, deletions: 17)
        )
        XCTAssertEqual(
            GitShortStat.parse(" 1 file changed, 1 deletion(-)"),
            GitShortStat(filesChanged: 1, insertions: 0, deletions: 1)
        )
        XCTAssertTrue(GitShortStat.parse("").isEmpty)
        XCTAssertTrue(GitShortStat.parse("\n").isEmpty)
    }

    // MARK: GitCommands

    func testSplitExitFindsTrailingSentinel() {
        let (body, exit) = GitCommands.splitExit("line one\nline two\nMPXFV_EXIT:0")
        XCTAssertEqual(body, "line one\nline two")
        XCTAssertEqual(exit, 0)
    }

    func testSplitExitEmptyBody() {
        let (body, exit) = GitCommands.splitExit("MPXFV_EXIT:128")
        XCTAssertEqual(body, "")
        XCTAssertEqual(exit, 128)
    }

    func testSplitExitTakesLastOccurrence() {
        // Body content can echo the sentinel; ours is always the final one.
        let (body, exit) = GitCommands.splitExit("x\nMPXFV_EXIT:7\ny\nMPXFV_EXIT:1")
        XCTAssertEqual(body, "x\nMPXFV_EXIT:7\ny")
        XCTAssertEqual(exit, 1)
    }

    func testSplitExitMissingSentinel() {
        let (body, exit) = GitCommands.splitExit("truncated")
        XCTAssertEqual(body, "truncated")
        XCTAssertNil(exit)
    }

    func testCommandsQuotePaths() {
        let command = GitCommands.diffFile(root: "/srv/my repo", path: "a'b.swift")
        XCTAssertTrue(command.contains("'/srv/my repo'"))
        XCTAssertTrue(command.contains("'a'\\''b.swift'"))
        XCTAssertTrue(command.contains("--no-ext-diff"))
        XCTAssertTrue(command.contains("2>/dev/null"))
        XCTAssertTrue(command.hasSuffix("printf '\\nMPXFV_EXIT:%s' \"$?\""))
    }

    func testRepoProbeParse() {
        let body = "/home/dev/app\nMPXFV_BR:main"
        let parsed = GitCommands.parseRepoProbe(body: body)
        XCTAssertEqual(parsed.toplevel, "/home/dev/app")
        XCTAssertEqual(parsed.branch, "main")

        let unborn = GitCommands.parseRepoProbe(body: "/home/dev/app\nMPXFV_BR:")
        XCTAssertEqual(unborn.toplevel, "/home/dev/app")
        XCTAssertNil(unborn.branch)

        let outside = GitCommands.parseRepoProbe(body: "\nMPXFV_BR:")
        XCTAssertNil(outside.toplevel)
        XCTAssertNil(outside.branch)
    }
}
