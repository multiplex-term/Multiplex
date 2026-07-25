import XCTest
@testable import Multiplex

/// The whole suspension-repair matrix without a socket: who authorizes an
/// automatic re-attach, who is left to the manual RECONNECT panel, and how
/// the attempt budget behaves.
final class SessionResumePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: The case this exists for

    func testTransportKilledWhileBackgroundedResumesOnReturn() {
        var policy = SessionResumePolicy()
        policy.appMovedToBackground(isLive: true)

        // The close is discovered while the app is still away: nothing is
        // attempted there, the repair is owed to the next foreground.
        XCTAssertNil(policy.transportEnded(now: now, isForeground: false))
        XCTAssertEqual(policy.attempts, 0)

        XCTAssertEqual(
            policy.appReturnedToForeground(now: now.addingTimeInterval(1), isLive: false),
            0,
            "the first attempt runs immediately on return"
        )
        XCTAssertEqual(policy.attempts, 1)
    }

    func testCloseArrivingAfterTheAppIsBackStillCountsAsSuspensionDamage() {
        var policy = SessionResumePolicy()
        policy.appMovedToBackground(isLive: true)
        // Frozen event loops deliver the socket's death on resume, which can
        // land after the app is already foreground: the tab still reads live.
        XCTAssertNil(policy.appReturnedToForeground(now: now, isLive: true))

        XCTAssertEqual(
            policy.transportEnded(now: now.addingTimeInterval(1), isForeground: true),
            0
        )
    }

    func testCloseLongAfterReturningIsTheUserEndingTheSession() {
        var policy = SessionResumePolicy()
        policy.appMovedToBackground(isLive: true)
        XCTAssertNil(policy.appReturnedToForeground(now: now, isLive: true))

        let afterGrace = now.addingTimeInterval(SessionResumePolicy.graceAfterForeground)
        XCTAssertNil(
            policy.transportEnded(now: afterGrace, isForeground: true),
            "an exit typed minutes later must not be re-attached"
        )
    }

    func testDeliberateExitWithoutAnySuspensionIsNeverResumed() {
        var policy = SessionResumePolicy()
        XCTAssertNil(policy.transportEnded(now: now, isForeground: true))
        XCTAssertEqual(policy.attempts, 0)
    }

    // MARK: Arming

    func testBackgroundingAnAlreadyEndedTabArmsNothing() {
        var policy = SessionResumePolicy()
        policy.appMovedToBackground(isLive: false)

        XCTAssertNil(policy.appReturnedToForeground(now: now, isLive: false))
        XCTAssertNil(policy.transportEnded(now: now, isForeground: true))
    }

    func testForegroundWithNoPriorBackgroundDoesNothing() {
        var policy = SessionResumePolicy()
        XCTAssertNil(policy.appReturnedToForeground(now: now, isLive: true))
        XCTAssertNil(policy.appReturnedToForeground(now: now, isLive: false))
    }

    func testGraceWindowIsRearmedByEachSuspension() {
        var policy = SessionResumePolicy()
        policy.appMovedToBackground(isLive: true)
        XCTAssertNil(policy.appReturnedToForeground(now: now, isLive: true))
        let stale = now.addingTimeInterval(SessionResumePolicy.graceAfterForeground + 60)

        policy.appMovedToBackground(isLive: true)
        XCTAssertNil(policy.appReturnedToForeground(now: stale, isLive: true))
        XCTAssertEqual(policy.transportEnded(now: stale.addingTimeInterval(1), isForeground: true), 0)
    }

    // MARK: Attempt budget

    func testFailedAttemptsRetryOnASpacedBudgetThenGiveUp() {
        var policy = SessionResumePolicy()
        policy.appMovedToBackground(isLive: true)
        XCTAssertEqual(policy.appReturnedToForeground(now: now, isLive: false), 0)

        // Each failure re-enters through the same ended path.
        XCTAssertEqual(policy.transportEnded(now: now.addingTimeInterval(1), isForeground: true), 2)
        XCTAssertEqual(policy.transportEnded(now: now.addingTimeInterval(2), isForeground: true), 5)
        XCTAssertEqual(policy.attempts, SessionResumePolicy.maxAttempts)

        XCTAssertNil(
            policy.transportEnded(now: now.addingTimeInterval(3), isForeground: true),
            "a host that is genuinely gone falls back to the manual panel"
        )
    }

    func testRetryOwedFromTheBackgroundWaitsForTheForeground() {
        var policy = SessionResumePolicy()
        policy.appMovedToBackground(isLive: true)
        XCTAssertEqual(policy.appReturnedToForeground(now: now, isLive: false), 0)

        // Backgrounded again mid-recovery, and the attempt fails while away.
        policy.appMovedToBackground(isLive: false)
        XCTAssertNil(policy.transportEnded(now: now.addingTimeInterval(1), isForeground: false))

        XCTAssertEqual(
            policy.appReturnedToForeground(now: now.addingTimeInterval(2), isLive: false),
            2,
            "the owed retry keeps its place in the budget"
        )
    }

    func testGoingLiveRestoresTheFullBudget() {
        var policy = SessionResumePolicy()
        policy.appMovedToBackground(isLive: true)
        XCTAssertEqual(policy.appReturnedToForeground(now: now, isLive: false), 0)
        XCTAssertEqual(policy.transportEnded(now: now, isForeground: true), 2)

        policy.sessionBecameLive()
        XCTAssertEqual(policy.attempts, 0)
        XCTAssertNil(
            policy.transportEnded(now: now, isForeground: true),
            "a session that reached live again has no repair pending"
        )

        policy.appMovedToBackground(isLive: true)
        XCTAssertEqual(policy.appReturnedToForeground(now: now, isLive: false), 0)
    }

    func testManualReconnectReArmsAutomaticRecovery() {
        var policy = SessionResumePolicy()
        policy.appMovedToBackground(isLive: true)
        XCTAssertEqual(policy.appReturnedToForeground(now: now, isLive: false), 0)
        XCTAssertEqual(policy.transportEnded(now: now, isForeground: true), 2)
        XCTAssertEqual(policy.transportEnded(now: now, isForeground: true), 5)

        policy.userReconnected()
        XCTAssertEqual(policy.attempts, 0)

        policy.appMovedToBackground(isLive: true)
        XCTAssertEqual(
            policy.appReturnedToForeground(now: now, isLive: false),
            0,
            "the next suspension gets a clean budget"
        )
    }
}
