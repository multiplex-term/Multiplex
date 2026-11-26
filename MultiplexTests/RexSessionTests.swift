import XCTest
@testable import Multiplex

/// `RexSession` end to end against an in-process Rex server: every byte
/// goes through the real WebSocket codec and wire formats, only the SSH
/// pipes are replaced. What this pins is ORDER — the part of the attach
/// that is load-bearing and that no pure test can see — and what happens to
/// a tab's panes as the server's layout changes under it.
final class RexSessionTests: XCTestCase {
    private let sessionID = "session:0000-aaaaaa"
    private let front = PaneID("block:front")
    private let side = PaneID("block:side")
    private let other = PaneID("block:other")

    private func makeSession(
        _ server: FakeRexServer, blockID: String? = nil
    ) -> RexSession {
        RexSession(
            openPipe: { try server.makePipe() },
            closeLink: { server.note("link closed") },
            sessionID: sessionID, blockID: blockID, clientVersion: "test"
        )
    }

    /// Collects what the session hands the tab: each pane's output, the
    /// grids its emulator is given, the arrangements, and the end.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [PaneID: [Data]] = [:]
        private var arranged: [PaneArrangement] = []
        private var closes: [String?] = []
        /// What the tab "measures" for a pane; every other pane is 100x30.
        var sizes: [PaneID: TerminalGrid] = [:]

