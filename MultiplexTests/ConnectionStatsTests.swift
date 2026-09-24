import XCTest
@testable import Multiplex

final class ConnectionStatsTests: XCTestCase {
    private func sample(_ seconds: TimeInterval, _ value: Double) -> LinkStatSample {
        LinkStatSample(at: Date(timeIntervalSinceReferenceDate: seconds), value: value)
    }

    // MARK: LinkStatRing

    func testRingKeepsInsertionOrderBelowCapacity() {
        var ring = LinkStatRing(capacity: 4)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertNil(ring.latest)
        XCTAssertEqual(ring.recentValues(limit: 8), [])

        ring.append(sample(1, 10))
        ring.append(sample(2, 20))
        ring.append(sample(3, 30))

        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.recentValues(limit: 8), [10, 20, 30])
        XCTAssertEqual(ring.latest?.value, 30)
    }

    func testRingWrapsOverwritingOldestAndKeepsOrder() {
        var ring = LinkStatRing(capacity: 3)
        for i in 1...5 {
            ring.append(sample(TimeInterval(i), Double(i * 10)))
        }

        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.recentValues(limit: 8), [30, 40, 50])
        XCTAssertEqual(ring.latest?.value, 50)

        // Exactly at capacity, no wrap yet: plain insertion order.
        var exact = LinkStatRing(capacity: 3)
        for i in 1...3 {
            exact.append(sample(TimeInterval(i), Double(i)))
        }
        XCTAssertEqual(exact.recentValues(limit: 3), [1, 2, 3])
        XCTAssertEqual(exact.latest?.value, 3)
    }

    func testRecentValuesTakesTheNewestWindow() {
        var ring = LinkStatRing(capacity: 4)
        for i in 1...6 {
            ring.append(sample(TimeInterval(i), Double(i)))
        }
        // Ring holds 3,4,5,6 — a limit smaller than the count keeps the
        // newest, still oldest → newest.
        XCTAssertEqual(ring.recentValues(limit: 2), [5, 6])
        XCTAssertEqual(ring.recentValues(limit: 0), [])
    }

    // MARK: MoshLinkReport

    func testLossFraction() {
        var report = MoshLinkReport(
            srttMilliseconds: 12,
            rttVarianceMilliseconds: 3,
            packetsHeard: 95,
            packetsExpected: 100,
            unackedEvents: 0,
            roamCount: 2
        )
        XCTAssertEqual(report.lossFraction, 0.05, accuracy: 0.0001)

        report.packetsExpected = 0
        XCTAssertEqual(report.lossFraction, 0)

        // Reordering can make heard exceed expected transiently; loss never
        // goes negative.
        report.packetsExpected = 10
        report.packetsHeard = 12
        XCTAssertEqual(report.lossFraction, 0)
    }

    // MARK: Headline RTT

    func testHeadlineRTTPrefersFreshMoshAndFallsBackToProbe() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        var stats = HostLinkStats()
        XCTAssertNil(stats.headlineRTT(now: now))

        stats.probeRTT.append(LinkStatSample(at: now.addingTimeInterval(-2), value: 84))
        XCTAssertEqual(stats.headlineRTT(now: now)?.milliseconds, 84)
        XCTAssertEqual(stats.headlineRTT(now: now)?.source, .probe)

        // A fresh mosh sample outranks the probe number.
        stats.moshRTT.append(LinkStatSample(at: now.addingTimeInterval(-5), value: 12))
        XCTAssertEqual(stats.headlineRTT(now: now)?.milliseconds, 12)
        XCTAssertEqual(stats.headlineRTT(now: now)?.source, .moshSRTT)

        // A stale one (session gone/suspended) yields back to the probe.
        let later = now.addingTimeInterval(HostLinkStats.moshFreshnessWindow + 1)
        XCTAssertEqual(stats.headlineRTT(now: later)?.source, .probe)
    }

    // MARK: Formatting

    func testFormatting() {
        XCTAssertEqual(ConnectionStatsFormat.milliseconds(12.4), "12 MS")
        XCTAssertEqual(ConnectionStatsFormat.milliseconds(999), "999 MS")
        XCTAssertEqual(ConnectionStatsFormat.milliseconds(1400), "1.4 S")
        XCTAssertEqual(ConnectionStatsFormat.milliseconds(12_000), "12 S")
        XCTAssertEqual(ConnectionStatsFormat.milliseconds(-1), "—")

        XCTAssertEqual(ConnectionStatsFormat.lossPercent(0), "0.0%")
        XCTAssertEqual(ConnectionStatsFormat.lossPercent(0.014), "1.4%")

        XCTAssertEqual(ConnectionStatsFormat.bytes(84), "84 B")
        XCTAssertEqual(ConnectionStatsFormat.bytes(3400), "3.4K")
        XCTAssertEqual(ConnectionStatsFormat.bytes(1_200_000), "1.2M")
        XCTAssertEqual(ConnectionStatsFormat.bytes(2_100_000_000), "2.1G")

        XCTAssertEqual(ConnectionStatsFormat.age(3), "3 S")
        XCTAssertEqual(ConnectionStatsFormat.age(41 * 60), "41 M")
        XCTAssertEqual(ConnectionStatsFormat.age(2 * 3600 + 14 * 60), "2 H 14 M")
    }
}

