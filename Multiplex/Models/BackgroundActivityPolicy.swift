import Foundation

/// Whether the app may keep talking to a host while it is not frontmost, and
/// whether leaving the screen is worth asking iOS for extra time at all.
///
/// The default posture is that it may not: iOS suspends a backgrounded app,
/// its sockets die with it, and `SessionResumePolicy` repairs the damage on
/// the way back. That is honest for a terminal, but it also means a ten-second
/// trip to another app costs every tab a reattach, and an agent that finishes
/// the moment you look away has nothing running to notice it.
///
/// A host opted into keep-alive buys the one extension iOS actually sanctions:
/// a `UIApplication` background-task assertion, which holds the process out of
/// suspension for the window the system grants — **tens of seconds, never
/// indefinite**. There is no supported way to hold a socket open past that.
/// The background modes that would (`audio`, `voip`, `location`) require the
/// app to genuinely do that thing, and faking one is an App Store rejection,
/// so the app declares no `UIBackgroundModes` at all and the setting's promise
/// is deliberately sized to the assertion. `BGTaskScheduler` is not that
/// mechanism either: it wakes a suspended app minutes-to-hours later at the
/// system's discretion, which reconnects rather than keeps alive, and is far
/// too late for "your agent is waiting on you".
///
/// Pure, so the whole matrix is testable without a scene, a socket, or a real
/// suspension.
enum BackgroundActivityPolicy {
    /// `UIApplication.State`, restated so Models keep their no-UIKit rule.
    enum AppActivity: Equatable {
        case active
        case inactive
        case background
    }

    /// Whether one host's probe/exec work may run right now.
    ///
    /// `.inactive` counts as permitted, a deliberate widening of the old
    /// `== .active` gate: the app is in the foreground and unsuspended, it is
    /// simply not the one receiving events. That is an iPad Stage Manager
    /// window sitting beside the app being typed in, a pulled-down Control
    /// Center, or the app switcher — cases where the deck was on screen the
    /// whole time and had silently stopped probing.
    ///
    /// `.background` needs both halves: without the opt-in this is the old
    /// promise, and without a grant the process is about to be suspended
    /// mid-exec anyway. A grant is either the departing app's assertion or a
    /// `BGAppRefreshTask` window — both are "iOS is letting us run right
    /// now", and neither is a licence for a host the user never opted in.
    static func permitsWork(
        activity: AppActivity,
        hostKeepsAlive: Bool,
        hasBackgroundGrant: Bool
    ) -> Bool {
        switch activity {
        case .active, .inactive: true
        case .background: hostKeepsAlive && hasBackgroundGrant
        }
    }

    /// Whether entering the background is worth an assertion at all: at least
    /// one opted-in host must have something for the extra time to do — a
    /// probe the deck would run (`isEnabled`), or a live terminal tab. A tab
    /// on a *disabled* host still counts, because disabling only stops the
    /// app dialling on its own; windows already open keep running.
    ///
    /// Asked once, as the app leaves. A user who has opted no host in never
    /// takes an assertion, so the default install's background behaviour is
    /// byte-for-byte what it was.
    static func wantsBackgroundTime(
        hosts: [Host],
        hostIDsWithLiveSessions: Set<UUID>
    ) -> Bool {
        hosts.contains { host in
            host.backgroundKeepAlive
                && (host.isEnabled || hostIDsWithLiveSessions.contains(host.id))
        }
    }
}
