import XCTest
@testable import Multiplex

/// Server-role harness assembled from the same codec pieces the client
/// uses — enough to drive MoshTransportEngine through real handshakes.
private struct FakeMoshServer {
    var packets: MoshPacketLayer
    var fragmenter = MoshFragmenter()
    var assembly = MoshFragmentAssembly()

    init(key: MoshKey) throws {
        packets = try MoshPacketLayer(key: key, direction: .server)
    }

    mutating func receive(_ datagrams: [Data], now: UInt64) -> [MoshInstruction] {
        var instructions: [MoshInstruction] = []
        for datagram in datagrams {
            guard let opened = packets.open(datagram, now: now),
                  let compressed = assembly.add(opened.payload),
                  let serialized = try? MoshZlib.decompress(compressed),
                  let instruction = MoshInstruction(parsing: serialized)
            else { continue }
            instructions.append(instruction)
        }
        return instructions
    }

    mutating func send(
        old: UInt64, new: UInt64, ack: UInt64,
        diff: Data = Data(), now: UInt64, budget: Int = 1224
    ) -> [Data] {
        var instruction = MoshInstruction()
        instruction.oldNum = old
        instruction.newNum = new
        instruction.ackNum = ack
        instruction.diff = diff
        let compressed = MoshZlib.compress(instruction.encoded())
        return fragmenter.fragments(of: compressed, budget: budget).map {
            packets.seal($0, now: now)
        }
    }
}

final class MoshTransportTests: XCTestCase {
    private let key = MoshKey(base64: "bmCuIRYJHSUF4dcm/qJt2w")!

    private func makePair(
        cols: Int = 120, rows: Int = 40, now: UInt64 = 1000
    ) throws -> (MoshTransportEngine, FakeMoshServer) {
        let engine = try MoshTransportEngine(key: key, cols: cols, rows: rows, budget: 1224, now: now)
        let server = try FakeMoshServer(key: key)
        return (engine, server)
    }

    func testInitialTickSendsTheTerminalSize() throws {
        var (engine, server) = try makePair()

        let (datagrams, _) = engine.tick(now: 1000)
        XCTAssertEqual(datagrams.count, 1)

        let instructions = server.receive(datagrams, now: 1005)
        XCTAssertEqual(instructions.count, 1)
        XCTAssertEqual(instructions[0].protocolVersionField, 2)
        XCTAssertEqual(instructions[0].oldNum, 0)
        XCTAssertEqual(instructions[0].newNum, 1)
        XCTAssertEqual(instructions[0].ackNum, 0)
        XCTAssertEqual(
            MoshUserMessage.decode(instructions[0].diff),
            [.resize(cols: 120, rows: 40)]
        )
    }

    func testUnackedInputRetransmitsUntilAcked() throws {
        var (engine, server) = try makePair()
        _ = engine.tick(now: 1000) // initial resize goes out (and is lost)

        engine.input(Data("ls\r".utf8))
        // A fresh session paces sends (250 ms frame interval until an RTT
        // sample exists) — walk the engine's own deadlines until it fires.
        var sendNow: UInt64 = 1100
        var firstBatch: [MoshInstruction] = []
        while firstBatch.isEmpty, sendNow < 3000 {
            let (datagrams, next) = engine.tick(now: sendNow)
            firstBatch = server.receive(datagrams, now: sendNow)
            if firstBatch.isEmpty { sendNow = next }
        }
        // Cumulative diff: the lost resize rides along with the keystrokes.
        let sent = try XCTUnwrap(firstBatch.first)
        XCTAssertEqual(
            MoshUserMessage.decode(sent.diff),
            [.resize(cols: 120, rows: 40), .keys(Data("ls\r".utf8))]
        )

        // No ack: the same state retransmits after the RTO window.
        var retransmit: [MoshInstruction] = []
        var now = sendNow
        while retransmit.isEmpty, now < 8000 {
            now += 100
            retransmit = server.receive(engine.tick(now: now).datagrams, now: now)
        }
        XCTAssertEqual(retransmit.last?.newNum, sent.newNum)
        XCTAssertEqual(MoshUserMessage.decode(retransmit.last!.diff)?.last, .keys(Data("ls\r".utf8)))

        // Ack lands: nothing further is due until the 3 s heartbeat.
        let acks = server.send(old: 0, new: 1, ack: sent.newNum, now: now + 10)
        for ack in acks { _ = engine.receive(ack, now: now + 20) }
        let (after, deadline) = engine.tick(now: now + 30)
        // The server state we just accepted gets a delayed data-ack…
        let ackInstructions = server.receive(after, now: now + 30)
        XCTAssertTrue(ackInstructions.allSatisfy { MoshUserMessage.decode($0.diff)?.isEmpty ?? true })
        XCTAssertLessThanOrEqual(deadline, now + 30 + 3000)
        // …and after that ack is out, the engine goes quiet.
        var quietNow = now + 30
        for _ in 0 ..< 3 {
            quietNow += 50
            let (more, _) = engine.tick(now: quietNow)
            XCTAssertTrue(server.receive(more, now: quietNow).allSatisfy {
                MoshUserMessage.decode($0.diff)?.isEmpty ?? true
            })
        }
    }

