import Foundation
import OSLog
import UIKit

/// Owns the app's single background-task assertion — the one sanctioned way
/// to keep sockets alive past the moment the app leaves the screen — and
/// answers the probe loops that ask whether they may run.
/// `BackgroundActivityPolicy` holds the decisions; this is the UIKit shell
/// that takes the assertion and gives it back.
///
/// App-wide and a singleton for the same reason `TerminalFocusArbiter` is:
/// there is exactly one process to keep awake, and the three loops that ask —
/// the wall feed, a terminal window's host probe, a direct shell's agent
/// monitor — sit in unrelated scenes with no shared configuration to thread a
/// dependency through.
@MainActor
final class BackgroundActivity {
    static let shared = BackgroundActivity()

    /// Whether any host wants the extra time, asked at the instant the app
    /// leaves. A closure because the answer needs the live `HostStore` and
    /// `TerminalWorkspace`, which `AppRuntime` composes and the asking scenes
    /// do not all hold.
    var demand: (@MainActor () -> Bool)?

    /// True only while the assertion is genuinely held. The probe loops read
    /// it every tick, so an expired grant parks them within one interval
    /// rather than leaving them to issue execs into a suspending process.
    private(set) var isHoldingBackgroundTime = false

    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "background"
    )

    private init() {}

    /// Start watching the app lifecycle. Called once, from `AppRuntime`.
    func start() {
        guard observers.isEmpty else { return }
        observers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidEnterBackground() }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.endHold(reason: "foreground") }
            },
        ]
    }

    // MARK: Asking

    /// The live opt-in for one host id. Set at composition alongside `demand`:
    /// every asking loop holds a host *snapshot* (a tab's `host` is a `let`
    /// from creation, and a probe model's is rebuilt only when the connection
    /// configuration changes), so without this a switch flipped in Host
    /// Settings would not reach a loop already running. Unset — as in tests —
    /// falls back to whatever the caller's snapshot says.
    var keepAliveLookup: (@MainActor (UUID) -> Bool)?

    /// Whether this host's probe/exec work may run right now.
    func permitsWork(for host: Host) -> Bool {
        permitsWork(keepAlive: keepAliveLookup?(host.id) ?? host.backgroundKeepAlive)
    }

    /// The same question for a caller that resolved the flag itself.
    func permitsWork(keepAlive: Bool) -> Bool {
        BackgroundActivityPolicy.permitsWork(
            activity: Self.activity,
            hostKeepsAlive: keepAlive,
            // Either grant counts: the departing app's assertion, or the
            // `BGAppRefreshTask` window iOS opened to let us look again.
            hasBackgroundGrant: isHoldingBackgroundTime || isRunningBackgroundRefresh
        )
    }

    /// Open while a `BGAppRefreshTask` handler is running. Set by
    /// `BackgroundRefresh`, which owns the task's lifetime and budget.
    private(set) var isRunningBackgroundRefresh = false

    func beginBackgroundRefreshWindow() {
        isRunningBackgroundRefresh = true
    }

    func endBackgroundRefreshWindow() {
        isRunningBackgroundRefresh = false
    }

    /// Where the app is in the foreground/background cycle. Read by anything
    /// whose rule has an "is the user here" premise — the probe gates below,
    /// and `AttentionFocusPolicy`, whose premise is otherwise invisible.
    static var activity: BackgroundActivityPolicy.AppActivity {
        switch UIApplication.shared.applicationState {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        // An unknown future state is not a licence to keep the radio on.
        @unknown default: .background
        }
    }

    // MARK: Holding

    private func applicationDidEnterBackground() {
        guard demand?() == true else { return }
        beginHold()
    }

    private func beginHold() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "app.multiplexterm.multiplex.keepalive"
        ) { [weak self] in
            // iOS calls this on the main thread when the grant runs out. The
            // assertion MUST be handed back here or the app is killed.
            MainActor.assumeIsolated { self?.endHold(reason: "expired") }
        }
        guard identifier != .invalid else {
            // Low Power Mode, or the system simply declining. Nothing is owed
            // back, and the loops park exactly as they always did.
            Self.logger.debug("keep-alive hold refused")
            return
        }
        isHoldingBackgroundTime = true
        // ⚠ `backgroundTimeRemaining` answers `.greatestFiniteMagnitude` while
        // the system is not counting down yet — which is exactly the moment
        // `didEnterBackground` runs. It is *finite*, so an `isFinite` guard
        // passes and `Int(_:)` traps on the way past `Int.max` (a crash on
        // every background, caught E2E 2026-08-05). Range-check the value,
        // never its finiteness.
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let granted = (remaining >= 0 && remaining < 86_400)
            ? "\(Int(remaining))s"
            : "unbounded"
        Self.logger.debug("keep-alive hold begun, \(granted, privacy: .public) granted")
    }

    private func endHold(reason: String) {
        guard identifier != .invalid else { return }
        // Park the loops BEFORE handing the time back: a tick that started in
        // between would open an exec channel the suspension is about to cut.
        isHoldingBackgroundTime = false
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        Self.logger.debug("keep-alive hold ended (\(reason, privacy: .public))")
    }
}
