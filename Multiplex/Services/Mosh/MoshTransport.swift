import Foundation

/// The client-role mosh transport engine: sender and receiver state
/// machines with clock and I/O injected — MoshSession pumps it with
/// datagrams, keystrokes, and time, and it answers with datagrams to send
/// and terminal actions to apply. Pure logic; exercised directly by unit
/// tests against a fake server built from the same codec pieces.
///
/// Sender side is a faithful translation of mosh's TransportSender: paced
/// diffs against an assumed receiver state, prospective resends from the
/// last acknowledged state, empty acks as heartbeats, and the
/// new_num = uint64.max shutdown handshake.
///
/// Receiver side deliberately diverges from mosh in one way: mosh keeps up
/// to 1024 server states so it can apply a diff against any of them; we
/// render straight into the live terminal, so only the head state exists.
/// A diff from the head applies; a diff from state 0 (the server's
/// recovery path) applies after a screen reset; anything else is dropped
/// and the server's ack timeout re-bases it within an RTO or two. The
/// pathological corner (server erases the state we keep acking) is caught
/// by the desync valve, which the session turns into a clean reconnect.
struct MoshTransportEngine {
    // transportsender.h timing parameters (ms)
    static let sendIntervalMin: UInt64 = 20
    static let sendIntervalMax: UInt64 = 250
    static let ackInterval: UInt64 = 3000
    static let ackDelay: UInt64 = 100
    static let shutdownRetries = 16
    static let activeRetryTimeout: UInt64 = 10000
    /// mosh-client sets send_delay to 1 ms — minimal keystroke latency.
    static let sendMindelay: UInt64 = 1
    static let sentStatesCap = 32

    /// What a received instruction asks the terminal layer to do.
    enum Output: Equatable {
        /// Server bytes that transform the previous screen into this one.
        case feed(Data)
        /// The diff is based on the blank state 0 — reset before feeding.
        case resetScreen
        /// Server-side emulator resized (normally the echo of our resize).
        case remoteResize(cols: Int, rows: Int)
        case echoAck(UInt64)
    }

    private struct SentState {
        var num: UInt64
        /// Absolute count of user events this state contains.
        var eventCount: Int
        var sentAt: UInt64
    }

    private var packets: MoshPacketLayer
    private var fragmenter = MoshFragmenter()
    private var assembly = MoshFragmentAssembly()
    private let zlib = MoshZlib.Context()
    /// Datagram payload budget: path MTU minus the 28 packet-layer bytes.
    private let budget: Int

    // MARK: Sender state (UserStream)

    /// Suffix of user events not yet known to be received; `eventOffset`
    /// is how many acknowledged events were dropped from the front.
    /// A slice makes dropping acknowledged prefixes O(1). Under packet loss a
    /// client can accumulate thousands of small key events; repeatedly calling
    /// `Array.removeFirst` shifted that whole suffix on every acknowledgement.
    private var events: ArraySlice<MoshUserEvent> = []
    private var eventOffset = 0
    private var totalEvents: Int { eventOffset + events.count }

    private var sentStates: [SentState]
    private var assumedReceiverNum: UInt64 = 0
    private var nextAckTime: UInt64
    private var nextSendTime: UInt64?
    private var mindelayClock: UInt64?
    private var pendingDataAck = false

    private(set) var shutdownInProgress = false
    private var shutdownStart: UInt64 = 0
    private var shutdownTries = 0
    private var shutdownAcked = false
    private var counterpartyShutdown = false
    private var counterpartyAckSent = false

    /// Last time an authentic in-order packet arrived.
    private(set) var lastHeard: UInt64
    /// Count of authentic in-order packets — lets the session detect "first
    /// contact" without comparing clock values.
    private(set) var packetsHeard = 0

    // MARK: Receiver state

    private(set) var headNum: UInt64 = 0
    private var lastAdvance: UInt64
    private var unapplicable = 0

    // MARK: - Setup

