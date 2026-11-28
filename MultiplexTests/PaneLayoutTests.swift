import XCTest
@testable import Multiplex

/// The pane tree a paned tab draws from, and its geometry. Pure: no view is
/// involved in deciding where a pane sits or what ratio a drag means.
final class PaneLayoutTests: XCTestCase {
    private let a = PaneID("a"), b = PaneID("b"), c = PaneID("c")

    /// `a | (b / c)`: `a` on the left, `b` above `c` on the right.
    private var nested: PaneLayout {
        .split(PaneLayout.Split(
            id: "outer", axis: .sideBySide, ratio: 0.5,
            before: .pane(a),
            after: .split(PaneLayout.Split(
                id: "inner", axis: .stacked, ratio: 0.25,
                before: .pane(b), after: .pane(c)))))
    }

    func testPanesAreListedInReadingOrder() {
        XCTAssertEqual(nested.panes, [a, b, c])
        XCTAssertEqual(nested.firstPane, a)
        XCTAssertTrue(nested.contains(c))
        XCTAssertFalse(nested.contains(PaneID("d")))
        XCTAssertEqual(PaneLayout.pane(a).panes, [a])
    }

    func testASplitIsFoundByItsIDAtAnyDepth() {
        XCTAssertEqual(nested.split(withID: "inner")?.axis, .stacked)
        XCTAssertEqual(nested.split(withID: "outer")?.ratio, 0.5)
        XCTAssertNil(nested.split(withID: "gone"))
        XCTAssertNil(PaneLayout.pane(a).split(withID: "outer"))
    }

    func testARatioIsSetOnOneSplitAndKeptOffTheEnds() {
        let moved = nested.settingRatio(0.7, ofSplit: "inner")
        XCTAssertEqual(moved.split(withID: "inner")?.ratio, 0.7)
        XCTAssertEqual(moved.split(withID: "outer")?.ratio, 0.5)
        // A pane of no width could not be dragged back open.
        XCTAssertEqual(nested.settingRatio(0, ofSplit: "outer").split(withID: "outer")?.ratio, 0.05)
        XCTAssertEqual(nested.settingRatio(3, ofSplit: "outer").split(withID: "outer")?.ratio, 0.95)
        // No such split: nothing changes.
        XCTAssertEqual(nested.settingRatio(0.9, ofSplit: "gone"), nested)
    }

    func testAClosingPanesFocusGoesToItsNearestNeighbour() {
        // The sibling takes a closed pane's room, and its focus.
        XCTAssertEqual(nested.neighbor(ofClosing: b), c)
        XCTAssertEqual(nested.neighbor(ofClosing: c), b)
        // `a`'s sibling is a split: the pane of it that reads first.
        XCTAssertEqual(nested.neighbor(ofClosing: a), b)
        XCTAssertNil(PaneLayout.pane(a).neighbor(ofClosing: a))
        XCTAssertNil(nested.neighbor(ofClosing: PaneID("d")))
        // A split's LAST pane is the one beside what follows it.
        let row = PaneLayout.split(PaneLayout.Split(
            id: "row", axis: .sideBySide, ratio: 0.5,
            before: nested.split(withID: "inner").map(PaneLayout.split) ?? .pane(b),
            after: .pane(a)))
        XCTAssertEqual(row.neighbor(ofClosing: a), c)
    }

    // MARK: - Geometry

