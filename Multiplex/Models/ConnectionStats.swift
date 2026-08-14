import Foundation

/// One timed measurement in a per-host stat series (milliseconds unless the
/// owning series says otherwise).
struct LinkStatSample: Equatable, Sendable {
    var at: Date
    var value: Double
}

/// Fixed-capacity append-only sample ring. Session-only by design: the stats
/// feature never persists measurements, so a bounded in-memory window is the
/// whole storage story.
///
/// Invariant: `nextWrite` only advances once the ring is full, so
/// `nextWrite != 0` implies `storage.count == capacity`.
struct LinkStatRing: Equatable, Sendable {
    private var storage: [LinkStatSample] = []
    /// Once full, the slot the next append overwrites — the oldest sample.
    private var nextWrite = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }

    var latest: LinkStatSample? {
        guard !storage.isEmpty else { return nil }
        // Not-full ⇒ nextWrite == 0 ⇒ this is simply the last element.
        return storage[(nextWrite + storage.count - 1) % storage.count]
    }

    mutating func append(_ sample: LinkStatSample) {
        if storage.count < capacity {
            storage.append(sample)
        } else {
            storage[nextWrite] = sample
            nextWrite = (nextWrite + 1) % capacity
        }
    }

    /// The newest `limit` values, oldest → newest — right-sized for a meter
    /// that can only draw so many bars, without materializing the whole ring.
    func recentValues(limit: Int) -> [Double] {
        let take = min(max(0, limit), storage.count)
        guard take > 0 else { return [] }
        var values = [Double]()
        values.reserveCapacity(take)
        // Walk forward from the oldest of the window; not-full ⇒ nextWrite 0.
        let start = (nextWrite + storage.count - take) % storage.count
        for offset in 0..<take {
            values.append(storage[(start + offset) % storage.count].value)
        }
        return values
    }
}

/// A point-in-time snapshot of one live mosh session's transport counters.
/// Produced by the transport engine (which measures all of this as part of
/// the protocol anyway), consumed by the stats center — pure data both ways.
struct MoshLinkReport: Equatable, Sendable {
    /// RFC 6298-shaped smoothed RTT, sampled from every datagram's
    /// timestamp echo.
    var srttMilliseconds: Double
    var rttVarianceMilliseconds: Double
    /// Authentic in-order datagrams actually opened.
    var packetsHeard: Int
    /// Datagrams the server has sent, inferred from the highest sequence
    /// number seen. Reordered late arrivals stay counted as missing — the
    /// estimate is deliberately pessimistic rather than wrong.
    var packetsExpected: Int
    /// User events (keystrokes, resizes) not yet acknowledged by the server.
    var unackedEvents: Int
    /// Fresh sockets beyond the first — mosh's port hops across network
    /// moves, dead NAT mappings, and better-path switches.
    var roamCount: Int

    /// Server→client loss estimate in 0...1.
    var lossFraction: Double {
        guard packetsExpected > 0 else { return 0 }
        return Double(max(0, packetsExpected - packetsHeard)) / Double(packetsExpected)
    }
}

/// Everything the stats feature knows about one host, assembled by the
/// center from passive taps. Value-typed so a UI read is a stable snapshot.
struct HostLinkStats: Equatable, Sendable {
    /// A mosh SRTT sample older than this yields the headline back to the
    /// probe number — the session it came from is gone or suspended.
    static let moshFreshnessWindow: TimeInterval = 15

    /// Deck probe exec round-trips (ms), one per settled probe cycle.
    var probeRTT = LinkStatRing(capacity: 360)
    /// Live mosh SRTT samples (ms), pushed while a mosh tab is attached.
    var moshRTT = LinkStatRing(capacity: 360)
    /// Newest keystroke → paint sample (ms), both transports. A single
    /// sample because that is all the board renders.
    var latestEcho: LinkStatSample?

    var latestMosh: MoshLinkReport?

    /// Connect-phase split from the control connection's last (re)connect.
    var connectSecretsMilliseconds: Double?
    var connectSSHMilliseconds: Double?
    var lastConnectAt: Date?

    /// Session volume across this host's terminal tabs (bytes).
    var bytesIn = 0
    var bytesOut = 0
    /// The probe's own payload for one cycle, all monitored backends summed.
    var probePayloadBytes: Int?

    /// Terminal tabs that went live a second (or later) time.
    var relinks = 0
    var lastDropReason: String?
    /// Set while at least one terminal tab is live; the start of the current
    /// continuous live period.
    var liveSince: Date?
    /// Live terminal tabs backing `liveSince` bookkeeping.
    var liveTabs = 0

    var lastProbeAt: Date?
    /// The control connection's last failure message (connect or probe).
    var lastFailure: String?

    enum RTTSource: Equatable, Sendable {
        /// Continuous, from every datagram of a live mosh session.
        case moshSRTT
        /// The deck probe's timed exec round-trip (~5 s cadence).
        case probe
    }

    /// The one number a chip shows: fresh mosh SRTT when a live session is
    /// feeding it, otherwise the latest probe round-trip.
    func headlineRTT(now: Date = Date()) -> (milliseconds: Double, source: RTTSource)? {
        if let sample = moshRTT.latest,
           now.timeIntervalSince(sample.at) <= Self.moshFreshnessWindow {
            return (sample.value, .moshSRTT)
        }
        guard let sample = probeRTT.latest else { return nil }
        return (sample.value, .probe)
    }
}

/// Shared formatting for stat chrome — chips, strips, and tiles must agree
/// on how a number reads. Deliberately the deck's terse mono voice
/// ("3.4K", "12 MS"), not the file viewer's prose "3.4 KB" — the two
/// surfaces speak differently on purpose.
enum ConnectionStatsFormat {
    /// "12 MS", "1.2 S" — milliseconds with a sub-second/seconds split.
    static func milliseconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 10_000 { return String(format: "%.0f S", value / 1000) }
        if value >= 1000 { return String(format: "%.1f S", value / 1000) }
        return "\(Int(value.rounded())) MS"
    }

    /// "0.0%", "1.4%" — loss fractions.
    static func lossPercent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    /// "84 B", "3.4K", "1.2M", "2.1G" — byte volumes in the UMD row's
    /// compact voice.
    static func bytes(_ count: Int) -> String {
        switch count {
        case ..<1000:
            return "\(max(0, count)) B"
        case ..<1_000_000:
            return String(format: "%.1fK", Double(count) / 1000)
        case ..<1_000_000_000:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        default:
            return String(format: "%.1fG", Double(count) / 1_000_000_000)
        }
    }

    /// "3 S", "41 M", "2 H 14 M" — ages and uptimes.
    static func age(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "—" }
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds) S" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) M" }
        return "\(minutes / 60) H \(String(format: "%02d", minutes % 60)) M"
    }
}
