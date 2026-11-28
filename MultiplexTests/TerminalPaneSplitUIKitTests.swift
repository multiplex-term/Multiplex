import SwiftTerm
import UIKit
import XCTest
@testable import Multiplex

/// A paned tab from the transport's events up: the real controller, the
/// real surface and split view, over a transport that only records. What a
/// backend says about its panes has to become emulators on screen, and what
/// a person does to them has to reach the right pane, in order.
@MainActor
final class TerminalPaneSplitUIKitTests: XCTestCase {
    private let left = PaneID("block:left")
    private let right = PaneID("block:right")
    private let below = PaneID("block:below")

    private var sideBySide: PaneLayout {
        .split(PaneLayout.Split(
            id: "split:1", axis: .sideBySide, ratio: 0.5,
            before: .pane(left), after: .pane(right)))
    }

    /// A paned transport that records what it is asked.
    private actor Transport: PanedTerminalTransport {
        private(set) var written: [String] = []
        private(set) var resized: [PaneID: TerminalGrid] = [:]
        private(set) var commands: [PaneCommand] = []
        private(set) var isClosed = false
        var failure: Error?

        func fail(with error: Error?) { failure = error }

        func write(_ data: Data, to pane: PaneID) async throws {
            written.append("\(pane.rawValue):\(String(decoding: data, as: UTF8.self))")
        }

        func resize(pane: PaneID, cols: Int, rows: Int) async throws {
            resized[pane] = TerminalGrid(cols: cols, rows: rows)
        }

        func perform(_ command: PaneCommand) async throws {
            commands.append(command)
            if let failure { throw failure }
        }

        func close() async { isClosed = true }
    }

    /// One live paned tab in a window: the pieces a test pokes at.
    private struct Tab {
        var controller: TerminalSessionController
        var pane: TerminalPaneViewController
        var transport: Transport
        var events: PaneEvents
        var window: UIWindow
        /// The grids the tab answered the first arrangement with.
        var measured: [PaneID: TerminalGrid]

        @MainActor var split: PaneSplitView {
            get throws { try XCTUnwrap(pane.terminalSurface?.paneSplitView) }
        }
    }

    private func eventually(
        _ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held", file: file, line: line)
    }

    private func makeTab(_ arrangement: PaneArrangement) async throws -> Tab {
        TerminalFocusArbiter.inputSuppressed = false
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "tester")
        let controller = TerminalSessionController(
            route: TerminalRoute(
                hostID: host.id,
                mode: .rexAttach(sessionName: "work", sessionID: "session:0000-aaaa")),
            host: host)
        let (pane, window) = mount(controller)

