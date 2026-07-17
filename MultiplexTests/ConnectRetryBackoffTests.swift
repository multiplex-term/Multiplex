import XCTest
@testable import Multiplex

final class ConnectRetryBackoffTests: XCTestCase {
    func testConsecutiveFailuresRampFromFiveToSixtySeconds() {
        var backoff = ConnectRetryBackoff()
        var now = Date(timeIntervalSince1970: 1_000)

        for delay in [5.0, 10.0, 20.0, 40.0, 60.0] {
            backoff.registerFailure(now: now)
            XCTAssertFalse(backoff.shouldAttempt(now: now.addingTimeInterval(delay - 0.001)))
            now = now.addingTimeInterval(delay)
            XCTAssertTrue(backoff.shouldAttempt(now: now))
        }
    }

    func testDelayRemainsCappedAtSixtySeconds() {
        var backoff = ConnectRetryBackoff()
        var now = Date(timeIntervalSince1970: 2_000)

        for delay in [5.0, 10.0, 20.0, 40.0, 60.0] {
            backoff.registerFailure(now: now)
            now = now.addingTimeInterval(delay)
        }

        for _ in 0..<3 {
            backoff.registerFailure(now: now)
            XCTAssertFalse(backoff.shouldAttempt(now: now.addingTimeInterval(59.999)))
            now = now.addingTimeInterval(60)
            XCTAssertTrue(backoff.shouldAttempt(now: now))
        }
    }

    func testResetAllowsImmediatelyAndRestartsRamp() {
        var backoff = ConnectRetryBackoff()
        let now = Date(timeIntervalSince1970: 3_000)

        backoff.registerFailure(now: now)
        backoff.registerFailure(now: now.addingTimeInterval(5))
        XCTAssertFalse(backoff.shouldAttempt(now: now.addingTimeInterval(6)))

        let resetAt = now.addingTimeInterval(6)
        backoff.reset()
        XCTAssertTrue(backoff.shouldAttempt(now: resetAt))

        backoff.registerFailure(now: resetAt)
        XCTAssertFalse(backoff.shouldAttempt(now: resetAt.addingTimeInterval(4.999)))
        XCTAssertTrue(backoff.shouldAttempt(now: resetAt.addingTimeInterval(5)))
    }

    func testAttemptIsAllowedExactlyAtDeadline() {
        var backoff = ConnectRetryBackoff()
        let now = Date(timeIntervalSince1970: 4_000)

        backoff.registerFailure(now: now)

        XCTAssertFalse(backoff.shouldAttempt(now: now.addingTimeInterval(4.999)))
        XCTAssertTrue(backoff.shouldAttempt(now: now.addingTimeInterval(5)))
    }
}
