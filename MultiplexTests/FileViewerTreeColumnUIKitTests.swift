import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class FileViewerTreeColumnUIKitTests: XCTestCase {
    func testSnapshotLocationAndRootHoistRules() {
        var snapshot = makeSnapshot(rootPath: "/srv/app")
        XCTAssertEqual(snapshot.locationLabel, "devbox ▸ app")
        XCTAssertTrue(snapshot.canHoistRoot)

        snapshot.rootPath = "/"
        XCTAssertEqual(snapshot.locationLabel, "devbox ▸ /")
        XCTAssertFalse(snapshot.canHoistRoot)
    }

    func testNativeChromePreservesGitActionsCountsAndAccessibility() {
        let row = makeRow(
            name: "Sources",
            path: "/srv/app/Sources",
            directory: true,
            expanded: true
        )
        var snapshot = makeSnapshot(rootPath: "/srv/app")
        snapshot.gitRoot = "/srv/app"
        snapshot.branch = "main"
        snapshot.shortStat = GitShortStat(filesChanged: 2, insertions: 14, deletions: 3)
        snapshot.rows = [row]
        var upCount = 0
        var diffCount = 0
        var changedCount = 0
        var selected: [FileTree.Row] = []
        let view = FileViewerTreeColumnView()
        view.render(
            snapshot: snapshot,
            onUp: { upCount += 1 },
            onRepoDiff: { diffCount += 1 },
            onChangedFilter: { changedCount += 1 },
            onSelect: { selected.append($0) }
        )

        XCTAssertEqual(view.locationSourceLabel?.accessibilityLabel, "devbox ▸ app")
        XCTAssertEqual(view.upChip?.accessibilityLabel, "Show the parent directory")
        XCTAssertEqual(view.branchLabel?.text, "⎇ main")
        XCTAssertEqual(
            view.countsButton?.accessibilityLabel,
            "Open the working tree's diff"
        )
        XCTAssertEqual(view.countsButton?.buttonType, .custom)
        XCTAssertNil(view.countsButton?.configuration)
        XCTAssertEqual(view.countsButton?.backgroundColor, .clear)
        XCTAssertEqual(view.countsButton?.contentEdgeInsets, .zero)
        XCTAssertEqual(view.countsButton?.layer.borderWidth, 0)
        XCTAssertEqual(view.countsButton?.attributedTitle(for: .normal)?.string, "+14 −3")
        XCTAssertEqual(
            view.changedChip?.accessibilityLabel,
            "Show only changed files"
        )
        XCTAssertEqual(view.tableView(view.tableView, numberOfRowsInSection: 0), 1)

        XCTAssertTrue(view.upChip?.accessibilityActivate() == true)
        view.countsButton?.sendActions(for: .touchUpInside)
        XCTAssertTrue(view.changedChip?.accessibilityActivate() == true)
        view.selectRow(at: 0)
        XCTAssertEqual(upCount, 1)
        XCTAssertEqual(diffCount, 1)
        XCTAssertEqual(changedCount, 1)
        XCTAssertEqual(selected, [row])
    }

    func testFileLongPressOffersOpenInNewTab() {
        let directory = makeRow(
            name: "Sources",
            path: "/srv/app/Sources",
            directory: true,
            expanded: false
        )
        let file = makeRow(
            name: "App.swift",
            path: "/srv/app/Sources/App.swift",
            directory: false,
            expanded: false
        )
        var snapshot = makeSnapshot(rootPath: "/srv/app")
        snapshot.rows = [directory, file]
        var opened: [FileTree.Row] = []
        let view = FileViewerTreeColumnView()
        view.render(
            snapshot: snapshot,
            onOpenInNewTab: { opened.append($0) }
        )

        XCTAssertNil(view.menu(for: directory.entry.path))
        XCTAssertEqual(menuTitles(view.menu(for: file.entry.path)), ["Open in New Tab"])
        XCTAssertNil(view.tableView(
            view.tableView,
            contextMenuConfigurationForRowAt: IndexPath(row: 0, section: 0),
            point: .zero
        ))
        XCTAssertNotNil(view.tableView(
            view.tableView,
            contextMenuConfigurationForRowAt: IndexPath(row: 1, section: 0),
            point: .zero
        ))

        let cell = view.tableView(
            view.tableView,
            cellForRowAt: IndexPath(row: 1, section: 0)
        )
        XCTAssertEqual(
            cell.accessibilityCustomActions?.map(\.name),
            ["Open in New Tab"]
        )
        view.openInNewTab(path: file.entry.path)
        XCTAssertEqual(opened, [file])
    }

    func testFailurePrecedesRowsAndEmptyStatUsesQuietReadout() {
        var snapshot = makeSnapshot(rootPath: "/srv/app")
        snapshot.treeFailure = "Permission denied"
        snapshot.rows = [makeRow(
            name: "README.md",
            path: "/srv/app/README.md",
            directory: false,
            expanded: false
        )]
        let view = FileViewerTreeColumnView()
        view.render(snapshot: snapshot)

        XCTAssertEqual(view.tableView(view.tableView, numberOfRowsInSection: 0), 2)
        let failure = view.tableView(
            view.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        )
        XCTAssertEqual(failure.accessibilityLabel, "Permission denied")
        XCTAssertEqual(
            FileViewerTreeColumnView.countsText(GitShortStat()).string,
            "±0"
        )
    }

    private func menuTitles(_ menu: UIMenu?) -> [String] {
        menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }

    private func makeSnapshot(rootPath: String) -> FileViewerTreeColumnSnapshot {
        FileViewerTreeColumnSnapshot(
            hostName: "devbox",
            rootPath: rootPath,
            gitRoot: nil,
            branch: nil,
            shortStat: GitShortStat(),
            changedFilter: false,
            treeFailure: nil,
            rows: [],
            railPath: rootPath
        )
    }

    private func makeRow(
        name: String,
        path: String,
        directory: Bool,
        expanded: Bool
    ) -> FileTree.Row {
        FileTree.Row(
            entry: FileTreeEntry(name: name, path: path, isDirectory: directory),
            depth: 0,
            isExpanded: expanded
        )
    }
}
