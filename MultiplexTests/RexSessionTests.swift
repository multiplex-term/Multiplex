import XCTest
@testable import Multiplex

/// `RexSession` end to end against an in-process Rex server: every byte
/// goes through the real WebSocket codec and wire formats, only the SSH
/// pipes are replaced. What this pins is ORDER — the part of the attach
/// that is load-bearing and that no pure test can see.
final class RexSessionTests: XCTestCase {
    private let sessionID = "session:0000-aaaaaa"

    private func makeSession(
        _ server: FakeRexServer, blockID: String? = nil
    ) -> RexSession {
        RexSession(
            openPipe: { server.makePipe() },
            closeLink: { server.note("link closed") },
            sessionID: sessionID, blockID: blockID, clientVersion: "test"
        )
    }

    /// Collects what the session hands the terminal and when it ends.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []
        private var closes: [String?] = []

        func data(_ chunk: Data) { lock.withLock { chunks.append(chunk) } }
        /// The emulator's grid changing hands, in line with what is drawn.
        func grid(_ grid: TerminalGrid?) {
            let text = grid.map { "GRID \($0.cols)x\($0.rows)" } ?? "GRID own"
            lock.withLock { chunks.append(Data(text.utf8)) }
        }
        func closed(_ reason: String?) { lock.withLock { closes.append(reason) } }
        var text: [String] { lock.withLock { chunks.map { String(decoding: $0, as: UTF8.self) } } }
        var closeReasons: [String?] { lock.withLock { closes } }
    }

    private func open(
        _ session: RexSession, sink: Sink, cols: Int = 100, rows: Int = 30
    ) async throws {
        try await session.open(
            cols: cols, rows: rows,
            onData: { sink.data($0) },
            onClose: { sink.closed($0) },
            onGrid: { sink.grid($0) }
        )
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
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
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
        // The fronted block was chosen: active window, focused block.
        XCTAssertEqual(server.attachedBlock, "block:front")
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
        XCTAssertEqual(sink.text, ["\u{1B}cSCREEN", "early\r\n"])

        server.sendOutput("later\r\n")
        await eventually { sink.text.count == 3 }
        XCTAssertEqual(sink.text.last, "later\r\n")
        await session.close()
    }

    func testANamedBlockIsAttachedWhileItExists() async throws {
        let server = FakeRexServer()
        let session = makeSession(server, blockID: "block:other")
        try await open(session, sink: Sink())
        XCTAssertEqual(server.attachedBlock, "block:other")
        await session.close()

        // One that has since closed falls back to the fronted block.
        let fallback = FakeRexServer()
        let second = makeSession(fallback, blockID: "block:gone")
        try await open(second, sink: Sink())
        XCTAssertEqual(fallback.attachedBlock, "block:front")
        await second.close()
    }

    // MARK: - Switching terminals

    func testTheSwitchListNamesEveryTerminalAndMarksTheOneOnShow() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())
        let listed = await session.terminalChoices()
        let choices = try XCTUnwrap(listed)
        XCTAssertEqual(choices.map(\.tmuxID), ["block:other", "block:side", "block:front"])
        XCTAssertEqual(choices.map(\.isActive), [false, false, true])
        XCTAssertEqual(choices.map(\.name), ["one — shell", "two — shell", "two — shell"])
        await session.close()
    }

    func testSwitchingRedrawsTheTabOnTheOtherTerminalWithoutEndingIt() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        let attachCalls = server.calls.count

        server.screen = "OTHER"
        await session.switchBlock(to: "block:other")

        // The old stream was closed properly, the old block given up, and
        // the new one claimed, sized, streamed and drawn — the attach's own
        // order, on the same control connection.
        XCTAssertEqual(server.closeFramesReceived, [RexWire.dataPath])
        let switchCalls = Array(server.calls.dropFirst(attachCalls))
        XCTAssertEqual(Array(switchCalls.prefix(4)), [
            "session.disown_block block:front",
            "session.own_block",
            "com.superlogical.terminal.resize 100x30",
            "data.connect",
        ])
        XCTAssertEqual(switchCalls.dropFirst(4).sorted(), Self.screenReads)
        XCTAssertEqual(server.attachedBlock, "block:other")
        XCTAssertEqual(sink.text, ["\u{1B}cSCREEN", "\u{1B}cOTHER"])
        // The retired stream ending is NOT the tab ending.
        XCTAssertTrue(sink.closeReasons.isEmpty)

        // The tab is live on the new terminal: output flows and typing
        // goes to it.
        server.sendOutput("from other\r\n")
        await eventually { sink.text.last == "from other\r\n" }
        try await session.write(Data("x".utf8))
        await eventually {
            server.written == ["x"]
                && server.calls.last == "com.superlogical.terminal.write"
        }
        XCTAssertEqual(server.lastWriteBlock, "block:other")
        let listed = await session.terminalChoices()
        let choices = try XCTUnwrap(listed)
        XCTAssertEqual(choices.map(\.isActive), [true, false, false])

        // Switching to the terminal already on show does nothing.
        let before = server.calls.count
        await session.switchBlock(to: "block:other")
        XCTAssertEqual(server.calls.count, before)
        await session.close()
    }

    func testTheWorkingDirectoryFollowsTheTerminalOnShow() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())
        let front = await session.workingDirectory()
        XCTAssertEqual(front, "/work/block:front")
        await session.switchBlock(to: "block:other")
        let other = await session.workingDirectory()
        XCTAssertEqual(other, "/work/block:other")
        await session.close()
        // A closed tab has no answer — the $HOME fallback.
        let closed = await session.workingDirectory()
        XCTAssertNil(closed)
    }

    // MARK: - Typing and sizing

    func testTypingReachesTheBlockInOrderAsText() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())

        try await session.write(Data("ls\r".utf8))
        // A character split across two writes is sent whole.
        let wide = Data("測".utf8)
        try await session.write(wide.prefix(2))
        try await session.write(wide.suffix(1))
        try await session.write(Data([0x1B, 0x5B, 0x41]))
        // A write queues and returns, so how the four were grouped into
        // calls is timing. What is not: every byte once, in order, and no
        // call carrying half a character.
        await eventually { server.written.joined() == "ls\r測\u{1B}[A" }
        XCTAssertFalse(server.written.contains { $0.contains("\u{FFFD}") })

        try await session.resize(cols: 120, rows: 40)
        XCTAssertEqual(server.calls.last, "com.superlogical.terminal.resize 120x40")
        await session.close()
    }

    func testWhatIsTypedWhileAWriteIsInFlightRidesTheNextOneTogether() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())

        // The server sits on its answers, as a slow link does.
        server.holdWriteReplies()
        try await session.write(Data("a".utf8))
        await eventually { server.written == ["a"] }
        // None of these waits for "a" to be answered...
        try await session.write(Data("b".utf8))
        try await session.write(Data("c".utf8))
        try await session.write(Data("d".utf8))
        XCTAssertEqual(server.written, ["a"])

        // ...and once it is, they go as one call, not three round trips.
        server.releaseWriteReplies()
        await eventually { server.written == ["a", "bcd"] }
        await session.close()
    }

    func testTypingClaimsTheBlockBackAfterAnotherClientTookIt() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        try await open(session, sink: Sink())
        let before = server.calls.filter { $0 == "session.own_block" }.count

        // While this tab owns the block, typing claims nothing.
        try await session.write(Data("a".utf8))
        await eventually { server.written == ["a"] }
        XCTAssertEqual(server.calls.filter { $0 == "session.own_block" }.count, before)

        // The Rex app takes the block; the next keystroke takes it back and
        // re-sizes it — the last client to type owns the size.
        server.announceOwner("client:rex-app")
        await eventually { server.eventsDelivered == 1 }
        try await Task.sleep(for: .milliseconds(150))
        try await session.write(Data("b".utf8))
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

    // MARK: - Another client's size

    func testAnotherClientsSizeIsGivenToTheEmulatorBeforeTheScreenIsDrawnAgain() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        XCTAssertEqual(sink.text, ["\u{1B}cSCREEN"])

        // The Rex app takes the terminal at its own size, and the program
        // repaints for it straight away.
        server.screen = "WIDE"
        server.sendResize(cols: 170, rows: 50, owner: "client:rex-app")
        server.sendOutput("REPAINT")
        await eventually { sink.text.last == "\u{1B}cWIDE" }
        // The grid first, then the screen at it — and the repaint, which
        // arrived before the rendering was asked for and so is in it, is
        // not drawn a second time on top.
        XCTAssertEqual(sink.text, ["\u{1B}cSCREEN", "GRID 170x50", "\u{1B}cWIDE"])
        // Following is all it does: the size is not asked back.
        XCTAssertEqual(server.calls.filter { $0 == "session.own_block" }.count, 1)
        XCTAssertEqual(
            server.calls.filter { $0.hasPrefix("com.superlogical.terminal.resize") }.count, 1)

        server.sendOutput("later")
        await eventually { sink.text.last == "later" }

        // Typing here takes the terminal back; the stream then says it is
        // this tab's size again and the emulator returns to its own grid.
        server.screen = "OWN"
        server.sendResize(cols: 100, rows: 30, owner: server.clientID)
        await eventually { sink.text.last == "\u{1B}cOWN" }
        XCTAssertEqual(Array(sink.text.suffix(2)), ["GRID own", "\u{1B}cOWN"])
        await session.close()
    }

    func testThisTabsOwnResizesNeverMoveTheEmulatorsGrid() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        // A window drag: the stream reports sizes this client set, some of
        // them already overtaken by the next one.
        try await session.resize(cols: 120, rows: 40)
        server.sendResize(cols: 110, rows: 35, owner: server.clientID)
        server.sendResize(cols: 120, rows: 40, owner: server.clientID)
        // Another client that happens to want this tab's size changes
        // nothing either.
        server.sendResize(cols: 120, rows: 40, owner: "client:rex-app")
        server.sendOutput("after")
        await eventually { sink.text.last == "after" }
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(sink.text, ["\u{1B}cSCREEN", "after"])
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
        await eventually { sink.text.count == 2 }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(sink.text, ["\u{1B}cSCREEN", "\u{1B}cBACK"])
        XCTAssertEqual(
            server.calls.filter { $0 == "com.superlogical.terminal.format" }.count, 2)
        await session.close()
    }

    func testATerminalAlreadyAtAnotherClientsSizeIsAttachedAtThatGrid() async throws {
        let server = FakeRexServer()
        // The claim did not hold: by the time the stream opens the Rex app
        // has the terminal again.
        server.openingSize = (170, 50, "client:rex-app")
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        XCTAssertEqual(sink.text, ["GRID 170x50", "\u{1B}cSCREEN"])
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
        XCTAssertEqual(sink.text, ["\u{1B}cVIM"])

        // The program leaves the alternate screen; the server can now
        // render the shell history that was underneath.
        server.screenKind = "primary"
        server.screen = "HISTORY"
        server.sendOutput("\u{1B}[?1049l$ ")
        await eventually { sink.text.last == "\u{1B}cHISTORY" }
        // The exit burst passed through, then ONE redraw replaced it.
        XCTAssertEqual(sink.text, ["\u{1B}cVIM", "\u{1B}[?1049l$ ", "\u{1B}cHISTORY"])
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

    func testABlockClosingEndsTheTabCleanlyAndSaysGoodbye() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)

        server.closeData(code: 4000, reason: "block closed")
        await eventually { !sink.closeReasons.isEmpty }
        // 4000 is a clean end — like a shell exiting, not an error.
        XCTAssertEqual(sink.closeReasons, [nil])
        // The control connection got a close frame, so the server ends the
        // client at once instead of keeping it "connection lost" a minute.
        await eventually { server.closeFramesReceived.contains(RexWire.controlPath) }
        await session.close()
        XCTAssertEqual(server.notes, ["link closed"])
    }

    func testClosingTheTabClosesTheStreamBeforeTheControlConnection() async throws {
        let server = FakeRexServer()
        let session = makeSession(server)
        let sink = Sink()
        try await open(session, sink: sink)
        await session.close()

        // Data first, with status 1000 (which ends the stream), then control.
        XCTAssertEqual(server.closeFramesReceived, [RexWire.dataPath, RexWire.controlPath])
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
        let server = FakeRexServer()
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
            try await session.write(Data("x".utf8))
            XCTFail("a dead tab accepted input")
        } catch {}
        await session.close()
    }

    // MARK: - Failing to attach

    func testASessionThatIsGoneFailsTheOpenWithAReadableReason() async {
        let server = FakeRexServer()
        server.attachError = ["code": "session_not_found", "message": "no such session", "status": 404]
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
        XCTAssertTrue(sink.text.isEmpty)
        await session.close()
    }

    func testASessionWithNoTerminalAndARefusedStreamBothFailTheOpen() async {
        let empty = FakeRexServer()
        empty.hasTerminals = false
        do {
            try await open(makeSession(empty), sink: Sink())
            XCTFail("the open should have thrown")
        } catch {
            XCTAssertEqual(
                (error as? RexSession.Failure)?.message,
                "This Rex session has no terminal to open.")
        }

        let refusing = FakeRexServer()
        refusing.rejectReason = 0x02
        do {
            try await open(makeSession(refusing), sink: Sink())
            XCTFail("the open should have thrown")
        } catch {
            XCTAssertEqual(
                (error as? RexSession.Failure)?.message.contains(
                    "another connection already has this terminal"),
                true)
        }
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
}

