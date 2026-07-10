import XCTest
@testable import Multiplex

final class MoshPacketTests: XCTestCase {
    private let key = MoshKey(base64: "bmCuIRYJHSUF4dcm/qJt2w")!

    func testClientToServerRoundTrip() throws {
        var client = try MoshPacketLayer(key: key, direction: .client)
        var server = try MoshPacketLayer(key: key, direction: .server)

        let first = client.seal(Data("one".utf8), now: 1000)
        let opened = server.open(first, now: 1010)
        XCTAssertEqual(opened?.payload, Data("one".utf8))
        XCTAssertEqual(opened?.isNew, true)

        let second = client.seal(Data("two".utf8), now: 1020)
        XCTAssertEqual(server.open(second, now: 1030)?.isNew, true)
    }

    func testReplayedDatagramIsStaleButStillDelivered() throws {
        var client = try MoshPacketLayer(key: key, direction: .client)
        var server = try MoshPacketLayer(key: key, direction: .server)

        let datagram = client.seal(Data("hi".utf8), now: 0)
        XCTAssertEqual(server.open(datagram, now: 5)?.isNew, true)

        let replay = server.open(datagram, now: 10)
        XCTAssertEqual(replay?.payload, Data("hi".utf8))
        XCTAssertEqual(replay?.isNew, false)
    }

    func testReorderedDatagramIsStale() throws {
        var client = try MoshPacketLayer(key: key, direction: .client)
        var server = try MoshPacketLayer(key: key, direction: .server)

        let a = client.seal(Data("a".utf8), now: 0)
        let b = client.seal(Data("b".utf8), now: 5)
        XCTAssertEqual(server.open(b, now: 10)?.isNew, true)
        XCTAssertEqual(server.open(a, now: 15)?.isNew, false)
    }

    func testReflectedAndTamperedDatagramsAreRejected() throws {
        var client = try MoshPacketLayer(key: key, direction: .client)
        var otherClient = try MoshPacketLayer(key: key, direction: .client)
        var server = try MoshPacketLayer(key: key, direction: .server)

        // A client must not accept client-direction packets (reflection).
        let clientPacket = client.seal(Data("x".utf8), now: 0)
        XCTAssertNil(otherClient.open(clientPacket, now: 0))

        var tampered = clientPacket
        tampered[tampered.count - 1] ^= 0x40
        XCTAssertNil(server.open(tampered, now: 0))

        XCTAssertNil(server.open(Data(repeating: 0, count: 10), now: 0)) // runt
    }

    func testTimestampEchoProducesRTTSample() throws {
        var client = try MoshPacketLayer(key: key, direction: .client)
        var server = try MoshPacketLayer(key: key, direction: .server)

        // Fresh layers report mosh's seeded worst-case RTO.
        XCTAssertEqual(client.rto, 1000)

        // Client stamps t=1000; server holds it 50 ms and echoes advanced.
        let request = client.seal(Data("ping".utf8), now: 1000)
        XCTAssertNotNil(server.open(request, now: 1030))
        let reply = server.seal(Data("pong".utf8), now: 1080)

        // Client sees the reply at t=1100: sample = 1100 − (1000+50) = 50.
        XCTAssertNotNil(client.open(reply, now: 1100))
        XCTAssertEqual(client.srtt, 50)
        XCTAssertEqual(client.rttvar, 25)
        XCTAssertEqual(client.rto, 150)
    }

    func testEachReceivedTimestampIsEchoedAtMostOnce() throws {
        var client = try MoshPacketLayer(key: key, direction: .client)
        var server = try MoshPacketLayer(key: key, direction: .server)

        XCTAssertNotNil(server.open(client.seal(Data(), now: 1000), now: 1000))
        _ = server.seal(Data(), now: 1010) // consumes the saved timestamp

        // The next server packet has no timestamp to echo, so the client
        // must not derive a (bogus) RTT sample from it.
        let second = server.seal(Data(), now: 1020)
        XCTAssertNotNil(client.open(second, now: 1030))
        XCTAssertEqual(client.rto, 1000) // still the seeded default
    }
}