        func data(_ pane: PaneID, _ chunk: Data) {
            lock.withLock { chunks[pane, default: []].append(chunk) }
        }
        /// The emulator's grid changing hands, in line with what is drawn.
        func grid(_ pane: PaneID, _ grid: TerminalGrid?) {
            let text = grid.map { "GRID \($0.cols)x\($0.rows)" } ?? "GRID own"
            lock.withLock { chunks[pane, default: []].append(Data(text.utf8)) }
        }
        func arrange(_ arrangement: PaneArrangement) -> [PaneID: TerminalGrid] {
            lock.withLock { arranged.append(arrangement) }
            return Dictionary(uniqueKeysWithValues: arrangement.layout.panes.map {
                ($0, sizes[$0] ?? TerminalGrid(cols: 100, rows: 30))
            })
        }
        func closed(_ reason: String?) { lock.withLock { closes.append(reason) } }
        func text(_ pane: PaneID) -> [String] {
            lock.withLock {
                (chunks[pane] ?? []).map { String(decoding: $0, as: UTF8.self) }
            }
        }
        var arrangements: [PaneArrangement] { lock.withLock { arranged } }
        var closeReasons: [String?] { lock.withLock { closes } }
    }

    private func open(_ session: RexSession, sink: Sink) async throws {
        try await session.open(events: PaneEvents(
            arrange: { sink.arrange($0) },
            output: { sink.data($0, $1) },
            grid: { sink.grid($0, $1) },
            close: { sink.closed($0) }
        ))
    }

    /// The two reads a screen is drawn from, sorted. They share a round
    /// trip, so which the server sees first is not the session's to say.
    private static let screenReads = [
        "com.superlogical.terminal.format",
        "com.superlogical.terminal.modes",
    ]

    private func eventually(
        _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    /// `block:side | block:front` in the fronted window, `front` focused.
    private func splitServer() -> FakeRexServer {
        let server = FakeRexServer()
        server.setWindow("window:2", tree: .split(
            id: "split:1", direction: "horizontal", ratio: 0.6,
            before: .block("block:side"), after: .block("block:front")))
        return server
    }

    // MARK: - Attach

    func testAttachClaimsAndSizesBeforeItAsksForTheScreenOrTheStream() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        XCTAssertEqual(Array(server.calls.prefix(4)), [
            "session.attach",
            // Claim and size FIRST: the rendering and the stream below must
            // describe the terminal at this tab's size.
            "session.own_block",
            "com.superlogical.terminal.resize 100x30",
            "data.connect",
        ])
        XCTAssertEqual(server.calls.dropFirst(4).sorted(), Self.screenReads)
        // The hello never claims to be an app (see `RexWire.hello`).
        XCTAssertEqual(server.helloKind, "other")
        // The fronted block was chosen: active window, focused block — and
        // the tab was told so before anything was opened.
        XCTAssertEqual(server.claims, [["block:front"]])
        XCTAssertEqual(
            sink.arrangements, [PaneArrangement(layout: .pane(front), focus: front)])
        await session.close()
    }

    func testTheSnapshotIsDroppedAndEarlyOutputIsDrawnAfterTheScreen() async throws {
        let server = FakeRexServer()
        // The server sends this the moment the stream opens — before the
        // session has fetched, let alone drawn, the rendering.
        server.earlyOutput = "early\r\n"
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        // RIS, then the rendering, then the held stream — never the
        // Ghostty snapshot, and never output UNDER a later rendering.
        XCTAssertEqual(sink.text(front), ["\u{1B}cSCREEN", "early\r\n"])

        server.sendOutput("later\r\n")
        await eventually { sink.text(self.front).count == 3 }
        XCTAssertEqual(sink.text(front).last, "later\r\n")
        await session.close()
    }

    func testANamedBlockIsAttachedWhileItExists() async throws {
        let server = FakeRexServer()
        let session = makeSession(server, blockID: "block:other")
        let sink = Sink()
        try await open(session, sink: sink)
        XCTAssertEqual(server.claims, [["block:other"]])
        XCTAssertEqual(sink.arrangements.last?.layout, .pane(other))
        await session.close()

        // One that has since closed falls back to the fronted block.
        let fallback = FakeRexServer()
        let second = makeSession(fallback, blockID: "block:gone")
        try await open(second, sink: Sink())
        XCTAssertEqual(fallback.claims, [["block:front"]])
        await second.close()
    }

    // MARK: - A window's panes

    func testAWindowsPanesAreArrangedMeasuredClaimedTogetherAndEachDrawnInItsOwn() async throws {
        let server = splitServer()
        server.screens = ["block:side": "SIDE", "block:front": "FRONT"]
        let session = makeSession(server)
        let sink = Sink()
        sink.sizes = [side: TerminalGrid(cols: 59, rows: 30), front: TerminalGrid(cols: 40, rows: 30)]
        try await open(session, sink: sink)

        // The whole split, as the app's own tree, with the keyboard on the
        // block the window is focused on.
        XCTAssertEqual(sink.arrangements, [PaneArrangement(
            layout: .split(PaneLayout.Split(
                id: "split:1", axis: .sideBySide, ratio: 0.6,
                before: .pane(side), after: .pane(front))),
            focus: front)])
        // ONE claim for both, then each terminal at the grid its own pane
        // measured, and only then the streams.
        XCTAssertEqual(server.claims, [["block:side", "block:front"]])
        XCTAssertEqual(Array(server.calls.prefix(4)), [
            "session.attach",
            "session.own_block",
            "com.superlogical.terminal.resize 59x30",
            "com.superlogical.terminal.resize 40x30",
        ])
        XCTAssertEqual(server.resizes.map(\.block), ["block:side", "block:front"])
        XCTAssertEqual(server.calls.filter { $0 == "data.connect" }.count, 2)
        // Each pane got its own terminal's screen, and gets its own output.
        XCTAssertEqual(sink.text(side), ["\u{1B}cSIDE"])
        XCTAssertEqual(sink.text(front), ["\u{1B}cFRONT"])
        server.sendOutput("for side", to: "block:side")
        await eventually { sink.text(self.side).last == "for side" }
        XCTAssertEqual(sink.text(front), ["\u{1B}cFRONT"])

        // Typing goes to the pane it was typed into, and a pane's new size
        // to its own terminal.
        try await session.write(Data("a".utf8), to: side)
        await eventually { server.written == ["a"] }
        XCTAssertEqual(server.lastWriteBlock, "block:side")
        try await session.resize(pane: front, cols: 44, rows: 28)
        XCTAssertEqual(server.resizes.last?.block, "block:front")
        XCTAssertEqual(server.calls.last, "com.superlogical.terminal.resize 44x28")
        await session.close()
    }

    func testAPaneThatCannotBeOpenedSaysSoInItsPaneAndTheTabStays() async throws {
        let server = splitServer()
        server.rejectReasons = ["block:side": 0x04]
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        XCTAssertEqual(sink.text(front), ["\u{1B}cSCREEN"])
        XCTAssertEqual(sink.text(side).count, 1)
        XCTAssertEqual(sink.text(side).first?.hasPrefix("\u{1B}cCouldn't open this terminal."), true)
        XCTAssertEqual(
            sink.text(side).first?.contains("the server is at its connection limit"), true)
        // The pane that works still does.
        server.sendOutput("still here")
        await eventually { sink.text(self.front).last == "still here" }
        XCTAssertTrue(sink.closeReasons.isEmpty)
        await session.close()
    }

    func testAPaneAnotherClientAddsIsDrawnAtItsOwnersSizeAndNotClaimed() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        let claimsBefore = server.claims

        // The Rex app splits the window. The new terminal is its own, at
        // the size of ITS pane.
        server.openingSizes["block:added"] = (50, 20, "client:rex-app")
        server.screens["block:added"] = "ADDED"
        server.addBlock("block:added", beside: "block:front", owner: "client:rex-app")
        let added = PaneID("block:added")
        await eventually { sink.text(added).last == "\u{1B}cADDED" }

        // The tab follows: the pane appears, drawn at its owner's grid, and
        // the keyboard stays where it was.
        XCTAssertEqual(sink.arrangements.last, PaneArrangement(
            layout: .split(PaneLayout.Split(
                id: "split:added", axis: .sideBySide, ratio: 0.5,
                before: .pane(front), after: .pane(added))),
            focus: nil))
        XCTAssertEqual(sink.text(added), ["GRID 50x20", "\u{1B}cADDED"])
        // Nothing was taken from the client that made it.
        XCTAssertEqual(server.claims, claimsBefore)
        XCTAssertFalse(server.resizes.contains { $0.block == "block:added" })

        // Typing here is what claims — every terminal the tab draws that it
        // does not own, the one typed into first.
        try await session.write(Data("x".utf8), to: front)
        await eventually { server.written == ["x"] }
        XCTAssertEqual(server.claims.count, claimsBefore.count)
        try await session.write(Data("y".utf8), to: added)
        await eventually { server.written == ["x", "y"] }
        XCTAssertEqual(server.claims.last, ["block:added"])
        XCTAssertEqual(server.resizes.last?.block, "block:added")
        await session.close()
    }

    // MARK: - Changing the layout

    func testASplitIsAskedOfTheServerAndTheNewPaneArrivesWithTheKeyboard() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        try await session.perform(.split(front, .stacked))
        let made = PaneID("block:new1")
        await eventually { sink.text(made) == ["\u{1B}cSCREEN"] }

        // Below the pane it was split from, starting where that pane's
        // program is, and NOT focused on the server: that would also make
        // this window the one the Rex app shows.
        let asked = try XCTUnwrap(server.splitRequests.first)
        XCTAssertEqual(asked["anchor_id"] as? String, "block:front")
        XCTAssertEqual(asked["direction"] as? String, "vertical")
        XCTAssertEqual(asked["side"] as? String, "after")
        XCTAssertEqual(asked["focus"] as? Bool, false)
        let block = (asked["layout"] as? [String: Any])?["block"] as? [String: Any]
        XCTAssertEqual(block?["flavor"] as? String, "com.superlogical.terminal.shell")
        XCTAssertEqual((block?["options"] as? [String: Any])?["cwd"] as? String, "/work/block:front")

        // The tab hears of it as an arrangement, the new pane focused.
        XCTAssertEqual(sink.arrangements.last?.layout, .split(PaneLayout.Split(
            id: "split:new1", axis: .stacked, ratio: 0.5,
            before: .pane(front), after: .pane(made))))
        XCTAssertTrue(sink.arrangements.contains { $0.focus == made })
        // It is this tab's own pane: claimed and sized like the attach's.
        XCTAssertEqual(server.claims.last, ["block:new1"])
        XCTAssertEqual(server.resizes.last?.block, "block:new1")
        let listed = await session.terminalChoices()
        XCTAssertEqual(listed?.first(where: \.isActive)?.tmuxID, "block:new1")
        await session.close()
    }

    func testClosingAPaneRemovesItAndTheKeyboardGoesToItsNeighbour() async throws {
        let server = splitServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        try await session.perform(.close(front))
        await eventually { sink.arrangements.last?.layout == .pane(self.side) }
        XCTAssertEqual(server.calls.filter { $0.hasPrefix("block.close") }, ["block.close block:front"])
        XCTAssertEqual(sink.arrangements.last?.focus, side)
        // A pane closing is not the tab ending, and a block that no longer
        // exists is not disowned (one unknown id fails that whole call).
        XCTAssertTrue(sink.closeReasons.isEmpty)
        XCTAssertFalse(server.calls.contains { $0.hasPrefix("session.disown_block") })
        // The pane that is left still works.
        try await session.write(Data("z".utf8), to: side)
        await eventually { server.written == ["z"] }
        // Nothing reaches the one that went.
        try await session.write(Data("lost".utf8), to: front)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.written, ["z"])

        // Closing the last pane closes the window: a clean end.
        try await session.perform(.close(side))
        await eventually { !sink.closeReasons.isEmpty }
        XCTAssertEqual(sink.closeReasons, [nil])
        await session.close()
    }

    func testADraggedLineSendsOnlyTheNewestRatioAndIsNotDraggedBackByOlderAnswers() async throws {
        let server = splitServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        let arrangedBefore = sink.arrangements.count

        // A slow link: the first ask is still out while the drag goes on.
        server.hold("session.resize_pane")
        try await session.perform(.setRatio(0.3, splitID: "split:1"))
        await eventually { server.ratioRequests.count == 1 }
        try await session.perform(.setRatio(0.4, splitID: "split:1"))
        try await session.perform(.setRatio(0.7, splitID: "split:1"))
        XCTAssertEqual(server.ratioRequests.map { $0["ratio"] as? Double }, [0.3])

        server.release()
        await eventually { server.ratioRequests.count == 2 }
        // 0.4 was never sent: only where the line is NOW matters.
        XCTAssertEqual(server.ratioRequests.map { $0["ratio"] as? Double }, [0.3, 0.7])
        // The server names the split by a block on each side of it.
        XCTAssertEqual(server.ratioRequests.last?["direction"] as? String, "horizontal")
        XCTAssertEqual(server.ratioRequests.last?["before_block_id"] as? String, "block:side")
        XCTAssertEqual(server.ratioRequests.last?["after_block_id"] as? String, "block:front")
        // The view the server sent for 0.3 arrived while 0.7 was the tab's
        // word; the tab — which moved its own line already — was told
        // nothing, least of all to go back.
        await eventually { server.calls.filter { $0 == "session.view" }.count >= 2 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(sink.arrangements.count, arrangedBefore)

        // A ratio somebody ELSE sets does arrive.
        server.setRatio(0.25, ofSplit: "split:1")
        await eventually { sink.arrangements.count == arrangedBefore + 1 }
        XCTAssertEqual(sink.arrangements.last, PaneArrangement(
            layout: .split(PaneLayout.Split(
                id: "split:1", axis: .sideBySide, ratio: 0.25,
                before: .pane(side), after: .pane(front))),
            focus: nil))
        await session.close()
    }

    func testANewTabIsMadeUnfocusedOnTheServerAndTheTabMovesToIt() async throws {
        let server = splitServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        try await session.perform(.newWindow(from: front))
        let made = PaneID("block:tab1")
        await eventually { sink.text(made) == ["\u{1B}cSCREEN"] }

        // One shell, starting where the pane it was asked from is — and NOT
        // the session's active window: that is the tab the Rex app shows.
        let asked = try XCTUnwrap(server.windowRequests.first)
        XCTAssertEqual(asked["focus"] as? Bool, false)
        let block = (asked["layout"] as? [String: Any])?["block"] as? [String: Any]
        XCTAssertEqual(block?["flavor"] as? String, "com.superlogical.terminal.shell")
        XCTAssertEqual((block?["options"] as? [String: Any])?["cwd"] as? String, "/work/block:front")

        // The tab draws the new window now, the keyboard in its shell.
        XCTAssertEqual(
            sink.arrangements.last, PaneArrangement(layout: .pane(made), focus: made))
        XCTAssertEqual(server.claims.last, ["block:tab1"])
        // The window it left is let go like one left through Switch
        // Terminal: its streams closed, its blocks given back.
        XCTAssertEqual(server.closeFramesReceived, [RexWire.dataPath, RexWire.dataPath])
        XCTAssertTrue(server.calls.contains("session.disown_block block:front,block:side"))
        // And is not the tab ending.
        XCTAssertTrue(sink.closeReasons.isEmpty)

        // The way back is the switch list, which now has four terminals.
        let listed = await session.terminalChoices()
        XCTAssertEqual(
            listed?.map(\.tmuxID), ["block:other", "block:side", "block:front", "block:tab1"])
        XCTAssertEqual(listed?.map(\.isActive), [false, false, false, true])
        await session.showTerminal("block:front")
        await eventually { sink.arrangements.last?.focus == self.front }
        XCTAssertEqual(sink.arrangements.last?.layout.panes, [side, front])
        await session.close()
    }

    func testAServerThatRefusesASplitFailsTheCommandWithItsReason() async throws {
        let server = FakeRexServer()
        server.errors["session.new_split"] = [
            "code": "conflict", "message": "too many blocks in this window", "status": 409,
        ]
        let session = makeSession(server)
        try await open(session, sink: Sink())
        do {
            try await session.perform(.split(front, .sideBySide))
            XCTFail("the split should have thrown")
        } catch {
            XCTAssertEqual(
                (error as? RexSession.Failure)?.message,
                "The Rex server refused: too many blocks in this window")
        }
        await session.close()
    }

    // MARK: - The session's other terminals

    func testTheSwitchListNamesEveryTerminalAndMarksTheOneWithTheKeyboard() async throws {
        let server = splitServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())
        let listed = await session.terminalChoices()
        let choices = try XCTUnwrap(listed)
        XCTAssertEqual(choices.map(\.tmuxID), ["block:other", "block:side", "block:front"])
        XCTAssertEqual(choices.map(\.isActive), [false, false, true])
        // Two panes of one window with the same label are told apart.
        XCTAssertEqual(choices.map(\.name), ["one — shell", "two — shell", "two — shell 2"])

        // The keyboard moving to another pane moves the mark: the tab's
        // focus is its own, and is not written to the server.
        let callsBefore = server.calls.count
        try await session.perform(.focus(side))
        XCTAssertEqual(server.calls.count, callsBefore)
        let moved = await session.terminalChoices()
        XCTAssertEqual(moved?.map(\.isActive), [false, true, false])
        await session.close()
    }

    func testATerminalAmongThePanesOnShowOnlyTakesTheKeyboard() async throws {
        let server = splitServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        let callsBefore = server.calls.count

        await session.showTerminal("block:side")
        await eventually { sink.arrangements.last?.focus == self.side }
        // The same panes, nothing opened or let go: one view read.
        XCTAssertEqual(sink.arrangements.last?.layout, sink.arrangements.first?.layout)
        XCTAssertEqual(Array(server.calls.dropFirst(callsBefore)), ["session.view"])
        await session.close()
    }

    func testATerminalInAnotherWindowBringsThatWindowsPanesInWithoutEndingTheTab() async throws {
        let server = splitServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        let attachCalls = server.calls.count

        server.screens["block:other"] = "OTHER"
        await session.showTerminal("block:other")
        await eventually { sink.text(self.other) == ["\u{1B}cOTHER"] }

        // The old streams were closed properly, the old blocks given up,
        // and the new one claimed, sized, streamed and drawn — the attach's
        // own order, on the same control connection.
        XCTAssertEqual(server.closeFramesReceived, [RexWire.dataPath, RexWire.dataPath])
        let switchCalls = Array(server.calls.dropFirst(attachCalls))
        XCTAssertEqual(Array(switchCalls.prefix(5)), [
            "session.view",
            "session.disown_block block:front,block:side",
            "session.own_block",
            "com.superlogical.terminal.resize 100x30",
            "data.connect",
        ])
        XCTAssertEqual(switchCalls.dropFirst(5).sorted(), Self.screenReads)
        XCTAssertEqual(server.claims.last, ["block:other"])
        XCTAssertEqual(
            sink.arrangements.last, PaneArrangement(layout: .pane(other), focus: other))
        // The retired streams ending is NOT the tab ending.
        XCTAssertTrue(sink.closeReasons.isEmpty)

        // The tab is live on the new terminal: output flows and typing
        // goes to it.
        server.sendOutput("from other\r\n", to: "block:other")
        await eventually { sink.text(self.other).last == "from other\r\n" }
        try await session.write(Data("x".utf8), to: other)
        await eventually {
            server.written == ["x"]
                && server.calls.last == "com.superlogical.terminal.write"
        }
        XCTAssertEqual(server.lastWriteBlock, "block:other")
        let listed = await session.terminalChoices()
        XCTAssertEqual(listed?.map(\.isActive), [true, false, false])
        await session.close()
    }

    func testTheWorkingDirectoryIsThePanesOwn() async throws {
        let server = splitServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())
        let inFront = await session.workingDirectory(of: front)
        XCTAssertEqual(inFront, "/work/block:front")
        let inSide = await session.workingDirectory(of: side)
        XCTAssertEqual(inSide, "/work/block:side")
        // A pane the tab does not draw has no answer.
        let elsewhere = await session.workingDirectory(of: other)
        XCTAssertNil(elsewhere)
        await session.close()
        // Nor has a closed tab — the $HOME fallback.
        let closed = await session.workingDirectory(of: front)
        XCTAssertNil(closed)
    }

    // MARK: - Typing and sizing

    func testTypingReachesTheBlockInOrderAsText() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())

        try await session.write(Data("ls\r".utf8), to: front)
        // A character split across two writes is sent whole.
        let wide = Data("測".utf8)
        try await session.write(wide.prefix(2), to: front)
        try await session.write(wide.suffix(1), to: front)
        try await session.write(Data([0x1B, 0x5B, 0x41]), to: front)
        // A write queues and returns, so how the four were grouped into
        // calls is timing. What is not: every byte once, in order, and no
        // call carrying half a character.
        await eventually { server.written.joined() == "ls\r測\u{1B}[A" }
        XCTAssertFalse(server.written.contains { $0.contains("\u{FFFD}") })

        try await session.resize(pane: front, cols: 120, rows: 40)
        XCTAssertEqual(server.calls.last, "com.superlogical.terminal.resize 120x40")
        await session.close()
    }

    func testWhatIsTypedWhileAWriteIsInFlightRidesTheNextOneTogether() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())

        // The server sits on its answers, as a slow link does.
        server.hold("com.superlogical.terminal.write")
        try await session.write(Data("a".utf8), to: front)
        await eventually { server.written == ["a"] }
        // None of these waits for "a" to be answered...
        try await session.write(Data("b".utf8), to: front)
        try await session.write(Data("c".utf8), to: front)
        try await session.write(Data("d".utf8), to: front)
        XCTAssertEqual(server.written, ["a"])

        // ...and once it is, they go as one call, not three round trips.
        server.release()
        await eventually { server.written == ["a", "bcd"] }
        await session.close()
    }

    func testTypingClaimsTheBlockBackAfterAnotherClientTookIt() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())
        let before = server.calls.filter { $0 == "session.own_block" }.count

        // While this tab owns the block, typing claims nothing.
        try await session.write(Data("a".utf8), to: front)
        await eventually { server.written == ["a"] }
        XCTAssertEqual(server.calls.filter { $0 == "session.own_block" }.count, before)

        // The Rex app takes the block; the next keystroke takes it back and
        // re-sizes it — the last client to type owns the size.
        server.announceOwner("client:rex-app", of: "block:front")
        await eventually { server.eventsDelivered == 1 }
        try await Task.sleep(for: .milliseconds(150))
        try await session.write(Data("b".utf8), to: front)
        await eventually {
            server.written == ["a", "b"]
                && server.calls.last == "com.superlogical.terminal.write"
        }
        XCTAssertEqual(server.calls.filter { $0 == "session.own_block" }.count, before + 1)
        XCTAssertEqual(server.calls.suffix(3), [
            "session.own_block",
            "com.superlogical.terminal.resize 100x30",
            "com.superlogical.terminal.write",
        ])
        await session.close()
    }

    func testTypingInOnePaneClaimsEveryPaneAnotherClientHolds() async throws {
        let server = splitServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())

        // The Rex app took both; a key in ONE pane here takes both back.
        // The tab draws them as one window, and half of it at another
        // client's size is a layout nobody chose.
        server.announceOwner("client:rex-app", of: "block:front")
        server.announceOwner("client:rex-app", of: "block:side")
        await eventually { server.eventsDelivered == 2 }
        try await Task.sleep(for: .milliseconds(150))
        try await session.write(Data("k".utf8), to: side)
        await eventually { server.written == ["k"] }
        XCTAssertEqual(server.claims.last, ["block:side", "block:front"])
        XCTAssertEqual(server.resizes.suffix(2).map(\.block), ["block:side", "block:front"])
        await session.close()
    }

    // MARK: - Another client's size

    func testAnotherClientsSizeIsGivenToTheEmulatorBeforeTheScreenIsDrawnAgain() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        XCTAssertEqual(sink.text(front), ["\u{1B}cSCREEN"])

        // The Rex app takes the terminal at its own size, and the program
        // repaints for it straight away.
        server.screen = "WIDE"
        server.sendResize(cols: 170, rows: 50, owner: "client:rex-app")
        server.sendOutput("REPAINT")
        await eventually { sink.text(self.front).last == "\u{1B}cWIDE" }
        // The grid first, then the screen at it — and the repaint, which
        // arrived before the rendering was asked for and so is in it, is
        // not drawn a second time on top.
        XCTAssertEqual(sink.text(front), ["\u{1B}cSCREEN", "GRID 170x50", "\u{1B}cWIDE"])
        // Following is all it does: the size is not asked back.
        XCTAssertEqual(server.calls.filter { $0 == "session.own_block" }.count, 1)
        XCTAssertEqual(
            server.calls.filter { $0.hasPrefix("com.superlogical.terminal.resize") }.count, 1)

        server.sendOutput("later")
        await eventually { sink.text(self.front).last == "later" }

        // Typing here takes the terminal back; the stream then says it is
        // this tab's size again and the emulator returns to its own grid.
        server.screen = "OWN"
        server.sendResize(cols: 100, rows: 30, owner: server.clientID)
        await eventually { sink.text(self.front).last == "\u{1B}cOWN" }
        XCTAssertEqual(Array(sink.text(front).suffix(2)), ["GRID own", "\u{1B}cOWN"])
        await session.close()
    }

    func testOnePaneFollowingAnotherClientsSizeLeavesItsSiblingAlone() async throws {
        let server = splitServer()
        server.screens = ["block:side": "SIDE", "block:front": "FRONT"]
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        server.screens["block:side"] = "SIDE WIDE"
        server.sendResize(cols: 170, rows: 50, owner: "client:rex-app", to: "block:side")
        await eventually { sink.text(self.side).last == "\u{1B}cSIDE WIDE" }
        XCTAssertEqual(sink.text(side), ["\u{1B}cSIDE", "GRID 170x50", "\u{1B}cSIDE WIDE"])
        XCTAssertEqual(sink.text(front), ["\u{1B}cFRONT"])
        await session.close()
    }

    func testThisTabsOwnResizesNeverMoveTheEmulatorsGrid() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        // A window drag: the stream reports sizes this client set, some of
        // them already overtaken by the next one.
        try await session.resize(pane: front, cols: 120, rows: 40)
        server.sendResize(cols: 110, rows: 35, owner: server.clientID)
        server.sendResize(cols: 120, rows: 40, owner: server.clientID)
        // Another client that happens to want this tab's size changes
        // nothing either.
        server.sendResize(cols: 120, rows: 40, owner: "client:rex-app")
        server.sendOutput("after")
        await eventually { sink.text(self.front).last == "after" }
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(sink.text(front), ["\u{1B}cSCREEN", "after"])
        XCTAssertEqual(
            server.calls.filter { $0 == "com.superlogical.terminal.format" }.count, 1)
        await session.close()
    }

    func testASizeThatGoesBackBeforeTheRedrawIsStillDrawnAgainAtTheTabsOwnGrid() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        // Taken and given back inside the quiet wait. The emulator's grid
        // has nowhere to go, but what the program wrote in between was
        // laid out for 170 columns: it is replaced, not drawn.
        server.screen = "BACK"
        server.sendResize(cols: 170, rows: 50, owner: "client:rex-app")
        server.sendOutput("one")
        server.sendResize(cols: 100, rows: 30, owner: server.clientID)
        server.sendOutput("two")
        await eventually { sink.text(self.front).count == 2 }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(sink.text(front), ["\u{1B}cSCREEN", "\u{1B}cBACK"])
        XCTAssertEqual(
            server.calls.filter { $0 == "com.superlogical.terminal.format" }.count, 2)
        await session.close()
    }

    func testATerminalAlreadyAtAnotherClientsSizeIsAttachedAtThatGrid() async throws {
        let server = FakeRexServer()
        // The claim did not hold: by the time the stream opens the Rex app
        // has the terminal again.
        server.openingSizes["block:front"] = (170, 50, "client:rex-app")
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        XCTAssertEqual(sink.text(front), ["GRID 170x50", "\u{1B}cSCREEN"])
        await session.close()
    }

    // MARK: - Full-screen programs

    func testATabAttachedDuringAFullScreenProgramRedrawsWhenItExits() async throws {
        let server = FakeRexServer()
        server.screenKind = "alternate"
        server.screen = "VIM"
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        XCTAssertEqual(sink.text(front), ["\u{1B}cVIM"])

        // The program leaves the alternate screen; the server can now
        // render the shell history that was underneath.
        server.screenKind = "primary"
        server.screen = "HISTORY"
        server.sendOutput("\u{1B}[?1049l$ ")
        await eventually { sink.text(self.front).last == "\u{1B}cHISTORY" }
        // The exit burst passed through, then ONE redraw replaced it.
        XCTAssertEqual(
            sink.text(front), ["\u{1B}cVIM", "\u{1B}[?1049l$ ", "\u{1B}cHISTORY"])
        XCTAssertEqual(
            server.calls.filter { $0 == "com.superlogical.terminal.format" }.count, 2)

        // Back on the primary screen there is nothing more to restore: a
        // later exit sequence is just output.
        server.sendOutput("\u{1B}[?1049l")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(
            server.calls.filter { $0 == "com.superlogical.terminal.format" }.count, 2)
        await session.close()
    }

    // MARK: - Ending

    func testTheLastBlockClosingEndsTheTabCleanlyAndSaysGoodbye() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        // The shell exits: its stream closes (4000), the block goes, and
        // with it the window.
        server.closeBlock("block:front")
        await eventually { !sink.closeReasons.isEmpty }
        // A clean end — like a shell exiting, not an error.
        XCTAssertEqual(sink.closeReasons, [nil])
        // The control connection got a close frame, so the server ends the
        // client at once instead of keeping it "connection lost" a minute.
        await eventually { server.closeFramesReceived.contains(RexWire.controlPath) }
        await session.close()
        XCTAssertEqual(server.notes, ["link closed"])
    }

    func testAProgramExitingInOnePaneTakesOnlyThatPane() async throws {
        let server = splitServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        server.closeBlock("block:side")
        await eventually { sink.arrangements.last?.layout == .pane(self.front) }
        // The keyboard was on the other pane and stays there.
        XCTAssertNil(sink.arrangements.last?.focus)
        XCTAssertTrue(sink.closeReasons.isEmpty)
        server.sendOutput("alive")
        await eventually { sink.text(self.front).last == "alive" }
        await session.close()
    }

    func testClosingTheTabClosesEveryStreamBeforeTheControlConnection() async throws {
        let server = splitServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        await session.close()

        // Data first, with status 1000 (which ends each stream), then
        // control.
        XCTAssertEqual(
            server.closeFramesReceived,
            [RexWire.dataPath, RexWire.dataPath, RexWire.controlPath])
        XCTAssertEqual(server.notes, ["link closed"])
        // Closing is the tab's own doing — nobody is told it "ended".
        XCTAssertTrue(sink.closeReasons.isEmpty)
        // And is safe to repeat.
        await session.close()
    }

    func testAnAbnormalStreamCloseIsAnErrorTheTabCanShow() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        server.closeData(code: 1011, reason: "data provider failed")
        await eventually { !sink.closeReasons.isEmpty }
        XCTAssertEqual(sink.closeReasons.count, 1)
        XCTAssertEqual(sink.closeReasons.first??.contains("data provider failed"), true)
        await session.close()
    }

    func testALinkThatDiesUnderALiveTabEndsItOnceWithTheReason() async throws {
        // What iOS suspension does: the sockets die with no goodbye. The
        // tab must END (once), because that close is what
        // `SessionResumePolicy` hangs an automatic re-attach on.
        let server = splitServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        server.dropLinks(SSHConnectionError.connectFailed("connection reset by peer"))
        await eventually { !sink.closeReasons.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        // Said as a lost connection — never the transport's own shorthand.
        XCTAssertEqual(sink.closeReasons, ["The connection to the Rex server was lost."])
        // Nothing can be typed into a dead tab, and closing it is still safe.
        do {
            try await session.write(Data("x".utf8), to: front)
            XCTFail("a dead tab accepted input")
        } catch {}
        await session.close()
    }

    // MARK: - Failing to attach

    func testASessionThatIsGoneFailsTheOpenWithAReadableReason() async {
        let server = FakeRexServer()
        server.errors["session.attach"] = [
            "code": "session_not_found", "message": "no such session", "status": 404,
        ]
        let session = makeSession(server)
        let sink = Sink()
        do {
            try await open(session, sink: sink)
            XCTFail("the open should have thrown")
        } catch {
            XCTAssertEqual(
                (error as? RexSession.Failure)?.message, "This Rex session no longer exists.")
        }
        // A failed open is reported by the throw alone.
        XCTAssertTrue(sink.closeReasons.isEmpty)
        XCTAssertTrue(sink.text(front).isEmpty)
        await session.close()
    }

    func testASessionWithNoTerminalAndARefusedStreamBothFailTheOpen() async {
        let empty = FakeRexServer()
        empty.removeAllWindows()
        do {
            try await open(makeSession(empty), sink: Sink())
            XCTFail("the open should have thrown")
        } catch {
            XCTAssertEqual(
                (error as? RexSession.Failure)?.message,
                "This Rex session has no terminal to open.")
        }

        // With no pane opened there is no tab to say it in: the open fails
        // with the terminal's own reason.
        let refusing = FakeRexServer()
        refusing.rejectReasons = ["block:front": 0x02]
        let sink = Sink()
        do {
            try await open(makeSession(refusing), sink: sink)
            XCTFail("the open should have thrown")
        } catch {
            XCTAssertEqual(
                (error as? RexSession.Failure)?.message.contains(
                    "another connection already has this terminal"),
                true)
        }
        XCTAssertTrue(sink.text(front).isEmpty)
    }

    func testAPipeThatCannotStartCarriesTheCommandsOwnReason() async {
        let session = RexSession(
            openPipe: {
                throw SSHConnectionError.connectFailed(
                    "Error: no Rex server is running, and REX_AUTOSTART=0 turns autostart off")
            },
            closeLink: {},
            sessionID: sessionID, blockID: nil, clientVersion: "test"
        )
        do {
            try await open(session, sink: Sink())
            XCTFail("the open should have thrown")
        } catch {
            XCTAssertEqual(
                (error as? RexSession.Failure)?.message,
                "Couldn't reach the Rex server. Error: no Rex server is running, "
                    + "and REX_AUTOSTART=0 turns autostart off")
        }
    }

    func testAConnectionWithNoRoomForOnePanesPipeLeavesTheOtherPanesUp() async throws {
        // sshd's MaxSessions: the control pipe and the first stream open,
        // the third channel is refused.
        let server = splitServer()
        server.pipeLimit = 2
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        let texts = [sink.text(side), sink.text(front)]
        XCTAssertEqual(texts.filter { $0 == ["\u{1B}cSCREEN"] }.count, 1)
        XCTAssertEqual(
            texts.filter {
                $0.first?.contains("Couldn't open this terminal. Couldn't reach the Rex server.")
                    == true
            }.count, 1)
        XCTAssertTrue(sink.closeReasons.isEmpty)
        await session.close()
    }
}

