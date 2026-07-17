import Foundation

/// Retry schedule for fresh SSH control-connection failures.
struct ConnectRetryBackoff {
    private static let delays: [Double] = [5, 10, 20, 40, 60]

    private var consecutiveFailures = 0
    private var retryNotBefore: Date?

    func shouldAttempt(now: Date) -> Bool {
        guard let retryNotBefore else { return true }
        return now >= retryNotBefore
    }

    mutating func registerFailure(now: Date) {
        let index = min(consecutiveFailures, Self.delays.count - 1)
        retryNotBefore = now.addingTimeInterval(Self.delays[index])
        consecutiveFailures = min(consecutiveFailures + 1, Self.delays.count)
    }

    mutating func reset() {
        consecutiveFailures = 0
        retryNotBefore = nil
    }
}
