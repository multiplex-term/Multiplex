import Foundation
import os

/// One host's `mpx bridge`: a dedicated SSH connection (never the probe's —
/// the same rule the file viewer follows) carrying a PTY-less login shell
/// that execs the bridge. Requests arrive as JSON lines; answers go back
/// the same way. Lives on the main actor; the SSH callbacks hop here
/// through one ordered stream.
@MainActor
final class AgentBrowserLink {
    enum State: Equatable {
        case idle
        case connecting
        /// Serving `socket` on the host.
        case ready(socket: String?)
        /// No `mpx` on the host's PATH or in the usual places.
        case missingCLI
        /// An `mpx` from before `bridge` existed.
        case outdatedCLI
        case failed(String)
    }

    typealias Handler = @MainActor (_ hostID: UUID, _ method: String, _ params: JSONValue) async
        -> Result<JSONValue, AgentBrowserError>

    private(set) var host: Host
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            Self.log.info("\(self.host.name, privacy: .private) bridge: \(String(describing: self.state), privacy: .public)")
        }
    }

    private let handler: Handler
    private let deviceName: String
    private var connection: SSHConnection?
    private var session: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var backoff = ConnectRetryBackoff()
    /// Bumped per session so a late callback from a dead one is ignored.
    private var generation = 0
    /// The ping in flight and when it left (local ms).
    private var outstandingPing: (token: UInt64, sentMs: Double)?
    /// Requests the bridge gave up on; bounded, ids only grow.
    private var cancelled = Set<UInt64>()
    /// Requests being served, by id — cancelled on teardown, so nothing a
    /// dead or revoked link asked for keeps acting.
    private var inFlight: [UInt64: Task<Void, Never>] = [:]
    private var bridgeClock = AgentBrowserWire.BridgeClock()
    private let epoch = ContinuousClock.now
    private var localMs: Double { (ContinuousClock.now - epoch) / .milliseconds(1) }
    private var nextPing: UInt64 = 1
    private var wanted = false

    private static let log = Logger.agentBrowser
    private static let pingInterval: Duration = .seconds(20)
    /// A host can ask for at most this much at once; more is refused, not
    /// queued.
    static let maxInFlight = 8
    /// An answer larger than this is replaced by a `too_large` error.
    static let maxResultBytes = 16 << 20
    /// SSH reads the main actor has not consumed yet. A host that outpaces
    /// it is flooding: the session is dropped rather than buffered.
    static let maxPendingReads = 1024

    init(host: Host, deviceName: String, handler: @escaping Handler) {
        self.host = host
        self.deviceName = deviceName
        self.handler = handler
    }

    func start() {
        wanted = true
        guard session == nil, retry == nil else { return }
        connect()
    }

    func stop() {
        wanted = false
        retry?.cancel()
        retry = nil
        tearDown()
        state = .idle
    }

    /// A host record edit that changes how to reach it (the probe's own
    /// identity — address, credentials, pinned keys) restarts the link.
    func update(host newHost: Host) {
        let redial = !newHost.hasSameConnectionModelConfiguration(as: host)
        host = newHost
        if redial, wanted { redialNow() }
    }

    /// The device changed networks: the SSH socket belongs to the old path,
    /// so reconnect now rather than wait for a ping to fail.
    func networkChanged() {
        guard wanted, session != nil else { return }
        redialNow()
    }

    private func redialNow() {
        retry?.cancel()
        retry = nil
        backoff.reset()
        tearDown()
        connect()
    }

    /// Back in front: a link that died while suspended reconnects now
    /// instead of at its backoff; a live-looking one proves itself with an
    /// immediate ping.
    func applicationWillEnterForeground() {
        guard wanted else { return }
        switch state {
        case .ready:
            guard let token = sendPing() else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.outstandingPing?.token == token else { return }
                self.sessionEnded(detail: "no answer after resume", stderr: "")
            }
        default:
            backoff.reset()
            retry?.cancel()
            retry = nil
            if session == nil { connect() }
        }
    }

    // MARK: Session

    private func connect() {
        generation &+= 1
        let generation = generation
        state = .connecting
        let host = host
        #if DEBUG
        // MULTIPLEX_AGENT_MPX=<path on the host>: run a dev build of mpx.
        let preferred = ProcessInfo.processInfo.environment["MULTIPLEX_AGENT_MPX"]
        #else
        let preferred: String? = nil
        #endif
        let payload = AgentBrowserLaunch.payload(
            deviceName: deviceName,
            installID: AgentBrowserLaunch.installID(),
            preferred: preferred
        )
        // A new bridge process has a new clock.
        bridgeClock.reset()
        let (lines, sink) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maxPendingReads)
        )
        let overflow = OverflowLatch()
        let push: @Sendable (Event) -> Void = { event in
            if case .dropped = sink.yield(event) { overflow.trip() }
        }
        session = Task { [weak self] in
            let secrets = await HostSecrets.loadOffMain(for: host)
            let connection = SSHConnection(host: host, secrets: secrets)
            self?.connection = connection
            do {
                // Citadel connects can black-hole and ignore cancellation.
                try await deadlined(seconds: HostTest.connectDeadline) { try await connection.connect() }
                try await connection.openLineChannel(
                    payload: payload,
                    onStdout: { push(.stdout($0)) },
                    onStderr: { push(.stderr($0)) },
                    onClose: { detail in
                        push(.closed(detail))
                        sink.finish()
                    }
                )
            } catch {
                sink.yield(.closed(String(describing: error)))
                sink.finish()
            }
            var buffer = AgentBrowserWire.LineBuffer()
            var stderr = ""
            for await event in lines {
                guard let self, self.generation == generation else { break }
                if overflow.isTripped {
                    self.sessionEnded(detail: "the host sent more than the app could read", stderr: stderr)
                    break
                }
                switch event {
                case .stdout(let data):
                    for line in buffer.append(data) {
                        self.receive(line)
                    }
                case .stderr(let data):
                    stderr = String((stderr + String(decoding: data, as: UTF8.self)).suffix(2048))
                case .closed(let detail):
                    self.sessionEnded(detail: detail, stderr: stderr)
                }
            }
        }
    }

    /// Set from SSH callbacks when the bounded stream drops a read.
    private final class OverflowLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var tripped = false

        func trip() {
            lock.withLock { tripped = true }
        }

        var isTripped: Bool {
            lock.withLock { tripped }
        }
    }

    private enum Event: Sendable {
        case stdout(Data)
        case stderr(Data)
        case closed(String?)
    }

    private func receive(_ line: String) {
        switch AgentBrowserWire.decode(line) {
        case .hello(let version, let socket):
            guard version == AgentBrowserWire.protocolVersion else {
                state = version > AgentBrowserWire.protocolVersion
                    ? .failed("mpx speaks bridge v\(version); update Multiplex")
                    : .outdatedCLI
                tearDown()
                return
            }
            backoff.reset()
            state = .ready(socket: socket)
            sendPing()
            Self.log.info("bridge ready on \(self.host.name, privacy: .private) at \(socket ?? "?", privacy: .private)")
            startPinging()
        case .missing:
            state = .missingCLI
        case .request(let request):
            guard inFlight.count < Self.maxInFlight, inFlight[request.id] == nil else {
                reply(request.id, .failure(.init(
                    code: "busy",
                    message: "Multiplex is already working on \(Self.maxInFlight) requests from this host — wait for them."
                )))
                return
            }
            let generation = generation
            // The hop matters: a cancel in the same read lands in
            // `cancelled` before this task looks.
            inFlight[request.id] = Task { [weak self] in
                await self?.serve(request, generation: generation)
            }
        case .cancel(let id):
            inFlight[id]?.cancel()
            cancelled.insert(id)
            if cancelled.count > 256, let oldest = cancelled.min() { cancelled.remove(oldest) }
        case .pong(let token, let bridgeMs):
            guard let ping = outstandingPing, ping.token == token else { return }
            outstandingPing = nil
            if let bridgeMs {
                bridgeClock.learn(bridgeMs: bridgeMs, sentLocalMs: ping.sentMs, receivedLocalMs: localMs)
            }
        case .ignored:
            break
        }
    }

    private func serve(_ request: AgentBrowserWire.Request, generation: Int) async {
        defer { if self.generation == generation { inFlight[request.id] = nil } }
        if cancelled.remove(request.id) != nil || bridgeClock.isStale(request, localMs: localMs) {
            Self.log.info("\(request.method, privacy: .public) skipped: its agent already gave up")
            return
        }
        let started = ContinuousClock.now
        let result = await handler(host.id, request.method, request.params)
        // Torn down or cancelled meanwhile: the answer has nowhere to go.
        guard !Task.isCancelled, self.generation == generation else { return }
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        Self.log.debug("\(request.method, privacy: .public) answered in \(milliseconds, privacy: .public) ms")
        reply(request.id, result)
    }

    private func reply(_ id: UInt64, _ result: Result<JSONValue, AgentBrowserError>) {
        var line: Data
        switch result {
        case .success(let value): line = AgentBrowserWire.result(id: id, value)
        case .failure(let error): line = AgentBrowserWire.error(id: id, error)
        }
        if line.count > Self.maxResultBytes {
            line = AgentBrowserWire.error(id: id, .init(
                code: "too_large",
                message: "The answer was \(line.count / 1_048_576) MiB; narrow the request."
            ))
        }
        guard let connection else { return }
        Task { try? await connection.write(line) }
    }

    private func sessionEnded(detail: String?, stderr: String) {
        let previous = state
        tearDown()
        switch previous {
        case .missingCLI:
            state = .missingCLI
        case .connecting where AgentBrowserLaunch.isOutdatedCLI(stderr: stderr):
            state = .outdatedCLI
        case .connecting, .ready, .idle:
            state = .failed(detail ?? "the bridge ended")
        case .outdatedCLI, .failed:
            break
        }
        Self.log.info("bridge ended on \(self.host.name, privacy: .private): \(detail ?? "eof", privacy: .private) stderr: \(stderr, privacy: .private)")
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard wanted else { return }
        backoff.registerFailure(now: Date())
        retry?.cancel()
        let wait = max(backoff.retryNotBefore?.timeIntervalSinceNow ?? 0, 0)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled, self.wanted else { return }
            self.retry = nil
            self.connect()
        }
    }

    private func tearDown() {
        generation &+= 1
        session?.cancel()
        session = nil
        pinger?.cancel()
        pinger = nil
        outstandingPing = nil
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        cancelled.removeAll()
        if let connection {
            Task { await connection.close() }
        }
        connection = nil
    }

    // MARK: Liveness

    /// TCP can die silently (NAT timeout, Wi-Fi hop); the bridge would sit
    /// on a dead channel forever. An unanswered ping by the next tick is a
    /// dead link.
    private func startPinging() {
        pinger?.cancel()
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard let self, !Task.isCancelled else { return }
                if self.outstandingPing != nil {
                    Self.log.info("bridge ping unanswered; reconnecting")
                    self.sessionEnded(detail: "ping timeout", stderr: "")
                    return
                }
                self.sendPing()
            }
        }
    }

    @discardableResult
    private func sendPing() -> UInt64? {
        guard let connection, case .ready = state else { return nil }
        let token = nextPing
        nextPing &+= 1
        outstandingPing = (token, localMs)
        Task { try? await connection.write(AgentBrowserWire.ping(token)) }
        return token
    }
}