    func testServerDiffFeedsTerminalAndGetsAcked() throws {
        var (engine, server) = try makePair()
        _ = server.receive(engine.tick(now: 1000).datagrams, now: 1000)

        let hostDiff = MoshHostMessage.encode([
            .echoAck(1),
            .hostBytes(Data("hello from tmux".utf8)),
        ])
        let datagrams = server.send(old: 0, new: 1, ack: 1, diff: hostDiff, now: 1050)

        var outputs: [MoshTransportEngine.Output] = []
        for datagram in datagrams {
            outputs += engine.receive(datagram, now: 1060)
        }
        XCTAssertEqual(outputs, [.echoAck(1), .feed(Data("hello from tmux".utf8))])
        XCTAssertEqual(engine.headNum, 1)

        // The session pumps a tick right after receiving (arming the
        // delayed ack), then the data ack goes out within ACK_DELAY.
        let (immediate, deadline) = engine.tick(now: 1060)
        XCTAssertLessThanOrEqual(deadline, 1060 + MoshTransportEngine.ackDelay)
        let (ackDatagrams, _) = engine.tick(now: deadline)
        let acked = server.receive(immediate + ackDatagrams, now: deadline)
        XCTAssertEqual(acked.last?.ackNum, 1)
    }

    func testDuplicateAndStaleServerStatesAreIgnored() throws {
        var (engine, server) = try makePair()
        _ = server.receive(engine.tick(now: 1000).datagrams, now: 1000)

        let diff = MoshHostMessage.encode([.hostBytes(Data("A".utf8))])
        for datagram in server.send(old: 0, new: 1, ack: 1, diff: diff, now: 1010) {
            _ = engine.receive(datagram, now: 1015)
        }
        XCTAssertEqual(engine.headNum, 1)

        // Same state re-sent (server didn't see our ack yet): no re-feed.
        for datagram in server.send(old: 0, new: 1, ack: 1, diff: diff, now: 1020) {
            XCTAssertEqual(engine.receive(datagram, now: 1025), [])
        }
        XCTAssertEqual(engine.headNum, 1)
    }

    func testDiffFromBlankStateResetsTheScreen() throws {
        var (engine, server) = try makePair()
        _ = server.receive(engine.tick(now: 1000).datagrams, now: 1000)

        for datagram in server.send(
            old: 0, new: 2, ack: 1,
            diff: MoshHostMessage.encode([.hostBytes(Data("first".utf8))]), now: 1010
        ) {
            _ = engine.receive(datagram, now: 1015)
        }
        XCTAssertEqual(engine.headNum, 2)

        // Server re-bases from state 0 (recovery): reset precedes the feed.
        var outputs: [MoshTransportEngine.Output] = []
        for datagram in server.send(
            old: 0, new: 9, ack: 1,
            diff: MoshHostMessage.encode([.hostBytes(Data("repaint".utf8))]), now: 1100
        ) {
            outputs += engine.receive(datagram, now: 1105)
        }
        XCTAssertEqual(outputs, [.resetScreen, .feed(Data("repaint".utf8))])
        XCTAssertEqual(engine.headNum, 9)
    }

    func testUnapplicableDiffsTripTheDesyncValve() throws {
        var (engine, server) = try makePair()
        _ = server.receive(engine.tick(now: 1000).datagrams, now: 1000)

        // Diffs based on states we never had (and not on 0): undecodable.
        var now: UInt64 = 1010
        for n in 0 ..< 25 {
            for datagram in server.send(
                old: 40 + UInt64(n), new: 41 + UInt64(n), ack: 1,
                diff: MoshHostMessage.encode([.hostBytes(Data("x".utf8))]), now: now
            ) {
                XCTAssertEqual(engine.receive(datagram, now: now), [])
            }
            now += 300
        }
        XCTAssertTrue(engine.isDesynced(now: now))
    }

    func testHeartbeatKeepsFlowingWhenIdle() throws {
        var (engine, server) = try makePair()
        _ = server.receive(engine.tick(now: 1000).datagrams, now: 1000)
        for datagram in server.send(old: 0, new: 1, ack: 1, now: 1010) {
            _ = engine.receive(datagram, now: 1015)
        }

        // Walk the engine's own deadlines for ~10 s of idle time.
        var now: UInt64 = 1200
        var heartbeats = 0
        for _ in 0 ..< 6 {
            let (datagrams, next) = engine.tick(now: now)
            heartbeats += server.receive(datagrams, now: now).count
            XCTAssertLessThanOrEqual(next - now, MoshTransportEngine.ackInterval + 1)
            now = next
        }
        XCTAssertGreaterThanOrEqual(heartbeats, 2)
    }