    init(key: MoshKey, cols: Int, rows: Int, budget: Int, now: UInt64) throws {
        packets = try MoshPacketLayer(key: key, direction: .client)
        self.budget = budget
        sentStates = [SentState(num: 0, eventCount: 0, sentAt: now)]
        nextAckTime = now
        nextSendTime = now
        lastHeard = now
        lastAdvance = now
        // First thing on the wire is the terminal size, like mosh-client.
        events.append(.resize(cols: cols, rows: rows))
    }

    // MARK: - Local inputs

    mutating func input(_ data: Data) {
        guard !shutdownInProgress, !data.isEmpty else { return }
        // Input arriving inside the send-mindelay window has not appeared in a
        // numbered state yet. Fold it into that unsent event now instead of
        // retaining one allocation per UIKit key callback and rediscovering the
        // same coalescing on every retransmit encode.
        if totalEvents > sentStates.last!.eventCount,
           let lastIndex = events.indices.last,
           case .keys(var pending) = events[lastIndex] {
            pending.append(data)
            events[lastIndex] = .keys(pending)
            return
        }
        events.append(.keys(data))
    }

    mutating func resize(cols: Int, rows: Int) {
        guard !shutdownInProgress else { return }
        // Window drags can emit several sizes inside one transport frame. Only
        // the newest unsent size matters; a size already present in a numbered
        // state is immutable because retransmission diffs refer to that state.
        if totalEvents > sentStates.last!.eventCount,
           let lastIndex = events.indices.last,
           case .resize = events[lastIndex] {
            events[lastIndex] = .resize(cols: cols, rows: rows)
            return
        }
        events.append(.resize(cols: cols, rows: rows))
    }

    /// A fresh UDP socket needs a packet immediately so the server learns the
    /// new source port. Merely waking `tick` is insufficient while the normal
    /// three-second acknowledgement deadline is still in the future.
    mutating func requestHeartbeat(now: UInt64) {
        guard !shutdownInProgress else { return }
        nextAckTime = min(nextAckTime, now)
    }

    mutating func startShutdown(now: UInt64) {
        guard !shutdownInProgress else { return }
        shutdownInProgress = true
        shutdownStart = now
    }

    // MARK: - Receive path

    mutating func receive(_ datagram: Data, now: UInt64) -> [Output] {
        guard let opened = packets.open(datagram, now: now) else { return [] }
        if opened.isNew {
            lastHeard = now
            packetsHeard += 1
        }

        guard let compressed = assembly.add(opened.payload),
              let serialized = try? zlib.decompress(compressed),
              let instruction = MoshInstruction(parsing: serialized),
              instruction.protocolVersionField == MoshInstruction.protocolVersion
        else { return [] }

        processAcknowledgment(through: instruction.ackNum)

        if instruction.newNum == .max {
            // Server-initiated shutdown (its command exited — e.g. the tmux
            // client detached). Ack with uint64.max and wind down.
            counterpartyShutdown = true
            pendingDataAck = true
            return []
        }

        guard instruction.newNum > headNum else { return [] } // dup or stale

        let outputs: [Output]
        if instruction.oldNum == headNum {
            outputs = apply(diff: instruction.diff, reset: false)
        } else if instruction.oldNum == 0 {
            // Server re-based from the blank state — full repaint follows.
            outputs = apply(diff: instruction.diff, reset: headNum != 0)
        } else {
            unapplicable += 1
            return []
        }

        headNum = instruction.newNum
        lastAdvance = now
        unapplicable = 0
        pendingDataAck = true
        return outputs
    }

    private mutating func processAcknowledgment(through ackNum: UInt64) {
        if ackNum == .max {
            shutdownAcked = true
            return
        }
        guard let index = sentStates.firstIndex(where: { $0.num == ackNum }) else { return }
        sentStates.removeFirst(index)
        // rationalize_states: everyone agrees on the acked prefix — drop it.
        let confirmed = sentStates[0].eventCount
        if confirmed > eventOffset {
            events.removeFirst(confirmed - eventOffset)
            eventOffset = confirmed
            // ArraySlice intentionally retains its original storage. Release a
            // long acknowledged prefix occasionally so a roaming session does
            // not pin old key payloads forever; the rare compaction amortizes
            // the O(n) copy over at least 1,024 removals.
            if events.isEmpty {
                events = []
            } else if events.startIndex >= 1_024,
                      events.startIndex > events.count {
                events = ArraySlice(Array(events))
            }
        }
    }

