import XCTest
@testable import Multiplex

/// Who may talk to a host while the app is not frontmost, and when leaving the
/// screen is worth an assertion at all — the whole matrix without a scene, a
/// socket, or a real suspension.
final class BackgroundActivityPolicyTests: XCTestCase {
    private func host(
        _ name: String,
        keepAlive: Bool = false,
        enabled: Bool = true
    ) -> Host {
        var host = Host(name: name, hostname: "\(name).invalid", username: "demo")
        host.backgroundKeepAlive = keepAlive
        host.isEnabled = enabled
        return host
    }

    // MARK: Permission to work

    func testForegroundWorkNeverNeedsAnOptIn() {
        for activity in [
            BackgroundActivityPolicy.AppActivity.active,
            .inactive,
        ] {
            XCTAssertTrue(
                BackgroundActivityPolicy.permitsWork(
                    activity: activity,
                    hostKeepsAlive: false,
                    hasBackgroundGrant: false
                ),
                "\(activity) is an unsuspended app: probing is the old behaviour"
            )
        }
    }

    /// The case the widened gate exists for: a Stage Manager window on screen
    /// beside the app being typed in is `.inactive`, and used to stop probing.
    func testAVisibleButUnfocusedAppKeepsProbing() {
        XCTAssertTrue(
            BackgroundActivityPolicy.permitsWork(
                activity: .inactive,
                hostKeepsAlive: false,
                hasBackgroundGrant: false
            )
        )
    }

    func testBackgroundWorkNeedsBothTheOptInAndAHeldAssertion() {
        XCTAssertTrue(
            BackgroundActivityPolicy.permitsWork(
                activity: .background,
                hostKeepsAlive: true,
                hasBackgroundGrant: true
            )
        )
        XCTAssertFalse(
            BackgroundActivityPolicy.permitsWork(
                activity: .background,
                hostKeepsAlive: true,
                hasBackgroundGrant: false
            ),
            "the grant ran out — the process is about to be suspended mid-exec"
        )
        XCTAssertFalse(
            BackgroundActivityPolicy.permitsWork(
                activity: .background,
                hostKeepsAlive: false,
                hasBackgroundGrant: true
            ),
            "another host bought the time; this one keeps the default promise"
        )
    }

    // MARK: Whether to take the assertion

    func testNoOptedInHostTakesNoBackgroundTime() {
        XCTAssertFalse(
            BackgroundActivityPolicy.wantsBackgroundTime(
                hosts: [host("a"), host("b")],
                hostIDsWithLiveSessions: []
            ),
            "the default install's background behaviour must be unchanged"
        )
    }

    func testAnOptedInHostTheDeckProbesWantsBackgroundTime() {
        XCTAssertTrue(
            BackgroundActivityPolicy.wantsBackgroundTime(
                hosts: [host("a"), host("b", keepAlive: true)],
                hostIDsWithLiveSessions: []
            )
        )
    }

    /// Disabling stops the app dialling on its own; windows already open keep
    /// running, so their transports are still worth holding awake.
    func testADisabledOptedInHostWantsTimeOnlyForALiveTab() {
        let parked = host("parked", keepAlive: true, enabled: false)
        XCTAssertFalse(
            BackgroundActivityPolicy.wantsBackgroundTime(
                hosts: [parked],
                hostIDsWithLiveSessions: []
            )
        )
        XCTAssertTrue(
            BackgroundActivityPolicy.wantsBackgroundTime(
                hosts: [parked],
                hostIDsWithLiveSessions: [parked.id]
            )
        )
    }

    func testALiveTabOnAHostThatNeverOptedInWantsNothing() {
        let plain = host("plain")
        XCTAssertFalse(
            BackgroundActivityPolicy.wantsBackgroundTime(
                hosts: [plain],
                hostIDsWithLiveSessions: [plain.id]
            )
        )
    }

    // MARK: The record

    func testKeepAliveIsOffForRecordsWrittenBeforeTheSwitchExisted() throws {
        let json = Data(
            #"{"name":"legacy","hostname":"legacy.invalid","username":"demo"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(Host.self, from: json)
        XCTAssertFalse(
            decoded.backgroundKeepAlive,
            "keep-alive spends battery on a host's behalf — never inherited"
        )
    }

    func testKeepAliveSurvivesACodableRoundTrip() throws {
        let original = host("devbox", keepAlive: true)
        let decoded = try JSONDecoder().decode(
            Host.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertTrue(decoded.backgroundKeepAlive)
    }

    /// The flag rides the connection identity so a flip — here or synced from
    /// another device — restarts the wall feed, which is the only thing that
    /// refreshes the host snapshot its loop reads.
    func testFlippingKeepAliveChangesTheConnectionModelConfiguration() {
        let off = host("devbox")
        var on = off
        on.backgroundKeepAlive = true
        XCTAssertFalse(off.hasSameConnectionModelConfiguration(as: on))
    }
}