// MARK: - The in-process server

/// A Rex server small enough to read: it answers the upgrade, the hello,
/// and the methods a tab makes, keeps a real layout tree per window, and
/// streams what a test tells it to. One instance serves every pipe of a
/// session.
private final class FakeRexServer: @unchecked Sendable {
    indirect enum Node {
        case block(String)
        case split(id: String, direction: String, ratio: Double, before: Node, after: Node)

        var blocks: [String] {
            switch self {
            case .block(let id): [id]
            case .split(_, _, _, let before, let after): before.blocks + after.blocks
            }
        }

        func removing(_ block: String) -> Node? {
            switch self {
            case .block(let id):
                return id == block ? nil : self
            case .split(let id, let direction, let ratio, let before, let after):
                guard let first = before.removing(block) else { return after.removing(block) }
                guard let second = after.removing(block) else { return first }
                return .split(
                    id: id, direction: direction, ratio: ratio, before: first, after: second)
            }
        }

        func splitting(_ anchor: String, direction: String, splitID: String, adding new: String) -> Node {
            switch self {
            case .block(let id):
                guard id == anchor else { return self }
                return .split(
                    id: splitID, direction: direction, ratio: 0.5,
                    before: self, after: .block(new))
            case .split(let id, let own, let ratio, let before, let after):
                return .split(
                    id: id, direction: own, ratio: ratio,
                    before: before.splitting(
                        anchor, direction: direction, splitID: splitID, adding: new),
                    after: after.splitting(
                        anchor, direction: direction, splitID: splitID, adding: new))
            }
        }

        func settingRatio(_ ratio: Double, where matches: (Node, Node, String, String) -> Bool) -> Node {
            guard case .split(let id, let direction, let own, let before, let after) = self
            else { return self }
            if matches(before, after, direction, id) {
                return .split(id: id, direction: direction, ratio: ratio, before: before, after: after)
            }
            return .split(
                id: id, direction: direction, ratio: own,
                before: before.settingRatio(ratio, where: matches),
                after: after.settingRatio(ratio, where: matches))
        }

        func json(in rect: [Double]) -> [String: Any] {
            switch self {
            case .block(let id):
                return ["rect": rect, "block_id": id]
            case .split(let id, let direction, let ratio, let before, let after):
                return ["rect": rect, "split": [
                    "split_id": id, "direction": direction, "ratio": ratio,
                    "before": before.json(in: rect), "after": after.json(in: rect),
                ] as [String: Any]]
            }
        }
    }