@MainActor
final class ConnectionStatsCenterTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var now = Date(timeIntervalSinceReferenceDate: 0)

    private func makeCenter() -> ConnectionStatsCenter {
        suiteName = "connection-stats-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        return ConnectionStatsCenter(defaults: defaults) { [weak self] in
            self?.now ?? Date()
        }
    }

    override func tearDown() {
        if let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        super.tearDown()
    }

    func testProbeRecordingSnapshotAndCaptionSignal() {
        let center = makeCenter()
        let host = UUID()
        XCTAssertTrue(center.isCollecting)
        XCTAssertNil(center.snapshot(for: host))
        XCTAssertNil(center.captionSignal(for: host).caption)

        center.recordProbe(hostID: host, rttMilliseconds: 84, payloadBytes: 3478)
        let stats = center.snapshot(for: host)
        XCTAssertEqual(stats?.probeRTT.latest?.value, 84)
        XCTAssertEqual(stats?.probePayloadBytes, 3478)
        XCTAssertEqual(stats?.lastProbeAt, now)
        XCTAssertNil(stats?.lastFailure)
        // The rail's per-host signal carries the formatted reading.
        XCTAssertEqual(center.captionSignal(for: host).caption, "84 MS")

        center.recordUnreachable(hostID: host, message: "Timed out.")
        XCTAssertEqual(center.snapshot(for: host)?.lastFailure, "Timed out.")

        // The next good probe clears the failure and updates the signal.
        center.recordProbe(hostID: host, rttMilliseconds: 90, payloadBytes: 3478)
        XCTAssertNil(center.snapshot(for: host)?.lastFailure)
        XCTAssertEqual(center.captionSignal(for: host).caption, "90 MS")
    }

    func testDisableIsFullyOffAndPersists() {
        let center = makeCenter()
        let host = UUID()
        center.recordProbe(hostID: host, rttMilliseconds: 84, payloadBytes: 1)
        center.recordNetworkChange()
        XCTAssertEqual(center.networkChanges, 1)

        center.setCollecting(false)
        XCTAssertFalse(center.isCollecting)
        XCTAssertFalse(ConnectionStatsSetting.isEnabled(defaults: defaults))
        XCTAssertNil(center.snapshot(for: host))
        XCTAssertEqual(center.networkChanges, 0)
        XCTAssertNil(center.captionSignal(for: host).caption)

        // Recorders are inert while off.
        center.recordProbe(hostID: host, rttMilliseconds: 84, payloadBytes: 1)
        center.recordEcho(hostID: host, milliseconds: 21)
        center.recordNetworkChange()
        XCTAssertNil(center.snapshot(for: host))
        XCTAssertEqual(center.networkChanges, 0)

        center.setCollecting(true)
        XCTAssertTrue(ConnectionStatsSetting.isEnabled(defaults: defaults))
        center.recordProbe(hostID: host, rttMilliseconds: 12, payloadBytes: 1)
        XCTAssertEqual(center.snapshot(for: host)?.probeRTT.latest?.value, 12)
        XCTAssertEqual(center.captionSignal(for: host).caption, "12 MS")
    }

    func testLiveTabPairingDrivesUptime() {
        let center = makeCenter()
        let host = UUID()

        center.recordTransportLive(hostID: host)
        XCTAssertEqual(center.snapshot(for: host)?.liveSince, now)

        // A second tab joins; uptime keeps the first tab's start.
        now = now.addingTimeInterval(60)
        center.recordTransportLive(hostID: host)
        XCTAssertEqual(
            center.snapshot(for: host)?.liveSince,
            Date(timeIntervalSinceReferenceDate: 0)
        )

        center.recordTransportEnded(hostID: host, reason: nil)
        XCTAssertNotNil(center.snapshot(for: host)?.liveSince)

        center.recordTransportEnded(hostID: host, reason: "Connection reset.")
        let stats = center.snapshot(for: host)
        XCTAssertNil(stats?.liveSince)
        XCTAssertEqual(stats?.lastDropReason, "Connection reset.")
    }

    func testRelinkBytesMoshAndDrop() {
        let center = makeCenter()
        let host = UUID()

        center.recordRelink(hostID: host)
        center.recordRelink(hostID: host)
        center.addBytes(hostID: host, bytesIn: 1000, bytesOut: 84)
        center.addBytes(hostID: host, bytesIn: 200, bytesOut: 16)
        let report = MoshLinkReport(
            srttMilliseconds: 12.5,
            rttVarianceMilliseconds: 3,
            packetsHeard: 100,
            packetsExpected: 100,
            unackedEvents: 0,
            roamCount: 1
        )
        center.recordMosh(hostID: host, report: report)
        center.recordEcho(hostID: host, milliseconds: 21)
        center.recordConnect(
            hostID: host, secretsMilliseconds: 12, sshMilliseconds: 340)

        let stats = center.snapshot(for: host)
        XCTAssertEqual(stats?.relinks, 2)
        XCTAssertEqual(stats?.bytesIn, 1200)
        XCTAssertEqual(stats?.bytesOut, 100)
        XCTAssertEqual(stats?.latestMosh, report)
        XCTAssertEqual(stats?.moshRTT.latest?.value, 12.5)
        XCTAssertEqual(stats?.latestEcho?.value, 21)
        XCTAssertEqual(stats?.connectSecretsMilliseconds, 12)
        XCTAssertEqual(stats?.connectSSHMilliseconds, 340)
        // A fresh mosh sample wins the signal's headline.
        XCTAssertEqual(center.captionSignal(for: host).caption, "13 MS")

        center.dropStats(for: host)
        XCTAssertNil(center.snapshot(for: host))
        XCTAssertNil(center.captionSignal(for: host).caption)
    }
}
