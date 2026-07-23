import Darwin
import Dispatch
import Foundation
import os

/// One-shot localhost TCP relay between Citadel and an already-connected
/// socket (the `tailscale_dial` socketpair end). Citadel 0.12.0's
/// channel-injection overload cannot be called off the event loop — its
/// synchronous prefix asserts `inEventLoop` (NIOCore
/// ChannelPipeline.swift:1208) — and pinning the calling Task to the loop
/// needs iOS 18, above the app's floor. So Citadel dials
/// `127.0.0.1:<port>` through its wholly ordinary bootstrap (handlers
/// installed on-loop by its own initializer) and this relay splices that
/// connection onto the remote fd.
///
/// iOS loopback is reachable cross-app, so the listener accepts exactly
/// ONE connection and closes immediately; a peer that never connects is
/// bounded by the accept poll timeout. The relay stays alive by
/// self-retention in its queue work items and tears itself down on EOF
/// from either side — the SSH client closing its localhost socket is what
/// releases the tailscale fd, so callers don't need to hold a reference.
final class TailscaleLoopbackRelay: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "tailscale"
    )
    private static let acceptTimeoutMilliseconds: Int32 = 10_000
    private static let pumpBufferSize = 64 * 1024

    private let queue = DispatchQueue(
        label: "app.multiplexterm.multiplex.tailscale.relay",
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var listenerFD: CInt = -1
    private var remoteFD: CInt = -1
    private var acceptedFD: CInt = -1
    private var wakePipe: (read: CInt, write: CInt) = (-1, -1)
    private var finishedPumps = 0
    private var isClosed = false

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Takes ownership of `remoteFD` unconditionally: on throw it has been
    /// closed, on success the relay closes it when the splice ends.
    func start(spliceTo remoteFD: CInt) throws -> UInt16 {
        guard lock.withLock({ !isClosed }) else {
            Darwin.close(remoteFD)
            throw Failure(message: "Relay already closed.")
        }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else {
            Darwin.close(remoteFD)
            throw Failure(message: "Relay socket creation failed (errno \(errno)).")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(listener, 1) == 0 else {
            Darwin.close(listener)
            Darwin.close(remoteFD)
            throw Failure(message: "Relay bind/listen failed (errno \(errno)).")
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(listener)
            Darwin.close(remoteFD)
            throw Failure(message: "Relay port lookup failed (errno \(errno)).")
        }
        let port = UInt16(bigEndian: bound.sin_port)

        var pipeFDs: [CInt] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            Darwin.close(listener)
            Darwin.close(remoteFD)
            throw Failure(message: "Relay wake pipe failed (errno \(errno)).")
        }

        lock.withLock {
            self.listenerFD = listener
            self.remoteFD = remoteFD
            self.wakePipe = (pipeFDs[0], pipeFDs[1])
        }

        queue.async { self.acceptOnce() }
        Self.logger.debug("relay listening on 127.0.0.1:\(port)")
        return port
    }

    /// Idempotent teardown. Wakes a blocked accept poll via the pipe and
    /// unblocks pump reads with shutdown; the pumps then close the fds.
    func close() {
        let (wakeWrite, hadStarted): (CInt, Bool) = lock.withLock {
            guard !isClosed else { return (-1, false) }
            isClosed = true
            if acceptedFD >= 0 || remoteFD >= 0 {
                if acceptedFD >= 0 { shutdown(acceptedFD, SHUT_RDWR) }
                if remoteFD >= 0 { shutdown(remoteFD, SHUT_RDWR) }
            }
            return (wakePipe.write, true)
        }
        guard hadStarted else { return }
        if wakeWrite >= 0 {
            var byte: UInt8 = 0
            _ = write(wakeWrite, &byte, 1)
        }
    }

    private func acceptOnce() {
        let (listener, wakeRead) = lock.withLock { (listenerFD, wakePipe.read) }
        guard listener >= 0 else { return }

        var fds = [
            pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
        ]
        var pollResult: Int32
        repeat {
            pollResult = poll(&fds, 2, Self.acceptTimeoutMilliseconds)
        } while pollResult < 0 && errno == EINTR

        let listenerReadable = pollResult > 0 && (fds[0].revents & Int16(POLLIN)) != 0
        let wasClosed = lock.withLock { isClosed }
        guard listenerReadable, !wasClosed else {
            Self.logger.debug("relay accept ended without a connection (poll \(pollResult))")
            closeEverything()
            return
        }

        let accepted = accept(listener, nil, nil)
        // One-shot: no second connection can ever be accepted, and the
        // cross-app-visible listening port disappears immediately.
        lock.withLock {
            Darwin.close(listenerFD)
            listenerFD = -1
            acceptedFD = accepted
        }
        guard accepted >= 0 else {
            Self.logger.debug("relay accept failed (errno \(errno))")
            closeEverything()
            return
        }

        let remote = lock.withLock { remoteFD }
        queue.async { self.pump(from: accepted, to: remote) }
        queue.async { self.pump(from: remote, to: accepted) }
    }

    private func pump(from source: CInt, to destination: CInt) {
        var buffer = [UInt8](repeating: 0, count: Self.pumpBufferSize)
        outer: while true {
            var bytesRead: Int
            repeat {
                bytesRead = read(source, &buffer, buffer.count)
            } while bytesRead < 0 && errno == EINTR
            guard bytesRead > 0 else { break }

            var offset = 0
            while offset < bytesRead {
                var written: Int
                repeat {
                    written = buffer[offset...].withUnsafeBytes {
                        write(destination, $0.baseAddress, bytesRead - offset)
                    }
                } while written < 0 && errno == EINTR
                guard written > 0 else { break outer }
                offset += written
            }
        }
        // Forward the half-close so the far side's read sees EOF rather
        // than a stall; fds are closed only once both directions end.
        shutdown(destination, SHUT_WR)
        let finished = lock.withLock {
            finishedPumps += 1
            return finishedPumps
        }
        if finished == 2 {
            closeEverything()
        }
    }

    private func closeEverything() {
        lock.withLock {
            isClosed = true
            for fd in [listenerFD, remoteFD, acceptedFD, wakePipe.read, wakePipe.write] where fd >= 0 {
                Darwin.close(fd)
            }
            listenerFD = -1
            remoteFD = -1
            acceptedFD = -1
            wakePipe = (-1, -1)
        }
        Self.logger.debug("relay closed")
    }
}