    private struct Window {
        var id: String
        var label: String
        var focused: String?
        var tree: Node?
    }

    private let lock = NSLock()
    private var windows = [
        Window(id: "window:1", label: "one", focused: "block:other", tree: .block("block:other")),
        Window(id: "window:2", label: "two", focused: "block:front", tree: .block("block:front")),
    ]
    private var revision = 1
    private var recordedCalls: [String] = []
    private var recordedWrites: [String] = []
    private var recordedNotes: [String] = []
    private var recordedCloses: [String] = []
    private var recordedClaims: [[String]] = []
    private var recordedResizes: [(block: String, cols: Int, rows: Int)] = []
    private var recordedSplits: [[String: Any]] = []
    private var recordedWindows: [[String: Any]] = []
    private var recordedRatios: [[String: Any]] = []
    private var kind: String?
    private var writeBlock: String?
    private var events = 0
    private var pipes = 0
    private var created = 0
    private var owners: [String: String] = [:]
    private var tickets: [String] = []
    private var controlFeed: AsyncThrowingStream<Data, Error>.Continuation?
    private var dataFeeds: [String: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    /// The method whose answers a test is sitting on, and the answers.
    private var heldMethod: String?
    private var heldReplies: [() -> Void] = []

    // What a test configures before the attach.
    var errors: [String: [String: Any]] = [:]
    var rejectReasons: [String: UInt8] = [:]
    var earlyOutput = ""
    var screen = "SCREEN"
    var screens: [String: String] = [:]
    var screenKind = "primary"
    /// The size a block's stream opens by stating, and whose it is.
    var openingSizes: [String: (cols: Int, rows: Int, owner: String)] = [:]
    /// How many pipes may open; the next one is refused, as sshd refuses a
    /// channel past `MaxSessions`.
    var pipeLimit = Int.max
    let nonce: UInt64 = 0x1122_3344_5566_7788
    let clientID = "client:me"

    var calls: [String] { lock.withLock { recordedCalls } }
    var written: [String] { lock.withLock { recordedWrites } }
    var notes: [String] { lock.withLock { recordedNotes } }
    var closeFramesReceived: [String] { lock.withLock { recordedCloses } }
    var claims: [[String]] { lock.withLock { recordedClaims } }
    var resizes: [(block: String, cols: Int, rows: Int)] { lock.withLock { recordedResizes } }
    var splitRequests: [[String: Any]] { lock.withLock { recordedSplits } }
    var windowRequests: [[String: Any]] { lock.withLock { recordedWindows } }
    var ratioRequests: [[String: Any]] { lock.withLock { recordedRatios } }
    var helloKind: String? { lock.withLock { kind } }
    var lastWriteBlock: String? { lock.withLock { writeBlock } }
    var eventsDelivered: Int { lock.withLock { events } }

    func note(_ text: String) { lock.withLock { recordedNotes.append(text) } }

    func setWindow(_ id: String, tree: Node) {
        lock.withLock {
            guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
            windows[index].tree = tree
        }
    }

    func removeAllWindows() {
        lock.withLock { windows = [] }
    }

    func makePipe() throws -> RemotePipe {
        let refused = lock.withLock {
            pipes += 1
            return pipes > pipeLimit
        }
        if refused {
            throw SSHConnectionError.connectFailed("channel open failed: administratively prohibited")
        }
        let (stream, feed) = AsyncThrowingStream<Data, Error>.makeStream()
        let connection = Connection(server: self, feed: feed)
        return RemotePipe(
            incoming: stream,
            write: { connection.receive($0) },
            close: { feed.finish() }
        )
    }

    // MARK: Driving a stream from a test

    func sendOutput(_ text: String, to block: String = "block:front") {
        lock.withLock { dataFeeds[block] }?.yield(Self.frame(0x2, Data(text.utf8)))
    }

    /// The stream's own word that the terminal changed size, and whose
    /// size it now is.
    func sendResize(cols: Int, rows: Int, owner: String, to block: String = "block:front") {
        lock.withLock { dataFeeds[block] }?.yield(Self.frame(
            0x2, Data(Self.resizeMessage(nonce: nonce, cols: cols, rows: rows, owner: owner).utf8)))
    }

    static func resizeMessage(nonce: UInt64, cols: Int, rows: Int, owner: String) -> String {
        "\u{1B}_rex1;\(nonce);"
            + #"{"type":"resize","cols":\#(cols),"rows":\#(rows),"owner":"\#(owner)"}"#
            + "\u{1B}\\"
    }

    func closeData(code: UInt16, reason: String, of block: String = "block:front") {
        let feed = lock.withLock { dataFeeds[block] }
        feed?.yield(Self.frame(
            0x8, Data([UInt8(code >> 8), UInt8(code & 0xFF)]) + Data(reason.utf8)))
        feed?.finish()
    }

    /// Every pipe fails at once, as when the SSH connection under them dies.
    func dropLinks(_ error: Error) {
        let feeds = lock.withLock { [controlFeed] + Array(dataFeeds.values) }
        feeds.forEach { $0?.finish(throwing: error) }
    }

    /// Calls to `method` are recorded as they arrive but go unanswered
    /// until `release` — a link slow enough to act ahead of.
    func hold(_ method: String) {
        lock.withLock { heldMethod = method }
    }

    func release() {
        let held = lock.withLock {
            defer {
                heldMethod = nil
                heldReplies = []
            }
            return heldReplies
        }
        held.forEach { $0() }
    }

    // MARK: Changing the session from a test, as another client would

    func announceOwner(_ owner: String, of block: String) {
        lock.withLock { owners[block] = owner }
        sendEvent("block_owner_changed", ["block_id": block, "owner": owner])
        lock.withLock { events += 1 }
    }

    /// A program exits: its stream closes, its block goes, and — if it was
    /// the last — its window with it.
    func closeBlock(_ block: String) {
        let revision = lock.withLock { () -> Int in
            for index in windows.indices {
                windows[index].tree = windows[index].tree?.removing(block)
                if windows[index].focused == block {
                    windows[index].focused = windows[index].tree?.blocks.first
                }
            }
            windows.removeAll { $0.tree == nil }
            self.revision += 1
            return self.revision
        }
        closeData(code: 4000, reason: "block closed", of: block)
        sendEvent("block_closed", ["block_id": block])
        sendEvent("session_view_changed", ["revision": revision])
    }

    /// Another client splits `anchor`, side by side.
    func addBlock(_ block: String, beside anchor: String, owner: String) {
        let revision = lock.withLock { () -> Int in
            for index in windows.indices {
                windows[index].tree = windows[index].tree?.splitting(
                    anchor, direction: "horizontal", splitID: "split:added", adding: block)
            }
            owners[block] = owner
            self.revision += 1
            return self.revision
        }
        sendEvent("block_created", ["block_id": block])
        sendEvent("block_owner_changed", ["block_id": block, "owner": owner])
        sendEvent("session_view_changed", ["revision": revision])
    }

    func setRatio(_ ratio: Double, ofSplit splitID: String) {
        let revision = lock.withLock { () -> Int in
            for index in windows.indices {
                windows[index].tree = windows[index].tree?.settingRatio(ratio) { _, _, _, id in
                    id == splitID
                }
            }
            self.revision += 1
            return self.revision
        }
        sendEvent("session_view_changed", ["revision": revision])
    }

    private func sendEvent(_ type: String, _ payload: [String: Any]) {
        let event: [String: Any] = [
            "type": "event", "seq": 9,
            "payload": [
                "type": "session_event",
                "payload": [
                    "session_id": "session:0000-aaaaaa",
                    "event": ["type": type, "payload": payload],
                ],
            ],
        ]
        lock.withLock { controlFeed }?.yield(Self.frame(0x1, Self.json(event)))
    }

    // MARK: Frames

    /// An unmasked server frame.
    static func frame(_ opcode: UInt8, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        }
        return frame + payload
    }

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: One pipe