    func testASinglePaneFillsTheBoundsWithNoLine() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let frames = PaneLayout.pane(a).frames(in: bounds, dividerThickness: 9, displayScale: 2)
        XCTAssertEqual(frames.panes, [a: bounds])
        XCTAssertTrue(frames.dividers.isEmpty)
    }

    func testSplitsDivideWhatIsLeftAfterTheLineBetweenThem() {
        let frames = nested.frames(
            in: CGRect(x: 0, y: 0, width: 409, height: 209),
            dividerThickness: 9, displayScale: 2)
        // 400 usable points across: 200 each side of a 9-point line.
        XCTAssertEqual(frames.panes[a], CGRect(x: 0, y: 0, width: 200, height: 209))
        // 200 usable points down the right side: a quarter above the line.
        XCTAssertEqual(frames.panes[b], CGRect(x: 209, y: 0, width: 200, height: 50))
        XCTAssertEqual(frames.panes[c], CGRect(x: 209, y: 59, width: 200, height: 150))
        XCTAssertEqual(frames.dividers.map(\.splitID), ["outer", "inner"])
        let outer = frames.dividers[0], inner = frames.dividers[1]
        XCTAssertEqual(outer.frame, CGRect(x: 200, y: 0, width: 9, height: 209))
        XCTAssertEqual(outer.extent, CGRect(x: 0, y: 0, width: 409, height: 209))
        // The inner line spans only its own split.
        XCTAssertEqual(inner.frame, CGRect(x: 209, y: 50, width: 200, height: 9))
        XCTAssertEqual(inner.extent, CGRect(x: 209, y: 0, width: 200, height: 209))
    }

    func testEdgesLandOnPhysicalPixels() {
        let layout = PaneLayout.split(PaneLayout.Split(
            id: "s", axis: .sideBySide, ratio: 1.0 / 3, before: .pane(a), after: .pane(b)))
        let frames = layout.frames(
            in: CGRect(x: 0, y: 0, width: 300, height: 100),
            dividerThickness: 9, displayScale: 2)
        // 291 / 3 = 97: already whole. At a third of 292 it would be 97.33,
        // which lands on the half point a 2x display has.
        XCTAssertEqual(frames.panes[a]?.width, 97)
        let odd = layout.frames(
            in: CGRect(x: 0, y: 0, width: 301, height: 100),
            dividerThickness: 9, displayScale: 2)
        XCTAssertEqual(odd.panes[a]?.width, 97.5)
        // Nothing is lost or doubled: the three widths are the bounds'.
        XCTAssertEqual((odd.panes[a]?.width ?? 0) + 9 + (odd.panes[b]?.width ?? 0), 301)
    }

    func testADragBecomesTheRatioThatPutsTheLineUnderIt() {
        let extent = CGRect(x: 100, y: 0, width: 409, height: 200)
        // The line's centre at the extent's middle: an even split.
        XCTAssertEqual(
            PaneLayout.ratio(
                forDividerAt: 304.5, in: extent, axis: .sideBySide, dividerThickness: 9),
            0.5, accuracy: 0.0001)
        XCTAssertEqual(
            PaneLayout.ratio(
                forDividerAt: 204.5, in: extent, axis: .sideBySide, dividerThickness: 9),
            0.25, accuracy: 0.0001)
        // Laying the result out puts the line back where the drag was.
        let layout = PaneLayout.split(PaneLayout.Split(
            id: "s", axis: .sideBySide, ratio: 0.25, before: .pane(a), after: .pane(b)))
        let line = layout.frames(in: extent, dividerThickness: 9, displayScale: 2).dividers[0]
        XCTAssertEqual(line.frame.midX, 204.5)
        // The other axis reads the other coordinate.
        XCTAssertEqual(
            PaneLayout.ratio(
                forDividerAt: 100, in: CGRect(x: 0, y: 0, width: 50, height: 409),
                axis: .stacked, dividerThickness: 9),
            (100 - 4.5) / 400, accuracy: 0.0001)
    }

    func testADragCannotCrushEitherPane() {
        let extent = CGRect(x: 0, y: 0, width: 409, height: 200)
        // Past either end the pane keeps its minimum length.
        XCTAssertEqual(
            PaneLayout.ratio(
                forDividerAt: -500, in: extent, axis: .sideBySide, dividerThickness: 9),
            Double(PaneLayout.minimumPaneLength / 400), accuracy: 0.0001)
        XCTAssertEqual(
            PaneLayout.ratio(
                forDividerAt: 5000, in: extent, axis: .sideBySide, dividerThickness: 9),
            Double(1 - PaneLayout.minimumPaneLength / 400), accuracy: 0.0001)
        // A split too small to give both that still keeps a ratio off the
        // ends, and one with no room at all is left even.
        XCTAssertEqual(
            PaneLayout.ratio(
                forDividerAt: 0, in: CGRect(x: 0, y: 0, width: 100, height: 50),
                axis: .sideBySide, dividerThickness: 9),
            0.05)
        XCTAssertEqual(
            PaneLayout.ratio(
                forDividerAt: 3, in: CGRect(x: 0, y: 0, width: 9, height: 50),
                axis: .sideBySide, dividerThickness: 9),
            0.5)
    }

    // MARK: - Shortcut rows

    func testThePanelRowsBecomeCommandsOnThePaneWithTheKeyboard() {
        XCTAssertEqual(PaneShortcut.splitRight.command(on: a), .split(a, .sideBySide))
        XCTAssertEqual(PaneShortcut.splitDown.command(on: a), .split(a, .stacked))
        XCTAssertEqual(PaneShortcut.closePane.command(on: b), .close(b))
        XCTAssertEqual(PaneShortcut.newWindow.command(on: b), .newWindow(from: b))
        // The zoom is the tab's own drawing: no backend is asked.
        XCTAssertNil(PaneShortcut.zoomPane.command(on: a))
        // Only the close ends a program, so only it asks twice.
        XCTAssertEqual(
            PaneShortcut.allCases.filter(\.requiresDoubleActivation), [.closePane])
        XCTAssertEqual(PaneShortcut.closePane.bindingLabel, "2×")
        XCTAssertEqual(PaneShortcut.splitRight.bindingLabel, "")
    }
}
