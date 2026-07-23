import XCTest
@testable import Multiplex

/// In-process only: one end of a socketpair stands in for the tailscale
/// fd, a plain TCP client stands in for Citadel. Reads are poll-bounded so
/// a broken relay fails fast instead of hanging the suite.
final class TailscaleLoopbackRelayTests: XCTestCase {
    private func makeSocketPair() throws -> (relayEnd: CInt, testEnd: CInt) {
        var pair: [CInt] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw XCTSkip("socketpair failed (errno \(errno))")
        }
        return (pair[0], pair[1])
    }

    private func connectClient(port: UInt16) -> CInt {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    /// Reads exactly `count` bytes with a 2 s poll bound per chunk.
    private func read(_ fd: CInt, count: Int) -> [UInt8] {
        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: count)
        while collected.count < count {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 2000) > 0 else { return collected }
            let n = Darwin.read(fd, &buffer, count - collected.count)
            guard n > 0 else { return collected }
            collected.append(contentsOf: buffer[0..<n])
        }
        return collected
    }

    /// True when the fd reports EOF (readable with a zero-byte read)
    /// within 2 s.
    private func reachesEOF(_ fd: CInt) -> Bool {
        var byte: UInt8 = 0
        for _ in 0..<20 {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pollFD, 1, 100) > 0 {
                let n = Darwin.read(fd, &byte, 1)
                if n == 0 { return true }
                if n < 0 { return true }
            }
        }
        return false
    }

    func testRoundTripBothDirectionsThenEOFPropagates() throws {
        let (relayEnd, testEnd) = try makeSocketPair()
        defer { close(testEnd) }
        let relay = TailscaleLoopbackRelay()
        let port = try relay.start(spliceTo: relayEnd)

        let client = connectClient(port: port)
        XCTAssertGreaterThanOrEqual(client, 0)

        let toRemote: [UInt8] = Array("hello".utf8)
        XCTAssertEqual(toRemote.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }, 5)
        XCTAssertEqual(read(testEnd, count: 5), toRemote)

        let toClient: [UInt8] = Array("world".utf8)
        XCTAssertEqual(toClient.withUnsafeBytes { write(testEnd, $0.baseAddress, $0.count) }, 5)
        XCTAssertEqual(read(client, count: 5), toClient)

        close(client)
        XCTAssertTrue(reachesEOF(testEnd), "client close should reach the spliced fd as EOF")
    }

    func testSecondConnectIsRefusedAfterOneShotAccept() throws {
        let (relayEnd, testEnd) = try makeSocketPair()
        defer { close(testEnd) }
        let relay = TailscaleLoopbackRelay()
        let port = try relay.start(spliceTo: relayEnd)

        let first = connectClient(port: port)
        XCTAssertGreaterThanOrEqual(first, 0)
        defer { close(first) }

        // A round-trip proves the accept has happened (and therefore the
        // listener is closed) before the second attempt.
        let probe: [UInt8] = [0x2A]
        XCTAssertEqual(probe.withUnsafeBytes { write(first, $0.baseAddress, 1) }, 1)
        XCTAssertEqual(read(testEnd, count: 1), probe)

        let second = connectClient(port: port)
        if second >= 0 { close(second) }
        XCTAssertEqual(second, -1, "the one-shot listener must be gone after the first accept")
    }

    func testCloseBeforeAcceptReleasesSplicedFD() throws {
        let (relayEnd, testEnd) = try makeSocketPair()
        defer { close(testEnd) }
        let relay = TailscaleLoopbackRelay()
        _ = try relay.start(spliceTo: relayEnd)

        relay.close()
        XCTAssertTrue(reachesEOF(testEnd), "close() before any accept must close the spliced fd")
    }

    func testStartAfterCloseThrowsAndClosesFD() throws {
        let (relayEnd, testEnd) = try makeSocketPair()
        defer { close(testEnd) }
        let relay = TailscaleLoopbackRelay()
        relay.close()
        XCTAssertThrowsError(try relay.start(spliceTo: relayEnd))
        XCTAssertTrue(reachesEOF(testEnd))
    }
}
