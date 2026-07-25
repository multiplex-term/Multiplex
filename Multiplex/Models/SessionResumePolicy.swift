import Foundation

/// Whether a terminal tab that just lost its transport should re-attach on
/// its own, without the user finding the RECONNECT panel.
///
/// iOS suspends a backgrounded app and its sockets die with it — the phone's
/// screen going dark is enough. The tmux session on the host is untouched by
/// that, so the honest recovery when the app returns is to re-attach: what
/// the user lost was the pipe, not the work. Parking on a manual panel after
/// every screen lock claims otherwise.
///
/// The hard part is telling suspension damage apart from a session the user
/// deliberately ended (`exit`, `tmux kill-session`, a detach): the channel
/// closes the same way for both, and re-attaching after a deliberate exit
/// would fight the user. The only thing that separates them is whether the
/// app left the foreground while the session was live and hasn't proven
/// itself alive since — which is what this tracks.
///
/// Both orderings are covered, because frozen event loops deliver the
/// socket's death whenever the process resumes and that can land before OR
/// after the app is foreground again: a close seen while still away is owed
/// a resume on return, and a close seen shortly after return is still
/// suspension damage. Pure, so the whole matrix is unit-testable without a
/// host, a scene, or a socket.
struct SessionResumePolicy: Equatable {
    /// Consecutive automatic attempts before the manual panel takes over. A
    /// host that is genuinely gone must not be dialled forever.
    static let maxAttempts = 3
    /// Delay before each attempt. The first is immediate; later ones give a
    /// waking radio time to settle instead of spinning against it.
    static let attemptDelays: [TimeInterval] = [0, 2, 5]
    /// How long after the app returns a close still counts as suspension
    /// damage. The resumed event loop surfaces a dead socket within a
    /// round trip, so this only has to outlast the wake — kept short
    /// because a deliberate `exit` right after returning must not be
    /// mistaken for it.
    static let graceAfterForeground: TimeInterval = 6

    /// The app left the foreground while this session was live: whatever
    /// kills the transport between then and the next foreground is
    /// suspension damage by construction — the user cannot type into a
    /// backgrounded app.
    private var suspended = false
    /// Set while the app is back but the suspension's close may still be in
    /// flight.
    private var graceUntil: Date?
    /// A resume is owed but the app is not foreground enough to run it.
    private var pending = false
    /// An automatic attempt is in flight or has just failed, so the next
    /// close is part of this recovery rather than a fresh event.
    private var recovering = false
    private(set) var attempts = 0

    /// The app went away. Only a live session has a transport to lose.
    mutating func appMovedToBackground(isLive: Bool) {
        graceUntil = nil
        guard isLive else { return }
        suspended = true
    }

    /// The app is foreground again. Returns the delay before an automatic
    /// attempt, or nil when there is nothing to repair.
    mutating func appReturnedToForeground(now: Date, isLive: Bool) -> TimeInterval? {
        if pending {
            pending = false
            suspended = false
            graceUntil = nil
            return authorizeAttempt()
        }
        guard suspended else { return nil }
        suspended = false
        guard isLive else { return authorizeAttempt() }
        // The tab still believes it is connected; the socket's death can
        // still surface within the window below.
        graceUntil = now.addingTimeInterval(Self.graceAfterForeground)
        return nil
    }

    /// The transport ended for a reason other than the user closing the tab.
    /// Returns the delay before an automatic attempt, or nil to leave the
    /// manual panel in charge.
    mutating func transportEnded(now: Date, isForeground: Bool) -> TimeInterval? {
        let damaged = suspended
            || recovering
            || (graceUntil.map { now < $0 } ?? false)
        suspended = false
        graceUntil = nil
        guard damaged else { return nil }
        guard isForeground else {
            // Repair belongs to the foreground: no reconnect is attempted
            // from the background, where the app does no network work at all.
            pending = true
            return nil
        }
        return authorizeAttempt()
    }

    /// The session is live again — automatic recovery worked (or never had
    /// to run), so the next suspension starts from a clean budget.
    mutating func sessionBecameLive() {
        suspended = false
        graceUntil = nil
        pending = false
        recovering = false
        attempts = 0
    }

    /// The user pressed RECONNECT. They are driving now, and their attempt
    /// re-arms automatic recovery for the next suspension.
    mutating func userReconnected() {
        sessionBecameLive()
    }

    private mutating func authorizeAttempt() -> TimeInterval? {
        guard attempts < Self.maxAttempts else {
            recovering = false
            return nil
        }
        let delay = Self.attemptDelays[min(attempts, Self.attemptDelays.count - 1)]
        attempts += 1
        recovering = true
        return delay
    }
}