    private func apply(diff: Data, reset: Bool) -> [Output] {
        guard !diff.isEmpty else { return [] } // heartbeat state
        guard let items = MoshHostMessage.decode(diff) else { return [] }
        var outputs: [Output] = reset ? [.resetScreen] : []
        for item in items {
            switch item {
            case .hostBytes(let bytes): outputs.append(.feed(bytes))
            case .resize(let cols, let rows): outputs.append(.remoteResize(cols: cols, rows: rows))
            case .echoAck(let num): outputs.append(.echoAck(num))
            }
        }
        return outputs
    }

    // MARK: - Send path

    /// Run the timers; returns datagrams due now plus the next deadline.
    mutating func tick(now: UInt64) -> (datagrams: [Data], nextDeadline: UInt64) {
        calculateTimers(now: now)

        let ackDue = now >= nextAckTime
        let sendDue = nextSendTime.map { now >= $0 } ?? false
        guard ackDue || sendDue else {
            return ([], deadline(now: now))
        }

        // Diff against the state we assume the server has, then consider
        // re-basing on the last *known* state when that's cheap — it makes
        // every packet carry all unacknowledged input.
        var baseNum = assumedReceiverNum
        var baseCount = sentStates.first(where: { $0.num == baseNum })?.eventCount ?? sentStates[0].eventCount
        var diff: Data
        if baseNum != sentStates[0].num {
            let cumulative = encodeDiff(fromEventCount: sentStates[0].eventCount)
            let proposed = encodeDiff(fromEventCount: baseCount)
            if cumulative.count <= proposed.count
                || (cumulative.count < 1000 && cumulative.count - proposed.count < 100) {
                baseNum = sentStates[0].num
                baseCount = sentStates[0].eventCount
                diff = cumulative
            } else {
                diff = proposed
            }
        } else {
            diff = encodeDiff(fromEventCount: baseCount)
        }

        var datagrams: [Data] = []
        if diff.isEmpty {
            if ackDue {
                datagrams = sendInstruction(diff: Data(), oldNum: baseNum, isNewState: true, now: now)
                mindelayClock = nil
            } else if sendDue {
                nextSendTime = nil
                mindelayClock = nil
            }
        } else {
            let isNewState = totalEvents != sentStates.last!.eventCount
            datagrams = sendInstruction(diff: diff, oldNum: baseNum, isNewState: isNewState, now: now)
            mindelayClock = nil
        }
        return (datagrams, deadline(now: now))
    }

    private mutating func sendInstruction(diff: Data, oldNum: UInt64, isNewState: Bool, now: UInt64) -> [Data] {
        // Shutdown first: once a uint64.max state is queued, computing
        // `last.num + 1` would overflow. mosh's num space never otherwise
        // approaches the top, so a saturating guard is only cosmetic.
        let newNum: UInt64
        if shutdownInProgress {
            newNum = .max
        } else if isNewState {
            newNum = sentStates.last!.num == .max ? .max : sentStates.last!.num + 1
        } else {
            newNum = sentStates.last!.num
        }

        if newNum != sentStates.last!.num {
            sentStates.append(SentState(num: newNum, eventCount: totalEvents, sentAt: now))
            if sentStates.count > Self.sentStatesCap {
                sentStates.remove(at: 1) // keep the known front and the newest
            }
        } else {
            sentStates[sentStates.count - 1].sentAt = now
        }

        let ackNum: UInt64 = counterpartyShutdown ? .max : headNum
        var instruction = MoshInstruction()
        instruction.oldNum = oldNum
        instruction.newNum = newNum
        instruction.ackNum = ackNum
        instruction.throwawayNum = sentStates[0].num
        instruction.diff = diff
        instruction.chaff = Self.chaff()

        if newNum == .max { shutdownTries += 1 }
        if ackNum == .max { counterpartyAckSent = true }

        assumedReceiverNum = newNum
        nextAckTime = now + Self.ackInterval
        nextSendTime = nil
        pendingDataAck = false

        let compressed = zlib.compress(instruction.encoded())
        return fragmenter.fragments(of: compressed, budget: budget).map {
            packets.seal($0, now: now)
        }
    }