// MARK: - The in-process server

/// A Rex server small enough to read: it answers the upgrade, the hello,
/// and the handful of methods an attach makes, and it streams what a test
/// tells it to. One instance serves both of a session's pipes.
private final class FakeRexServer: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedWrites: [String] = []
    private var recordedNotes: [String] = []
    private var recordedCloses: [String] = []
    private var kind: String?
    private var block: String?
    private var writeBlock: String?
    private var events = 0
    private var controlFeed: AsyncThrowingStream<Data, Error>.Continuation?
    private var dataFeed: AsyncThrowingStream<Data, Error>.Continuation?
    /// nil while write calls are answered as they arrive; otherwise the
    /// answers a test is sitting on.
    private var heldWriteReplies: [() -> Void]?

    // What a test configures before the attach.
    var attachError: [String: Any]?
    var hasTerminals = true
    var rejectReason: UInt8?
    var earlyOutput = ""
    var screen = "SCREEN"
    var screenKind = "primary"
    /// The size the stream opens by stating, and whose it is.
    var openingSize: (cols: Int, rows: Int, owner: String) = (100, 30, "client:me")
    let nonce: UInt64 = 0x1122_3344_5566_7788
    let clientID = "client:me"

    var calls: [String] { lock.withLock { recordedCalls } }
    var written: [String] { lock.withLock { recordedWrites } }
    var notes: [String] { lock.withLock { recordedNotes } }
    var closeFramesReceived: [String] { lock.withLock { recordedCloses } }
    var helloKind: String? { lock.withLock { kind } }
    var attachedBlock: String? { lock.withLock { block } }
    var lastWriteBlock: String? { lock.withLock { writeBlock } }
    var eventsDelivered: Int { lock.withLock { events } }

    func note(_ text: String) { lock.withLock { recordedNotes.append(text) } }

    func makePipe() -> RemotePipe {
        let (stream, feed) = AsyncThrowingStream<Data, Error>.makeStream()
        let connection = Connection(server: self, feed: feed)
        return RemotePipe(
            incoming: stream,
            write: { connection.receive($0) },
            close: { feed.finish() }
        )
    }

    // MARK: Driving the stream from a test

    func sendOutput(_ text: String) {
        lock.withLock { dataFeed }?.yield(Self.frame(0x2, Data(text.utf8)))
    }

    /// The stream's own word that the terminal changed size, and whose
    /// size it now is.
    func sendResize(cols: Int, rows: Int, owner: String) {
        lock.withLock { dataFeed }?.yield(Self.frame(
            0x2, Data(Self.resizeMessage(nonce: nonce, cols: cols, rows: rows, owner: owner).utf8)))
    }

    static func resizeMessage(nonce: UInt64, cols: Int, rows: Int, owner: String) -> String {
        "\u{1B}_rex1;\(nonce);"
            + #"{"type":"resize","cols":\#(cols),"rows":\#(rows),"owner":"\#(owner)"}"#
            + "\u{1B}\\"
    }

    func closeData(code: UInt16, reason: String) {
        let feed = lock.withLock { dataFeed }
        feed?.yield(Self.frame(
            0x8, Data([UInt8(code >> 8), UInt8(code & 0xFF)]) + Data(reason.utf8)))
        feed?.finish()
    }

    /// Both pipes fail at once, as when the SSH connection under them dies.
    func dropLinks(_ error: Error) {
        let feeds = lock.withLock { [controlFeed, dataFeed] }
        feeds.forEach { $0?.finish(throwing: error) }
    }

    /// Write calls are recorded as they arrive but go unanswered until
    /// `releaseWriteReplies` — a link slow enough to type ahead of.
    func holdWriteReplies() {
        lock.withLock { heldWriteReplies = [] }
    }

    func releaseWriteReplies() {
        let held = lock.withLock {
            defer { heldWriteReplies = nil }
            return heldWriteReplies ?? []
        }
        held.forEach { $0() }
    }

    func announceOwner(_ owner: String) {
        let event: [String: Any] = [
            "type": "event", "seq": 9,
            "payload": [
                "type": "session_event",
                "payload": [
                    "session_id": "session:0000-aaaaaa",
                    "event": [
                        "type": "block_owner_changed",
                        "payload": ["block_id": attachedBlock ?? "", "owner": owner],
                    ],
                ],
            ],
        ]
        lock.withLock { controlFeed }?.yield(Self.frame(0x1, Self.json(event)))
        lock.withLock { events += 1 }
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
            } else {
                server.lock.withLock { server.dataFeed = feed }
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
            var record = method
            var result: [String: Any] = [:]
            var error: [String: Any]?
            switch method {
            case "session.attach":
                error = server.attachError
                result = ["client_id": server.clientID, "view": view()]
            case "session.own_block":
                let ids = payload["block_ids"] as? [String] ?? []
                server.lock.withLock { server.block = ids.first }
                result = ["blocks": ids.map { ["block_id": $0, "owner": server.clientID] }]
            case "session.disown_block":
                let ids = payload["block_ids"] as? [String] ?? []
                record += " " + ids.joined(separator: ",")
                result = ["blocks": ids.map { ["block_id": $0] }]
            case "session.view":
                result = view()
            case "com.superlogical.terminal.process":
                let id = payload["block_id"] as? String ?? ""
                result = ["foreground": ["cwd": "/work/\(id)"], "child": ["cwd": "/home"]]
            case "com.superlogical.terminal.resize":
                record += " \(args["columns"] as? Int ?? 0)x\(args["rows"] as? Int ?? 0)"
            case "data.connect":
                result = ["ticket": "AAECAwQFBgcICQoLDA0ODw", "expires_in_ms": 60_000]
            case "com.superlogical.terminal.modes":
                result = ["screen": server.screenKind]
            case "com.superlogical.terminal.format":
                result = ["content": server.screen]
            case "com.superlogical.terminal.write":
                let text = args["data"] as? String ?? ""
                server.lock.withLock {
                    server.recordedWrites.append(text)
                    server.writeBlock = payload["block_id"] as? String
                }
                result = ["bytes_written": text.utf8.count]
            default:
                error = ["code": "method_not_found", "message": method, "status": 404]
            }
            server.lock.withLock { server.recordedCalls.append(record) }
            var response: [String: Any] = ["type": "response", "id": id, "seq": 0]
            if let error { response["error"] = error } else { response["payload"] = result }
            let reply = response
            let isHeld = method == "com.superlogical.terminal.write" && server.lock.withLock {
                guard server.heldWriteReplies != nil else { return false }
                server.heldWriteReplies?.append { [self] in send(reply) }
                return true
            }
            if !isHeld { send(response) }
        }

        private func view() -> [String: Any] {
            guard server.hasTerminals else { return ["windows": [[String: Any]]()] }
            func block(_ id: String) -> [String: Any] {
                ["block_id": id, "label": "shell", "creator_name": RexWire.terminalCreator]
            }
            return [
                "active_window_id": "window:2",
                "windows": [
                    [
                        "window_id": "window:1", "label": "one",
                        "focused_block_id": "block:other",
                        "layers": [["blocks": [block("block:other")]]],
                    ],
                    [
                        "window_id": "window:2", "label": "two",
                        "focused_block_id": "block:front",
                        "layers": [["blocks": [block("block:side"), block("block:front")]]],
                    ],
                ],
            ]
        }

        private func dataHello(_ bytes: Data) {
            guard bytes.first == 0x01, bytes.count == 17 else { return }
            if let reason = server.rejectReason {
                feed.yield(FakeRexServer.frame(0x2, Data([0x82, reason])))
                feed.yield(FakeRexServer.frame(
                    0x8, Data([0x03, 0xF0]) + Data("data handshake rejected".utf8)))
                feed.finish()
                return
            }
            var welcome = [UInt8](repeating: 0, count: 32)
            welcome[0] = 0x81
            for index in 0..<8 {
                welcome[24 + index] = UInt8((server.nonce >> (8 * UInt64(index))) & 0xFF)
            }
            feed.yield(FakeRexServer.frame(0x2, Data(welcome)))
            // A snapshot the emulator must never see, the `resize` that ends
            // it, and whatever the program printed straight away.
            let opening = server.openingSize
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
