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

    /// A picture is a press away, and the press asks to SHOW it — never to
    /// navigate. A placeholder that named nothing stays the inert caption it
    /// always was.
    func testMarkdownImagePlaceholderPressAsksToShowTheImage() throws {
        var opened: [String] = []
        var shown: [String] = []
        let markdown = FileViewerMarkdownContentView()
        markdown.openLink = { opened.append($0) }
        markdown.showImage = { shown.append($0) }
        markdown.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        markdown.apply(blocks: [
            .paragraph(inlines: [.image(alt: "shot", destination: "docs/shot.png")]),
            .paragraph(inlines: [.image(alt: "none", destination: "")]),
        ])
        markdown.layoutIfNeeded()

        let textViews = markdown.descendants.compactMap {
            $0 as? FileViewerMarkdownTextView
        }
        XCTAssertEqual(textViews.count, 2)
        XCTAssertEqual(textViews[0].imageDestinations, ["docs/shot.png"])
        XCTAssertTrue(textViews[1].imageDestinations.isEmpty)

        let pressable = try XCTUnwrap(textViews[0].attributedText)
        var linked: URL?
        pressable.enumerateAttribute(
            .link, in: NSRange(location: 0, length: pressable.length)
        ) { value, _, _ in
            if let url = value as? URL { linked = url }
        }
        let inert = try XCTUnwrap(textViews[1].attributedText)
        inert.enumerateAttribute(
            .link, in: NSRange(location: 0, length: inert.length)
        ) { value, _, _ in
            XCTAssertNil(value, "a destination-less image is not a press target")
        }

        let url = try XCTUnwrap(linked)
        XCTAssertFalse(
            textViews[0].textView(
                textViews[0],
                shouldInteractWith: url,
                in: NSRange(location: 0, length: 1),
                interaction: .invokeDefaultAction
            ),
            "the app answers the press; UIKit must not also open it"
        )
        XCTAssertEqual(shown, ["docs/shot.png"])
        XCTAssertTrue(opened.isEmpty, "showing a picture is not a navigation")
        XCTAssertEqual(markdown.firstMountedImageDestination(), "docs/shot.png")
    }

    /// The picture lands in the block that named it — the document stack stays
    /// index-paired with `blocks` — and putting it away leaves no trace.
    func testAShownImageMountsInsideItsOwnBlockAndCollapsesBack() throws {
        let markdown = FileViewerMarkdownContentView()
        markdown.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        markdown.apply(blocks: [
            .paragraph(inlines: [
                .text("See ", []),
                .image(alt: "shot", destination: "docs/shot.png"),
            ]),
            .paragraph(inlines: [.text("After.", [])]),
        ])
        markdown.layoutIfNeeded()
        XCTAssertEqual(markdown.blockStack.arrangedSubviews.count, 2)

        let blocks = markdown.descendants.compactMap {
            $0 as? FileViewerMarkdownProseBlockView
        }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks.allSatisfy { $0.shownImageViews.isEmpty })

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100))
        let image = renderer.image { $0.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }
        markdown.setImageStates(["docs/shot.png": .loading])
        markdown.layoutIfNeeded()
        XCTAssertEqual(blocks[0].shownImageViews.count, 1)
        XCTAssertEqual(blocks[0].shownImageViews[0].state, .loading)
        XCTAssertTrue(blocks[1].shownImageViews.isEmpty)
        XCTAssertEqual(
            markdown.blockStack.arrangedSubviews.count, 2,
            "a picture is never a row of the document stack"
        )

        markdown.setImageStates(["docs/shot.png": .ready(image)])
        markdown.layoutIfNeeded()
        XCTAssertEqual(blocks[0].shownImageViews.count, 1, "the view is reused, not rebuilt")
        XCTAssertEqual(blocks[0].shownImageViews[0].state, .ready(image))
        // The caption drops its link ink once the picture is under it.
        let text = try XCTUnwrap(blocks[0].text.attributedText)
        XCTAssertTrue(text.string.contains("⌄ image: shot"))

        markdown.setImageStates([:])
        markdown.layoutIfNeeded()
        XCTAssertTrue(blocks[0].shownImageViews.isEmpty)
        XCTAssertTrue(
            try XCTUnwrap(blocks[0].text.attributedText).string.contains("⟨image: shot⟩")
        )
    }

    /// The picture fills the height it is given: no band of empty chassis
    /// above and below it, which is what a height measured once — before the
    /// column had a width — produced (caught on device 2026-08-08).
    func testAShownImageIsAsTallAsItDrawsInsideTheColumn() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1400, height: 620))
            .image { $0.fill(CGRect(x: 0, y: 0, width: 1400, height: 620)) }
        let markdown = FileViewerMarkdownContentView()
        markdown.frame = CGRect(x: 0, y: 0, width: 800, height: 900)
        markdown.apply(blocks: [
            .paragraph(inlines: [.image(alt: "shot", destination: "img/shot.png")]),
        ])
        markdown.setImageStates(["img/shot.png": .ready(image)])
        markdown.layoutIfNeeded()
        markdown.layoutIfNeeded()

        let view = try? XCTUnwrap(
            markdown.descendants.compactMap { $0 as? FileViewerMarkdownImageView }.first
        )
        guard let view else { return XCTFail("no picture mounted") }
        XCTAssertGreaterThan(view.bounds.width, 0)
        XCTAssertEqual(
            view.bounds.height,
            FileViewerMarkdownImageView.height(for: .ready(image), inWidth: view.bounds.width),
            accuracy: 1,
            "the container is exactly the drawn height at this column width"
        )
        XCTAssertEqual(
            view.bounds.height,
            view.bounds.width * 620 / 1400,
            accuracy: 1,
            "and that height is the picture's own aspect in this column"
        )
    }

    /// The reading column decides the picture's size, and the picture's own
    /// pixels cap it — an upscaled screenshot is worse than a small one.
    func testAnInlineImageFitsTheColumnWithoutUpscalingOrTakingTheScreen() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100))
        let small = renderer.image { $0.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }
        XCTAssertEqual(
            FileViewerMarkdownImageView.height(for: .ready(small), inWidth: 600),
            100,
            accuracy: 0.5
        )
        let tall = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 4000))
            .image { $0.fill(CGRect(x: 0, y: 0, width: 800, height: 4000)) }
        XCTAssertEqual(
            FileViewerMarkdownImageView.height(for: .ready(tall), inWidth: 600),
            FileViewerMarkdownImageView.maximumHeight,
            accuracy: 0.5
        )
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 300))
            .image { $0.fill(CGRect(x: 0, y: 0, width: 1200, height: 300)) }
        XCTAssertEqual(
            FileViewerMarkdownImageView.height(for: .ready(wide), inWidth: 600),
            150,
            accuracy: 0.5
        )
        // A failure or a load in flight is a panel, not a zero-height gap.
        XCTAssertGreaterThan(
            FileViewerMarkdownImageView.height(for: .loading, inWidth: 600), 0
        )
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
