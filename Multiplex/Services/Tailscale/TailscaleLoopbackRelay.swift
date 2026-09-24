import Darwin
import Dispatch
import Foundation
import os

/// The far side of the relay — a tailnet connection the local SSH client's
/// bytes are spliced onto. tailscale-rs hands back an opaque `ts_tcp_stream`
/// handle with blocking send/recv (NOT an fd), so the relay pumps through
/// this seam instead of a second file descriptor. The DEBUG fake-dial path
/// supplies an fd-backed remote so the whole splice is exercisable without a
/// node. `recv`/`send` mirror POSIX semantics: recv returns >0 bytes, 0 on
/// EOF, <0 on error; send returns bytes written (may be partial) or <0.
protocol TailscaleRelayRemote: Sendable {
    func recv(into buffer: UnsafeMutableRawBufferPointer) -> Int
    func send(_ buffer: UnsafeRawBufferPointer) -> Int
    /// Half-close the write side after the local side stops sending, so the
    /// peer sees EOF rather than stalling. A no-op where the transport has no
    /// half-close (the tailnet handle) — there, full teardown rides `close()`
    /// via the relay when the SSH client tears down.
    func shutdownWrite()
    func close()
}

/// One-shot localhost TCP relay between Citadel and a tailnet connection.
/// Citadel 0.12.0's channel-injection overload cannot be called off the
/// event loop — its synchronous prefix asserts `inEventLoop` (NIOCore
/// ChannelPipeline.swift:1208) — and pinning the calling Task to the loop
/// needs iOS 18, above the app's floor. So Citadel dials `127.0.0.1:<port>`
/// through its wholly ordinary bootstrap (handlers installed on-loop by its
/// own initializer) and this relay splices that connection onto the remote.
///
/// iOS loopback is reachable cross-app, so the listener accepts exactly ONE
/// connection and closes immediately; a peer that never connects is bounded
/// by the accept poll timeout. The relay stays alive by self-retention in
/// its queue work items and tears itself down on EOF from either side — the
/// SSH client closing its localhost socket is what releases the tailnet
/// connection, so callers don't need to hold a reference.
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
    private var acceptedFD: CInt = -1
    private var wakePipe: (read: CInt, write: CInt) = (-1, -1)
    private var remote: TailscaleRelayRemote?
    private var finishedPumps = 0
    private var isClosed = false

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Takes ownership of `remote` unconditionally: on throw it is closed, on
    /// success the relay closes it when the splice ends.
    func start(spliceTo remote: TailscaleRelayRemote) throws -> UInt16 {
        guard lock.withLock({ !isClosed }) else {
            remote.close()
            throw Failure(message: "Relay already closed.")
        }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else {
            remote.close()
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
            remote.close()
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
            remote.close()
            throw Failure(message: "Relay port lookup failed (errno \(errno)).")
        }
        let port = UInt16(bigEndian: bound.sin_port)

        var pipeFDs: [CInt] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            Darwin.close(listener)
            remote.close()
            throw Failure(message: "Relay wake pipe failed (errno \(errno)).")
        }

        lock.withLock {
            self.listenerFD = listener
            self.remote = remote
            self.wakePipe = (pipeFDs[0], pipeFDs[1])
        }

        queue.async { self.acceptOnce() }
        Self.logger.debug("relay listening on 127.0.0.1:\(port)")
        return port
    }

    /// Idempotent teardown. Wakes a blocked accept poll via the pipe and
    /// unblocks the local pump with shutdown; the pumps then close both
    /// sides.
    func close() {
        let (wakeWrite, hadStarted): (CInt, Bool) = lock.withLock {
            guard !isClosed else { return (-1, false) }
            isClosed = true
            if acceptedFD >= 0 { shutdown(acceptedFD, SHUT_RDWR) }
            remote?.close()
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

        queue.async { self.pumpLocalToRemote(accepted) }
        queue.async { self.pumpRemoteToLocal(accepted) }
    }

    private func pumpLocalToRemote(_ local: CInt) {
        guard let remote = lock.withLock({ self.remote }) else { return }
        var buffer = [UInt8](repeating: 0, count: Self.pumpBufferSize)
        outer: while true {
            var bytesRead: Int
            repeat {
                bytesRead = read(local, &buffer, buffer.count)
            } while bytesRead < 0 && errno == EINTR
            guard bytesRead > 0 else { break }

            var offset = 0
            while offset < bytesRead {
                let written = buffer[offset..<bytesRead].withUnsafeBytes {
                    remote.send($0)
                }
                guard written > 0 else { break outer }
                offset += written
            }
        }
        // Forward the half-close so the tailnet peer sees EOF rather than a
        // stall; the handle/fd closes only once both directions end.
        remote.shutdownWrite()
        pumpFinished()
    }

    private func pumpRemoteToLocal(_ local: CInt) {
        guard let remote = lock.withLock({ self.remote }) else { return }
        var buffer = [UInt8](repeating: 0, count: Self.pumpBufferSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { remote.recv(into: $0) }
            guard bytesRead > 0 else { break }

            var offset = 0
            var failed = false
            while offset < bytesRead {
                var written: Int
                repeat {
                    written = buffer[offset..<bytesRead].withUnsafeBytes {
                        write(local, $0.baseAddress, bytesRead - offset)
                    }
                } while written < 0 && errno == EINTR
                guard written > 0 else { failed = true; break }
                offset += written
            }
            if failed { break }
        }
        // Forward the half-close so the SSH client's read sees EOF rather
        // than a stall; fds/handle close only once both directions end.
        shutdown(local, SHUT_WR)
        pumpFinished()
    }

    private func pumpFinished() {
        let finished = lock.withLock {
            finishedPumps += 1
            return finishedPumps
        }
        if finished == 2 {
            closeEverything()
        }
    }

    private func closeEverything() {
        let remoteToClose: TailscaleRelayRemote? = lock.withLock {
            isClosed = true
            for fd in [listenerFD, acceptedFD, wakePipe.read, wakePipe.write] where fd >= 0 {
                Darwin.close(fd)
            }
            listenerFD = -1
            acceptedFD = -1
            wakePipe = (-1, -1)
            let remote = self.remote
            self.remote = nil
            return remote
        }
        remoteToClose?.close()
        Self.logger.debug("relay closed")
    }
}

/// fd-backed remote for the DEBUG fake-dial path (a plain kernel TCP socket
/// to the harness), so the relay is exercised end-to-end without a node.
struct TailscaleFDRemote: TailscaleRelayRemote {
    let fd: CInt

    func recv(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        var result: Int
        repeat {
            result = read(fd, buffer.baseAddress, buffer.count)
        } while result < 0 && errno == EINTR
        return result
    }

    func send(_ buffer: UnsafeRawBufferPointer) -> Int {
        var result: Int
        repeat {
            result = write(fd, buffer.baseAddress, buffer.count)
        } while result < 0 && errno == EINTR
        return result
    }

    func shutdownWrite() {
        shutdown(fd, SHUT_WR)
    }

    func close() {
        Darwin.close(fd)
    }
}
