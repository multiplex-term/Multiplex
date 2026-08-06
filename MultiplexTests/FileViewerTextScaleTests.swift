import XCTest
@testable import Multiplex

/// The reader's file-viewer text size: the pure ladder and the device-local
/// store that remembers a rung. Each store test gets its own defaults suite,
/// so nothing touches the app's real state.
@MainActor
final class FileViewerTextScaleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "FileViewerTextScaleTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Ladder

    func testTheDefaultIsARungAndTheLadderIsAscending() {
        XCTAssertTrue(FileViewerTextScale.steps.contains(FileViewerTextScale.default))
        XCTAssertEqual(
            FileViewerTextScale.steps,
            FileViewerTextScale.steps.sorted(),
            "the ladder is walked by index in both directions"
        )
    }

    func testClampingHoldsTheRangeAndSurvivesNonsense() {
        XCTAssertEqual(FileViewerTextScale.clamped(0.1), FileViewerTextScale.minimum)
        XCTAssertEqual(FileViewerTextScale.clamped(99), FileViewerTextScale.maximum)
        XCTAssertEqual(
            FileViewerTextScale.clamped(.nan),
            FileViewerTextScale.default,
            "a NaN pinch magnitude must not reach a font size"
        )
    }

    func testAPinchMagnitudeSnapsToTheNearestRung() {
        // A live pinch is continuous; a rebuild of the whole attributed
        // screen is not, so every magnitude has to land on a rung.
        XCTAssertEqual(FileViewerTextScale.snapped(1.02), 1)
        XCTAssertEqual(FileViewerTextScale.snapped(1.2), 1.15)
        XCTAssertEqual(FileViewerTextScale.snapped(4), FileViewerTextScale.maximum)
    }

    func testSteppingMovesOneRungAndStopsAtTheEnds() {
        XCTAssertEqual(FileViewerTextScale.stepping(1, by: 1), 1.15)
        XCTAssertEqual(FileViewerTextScale.stepping(1, by: -1), 0.85)
        XCTAssertEqual(FileViewerTextScale.stepping(FileViewerTextScale.maximum, by: 1),
                       FileViewerTextScale.maximum)
        XCTAssertEqual(FileViewerTextScale.stepping(FileViewerTextScale.minimum, by: -1),
                       FileViewerTextScale.minimum)
        XCTAssertFalse(FileViewerTextScale.canStep(FileViewerTextScale.maximum, by: 1))
        XCTAssertTrue(FileViewerTextScale.canStep(FileViewerTextScale.maximum, by: -1))
    }

    func testSteppingFromBetweenRungsNeverStalls() {
        // Nothing writes an off-ladder value today, but a future rung change
        // can leave a persisted one — a button press must still move.
        XCTAssertEqual(FileViewerTextScale.stepping(1.05, by: 1), 1.15)
        XCTAssertEqual(FileViewerTextScale.stepping(1.05, by: -1), 1)
    }

    func testPercentLabel() {
        XCTAssertEqual(FileViewerTextScale.percentLabel(1), "100%")
        XCTAssertEqual(FileViewerTextScale.percentLabel(1.3), "130%")
    }

    // MARK: Store

    func testTheChosenSizeSurvivesRelaunch() {
        let store = FileViewerTextScaleStore(defaults: defaults)
        XCTAssertEqual(store.scale, FileViewerTextScale.default)

        store.step(by: 1)
        XCTAssertEqual(store.scale, 1.15)
        XCTAssertEqual(
            FileViewerTextScaleStore(defaults: defaults).scale,
            1.15,
            "the reading size is device-local state, not per-tab"
        )
    }

    // MARK: The rail

    func testTheRailCarriesTheSizeControlsAndOnlyReadsOutOffTheDefault() {
        var stepped: [Int] = []
        var resets = 0
        var configuration = ViewportUMDConfiguration(
            title: "▤ README.md · devbox",
            mergeSources: [],
            showDeck: {},
            merge: { _ in },
            close: {},
            style: .regular,
            deckControlLabel: "DECK",
            contentSafeArea: .zero,
            closeAccessibilityLabel: "Close file viewer",
            textScale: ViewportUMDConfiguration.TextScale(
                scale: FileViewerTextScale.default,
                canDecrease: true,
                canIncrease: true,
                step: { stepped.append($0) },
                reset: { resets += 1 }
            )
        )
        let controller = ViewportUMDViewController(configuration: configuration)
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.textScaleDownChip?.accessibilityLabel, "Smaller text")
        XCTAssertEqual(controller.textScaleUpChip?.accessibilityLabel, "Larger text")
        XCTAssertNil(
            controller.textScaleResetChip,
            "at 100% the percentage would report nothing"
        )
        XCTAssertTrue(controller.textScaleUpChip?.accessibilityActivate() == true)
        XCTAssertEqual(stepped, [1])

        configuration.textScale?.scale = 2
        configuration.textScale?.canIncrease = false
        controller.update(configuration: configuration)
        XCTAssertEqual(
            controller.textScaleResetChip?.accessibilityLabel,
            "Text size 200%; resets to 100 percent"
        )
        XCTAssertEqual(controller.textScaleUpChip?.isUserInteractionEnabled, false)
        XCTAssertTrue(controller.textScaleResetChip?.accessibilityActivate() == true)
        XCTAssertEqual(resets, 1)

        // Same slot on the shell's slim row, and gone entirely from a ⌗ tab.
        configuration.style = .shell
        controller.update(configuration: configuration)
        XCTAssertNotNil(controller.textScaleUpChip)
        configuration.textScale = nil
        controller.update(configuration: configuration)
        XCTAssertNil(controller.textScaleUpChip)
        XCTAssertNil(controller.textScaleDownChip)
        XCTAssertNil(controller.textScaleResetChip)
    }

    // MARK: Screens

    func testTheCodeScreenRebuildsAtTheChosenSize() async throws {
        let screen = FileViewerCodeContentView()
        screen.apply(lines: CodeHighlighter.highlight("let x = 1\n", language: nil))
        let authored = try await settledBodyFontSize(screen.textView)

        screen.setTextScale(1.5)
        let enlarged = try await settledBodyFontSize(screen.textView, differingFrom: authored)
        XCTAssertEqual(enlarged, authored * 1.5, accuracy: 0.01)

        // The gutter travels with the text, or the line numbers collide with
        // the code they number.
        let content = try XCTUnwrap(screen.textView.content)
        XCTAssertEqual(content.gutterWidth, 56 * 1.5 * Theme.typeScale, accuracy: 0.01)
    }

    func testTheDiffScreenRebuildsAtTheChosenSize() async throws {
        let diff = GitDiff.parse("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        -let x = 0
        +let x = 1
        """)
        let screen = FileViewerDiffContentView()
        screen.apply(diff: diff, scope: .file(path: "a.swift"))
        let authored = try await settledBodyFontSize(screen.textView)

        screen.setTextScale(0.75)
        let reduced = try await settledBodyFontSize(screen.textView, differingFrom: authored)
        XCTAssertEqual(reduced, authored * 0.75, accuracy: 0.01)
    }

    func testTheRenderedMarkdownScreenRemountsAtTheChosenSize() {
        let screen = FileViewerMarkdownContentView()
        screen.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        screen.apply(blocks: [.paragraph(inlines: [.text("hello", [])])])
        screen.layoutIfNeeded()
        let authored = try? XCTUnwrap(markdownHeight(screen))

        // Fence heights and table geometry are precomputed from their fonts,
        // so the whole stack has to come back — `apply` alone short-circuits.
        screen.setTextScale(2)
        screen.layoutIfNeeded()
        let enlarged = markdownHeight(screen)
        XCTAssertNotNil(authored)
        XCTAssertGreaterThan(enlarged ?? 0, (authored ?? 0) + 1)
    }

    /// A resize used to tear the mounted stack down and refill it. Two things
    /// went wrong, both measured on the iPad sim 2026-08-06: the scroll view
    /// kept its old height through the teardown, so the refill decided the
    /// viewport was already full and the screen went BLANK until the reader
    /// scrolled; and refilling costs the whole scroll depth (2.7 s for 160
    /// mounted blocks) because every block above the reader has to be rebuilt
    /// before theirs can have a position. Now the mounted blocks are restyled
    /// where they stand, near the viewport first.
    func testResizingALongMarkdownScreenKeepsItMountedAndStaysCheap() {
        let unit = """
        ## A section heading

        A paragraph of prose with `inline code`, a [link](https://example.com) and
        **bold** runs, long enough to wrap over two or three lines in a wide pane.

        - a list item with `code`
        - another list item that also runs long enough to wrap once in the pane

        """
        let blocks = MarkdownDocument.parse(String(repeating: unit, count: 60))
        let screen = FileViewerMarkdownContentView()
        screen.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
        screen.apply(blocks: blocks)
        screen.layoutIfNeeded()
        for step in stride(from: 0, through: 6000, by: 600) {
            screen.scrollView.contentOffset = CGPoint(x: 0, y: CGFloat(step))
            screen.layoutIfNeeded()
        }
        let mountedWhileReading = screen.blockStack.arrangedSubviews.count
        XCTAssertGreaterThan(mountedWhileReading, 100, "the reader scrolled deep")
        let readingAt = screen.scrollView.contentOffset.y

        let started = CFAbsoluteTimeGetCurrent()
        screen.setTextScale(1.3)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertGreaterThanOrEqual(
            screen.blockStack.arrangedSubviews.count,
            mountedWhileReading,
            "the screen must never empty itself to resize"
        )
        XCTAssertLessThan(elapsed, 1.0, "resize regressed to rebuilding the scroll depth")
        // The reader keeps their place: the anchor block is held, so the
        // offset moves with the reflow instead of staying a stale pixel count.
        XCTAssertGreaterThan(screen.scrollView.contentOffset.y, readingAt * 0.5)
    }

    private func markdownHeight(_ screen: FileViewerMarkdownContentView) -> CGFloat? {
        screen.blockStack.arrangedSubviews.first.map {
            $0.systemLayoutSizeFitting(
                CGSize(width: 360, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }
    }

    /// The screens assemble their attributed text off-main, so a size is only
    /// readable once the build lands.
    private func settledBodyFontSize(
        _ textView: FileViewerTextView,
        differingFrom previous: CGFloat? = nil
    ) async throws -> CGFloat {
        for _ in 0..<200 {
            if let size = textView.content?.bodyFont.pointSize, size != previous {
                return size
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw XCTSkip("the screen never finished building")
    }

    func testTheStoreOnlyEverHoldsARung() {
        let store = FileViewerTextScaleStore(defaults: defaults)
        store.set(1.19)
        XCTAssertEqual(store.scale, 1.15, "a live pinch magnitude snaps before it is kept")

        defaults.set(1.07, forKey: "MultiplexFileViewerTextScale")
        XCTAssertEqual(
            FileViewerTextScaleStore(defaults: defaults).scale,
            1,
            "an off-ladder stored value snaps on load"
        )
    }
}
