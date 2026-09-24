import Foundation

/// Thrown when `deadlined` fires before its operation resolves.
struct DeadlineExceeded: Error {}

/// Races `operation` against a wall-clock deadline: whichever side finishes
/// first resumes the caller and cancels the loser. Deliberately unstructured
/// underneath — a `withThrowingTaskGroup` race would re-await the losing
/// child on exit, and Citadel/NIO futures and Network.framework callbacks
/// don't reliably honor task cancellation, so a black-holed connect must
/// fail the caller *now* while the hung task is cancelled best-effort and
/// abandoned.
func deadlined<T: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = DeadlineGate(continuation)
        let work = Task {
            do {
                gate.finish(.success(try await operation()), winner: .work)
            } catch {
                gate.finish(.failure(error), winner: .work)
            }
        }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            gate.finish(.failure(DeadlineExceeded()), winner: .timer)
        }
        gate.install(work: work, timer: timer)
    }
}

/// First-wins gate for a deadline race: resumes the continuation exactly
/// once and cancels the losing task — the timer after a win (never sleep out
/// a long deadline for nothing), the work after a timeout. `install` closes
/// the creation race: a race already decided before both handles were
/// registered cancels them on registration instead.
final class DeadlineGate<Value>: @unchecked Sendable {
    enum Winner: Equatable { case work, timer }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func install(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            work.cancel()
            timer.cancel()
            return
        }
        self.work = work
        self.timer = timer
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>, winner: Winner) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let loser = winner == .work ? timer : work
        work = nil
        timer = nil
        lock.unlock()

        loser?.cancel()
        continuation?.resume(with: result)
    }
}