    private final class Connection: @unchecked Sendable {
        private let server: FakeRexServer
        private let feed: AsyncThrowingStream<Data, Error>.Continuation
        private let lock = NSLock()
        private var head = Data()
        private var path: String?
        private var decoder = WebSocketCodec.Decoder()

        init(server: FakeRexServer, feed: AsyncThrowingStream<Data, Error>.Continuation) {
            self.server = server
            self.feed = feed
        }

        func receive(_ bytes: Data) {
            lock.withLock {
                if path == nil {
                    head.append(bytes)
                    guard let end = head.range(of: Data("\r\n\r\n".utf8)) else { return }
                    upgrade(String(decoding: head[..<end.lowerBound], as: UTF8.self))
                    decoder.append(Data(head[end.upperBound...]))
                } else {
                    decoder.append(bytes)
                }
                while let message = try? decoder.next() {
                    handle(message)
                }
            }
        }

        private func upgrade(_ request: String) {
            let lines = request.components(separatedBy: "\r\n")
            let path = String(lines[0].split(separator: " ")[1])
            func header(_ name: String) -> String {
                lines.first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                    .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
                    ?? ""
            }
            self.path = path
            if path == RexWire.controlPath {
                server.lock.withLock { server.controlFeed = feed }
            }
            feed.yield(Data("""
                HTTP/1.1 101 Switching Protocols\r
                Upgrade: websocket\r
                Connection: Upgrade\r
                Sec-Websocket-Accept: \(WebSocketCodec.acceptValue(forKey: header("Sec-WebSocket-Key")))\r
                Sec-Websocket-Protocol: \(header("Sec-WebSocket-Protocol"))\r
                \r

                """.utf8))
        }