        let transport = Transport()
        var handed: PaneEvents?
        var measured: [PaneID: TerminalGrid] = [:]
        await controller.runPanesForTesting(over: transport) { events in
            handed = events
            measured = await events.arrange(arrangement)
        }
        return Tab(
            controller: controller, pane: pane, transport: transport,
            events: try XCTUnwrap(handed), window: window, measured: measured)
    }

    private func configuration(_ controller: TerminalSessionController) -> TerminalPaneConfiguration {
        TerminalPaneConfiguration(
            controller: controller, hostExists: true, fontSize: 14, theme: .tally,
            bottomChromeHeight: 0, contentSafeArea: .zero, keyRailSafeArea: .zero,
            railOwnsBottomSafeArea: false, isActive: true, focusAllowed: true,
            close: {})
    }

    /// The tab's pane in a window of its own, laid out.
    private func mount(
        _ controller: TerminalSessionController
    ) -> (TerminalPaneViewController, UIWindow) {
        let pane = TerminalPaneViewController(configuration: configuration(controller))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        window.rootViewController = pane
        window.isHidden = false
        pane.view.layoutIfNeeded()
        return (pane, window)
    }

    // MARK: - Arrangement

    func testAPanedTabStartsWithNoEmulatorAndGetsOnePerPaneFromItsTransport() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: right))
        let split = try tab.split

        XCTAssertTrue(tab.controller.drawsPanes)
        XCTAssertNil(tab.controller.soleScreen)
        XCTAssertEqual(tab.controller.status, .live)
        XCTAssertEqual(tab.controller.screens.map(\.paneID), [left, right])
        XCTAssertEqual(split.cells.map(\.screen.paneID), [left, right])

        // Side by side, the gap's width apart, and laid out BEFORE the
        // transport got its answer: each pane's grid is the one its own
        // emulator measured, which is what its terminal is opened at.
        let first = split.cells[0].frame, second = split.cells[1].frame
        XCTAssertEqual(first.minX, 0)
        XCTAssertEqual(second.minX - first.maxX, PaneSplitView.gap)
        XCTAssertEqual(second.maxX, split.bounds.maxX)
        XCTAssertEqual(first.width, second.width, accuracy: 1)
        let leftGrid = try XCTUnwrap(tab.measured[left])
        let rightGrid = try XCTUnwrap(tab.measured[right])
        XCTAssertGreaterThan(leftGrid.cols, 20)
        XCTAssertEqual(leftGrid.cols, rightGrid.cols, accuracy: 1)
        XCTAssertEqual(leftGrid.cols, split.cells[0].terminalView.terminalDimensions.cols)
        XCTAssertEqual(leftGrid.rows, split.cells[0].terminalView.terminalDimensions.rows)

        // The keyboard is where the transport said, and "the terminal" of
        // the tab is that pane's emulator.
        XCTAssertEqual(tab.controller.activePaneID, right)
        XCTAssertTrue(tab.controller.terminalView === split.cells[1].terminalView)
        XCTAssertEqual(tab.controller.rexBlockID, "block:right")
        // A line between the two, and a frame around the focused one.
        XCTAssertEqual(views(ofType: PaneDividerView.self, in: split).count, 1)
        tab.window.isHidden = true
    }

    func testASinglePaneDrawsNoLineAndFillsTheSurface() async throws {
        let tab = try await makeTab(PaneArrangement(layout: .pane(left), focus: left))
        let split = try tab.split
        XCTAssertEqual(split.cells.count, 1)
        XCTAssertEqual(split.cells[0].frame, split.bounds)
        XCTAssertTrue(views(ofType: PaneDividerView.self, in: split).isEmpty)
        tab.window.isHidden = true
    }

    func testOutputAndInputEachReachTheirOwnPane() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: left))
        let split = try tab.split

        tab.events.output(right, Data("for the right pane".utf8))
        await eventually {
            split.cells[1].screen.snapshot().lines.first?.contains("for the right pane") == true
        }
        XCTAssertFalse(
            split.cells[0].screen.snapshot().lines.contains { $0.contains("for the right pane") })

        // What an emulator sends is its own pane's; what the chrome sends
        // goes to the pane the keyboard is on.
        split.cells[1].terminalView.send(txt: "r")
        tab.controller.sendInput(Data("k".utf8))
        await eventually {
            await Set(tab.transport.written) == ["block:right:r", "block:left:k"]
        }
        tab.window.isHidden = true
    }

    // MARK: - Focus

    func testFocusMovesTheTabsTerminalAndTellsTheTransport() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: left))
        let split = try tab.split
        XCTAssertTrue(tab.controller.terminalView === split.cells[0].terminalView)

        tab.controller.focusPane(right)
        XCTAssertEqual(tab.controller.activePaneID, right)
        XCTAssertTrue(tab.controller.terminalView === split.cells[1].terminalView)
        XCTAssertEqual(tab.controller.rexBlockID, "block:right")
        await eventually { await tab.transport.commands.last == .focus(self.right) }
        // The chrome's input follows.
        tab.controller.sendInput(Data("k".utf8))
        await eventually { await tab.transport.written == ["block:right:k"] }

        // The transport moving the focus (a terminal chosen from the panel)
        // does the same; saying nothing leaves it where the person put it.
        _ = await tab.events.arrange(PaneArrangement(layout: sideBySide, focus: left))
        XCTAssertEqual(tab.controller.activePaneID, left)
        _ = await tab.events.arrange(PaneArrangement(layout: sideBySide, focus: nil))
        XCTAssertEqual(tab.controller.activePaneID, left)
        tab.window.isHidden = true
    }

    // MARK: - Changing the layout

    func testADraggedLineMovesThePanesAtOnceAndAsksTheTransportInOrder() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: left))
        let split = try tab.split
        let before = split.cells[0].frame.width

        tab.controller.setPaneRatio(0.4, ofSplit: "split:1")
        tab.controller.setPaneRatio(0.3, ofSplit: "split:1")
        tab.controller.setPaneRatio(0.25, ofSplit: "split:1")
        // The layout followed synchronously — the drag has to stay under
        // the finger — and each emulator measured its new grid.
        XCTAssertEqual(tab.controller.paneLayout?.split(withID: "split:1")?.ratio, 0.25)
        XCTAssertEqual(split.cells[0].frame.width, before / 2, accuracy: 1)
        XCTAssertLessThan(
            split.cells[0].terminalView.terminalDimensions.cols,
            split.cells[1].terminalView.terminalDimensions.cols)
        // The transport hears every step in the order it was made.
        await eventually {
            await tab.transport.commands.filter { $0 != .focus(self.left) } == [
                .setRatio(0.4, splitID: "split:1"),
                .setRatio(0.3, splitID: "split:1"),
                .setRatio(0.25, splitID: "split:1"),
            ]
        }
        // And each pane's new size, as its own.
        await eventually {
            let resized = await tab.transport.resized
            return resized[self.left].map { $0.cols } ?? 0 < resized[self.right].map { $0.cols } ?? 0
        }

        // VoiceOver's adjust moves the same line a twentieth at a time.
        let divider = try XCTUnwrap(views(ofType: PaneDividerView.self, in: split).first)
        divider.accessibilityIncrement()
        XCTAssertEqual(
            tab.controller.paneLayout?.split(withID: "split:1")?.ratio ?? 0, 0.3, accuracy: 0.0001)
        tab.window.isHidden = true
    }

    func testThePanelsRowsActOnThePaneWithTheKeyboard() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: right))
        let panel = try XCTUnwrap(ShortcutPanelContent.content(for: .rex))
        for item in panel.sections.flatMap(\.items) {
            tab.controller.performPanelShortcut(item)
        }
        await eventually {
            await tab.transport.commands.filter { $0 != .focus(self.right) } == [
                .split(self.right, .sideBySide),
                .split(self.right, .stacked),
                .close(self.right),
                .newWindow(from: self.right),
            ]
        }
        // The zoom row asked the transport nothing: it is the tab's own.
        XCTAssertEqual(tab.controller.zoomedPaneID, right)
        tab.window.isHidden = true
    }

    // MARK: - Zoom

    func testAZoomedPaneIsDrawnAloneAndTheOthersKeepTheirPlaceAndSize() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: right))
        let split = try tab.split
        let leftFrame = split.cells[0].frame
        let leftGrid = split.cells[0].terminalView.terminalDimensions
        let rightColumns = split.cells[1].terminalView.terminalDimensions.cols

        tab.controller.performPaneShortcut(.zoomPane)
        XCTAssertEqual(tab.controller.zoomedPaneID, right)
        // The pane the keyboard is on has the whole view: no line, no
        // frame, and its emulator measured the larger grid.
        XCTAssertEqual(split.cells[1].frame, split.bounds)
        XCTAssertFalse(split.cells[1].isHidden)
        XCTAssertTrue(views(ofType: PaneDividerView.self, in: split).isEmpty)
        XCTAssertGreaterThan(split.cells[1].terminalView.terminalDimensions.cols, rightColumns)
        // The other is hidden, not gone — still where the split has it and
        // at the size it will be shown at again, so nothing is resized or
        // redrawn for it on the way in or out.
        XCTAssertTrue(split.cells[0].isHidden)
        XCTAssertEqual(split.cells[0].frame, leftFrame)
        XCTAssertEqual(split.cells[0].terminalView.terminalDimensions.cols, leftGrid.cols)
        // What is under a point is what is on screen there.
        XCTAssertEqual(split.pane(at: CGPoint(x: 20, y: 40)), right)
        // It still gets its output while hidden.
        tab.events.output(left, Data("behind the zoom".utf8))
        await eventually {
            split.cells[0].screen.snapshot().lines.contains { $0.contains("behind the zoom") }
        }
        // The tab says it is zoomed and carries the way back.
        await eventually {
            self.views(ofType: TerminalContextBarView.self, in: tab.pane.view)
                .contains { $0.accessibilityIdentifier == "terminalPane.context.zoomed" }
        }
        let asked = await tab.transport.commands
        XCTAssertFalse(asked.contains { $0 != .focus(self.right) })

        // ALL PANES on that bar is the way back.
        let showAll = try XCTUnwrap(
            views(ofType: UIKitChassisChip.self, in: tab.pane.view)
                .first { $0.accessibilityLabel == "Show all panes" })
        XCTAssertTrue(showAll.accessibilityActivate())
        XCTAssertNil(tab.controller.zoomedPaneID)
        XCTAssertFalse(split.cells[0].isHidden)
        XCTAssertEqual(split.cells[0].frame, leftFrame)
        XCTAssertEqual(split.cells[1].terminalView.terminalDimensions.cols, rightColumns)
        XCTAssertEqual(views(ofType: PaneDividerView.self, in: split).count, 1)
        tab.window.isHidden = true
    }

    func testAZoomEndsWhenTheKeyboardLeavesItsPaneOrThePaneGoes() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: right))
        let split = try tab.split

        // The keyboard going to another pane ends it: that pane has to be
        // on screen.
        tab.controller.togglePaneZoom()
        tab.controller.focusPane(left)
        XCTAssertNil(tab.controller.zoomedPaneID)
        XCTAssertFalse(split.cells[1].isHidden)

        // So does a pane the transport brings the focus to — a split made
        // while zoomed.
        tab.controller.togglePaneZoom()
        XCTAssertEqual(tab.controller.zoomedPaneID, left)
        let grown = PaneLayout.split(PaneLayout.Split(
            id: "split:1", axis: .sideBySide, ratio: 0.5,
            before: .split(PaneLayout.Split(
                id: "split:2", axis: .stacked, ratio: 0.5,
                before: .pane(left), after: .pane(below))),
            after: .pane(right)))
        _ = await tab.events.arrange(PaneArrangement(layout: grown, focus: below))
        XCTAssertNil(tab.controller.zoomedPaneID)
        XCTAssertTrue(split.cells.allSatisfy { !$0.isHidden })

        // A layout change that leaves the focus alone leaves the zoom too…
        tab.controller.togglePaneZoom()
        _ = await tab.events.arrange(PaneArrangement(layout: sideBySide, focus: nil))
        XCTAssertNil(tab.controller.zoomedPaneID, "the zoomed pane itself closed")
        tab.controller.focusPane(right)
        tab.controller.togglePaneZoom()
        _ = await tab.events.arrange(PaneArrangement(
            layout: sideBySide.settingRatio(0.3, ofSplit: "split:1"), focus: nil))
        XCTAssertEqual(tab.controller.zoomedPaneID, right)
        // …and one pane alone has nothing to cover.
        _ = await tab.events.arrange(PaneArrangement(layout: .pane(right), focus: nil))
        XCTAssertNil(tab.controller.zoomedPaneID)
        tab.controller.togglePaneZoom()
        XCTAssertNil(tab.controller.zoomedPaneID)
        tab.window.isHidden = true
    }

    func testARefusedSplitIsSaidOnThePane() async throws {
        let tab = try await makeTab(PaneArrangement(layout: .pane(left), focus: left))
        await tab.transport.fail(with: RexSession.Failure("The Rex server refused: too many blocks"))
        tab.controller.performPaneShortcut(.splitRight)
        await eventually {
            tab.controller.historyNotice
                == "Couldn't split the pane. The Rex server refused: too many blocks"
        }
        tab.window.isHidden = true
    }

    func testPanesComeAndGoWithTheArrangementAndKeepTheirEmulators() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: right))
        let split = try tab.split
        let leftView = split.cells[0].terminalView

        // A pane is split below the right one: it arrives with the focus.
        let grown = PaneLayout.split(PaneLayout.Split(
            id: "split:1", axis: .sideBySide, ratio: 0.5,
            before: .pane(left),
            after: .split(PaneLayout.Split(
                id: "split:2", axis: .stacked, ratio: 0.5,
                before: .pane(right), after: .pane(below)))))
        let sizes = await tab.events.arrange(PaneArrangement(layout: grown, focus: below))
        XCTAssertEqual(split.cells.map(\.screen.paneID), [left, right, below])
        // The pane that stayed kept its emulator — buffer, scrollback, all.
        XCTAssertTrue(split.cells[0].terminalView === leftView)
        XCTAssertEqual(tab.controller.activePaneID, below)
        // The new pane was measured before the transport was answered: it
        // is half the height of the pane beside the split.
        let tall = try XCTUnwrap(sizes[left]), short = try XCTUnwrap(sizes[below])
        XCTAssertLessThan(short.rows, tall.rows)
        XCTAssertEqual(views(ofType: PaneDividerView.self, in: split).count, 2)

        // The focused pane closes: its neighbour is named, and the tab
        // follows; the pane and its emulator are gone.
        _ = await tab.events.arrange(PaneArrangement(layout: sideBySide, focus: right))
        XCTAssertEqual(split.cells.map(\.screen.paneID), [left, right])
        XCTAssertEqual(tab.controller.screens.map(\.paneID), [left, right])
        XCTAssertEqual(tab.controller.activePaneID, right)
        XCTAssertEqual(views(ofType: PaneDividerView.self, in: split).count, 1)

        // A pane that leaves without the transport naming a focus still
        // cannot leave the keyboard on nothing.
        _ = await tab.events.arrange(PaneArrangement(layout: .pane(left), focus: nil))
        XCTAssertEqual(tab.controller.activePaneID, left)
        XCTAssertTrue(tab.controller.terminalView === leftView)
        // Output for a pane that is gone goes nowhere, harmlessly.
        tab.events.output(right, Data("late".utf8))
        tab.window.isHidden = true
    }

    // MARK: - The keyboard, when its pane goes

    func testCellsThatLeaveAreStillInTheWindowWhileTheNewOnesAreAlreadyIn() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: right))
        let split = try tab.split
        let staying = split.cells[0], going = split.cells[1]
        let arriving = TerminalScreen(paneID: below)

        var handedOver = false
        split.apply(
            layout: PaneLayout.split(PaneLayout.Split(
                id: "split:1", axis: .sideBySide, ratio: 0.5,
                before: .pane(left), after: .pane(below))),
            screens: [staying.screen, arriving], activePane: below, zoomedPane: nil,
            theme: .tally
        ) {
            handedOver = true
            // The one moment a first responder can pass from the pane that
            // is going to the pane that came, with no turn in which neither
            // is in the window — which is when the keyboard would leave.
            XCTAssertNotNil(going.window)
            XCTAssertNotNil(split.cell(for: self.below)?.terminalView.window)
        }
        XCTAssertTrue(handedOver)
        XCTAssertNil(going.superview)
        XCTAssertEqual(split.cells.map(\.screen.paneID), [left, below])
        tab.window.isHidden = true
    }

    func testTheKeyboardGoesWithTheFocusBeforeTheTransportIsAnswered() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: right))
        let split = try tab.split
        let goingView = split.cells[1].terminalView
        await eventually { TerminalFocusArbiter.current === goingView }

        // The tab moves to another window of its session — New Tab, or a
        // terminal chosen from the panel: every pane it drew goes, one new
        // pane comes, and the keyboard is on it when the transport is
        // answered with its grid.
        let sizes = await tab.events.arrange(PaneArrangement(layout: .pane(below), focus: below))
        let arrived = try XCTUnwrap(split.cells.first?.terminalView)
        XCTAssertEqual(split.cells.map(\.screen.paneID), [below])
        XCTAssertTrue(TerminalFocusArbiter.current === arrived)
        XCTAssertNil(goingView.window)
        XCTAssertNotNil(sizes[below])

        // A pane that arrives beside one that stays takes it the same way.
        _ = await tab.events.arrange(PaneArrangement(
            layout: PaneLayout.split(PaneLayout.Split(
                id: "split:9", axis: .sideBySide, ratio: 0.5,
                before: .pane(below), after: .pane(right))),
            focus: right))
        let arrivedBeside = try XCTUnwrap(split.cell(for: right)?.terminalView)
        XCTAssertTrue(TerminalFocusArbiter.current === arrivedBeside)

        // A tab that did not have the keyboard does not take it because
        // its panes changed.
        TerminalFocusArbiter.release(arrivedBeside)
        _ = await tab.events.arrange(PaneArrangement(layout: .pane(left), focus: left))
        XCTAssertNil(TerminalFocusArbiter.current)
        tab.window.isHidden = true
    }

    // MARK: - Moving to another window

    func testAMovedTabsNewWindowAdoptsTheEmulatorsAndTheOldSurfaceCannotTakeThemBack() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: right))
        let old = try tab.split
        let views = old.cells.map(\.terminalView)

        // Merge / split: another window mounts the same controller. Its
        // cells take the live views — buffers, scrollback, connection.
        let (moved, window) = mount(tab.controller)
        let new = try XCTUnwrap(moved.terminalSurface?.paneSplitView)
        XCTAssertEqual(new.cells.map(\.terminalView), views)
        XCTAssertTrue(views.allSatisfy { $0.isDescendant(of: moved.view) })
        XCTAssertTrue(tab.controller.terminalView === views[1])

        // The window the tab left gets one last update. It must not make
        // cells of its own: adopting the views would pull them back out.
        tab.pane.update(configuration: configuration(tab.controller))
        tab.pane.view.layoutIfNeeded()
        XCTAssertTrue(views.allSatisfy { $0.isDescendant(of: moved.view) })

        // From here on the layout is the new window's to draw.
        let grown = PaneLayout.split(PaneLayout.Split(
            id: "split:1", axis: .sideBySide, ratio: 0.5,
            before: .pane(left),
            after: .split(PaneLayout.Split(
                id: "split:2", axis: .stacked, ratio: 0.5,
                before: .pane(right), after: .pane(below)))))
        let sizes = await tab.events.arrange(PaneArrangement(layout: grown, focus: below))
        XCTAssertEqual(new.cells.map(\.screen.paneID), [left, right, below])
        XCTAssertEqual(old.cells.count, 2)
        XCTAssertTrue(new.cells[2].terminalView.isDescendant(of: moved.view))
        // And measured there: the new pane's grid is its cell's in the new
        // window.
        XCTAssertEqual(
            sizes[below]?.rows, new.cells[2].terminalView.terminalDimensions.rows)
        window.isHidden = true
        tab.window.isHidden = true
    }

    func testAFileDroppedOnAPaneIsThatPanes() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: left))
        let split = try tab.split
        XCTAssertEqual(split.pane(at: CGPoint(x: 20, y: 40)), left)
        XCTAssertEqual(split.pane(at: CGPoint(x: split.bounds.maxX - 20, y: 40)), right)
        // On the line between them: nobody's, and the focus stays put.
        XCTAssertNil(split.pane(at: CGPoint(x: split.cells[0].frame.maxX + 4, y: 40)))
        tab.window.isHidden = true
    }

    // MARK: - A grid the backend dictates

    func testOnePaneIsHeldToAnotherClientsGridWhileItsSiblingKeepsItsOwn() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: left))
        let split = try tab.split
        let own = split.cells[1].terminalView.terminalDimensions

        await tab.events.grid(left, TerminalGrid(cols: 30, rows: 8))
        XCTAssertEqual(split.cells[0].screen.gridPin, TerminalGrid(cols: 30, rows: 8))
        XCTAssertEqual(split.cells[0].terminalView.terminalDimensions.cols, 30)
        XCTAssertEqual(split.cells[0].terminalView.terminalDimensions.rows, 8)
        // The other pane is untouched, and the pinned grid — somebody
        // else's — is never sent back as this tab's ask.
        XCTAssertEqual(split.cells[1].terminalView.terminalDimensions.cols, own.cols)
        let asked = await tab.transport.resized[left]
        XCTAssertNotEqual(asked, TerminalGrid(cols: 30, rows: 8))

        // Its own grid again: the pane measures and reports it.
        await tab.events.grid(left, nil)
        XCTAssertNil(split.cells[0].screen.gridPin)
        XCTAssertEqual(split.cells[0].terminalView.terminalDimensions.cols, own.cols, accuracy: 1)
        tab.window.isHidden = true
    }

    // MARK: - Ending

    func testTheTransportEndingEndsTheTabAndAReconnectKeepsThePanes() async throws {
        let tab = try await makeTab(PaneArrangement(layout: sideBySide, focus: left))
        let split = try tab.split
        let views = split.cells.map(\.terminalView)

        tab.events.close("The connection to the Rex server was lost.")
        await eventually {
            tab.controller.status == .ended("The connection to the Rex server was lost.")
        }
        await eventually { await tab.transport.isClosed }
        // Nothing typed reaches a tab that ended.
        tab.controller.sendInput(Data("x".utf8))
        try await Task.sleep(for: .milliseconds(50))
        let written = await tab.transport.written
        XCTAssertTrue(written.isEmpty)
        // The panes stay on screen under the ended panel, as a single
        // emulator does.
        XCTAssertEqual(split.cells.map(\.terminalView), views)

        // The next run draws the same panes into the same emulators.
        let again = Transport()
        await tab.controller.runPanesForTesting(over: again) { events in
            _ = await events.arrange(PaneArrangement(layout: self.sideBySide, focus: self.left))
        }
        XCTAssertEqual(tab.controller.status, .live)
        XCTAssertEqual(split.cells.map(\.terminalView), views)
        tab.controller.sendInput(Data("y".utf8))
        await eventually { await again.written == ["block:left:y"] }
        tab.controller.detach()
        tab.window.isHidden = true
    }

    private func views<T: UIView>(ofType type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { child -> [T] in
            (child as? T).map { [$0] } ?? views(ofType: type, in: child)
        }
    }
}
