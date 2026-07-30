import XCTest
@testable import Multiplex

final class FileTreeTests: XCTestCase {
    private func entry(
        _ name: String,
        in directory: String,
        dir: Bool = false
    ) -> FileTreeEntry {
        FileTreeEntry(
            name: name,
            path: FileTree.join(directory, name),
            isDirectory: dir
        )
    }

    func testSortDirectoriesFirstCaseInsensitive() {
        let sorted = FileTree.sorted([
            entry("zeta.txt", in: "/r"),
            entry("Alpha", in: "/r", dir: true),
            entry("beta", in: "/r", dir: true),
            entry("Apple.txt", in: "/r"),
        ])
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "beta", "Apple.txt", "zeta.txt"])
    }

    func testRowsFlattenExpandedDirectories() {
        let root = "/repo"
        let children: [String: [FileTreeEntry]] = [
            root: [
                entry("Sources", in: root, dir: true),
                entry("README.md", in: root),
            ],
            "/repo/Sources": [
                entry("App.swift", in: "/repo/Sources"),
            ],
        ]
        let collapsed = FileTree.rows(
            root: root, children: children,
            expanded: [], badges: [:], changedDirectories: []
        )
        XCTAssertEqual(collapsed.map(\.entry.name), ["Sources", "README.md"])

        let expanded = FileTree.rows(
            root: root, children: children,
            expanded: ["/repo/Sources"], badges: [:], changedDirectories: []
        )
        XCTAssertEqual(expanded.map(\.entry.name), ["Sources", "App.swift", "README.md"])
        XCTAssertEqual(expanded.map(\.depth), [0, 1, 0])
        XCTAssertTrue(expanded[0].isExpanded)
    }

    func testExpandedButUnlistedDirectoryContributesOnlyItself() {
        let root = "/r"
        let children: [String: [FileTreeEntry]] = [
            root: [entry("lazy", in: root, dir: true)]
        ]
        let rows = FileTree.rows(
            root: root, children: children,
            expanded: ["/r/lazy"], badges: [:], changedDirectories: []
        )
        XCTAssertEqual(rows.count, 1)
    }

    func testBadgesAndChangedDirectories() {
        let statuses = [
            GitFileStatus(path: "Sources/App.swift", originPath: nil, badge: .modified),
            GitFileStatus(path: "probe.ts", originPath: nil, badge: .untracked),
        ]
        let badges = FileTree.badges(statuses: statuses, repoRoot: "/repo")
        XCTAssertEqual(badges["/repo/Sources/App.swift"], .modified)
        XCTAssertEqual(badges["/repo/probe.ts"], .untracked)

        let changed = FileTree.changedDirectories(statuses: statuses, repoRoot: "/repo")
        XCTAssertEqual(changed, ["/repo/Sources"])
    }

    func testChangedRowsAreFlatAndSorted() {
        let statuses = [
            GitFileStatus(path: "b/two.swift", originPath: nil, badge: .modified),
            GitFileStatus(path: "a/one.swift", originPath: nil, badge: .added),
        ]
        let rows = FileTree.changedRows(statuses: statuses, repoRoot: "/repo")
        XCTAssertEqual(rows.map(\.entry.name), ["a/one.swift", "b/two.swift"])
        XCTAssertEqual(rows.map(\.entry.path), ["/repo/a/one.swift", "/repo/b/two.swift"])
        XCTAssertEqual(rows[0].badge, .added)
    }

    func testPathHelpers() {
        XCTAssertEqual(FileTree.join("/a/b", "c.txt"), "/a/b/c.txt")
        XCTAssertEqual(FileTree.join("/a/b/", "c.txt"), "/a/b/c.txt")
        XCTAssertEqual(FileTree.parent(of: "/a/b/c.txt"), "/a/b")
        XCTAssertEqual(FileTree.parent(of: "/a"), "/")
        XCTAssertNil(FileTree.parent(of: "/"))
        XCTAssertEqual(FileTree.name(of: "/a/b/c.txt"), "c.txt")
        XCTAssertEqual(FileTree.name(of: "plain"), "plain")
    }
}