    func testClientShutdownHandshake() throws {
        var (engine, server) = try makePair()
        _ = server.receive(engine.tick(now: 1000).datagrams, now: 1000)

        engine.startShutdown(now: 2000)
        let (datagrams, _) = engine.tick(now: 2001)
        let sent = server.receive(datagrams, now: 2005)
        XCTAssertEqual(sent.last?.newNum, .max)
        XCTAssertFalse(engine.shouldClose(now: 2005))

        for datagram in server.send(old: 0, new: 1, ack: .max, now: 2010) {
            _ = engine.receive(datagram, now: 2015)
        }
        XCTAssertTrue(engine.shouldClose(now: 2015))
    }

    func testShutdownWithEmptyDiffDoesNotOverflowNumSpace() throws {
        // Regression: the empty-ack path always passes isNewState: true, so
        // once shutdown queued a uint64.max state, the *next* empty ack
        // computed last.num + 1 and trapped. Reproduce by acking every
        // client state (diff goes empty), then shutting down and pumping
        // past the retry budget — the second shutdown ack is where it blew.
        var (engine, server) = try makePair()
        var now: UInt64 = 1000

        // Fully drain the client: ack whatever state number it last sent, so
        // its diff against the assumed receiver state is empty.
        var lastSent: UInt64 = 0
        for instruction in server.receive(engine.tick(now: now).datagrams, now: now) {
            lastSent = max(lastSent, instruction.newNum)
        }
        for datagram in server.send(old: 0, new: 1, ack: lastSent, now: now + 5) {
            _ = engine.receive(datagram, now: now + 10)
        }

        engine.startShutdown(now: now + 20)
        now += 20
        while !engine.shouldClose(now: now), now < 40000 {
            let (_, next) = engine.tick(now: now) // used to trap on the 2nd pass
            now = max(next, now + 1)
        }
        XCTAssertTrue(engine.shouldClose(now: now))
    }

    func testClientShutdownGivesUpAfterRetries() throws {
        var (engine, _) = try makePair()
        _ = engine.tick(now: 1000)

        engine.startShutdown(now: 2000)
        var now: UInt64 = 2000
        while !engine.shouldClose(now: now), now < 60000 {
            let (_, next) = engine.tick(now: now)
            now = max(next, now + 1)
        }
        // Gave up by the retry budget or the 10 s timeout, not the clock cap.
        XCTAssertTrue(engine.shouldClose(now: now))
        XCTAssertLessThan(now, 2000 + MoshTransportEngine.activeRetryTimeout + 1000)
    }

    func testServerInitiatedShutdownIsAckedAndCloses() throws {
        var (engine, server) = try makePair()
        _ = server.receive(engine.tick(now: 1000).datagrams, now: 1000)

        for datagram in server.send(old: 0, new: .max, ack: 1, now: 1500) {
            _ = engine.receive(datagram, now: 1505)
        }
        XCTAssertTrue(engine.peerInitiatedShutdown)
        XCTAssertFalse(engine.shouldClose(now: 1505))

        let (datagrams, _) = engine.tick(now: 1510)
        let acks = server.receive(datagrams, now: 1515)
        XCTAssertEqual(acks.last?.ackNum, .max)
        XCTAssertTrue(engine.shouldClose(now: 1515))
    }

    func testFragmentedServerInstructionAssembles() throws {
        var (engine, server) = try makePair()
        _ = server.receive(engine.tick(now: 1000).datagrams, now: 1000)

        // Incompressible payload forces several fragments at budget 200.
        let bytes = Data((0 ..< 3000).map { _ in UInt8.random(in: .min ... .max) })
        let datagrams = server.send(
            old: 0, new: 1, ack: 1,
            diff: MoshHostMessage.encode([.hostBytes(bytes)]),
            now: 1010, budget: 200
        )
        XCTAssertGreaterThan(datagrams.count, 1)

        var outputs: [MoshTransportEngine.Output] = []
        for datagram in datagrams {
            outputs += engine.receive(datagram, now: 1015)
        }
        XCTAssertEqual(outputs, [.feed(bytes)])
    }

    func testQuietTracksServerSilence() throws {
        var (engine, server) = try makePair()
        _ = server.receive(engine.tick(now: 1000).datagrams, now: 1000)
        for datagram in server.send(old: 0, new: 1, ack: 1, now: 1010) {
            _ = engine.receive(datagram, now: 1020)
        }
        XCTAssertEqual(engine.quiet(now: 7020), 6000)
    }
}
