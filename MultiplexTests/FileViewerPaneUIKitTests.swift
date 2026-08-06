import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class FileViewerPaneUIKitTests: XCTestCase {
    func testResponsiveWorkbenchPreservesRegularColumnAndCompactDrawer() {
        var closed = 0
        let pane = makePane(close: { closed += 1 })
        pane.loadViewIfNeeded()
        pane.view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        pane.applyResponsiveLayout(for: 900)
        pane.view.layoutIfNeeded()

        XCTAssertFalse(pane.isCompactLayout)
        XCTAssertTrue(pane.treeDocked)
        XCTAssertEqual(pane.treeChip?.accessibilityLabel, "Hide the file tree")
        XCTAssertTrue(pane.treeChip?.accessibilityActivate() == true)
        XCTAssertFalse(pane.treeDocked)
        XCTAssertEqual(pane.treeChip?.accessibilityLabel, "Show the file tree")

        pane.applyResponsiveLayout(for: 640)
        XCTAssertTrue(pane.isCompactLayout)
        XCTAssertTrue(pane.drawerOpen, "Browse summons start with the compact tree open")
        XCTAssertEqual(pane.treeChip?.accessibilityLabel, "Hide the file tree")
        XCTAssertTrue(pane.treeChip?.accessibilityActivate() == true)
        XCTAssertFalse(pane.drawerOpen)
        XCTAssertEqual(pane.treeChip?.accessibilityLabel, "Show the file tree")

        XCTAssertTrue(pane.closeChip?.accessibilityActivate() == true)
        XCTAssertEqual(closed, 1)
    }

    func testBreakpointDrawerGeometryAndBadgeVocabularyAreStable() {
        XCTAssertFalse(FileViewerPaneViewController.isCompact(width: 700))
        XCTAssertTrue(FileViewerPaneViewController.isCompact(width: 699.5))
        XCTAssertEqual(FileViewerPaneViewController.drawerWidth(for: 900), 260)
        XCTAssertEqual(FileViewerPaneViewController.drawerWidth(for: 240), 184)

        let expected: [(GitFileStatus.Badge, String)] = [
            (.modified, "MODIFIED"),
            (.added, "STAGED ADD"),
            (.deleted, "DELETED"),
            (.renamed, "RENAMED"),
            (.untracked, "UNTRACKED"),
            (.conflicted, "CONFLICT"),
        ]
        for (badge, caption) in expected {
            XCTAssertEqual(FileViewerPaneViewController.badgeCaption(badge), caption)
        }
        XCTAssertEqual(
            FileViewerPaneViewController.countsText(additions: 12, deletions: 4).string,
            "+12 −4"
        )
    }

    func testPressedPathDoesNotCoverItsDocumentWithInitialDrawer() throws {
        let target = try XCTUnwrap(TerminalPathTarget.resolve("Sources/App.swift:12"))
        let controller = FileViewerController(
            tabID: UUID(),
            host: makeHost(),
            startDirectory: "/srv/app",
            target: target
        )
        XCTAssertFalse(FileViewerPaneViewController.startsWithDrawerOpen(controller))

        let browsing = FileViewerController(
            tabID: UUID(),
            host: makeHost(),
            startDirectory: "/srv/app",
            target: nil
        )
        XCTAssertTrue(FileViewerPaneViewController.startsWithDrawerOpen(browsing))
    }

    func testDiffPresentationCarriesAcrossChangedFileSelections() {
        let changed = FileTree.Row(
            entry: FileTreeEntry(
                name: "App.swift",
                path: "/srv/app/App.swift",
                isDirectory: false
            ),
            depth: 0,
            badge: .modified
        )
        let clean = FileTree.Row(
            entry: FileTreeEntry(
                name: "README.md",
                path: "/srv/app/README.md",
                isDirectory: false
            ),
            depth: 0
        )
        let deleted = FileTree.Row(
            entry: FileTreeEntry(
                name: "Old.swift",
                path: "/srv/app/Old.swift",
                isDirectory: false
            ),
            depth: 0,
            badge: .deleted
        )
        let diffViewer = FileViewerController(
            tabID: UUID(),
            host: makeHost(),
            startDirectory: "/srv/app",
            target: nil,
            targetPresentation: .diff
        )
        let sourceViewer = FileViewerController(
            tabID: UUID(),
            host: makeHost(),
            startDirectory: "/srv/app",
            target: nil
        )

        XCTAssertEqual(diffViewer.selectionPresentation(for: changed), .diff)
        XCTAssertEqual(diffViewer.selectionPresentation(for: clean), .source)
        XCTAssertEqual(sourceViewer.selectionPresentation(for: changed), .source)
        XCTAssertEqual(sourceViewer.selectionPresentation(for: deleted), .diff)
    }

    func testNativeCodeScreenKeepsSelectionSurfaceAndTruncationVerdict() {
        let screen = FileViewerCodeContentView()
        screen.apply(
            lines: [HighlightedLine(segments: [.init(text: "let value = 7", kind: .plain)])],
            truncated: true,
            targetLine: 1
        )

        XCTAssertTrue(screen.textView.isSelectable)
        XCTAssertFalse(screen.textView.isEditable)
        XCTAssertFalse(screen.truncatedBanner.isHidden)
        XCTAssertTrue(screen.textView.dataDetectorTypes.isEmpty)
    }

    func testRenderedMarkdownIsNativeAndParagraphsRemainSelectable() {
        let markdown = FileViewerMarkdownContentView()
        markdown.apply(blocks: [
            .heading(level: 1, inlines: [.text("Read me", [])]),
            .paragraph(inlines: [
                .text("Open ", []),
                .link(text: "setup", destination: "docs/setup.md"),
            ]),
            .code(language: .swift, info: "swift", lines: ["let value = 7"]),
            .table(
                header: [[.text("Name", [])]],
                rows: [[[.text("Multiplex", [])]]]
            ),
        ])

        XCTAssertEqual(markdown.blockStack.arrangedSubviews.count, 4)
        let textViews = markdown.descendants.compactMap { $0 as? UITextView }
        XCTAssertFalse(textViews.isEmpty)
        XCTAssertTrue(textViews.allSatisfy(\.isSelectable))
        XCTAssertTrue(markdown.subviews.contains(markdown.scrollView))
    }

    func testImageScreenFitsWithoutUpscalingAndExposesZoomReset() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        }
        let screen = FileViewerImageContentView()
        screen.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        screen.apply(image: image)
        screen.layoutIfNeeded()

        XCTAssertEqual(screen.imageView.bounds.size.width, 100, accuracy: 0.5)
        XCTAssertEqual(screen.imageView.bounds.size.height, 50, accuracy: 0.5)
        XCTAssertTrue(screen.zoomChip.isHidden)
        screen.scrollView.setZoomScale(2, animated: false)
        screen.scrollViewDidZoom(screen.scrollView)
        XCTAssertFalse(screen.zoomChip.isHidden)
        XCTAssertEqual(
            screen.zoomChip.accessibilityLabel,
            "Zoom 200 percent; resets to fit"
        )
        XCTAssertTrue(screen.zoomChip.accessibilityActivate())
    }

    /// Replacing the text of a POPULATED TextKit view makes it reconcile the
    /// new document against the old one — 1.4 s for this file on the iPad sim,
    /// against ~20 ms when the view is emptied first (measured 2026-08-06;
    /// `FileViewerTextView.setContent` clears before it fills). Every screen
    /// swap pays this: a resize, an appearance flip, and every QUIET watch
    /// tick over an edited file. The bound is two orders of magnitude above
    /// the fast path and one below the slow one, so it catches a regression
    /// without being a stopwatch.
    func testReplacingATextScreenDoesNotReconcileAgainstTheOldDocument() throws {
        let source = (0..<8000)
            .map { "    let value\($0) = compute(\"literal \($0)\") // note" }
            .joined(separator: "\n")
        let lines = CodeHighlighter.highlight(source, language: .swift)
        let view = FileViewerTextView()
        view.isEditable = false
        view.installDecor()
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 800)
        view.layoutIfNeeded()
        view.setContent(
            FileViewerTextContent.code(lines, targetLine: nil, scale: 1),
            targetLine: nil
        )
        view.layoutIfNeeded()

        let resized = FileViewerTextContent.code(lines, targetLine: nil, scale: 1.5)
        let started = CFAbsoluteTimeGetCurrent()
        view.setContent(resized, targetLine: nil, preservingOffset: true)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertLessThan(elapsed, 0.3, "screen swap regressed to a full reconcile")
        XCTAssertEqual(view.attributedText.length, resized.text.length)
        XCTAssertEqual(view.content?.bodyFont.pointSize, resized.bodyFont.pointSize)
    }

    private func makePane(close: @escaping () -> Void) -> FileViewerPaneViewController {
        let controller = FileViewerController(
            tabID: UUID(),
            host: makeHost(),
            startDirectory: "/srv/app",
            target: nil
        )
        return FileViewerPaneViewController(
            controller: controller,
            startsController: false,
            close: close
        )
    }

    private func makeHost() -> Host {
        Host(
            name: "devbox",
            hostname: "127.0.0.1",
            username: "tester"
        )
    }
}

private extension UIView {
    var descendants: [UIView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
