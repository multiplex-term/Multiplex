import NIOCore
import NIOEmbedded
import XCTest
@testable import Multiplex

/// The host route's tunnel must not buffer without bound: a side stops
/// reading while its partner is full, and resumes when the partner drains.
final class AgentProxySpliceTests: XCTestCase {
    /// Counts the reads that make it past the splice to the channel.
    private final class ReadCounter: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        var reads = 0

        func read(context: ChannelHandlerContext) {
            reads += 1
            context.read()
        }
    }

    func testReadsWaitWhileThePartnerIsFullAndResumeWhenItDrains() throws {
        let device = EmbeddedChannel()
        let host = EmbeddedChannel()
        let (fromDevice, fromHost) = AgentProxySplice.pair(device, host)
        let counter = ReadCounter()
        try device.pipeline.syncOperations.addHandlers([counter, fromDevice])
        try host.pipeline.syncOperations.addHandler(fromHost)

        device.read()
        XCTAssertEqual(counter.reads, 1, "partner writable: the read goes through")

        host.isWritable = false
        device.read()
        XCTAssertEqual(counter.reads, 1, "partner full: the read is held")

        host.isWritable = true
        host.pipeline.fireChannelWritabilityChanged()
        device.embeddedEventLoop.run()
        XCTAssertEqual(counter.reads, 2, "partner drained: the held read is granted")

        // An idle side does not get a spurious read on the next drain.
        host.pipeline.fireChannelWritabilityChanged()
        device.embeddedEventLoop.run()
        XCTAssertEqual(counter.reads, 2)
    }

    func testBytesCrossAndAnEndClosesThePartner() throws {
        let device = EmbeddedChannel()
        let host = EmbeddedChannel()
        let (fromDevice, fromHost) = AgentProxySplice.pair(device, host)
        try device.pipeline.syncOperations.addHandler(fromDevice)
        try host.pipeline.syncOperations.addHandler(fromHost)

        try device.writeInbound(ByteBuffer(string: "GET / HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(try host.readOutbound(as: ByteBuffer.self), ByteBuffer(string: "GET / HTTP/1.1\r\n\r\n"))
        try host.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\n\r\n"))
        XCTAssertEqual(try device.readOutbound(as: ByteBuffer.self), ByteBuffer(string: "HTTP/1.1 200 OK\r\n\r\n"))

        try host.close().wait()
        device.embeddedEventLoop.run()
        XCTAssertFalse(device.isActive, "the host side ended; the device side follows")
    }
}
