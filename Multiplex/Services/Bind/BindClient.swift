import Foundation
import Network
import os

/// Runs one bind handshake against `mpx bind`'s listener: connect, INTRO,
/// sealed HELLO → OFFER → ENROLL → DONE. Message bytes come from the pure
/// `BindClientSession`; this file only moves frames and enforces deadlines.
/// The long overall deadline is deliberate — a human is reading a `[Y/n]`
/// prompt on the host between ENROLL and DONE.
enum BindClient {
    struct Completion: Sendable {
        var offer: BindOffer
        var comment: String
        /// The address the winning connection actually reached, when the
        /// transport can name it — what the saved host dials from now on.
        var connectedHost: String?
    }

    enum Failure: LocalizedError {
        case unreachable(String)
        case rejected(String)
        case wire(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unreachable(let detail): "Couldn't reach the machine — \(detail)"
            case .rejected(let reason): reason
            case .wire(let detail): "The bind exchange broke off — \(detail)"
            case .timedOut: "No answer from mpx bind — is it still running?"
            }
        }
    }

    private static let connectDeadline: Double = 6
    private static let exchangeDeadline: Double = 150

    /// Discovery path — the browser already resolved the service endpoint.
    static func run(
        endpoint: NWEndpoint,
        spub: Data,
        credential: BindClientSession.Credential,
        publicKeyLine: String,
        device: String
    ) async throws -> Completion {
        let connection = FrameConnection(endpoint: endpoint)
        return try await exchange(
            over: connection,
            spub: spub,
            credential: credential,
            publicKeyLine: publicKeyLine,
            device: device
        )
    }

    /// QR/clipboard path — try the payload's candidate addresses in order.
    static func run(
        payload: BindPayload,
        publicKeyLine: String,
        device: String
    ) async throws -> Completion {
        guard !payload.isOffline else {
            throw Failure.wire("offline payloads import directly, not over a handshake")
        }
        var lastError: Error = Failure.unreachable("no candidate addresses in the payload")
        for addr in payload.addrs {
            let connection = FrameConnection(host: addr, port: payload.port)
            do {
                var completion = try await exchange(
                    over: connection,
                    spub: payload.spub,
                    credential: .token(payload.token),
                    publicKeyLine: publicKeyLine,
                    device: device
                )
                if completion.connectedHost == nil { completion.connectedHost = addr }
                return completion
            } catch let error as Failure {
                // A live listener that says no won't say yes at another
                // address — only unreachability moves on.
                if case .unreachable = error { lastError = error; continue }
                if case .timedOut = error { lastError = error; continue }
                throw error
            }
        }
        throw lastError
    }

    private static func exchange(
        over connection: FrameConnection,
        spub: Data,
        credential: BindClientSession.Credential,
        publicKeyLine: String,
        device: String
    ) async throws -> Completion {
        var session = try BindClientSession(spub: spub, credential: credential)
        do {
            try await deadlined(seconds: connectDeadline) { try await connection.connect() }
        } catch is DeadlineExceeded {
            connection.cancel()
            throw Failure.unreachable("connection timed out")
        } catch {
            connection.cancel()
            throw Failure.unreachable(String(describing: error))
        }
        defer { connection.cancel() }
        do {
            return try await deadlined(seconds: exchangeDeadline) {
                try await connection.sendFrame(session.introBody())
                try await connection.sendFrame(session.helloBody())
                let offerFrame = try await connection.receiveFrame()
                let offer: BindOffer
                do {
                    offer = try session.parseOffer(offerFrame)
                } catch {
                    // A wrong PIN comes back as a sealed DONE {ok:false}
                    // instead of the offer — surface its reason.
                    if let done = try? session.parseDone(offerFrame), !done.ok {
                        throw Failure.rejected(rejectionMessage(done.error))
                    }
                    throw Failure.wire("unreadable offer")
                }
                try await connection.sendFrame(
                    session.enrollBody(publicKeyLine: publicKeyLine, device: device)
                )
                let done = try session.parseDone(try await connection.receiveFrame())
                guard done.ok, let comment = done.comment else {
                    throw Failure.rejected(rejectionMessage(done.error))
                }
                return Completion(
                    offer: offer,
                    comment: comment,
                    connectedHost: connection.remoteHostDescription()
                )
            }
        } catch is DeadlineExceeded {
            throw Failure.timedOut
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.wire(String(describing: error))
        }
    }

    private static func rejectionMessage(_ raw: String?) -> String {
        switch raw {
        case "wrong pin": "That PIN didn't match — check the terminal and try again."
        case "declined on the host": "The machine declined the bind."
        case .some(let reason): "The machine refused: \(reason)"
        case nil: "The machine refused the bind."
        }
    }

    // MARK: Frame transport

    private final class FrameConnection: @unchecked Sendable {
        private let connection: NWConnection
        private let connected = OSAllocatedUnfairLock(initialState: false)

        init(endpoint: NWEndpoint) {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            connection = NWConnection(to: endpoint, using: parameters)
        }

        init(host: String, port: UInt16) {
            connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 22,
                using: .tcp
            )
        }

        func connect() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [connected] state in
                    let resume: Result<Void, Error>?
                    switch state {
                    case .ready: resume = .success(())
                    case .failed(let error): resume = .failure(error)
                    case .cancelled:
                        resume = .failure(Failure.unreachable("connection cancelled"))
                    default: resume = nil
                    }
                    guard let resume else { return }
                    let first = connected.withLock { done -> Bool in
                        if done { return false }
                        done = true
                        return true
                    }
                    if first { continuation.resume(with: resume) }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }

        func cancel() {
            // Leave the state handler installed: when a connect deadline
            // fires, `connect()`'s continuation is still pending, and the
            // `.cancelled` transition this triggers is what resumes it (the
            // resume-once lock makes any later callback a no-op). Nil-ing
            // the handler first orphaned that continuation — a permanently
            // hung Task and a continuation-misuse warning per timed-out
            // candidate address.
            connection.cancel()
        }

        func remoteHostDescription() -> String? {
            guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint
            else { return nil }
            // fe80::1%en0 → the scope suffix is meaningless off-device.
            return "\(host)".split(separator: "%").first.map(String.init)
        }

        func sendFrame(_ body: Data) async throws {
            var frame = Data(withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
            frame.append(body)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }

        func receiveFrame() async throws -> Data {
            let header = try await receive(exactly: 4)
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= BindWire.maxFrame else {
                throw Failure.wire("oversized frame (\(length) bytes)")
            }
            return try await receive(exactly: length)
        }

        private func receive(exactly count: Int) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(
                    minimumIncompleteLength: count, maximumLength: count
                ) { data, _, isComplete, error in
                    if let data, data.count == count {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if isComplete {
                        continuation.resume(throwing: Failure.wire("connection closed mid-frame"))
                    } else {
                        continuation.resume(throwing: Failure.wire("short read"))
                    }
                }
            }
        }
    }

}
