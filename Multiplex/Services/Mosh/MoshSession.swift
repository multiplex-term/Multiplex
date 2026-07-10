import Foundation
import Network

/// One live mosh session: a UDP socket, the transport engine, and the
/// timer pump that keeps them honest. Speaks `TerminalTransport`, so
/// `TerminalSessionController` drives it exactly like an SSH shell.
///
/// Roaming is the whole point: the server accepts any source address that
/// authenticates, so on socket failure, a better path, or prolonged
/// silence the session just makes a fresh socket (mosh's port hop) and
/// keeps the crypto sequence going. App suspension needs no special
/// handling beyond that — the first heartbeat after resume re-associates.
actor MoshSession: TerminalTransport {
    enum Failure: Error {
        case noResponse
        case alreadyOpen

        func userMessage(host: Host) -> String {
            switch self {
            case .noResponse:
                "mosh-server started on \(host.name) but no UDP reply arrived. Check firewalls/NAT for the mosh port range (default 60000-61000)."
            case .alreadyOpen:
                "This mosh session is already open."
            }
        }
    }

    /// Contact-lost threshold — mosh's own overlay appears at 6.5 s.
    private static let quietThreshold: UInt64 = 6500
    /// Silence long enough to try a fresh socket (mosh's PORT_HOP_INTERVAL).
    private static let portHopInterval: UInt64 = 10000
    /// How long open() waits for the server's first authenticated packet.
    private static let firstContactTimeout: Duration = .seconds(10)
    /// How long close() lets the shutdown handshake run before tearing down.
    private static let closeGracePeriodMS: UInt64 = 2400

    private let target: MoshBootstrap.Target
    private var engine: MoshTransportEngine

    private var connection: NWConnection?
    private var pumpTask: Task<Void, Never>?
    private var wakeup: CheckedContinuation<Void, Never>?
    private var wakeupTimer: Task<Void, Never>?
    private var wakeupGeneration = 0

    private var onData: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (String?) -> Void)?
    private var onContact: (@Sendable (Bool) -> Void)?

    private var firstContact: CheckedContinuation<Void, Error>?
    private var everContacted = false
    private var closed = false
    private var contactLost = false
    private var lastPortHop: UInt64 = 0
    private var socketGeneration = 0
    private var socketState: NWConnection.State = .setup
    private var wakeupPending = false

    init(target: MoshBootstrap.Target, cols: Int, rows: Int) throws {
        self.target = target
        engine = try MoshTransportEngine(
            key: target.key,
            cols: cols,
            rows: rows,
            budget: target.datagramBudget,
            now: Self.now()
        )
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    // MARK: - Lifecycle

    /// Starts the socket and pump, then waits for the server's first
    /// authenticated packet — the moment the session is provably alive.
    func open(
        onData: @Sendable @escaping (Data) -> Void,
        onClose: @Sendable @escaping (String?) -> Void,
        onContact: @Sendable @escaping (Bool) -> Void = { _ in }
    ) async throws {
        guard pumpTask == nil, !closed else { throw Failure.alreadyOpen }
        self.onData = onData
        self.onClose = onClose
        self.onContact = onContact

        startSocket()
        pumpTask = Task { await pump() }

        // The first packet can already have landed by the time we get here
        // (handler jobs interleave on the actor) — only park if it hasn't.
        guard !everContacted else { return }
        let timeout = Task {
            try? await Task.sleep(for: Self.firstContactTimeout)
            await self.failFirstContact()
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            firstContact = continuation
        }
    }

    func write(_ data: Data) async throws {
        guard !closed else { return }
        engine.input(data)
        kick()
    }

    func resize(cols: Int, rows: Int) async throws {
        guard !closed else { return }
        engine.resize(cols: cols, rows: rows)
        kick()
    }

    /// Graceful shutdown: run the handshake briefly so mosh-server exits
    /// (detaching its tmux client), then tear down regardless.
    func close() async {
        guard !closed else { return }
        engine.startShutdown(now: Self.now())
        kick()
        let deadline = Self.now() + Self.closeGracePeriodMS
        while !closed, !engine.shouldClose(now: Self.now()), Self.now() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        finish(reason: nil, notify: false)
    }

    /// Foregrounded / user prodded the UI: heartbeat immediately, and if
    /// the socket died while suspended, replace it.
    func nudge() {
        guard !closed else { return }
        switch socketState {
        case .failed, .cancelled:
            recreateSocket()
        default:
            break
        }
        kick()
    }

    // MARK: - Socket

    private func startSocket() {
        socketGeneration += 1
        let generation = socketGeneration
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo

        let nwConnection = NWConnection(
            host: NWEndpoint.Host(target.ip),
            port: NWEndpoint.Port(rawValue: target.port) ?? 60001,
            using: params
        )
        connection = nwConnection

        nwConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.socketStateChanged(state, generation: generation) }
        }
        nwConnection.betterPathUpdateHandler = { [weak self] better in
            guard better, let self else { return }
            Task { await self.pathImproved(generation: generation) }
        }
        nwConnection.start(queue: DispatchQueue(label: "mosh.udp"))
        armReceive(nwConnection, generation: generation)
    }

    private func socketStateChanged(_ state: NWConnection.State, generation: Int) {
        guard !closed, generation == socketGeneration else { return }
        socketState = state
        switch state {
        case .ready:
            kick()
        case .failed:
            recreateSocket()
        default:
            break
        }
    }

    private func pathImproved(generation: Int) {
        guard !closed, generation == socketGeneration else { return }
        recreateSocket()
    }

    private func recreateSocket() {
        connection?.cancel()
        startSocket()
        kick()
    }

    private func armReceive(_ nwConnection: NWConnection, generation: Int) {
        nwConnection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.handleDatagram(data)
                }
                await self.rearmOrRecover(nwConnection, generation: generation, error: error)
            }
        }
    }

    private func rearmOrRecover(_ nwConnection: NWConnection, generation: Int, error: NWError?) {
        guard !closed, generation == socketGeneration else { return }
        if error != nil {
            recreateSocket()
        } else {
            armReceive(nwConnection, generation: generation)
        }
    }

    private func handleDatagram(_ datagram: Data) {
        guard !closed else { return }
        let now = Self.now()
        let heardBefore = engine.packetsHeard
        let outputs = engine.receive(datagram, now: now)

        if engine.packetsHeard > heardBefore {
            everContacted = true
            firstContact?.resume()
            firstContact = nil
            if contactLost {
                contactLost = false
                onContact?(false)
            }
        }

        for output in outputs {
            switch output {
            case .feed(let bytes):
                onData?(bytes)
            case .resetScreen:
                // The next diff assumes a blank screen (RIS).
                onData?(Data("\u{1B}c".utf8))
            case .remoteResize, .echoAck:
                // The visible terminal is sized by layout; the server echo
                // and prediction bookkeeping have no client-side effect.
                break
            }
        }
        kick()
    }

    private func send(_ datagrams: [Data]) {
        guard let connection else { return }
        for datagram in datagrams {
            connection.send(content: datagram, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Pump

    private func pump() async {
        while !closed {
            let now = Self.now()
            let (datagrams, nextDeadline) = engine.tick(now: now)
            send(datagrams)

            if engine.shouldClose(now: now) {
                // Peer-initiated: the wrapped command exited (tmux client
                // detached) — a clean end, like an SSH channel close.
                finish(reason: nil, notify: true)
                return
            }
            if engine.isDesynced(now: now) {
                finish(reason: "mosh session lost sync", notify: true)
                return
            }
            updateContact(now: now)
            hopPortIfDeaf(now: now)

            await sleep(until: nextDeadline, from: now)
        }
    }

    private func updateContact(now: UInt64) {
        let lost = engine.quiet(now: now) > Self.quietThreshold
        guard lost != contactLost else { return }
        contactLost = lost
        onContact?(lost)
    }

    /// mosh's port hop: prolonged one-way silence can mean a dead NAT
    /// mapping — a fresh socket (new source port) punches a new one.
    private func hopPortIfDeaf(now: UInt64) {
        guard engine.quiet(now: now) > Self.portHopInterval,
              now - lastPortHop > Self.portHopInterval
        else { return }
        lastPortHop = now
        recreateSocket()
    }

    private func sleep(until deadline: UInt64, from now: UInt64) async {
        // A kick that landed while the pump was mid-tick must not be lost —
        // skip the sleep and run another tick instead.
        if wakeupPending {
            wakeupPending = false
            return
        }
        let delay = deadline > now ? deadline - now : 1
        // A cancelled Task.sleep still falls through to its continuation
        // (cancellation only makes `try?` return nil), so a timer cancelled
        // by an early kick would otherwise wake the NEXT sleep — a pump
        // busy-loop. Tag each timer with the generation it belongs to and
        // ignore a firing whose generation has moved on.
        wakeupGeneration &+= 1
        let generation = wakeupGeneration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wakeup = continuation
            wakeupTimer = Task {
                try? await Task.sleep(for: .milliseconds(delay))
                await self.timerFired(generation)
            }
        }
        wakeupPending = false
    }

    private func timerFired(_ generation: Int) {
        guard generation == wakeupGeneration else { return }
        fireWakeup()
    }

    private func fireWakeup() {
        // Bump so any still-pending timer for this sleep is now stale.
        wakeupGeneration &+= 1
        wakeupTimer?.cancel()
        wakeupTimer = nil
        wakeup?.resume()
        wakeup = nil
    }

    /// Wake the pump now (new input, fresh datagram, socket event).
    private func kick() {
        wakeupPending = true
        fireWakeup()
    }

    // MARK: - Teardown

    private func finish(reason: String?, notify: Bool) {
        guard !closed else { return }
        closed = true
        firstContact?.resume(throwing: Failure.noResponse)
        firstContact = nil
        pumpTask?.cancel()
        pumpTask = nil
        fireWakeup()
        connection?.cancel()
        connection = nil
        if notify {
            onClose?(reason)
        }
        onData = nil
        onClose = nil
        onContact = nil
    }

    private func failFirstContact() {
        guard let continuation = firstContact else { return }
        firstContact = nil
        continuation.resume(throwing: Failure.noResponse)
        finish(reason: nil, notify: false)
    }
}