        private func handle(_ message: WebSocketCodec.Message) {
            switch message {
            case .close:
                server.lock.withLock { server.recordedCloses.append(path ?? "") }
            case .text(let text) where path == RexWire.controlPath:
                guard let object = (try? JSONSerialization.jsonObject(with: text)) as? [String: Any]
                else { return }
                control(object)
            case .binary(let bytes) where path == RexWire.dataPath:
                dataHello(bytes)
            default:
                break
            }
        }

        private func control(_ message: [String: Any]) {
            if message["type"] as? String == "hello" {
                let client = message["client"] as? [String: Any]
                server.lock.withLock { server.kind = client?["kind"] as? String }
                send([
                    "type": "welcome", "protocol": RexWire.controlSubprotocol,
                    "client": ["id": server.clientID],
                ])
                return
            }
            guard let id = message["id"] as? String, let method = message["method"] as? String
            else { return }
            let payload = message["payload"] as? [String: Any] ?? [:]
            let args = payload["args"] as? [String: Any] ?? [:]
            let block = payload["block_id"] as? String ?? ""
            var record = method
            var result: [String: Any] = [:]
            var error = server.errors[method]
            var after: (() -> Void)?
            switch method {
            case "session.attach":
                result = ["client_id": server.clientID, "view": view()]
            case "session.own_block":
                let ids = payload["block_ids"] as? [String] ?? []
                server.lock.withLock {
                    server.recordedClaims.append(ids)
                    for id in ids { server.owners[id] = server.clientID }
                }
                result = ["blocks": ids.map { ["block_id": $0, "owner": server.clientID] }]
            case "session.disown_block":
                let ids = payload["block_ids"] as? [String] ?? []
                record += " " + ids.sorted().joined(separator: ",")
                result = ["blocks": ids.map { ["block_id": $0] }]
            case "session.view":
                result = view()
            case "session.new_split" where error == nil:
                server.lock.withLock { server.recordedSplits.append(payload) }
                let (new, split, revision) = server.lock.withLock { () -> (String, String, Int) in
                    server.created += 1
                    let new = "block:new\(server.created)"
                    let split = "split:new\(server.created)"
                    let anchor = payload["anchor_id"] as? String ?? ""
                    for index in server.windows.indices {
                        server.windows[index].tree = server.windows[index].tree?.splitting(
                            anchor, direction: payload["direction"] as? String ?? "",
                            splitID: split, adding: new)
                    }
                    // A block's maker owns it from the start.
                    server.owners[new] = server.clientID
                    server.revision += 1
                    return (new, split, server.revision)
                }
                result = [
                    "anchor_id": payload["anchor_id"] ?? "", "block_ids": [new],
                    "split_ids": [split], "revision": revision,
                ]
                after = { [server] in
                    server.sendEvent("block_created", ["block_id": new])
                    server.sendEvent("session_view_changed", ["revision": revision])
                }
            case "session.new_window" where error == nil:
                let (window, new, revision) = server.lock.withLock { () -> (String, String, Int) in
                    server.recordedWindows.append(payload)
                    server.created += 1
                    let window = "window:new\(server.created)"
                    let new = "block:tab\(server.created)"
                    server.windows.append(Window(
                        id: window, label: "three", focused: new, tree: .block(new)))
                    server.owners[new] = server.clientID
                    server.revision += 1
                    return (window, new, server.revision)
                }
                result = ["window_id": window, "block_ids": [new], "revision": revision]
                after = { [server] in
                    server.sendEvent("window_created", ["window_id": window, "label": "three"])
                    server.sendEvent("session_view_changed", ["revision": revision])
                }
            case "session.resize_pane":
                server.lock.withLock { server.recordedRatios.append(payload) }
                let before = payload["before_block_id"] as? String ?? ""
                let behind = payload["after_block_id"] as? String ?? ""
                let direction = payload["direction"] as? String ?? ""
                let ratio = (payload["ratio"] as? NSNumber)?.doubleValue ?? 0.5
                let revision = server.lock.withLock { () -> Int in
                    for index in server.windows.indices {
                        server.windows[index].tree = server.windows[index].tree?
                            .settingRatio(ratio) { first, second, own, _ in
                                own == direction && first.blocks.contains(before)
                                    && second.blocks.contains(behind)
                            }
                    }
                    server.revision += 1
                    return server.revision
                }
                result = ["revision": revision]
                after = { [server] in
                    server.sendEvent("session_view_changed", ["revision": revision])
                }
            case "block.close":
                record += " " + block
                result = [
                    "block_id": block,
                    "revision": server.lock.withLock { server.revision + 1 },
                ]
                after = { [server] in server.closeBlock(block) }
            case "com.superlogical.terminal.process":
                result = ["foreground": ["cwd": "/work/\(block)"], "child": ["cwd": "/home"]]
            case "com.superlogical.terminal.resize":
                let cols = args["columns"] as? Int ?? 0, rows = args["rows"] as? Int ?? 0
                record += " \(cols)x\(rows)"
                server.lock.withLock { server.recordedResizes.append((block, cols, rows)) }
            case "data.connect":
                let ticket = server.lock.withLock { () -> String in
                    server.tickets.append(block)
                    var bytes = [UInt8](repeating: 0, count: 16)
                    bytes[15] = UInt8(server.tickets.count)
                    return Data(bytes).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                }
                result = ["ticket": ticket, "expires_in_ms": 60_000]
            case "com.superlogical.terminal.modes":
                result = ["screen": server.screenKind]
            case "com.superlogical.terminal.format":
                result = ["content": server.screens[block] ?? server.screen]
            case "com.superlogical.terminal.write":
                let text = args["data"] as? String ?? ""
                server.lock.withLock {
                    server.recordedWrites.append(text)
                    server.writeBlock = block
                }
                result = ["bytes_written": text.utf8.count]
            default:
                if error == nil {
                    error = ["code": "method_not_found", "message": method, "status": 404]
                }
            }
            server.lock.withLock { server.recordedCalls.append(record) }
            var response: [String: Any] = ["type": "response", "id": id, "seq": 0]
            if let error { response["error"] = error } else { response["payload"] = result }
            let reply = response
            let answer = { [self] in
                send(reply)
                after?()
            }
            let isHeld = server.lock.withLock {
                guard server.heldMethod == method else { return false }
                server.heldReplies.append(answer)
                return true
            }
            if !isHeld { answer() }
        }

