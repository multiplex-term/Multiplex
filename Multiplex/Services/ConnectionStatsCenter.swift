import Foundation
import Observation

/// Per-host observable box carrying the one string a deck rail renders.
/// Sections observe their own host's box, so a fleet of stat pushes can
/// never wake every rail — and the box only mutates when the *formatted*
/// number actually changed.
@MainActor
@Observable
final class HostStatsCaptionSignal {
    /// nil while collection is off or nothing has been measured yet.
    fileprivate(set) var caption: String?
}

/// The app-wide sink for passive connection measurements, keyed by host.
///
/// Writers push from where the numbers already exist — the hub's timed probe
/// cycle, a mosh session's transport counters, the terminal byte funnels,
/// the fork's echo-latency window — and the panel/chips read value
/// snapshots back out. Everything lives in session-only ring buffers:
/// nothing is persisted, nothing is synced, and turning the setting off
/// drops it all.
///
/// Observation is deliberately two-tier: rails observe their host's
/// `captionSignal` (fires only on a changed reading), while the board
/// observes the coarse `revision` heartbeat. Buffers themselves are
/// `@ObservationIgnored` — a keystroke's echo sample must not re-render a
/// wall.
@MainActor
@Observable
final class ConnectionStatsCenter {
    static let shared = ConnectionStatsCenter()

    /// Mirrors `ConnectionStatsSetting`; the one observable gate every chip
    /// and entry point reads. Flipped only through `setCollecting` — the
    /// center is the setting's only writer, which is what keeps this mirror
    /// honest.
    private(set) var isCollecting: Bool
    /// Coarse heartbeat for the board; rails use per-host signals instead.
    private(set) var revision = 0
    /// Meaningful network-path changes while collecting (fleet-wide fact,
    /// session-scoped like every other number here — deliberately not the
    /// monitor's lifetime `reconnectRevision`).
    private(set) var networkChanges = 0

    @ObservationIgnored private var stats: [UUID: HostLinkStats] = [:]
    @ObservationIgnored private var captionSignals: [UUID: HostStatsCaptionSignal] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        isCollecting = ConnectionStatsSetting.isEnabled(defaults: defaults)
    }

    // MARK: Reads

    func snapshot(for hostID: UUID) -> HostLinkStats? {
        stats[hostID]
    }

    /// The rail chip's observation surface for one host. Stable per host —
    /// observe it once and re-arm on change.
    func captionSignal(for hostID: UUID) -> HostStatsCaptionSignal {
        if let existing = captionSignals[hostID] { return existing }
        let signal = HostStatsCaptionSignal()
        captionSignals[hostID] = signal
        return signal
    }

    // MARK: Setting

    /// OFF is fully off: persist the choice, stop recording, and drop every
    /// buffer so nothing lingers for a later re-enable to resurrect.
    func setCollecting(_ collecting: Bool) {
        guard collecting != isCollecting else { return }
        ConnectionStatsSetting.setEnabled(collecting, defaults: defaults)
        isCollecting = collecting
        if !collecting {
            stats.removeAll()
            networkChanges = 0
            for signal in captionSignals.values where signal.caption != nil {
                signal.caption = nil
            }
        }
        revision &+= 1
    }

    // MARK: Probe taps (ConnectionHub)

    func recordProbe(hostID: UUID, rttMilliseconds: Double, payloadBytes: Int) {
        guard isCollecting else { return }
        mutate(hostID) { host, at in
            host.probeRTT.append(LinkStatSample(at: at, value: rttMilliseconds))
            host.probePayloadBytes = payloadBytes
            host.lastProbeAt = at
            host.lastFailure = nil
        }
    }

    /// The control connection settled UNREACHABLE — connect or probe, the
    /// hub's `markFailed` is the one seam either lands on.
    func recordUnreachable(hostID: UUID, message: String) {
        guard isCollecting else { return }
        mutate(hostID) { host, _ in
            host.lastFailure = message
        }
    }

    func recordConnect(hostID: UUID, secretsMilliseconds: Double, sshMilliseconds: Double) {
        guard isCollecting else { return }
        mutate(hostID) { host, at in
            host.connectSecretsMilliseconds = secretsMilliseconds
            host.connectSSHMilliseconds = sshMilliseconds
            host.lastConnectAt = at
        }
    }

    // MARK: Terminal-tab taps (TerminalSessionController)

    func recordTransportLive(hostID: UUID) {
        guard isCollecting else { return }
        mutate(hostID) { host, at in
            host.liveTabs += 1
            if host.liveSince == nil { host.liveSince = at }
        }
    }

    func recordTransportEnded(hostID: UUID, reason: String?) {
        guard isCollecting else { return }
        mutate(hostID) { host, _ in
            host.liveTabs = max(0, host.liveTabs - 1)
            if host.liveTabs == 0 { host.liveSince = nil }
            if let reason, !reason.isEmpty {
                host.lastDropReason = reason
            }
        }
    }

    /// A tab went live for the second (or later) time — auto-resume or the
    /// RECONNECT chip actually re-attaching, never mere attempts.
    func recordRelink(hostID: UUID) {
        guard isCollecting else { return }
        mutate(hostID) { host, _ in
            host.relinks += 1
        }
    }

    func recordMosh(hostID: UUID, report: MoshLinkReport) {
        guard isCollecting else { return }
        mutate(hostID) { host, at in
            host.moshRTT.append(LinkStatSample(at: at, value: report.srttMilliseconds))
            host.latestMosh = report
        }
    }

    /// Echo samples skip both observation tiers — they can arrive per
    /// keystroke burst, and the ~5 s heartbeats already re-render anything
    /// that shows them.
    func recordEcho(hostID: UUID, milliseconds: Double) {
        guard isCollecting else { return }
        stats[hostID, default: HostLinkStats()].latestEcho =
            LinkStatSample(at: now(), value: milliseconds)
    }

    func addBytes(hostID: UUID, bytesIn: Int, bytesOut: Int) {
        guard isCollecting, bytesIn > 0 || bytesOut > 0 else { return }
        mutate(hostID) { host, _ in
            host.bytesIn += bytesIn
            host.bytesOut += bytesOut
        }
    }

    // MARK: Device taps

    func recordNetworkChange() {
        guard isCollecting else { return }
        networkChanges += 1
        revision &+= 1
    }

    /// A removed host's buffers have nothing left to describe.
    func dropStats(for hostID: UUID) {
        guard stats.removeValue(forKey: hostID) != nil else { return }
        if let signal = captionSignals[hostID], signal.caption != nil {
            signal.caption = nil
        }
        revision &+= 1
    }

    // MARK: -

    private func mutate(_ hostID: UUID, _ change: (inout HostLinkStats, Date) -> Void) {
        let at = now()
        // In place through the defaulted subscript — copying the struct out
        // first would defeat the rings' copy-on-write and memcpy a full
        // buffer per sample.
        change(&stats[hostID, default: HostLinkStats()], at)
        refreshCaption(for: hostID, now: at)
        revision &+= 1
    }

    private func refreshCaption(for hostID: UUID, now: Date) {
        let caption = stats[hostID]?.headlineRTT(now: now).map {
            ConnectionStatsFormat.milliseconds($0.milliseconds)
        }
        let signal = captionSignal(for: hostID)
        if signal.caption != caption { signal.caption = caption }
    }
}