    private func encodeDiff(fromEventCount count: Int) -> Data {
        guard count < totalEvents else { return Data() }
        return MoshUserMessage.encode(events.dropFirst(count - eventOffset))
    }

    private static func chaff() -> Data {
        Data((0 ..< Int.random(in: 0 ... 16)).map { _ in UInt8.random(in: .min ... .max) })
    }

    // MARK: - Timers (transportsender-impl.h calculate_timers)

    private mutating func calculateTimers(now: UInt64) {
        updateAssumedReceiverState(now: now)

        if pendingDataAck {
            nextAckTime = min(nextAckTime, now + Self.ackDelay)
        }

        let back = sentStates.last!
        let assumedCount = sentStates.first(where: { $0.num == assumedReceiverNum })?.eventCount
            ?? sentStates[0].eventCount
        let retryWindowOpen = lastHeard + Self.activeRetryTimeout > now

        if totalEvents != back.eventCount {
            // Fresh input: collect for SEND_MINDELAY, pace at the frame rate.
            let clock = mindelayClock ?? now
            mindelayClock = clock
            nextSendTime = max(clock + Self.sendMindelay, back.sentAt + sendInterval())
        } else if totalEvents != assumedCount, retryWindowOpen {
            nextSendTime = back.sentAt + sendInterval()
            if let clock = mindelayClock {
                nextSendTime = max(nextSendTime!, clock + Self.sendMindelay)
            }
        } else if totalEvents != sentStates[0].eventCount, retryWindowOpen {
            nextSendTime = back.sentAt + packets.rto + Self.ackDelay
        } else {
            nextSendTime = nil
        }

        if shutdownInProgress || counterpartyShutdown {
            nextAckTime = min(nextAckTime, back.sentAt + sendInterval())
        }
    }

    private mutating func updateAssumedReceiverState(now: UInt64) {
        // The front is known-received (acked); give the benefit of the
        // doubt to anything sent within an RTO+delay of now.
        var assumed = sentStates[0]
        for state in sentStates.dropFirst() {
            if now - state.sentAt < packets.rto + Self.ackDelay {
                assumed = state
            } else {
                break
            }
        }
        assumedReceiverNum = assumed.num
    }

    /// Two frames per RTT, clamped — mosh's send_interval().
    private func sendInterval() -> UInt64 {
        UInt64((packets.srtt / 2).rounded(.up))
            .clamped(to: Self.sendIntervalMin ... Self.sendIntervalMax)
    }

    private func deadline(now: UInt64) -> UInt64 {
        var next = nextAckTime
        if let sendTime = nextSendTime {
            next = min(next, sendTime)
        }
        // The shutdown speed-up must shape the wakeup too, or retries pace
        // at the 3 s heartbeat instead of the frame interval.
        if shutdownInProgress || counterpartyShutdown {
            next = min(next, sentStates.last!.sentAt + sendInterval())
        }
        return max(next, now + 1)
    }

    // MARK: - Session status

    /// The handshake (either side's) has finished or timed out — close the
    /// socket.
    func shouldClose(now: UInt64) -> Bool {
        if shutdownAcked || counterpartyAckSent { return true }
        if shutdownInProgress {
            return shutdownTries >= Self.shutdownRetries
                || now - shutdownStart >= Self.activeRetryTimeout
        }
        return false
    }

    /// The peer ended the session (its command exited) rather than us.
    var peerInitiatedShutdown: Bool {
        counterpartyShutdown && !shutdownInProgress
    }

    /// Packets flow but nothing applies — the head-only receiver lost the
    /// thread (see type comment). The session recovers by reconnecting.
    func isDesynced(now: UInt64) -> Bool {
        unapplicable > 20 && now - lastAdvance > 4000 && now - lastHeard < 2000
    }

    /// ms since the server was last heard — drives the contact lamp.
    func quiet(now: UInt64) -> UInt64 {
        now - min(lastHeard, now)
    }
}

extension UInt64 {
    fileprivate func clamped(to range: ClosedRange<UInt64>) -> UInt64 {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