        private func view() -> [String: Any] {
            server.lock.withLock {
                func block(_ id: String) -> [String: Any] {
                    var block: [String: Any] = [
                        "block_id": id, "label": "shell",
                        "creator_name": RexWire.terminalCreator,
                    ]
                    if let owner = server.owners[id] { block["owner"] = owner }
                    return block
                }
                return [
                    "revision": server.revision,
                    "active_window_id": "window:2",
                    "windows": server.windows.map { window -> [String: Any] in
                        [
                            "window_id": window.id, "label": window.label,
                            "focused_block_id": window.focused ?? "",
                            "layers": [[
                                "layer_id": "layer:" + window.id, "kind": "tiled",
                                "layout": window.tree?.json(in: [0, 0, 1, 1]) ?? NSNull(),
                                "blocks": (window.tree?.blocks ?? []).map(block),
                            ] as [String: Any]],
                        ]
                    },
                ]
            }
        }

        private func dataHello(_ bytes: Data) {
            guard bytes.first == 0x01, bytes.count == 17 else { return }
            let index = Int(bytes[bytes.startIndex + 16])
            let block = server.lock.withLock {
                server.tickets.indices.contains(index - 1) ? server.tickets[index - 1] : ""
            }
            if let reason = server.rejectReasons[block] {
                feed.yield(FakeRexServer.frame(0x2, Data([0x82, reason])))
                feed.yield(FakeRexServer.frame(
                    0x8, Data([0x03, 0xF0]) + Data("data handshake rejected".utf8)))
                feed.finish()
                return
            }
            server.lock.withLock { server.dataFeeds[block] = feed }
            var welcome = [UInt8](repeating: 0, count: 32)
            welcome[0] = 0x81
            for index in 0..<8 {
                welcome[24 + index] = UInt8((server.nonce >> (8 * UInt64(index))) & 0xFF)
            }
            feed.yield(FakeRexServer.frame(0x2, Data(welcome)))
            // A snapshot the emulator must never see, the `resize` that ends
            // it, and whatever the program printed straight away.
            let opening = server.openingSizes[block] ?? (100, 30, server.clientID)
            feed.yield(FakeRexServer.frame(
                0x2,
                Data("GHOSTSNP\u{1}\u{0}binary snapshot".utf8)
                    + Data(FakeRexServer.resizeMessage(
                        nonce: server.nonce, cols: opening.cols, rows: opening.rows,
                        owner: opening.owner).utf8)
                    + Data(server.earlyOutput.utf8)))
        }

        private func send(_ object: [String: Any]) {
            feed.yield(FakeRexServer.frame(0x1, FakeRexServer.json(object)))
        }
    }
}
