import BackgroundTasks
import Foundation
import OSLog
import UIKit
#if DEBUG
import notify
#endif

/// The late half of background keep-alive: a `BGAppRefreshTask` that wakes the
/// app long after its assertion expired, probes the hosts the user opted in,
/// and lets `AttentionCenter` post whatever edges that finds.
///
/// **What this is honestly worth.** The assertion
/// (`BackgroundActivityPolicy`) covers the tens of seconds after you leave. A
/// real agent turn takes minutes, so it was missing the case the feature
/// exists for — measured 2026-08-05: leave, turn ends 60 s later, nothing
/// until you reopen the app. This closes that, but **on iOS's schedule, not
/// ours**: `earliestBeginDate` is a floor, the system decides the rest from
/// how you use the app, and a user who turns Background App Refresh off gets
/// nothing at all. An alert may land minutes or tens of minutes after the
/// turn ended, or not before you next open the app. Nothing in the UI may
/// promise timing.
///
/// **Why it can emit anything at all.** Edges need a baseline
/// (`AttentionTracker` returns nothing without a prior observation), and the
/// socket always dies across a suspension. `ConnectionHub.evaluateAttention`
/// therefore keeps the baseline when the probe stops showing sessions — the
/// reconnect's first pass is what compares "was busy" against "is idle now".
/// If that reset ever comes back, this whole file goes quiet and the tests
/// will not notice.
///
/// ⚠ Cold relaunch is a known gap: if iOS *terminated* the app rather than
/// suspending it, the tracker starts empty and this refresh only establishes
/// a baseline. The next one can alert. Persisting baselines across launches
/// was deliberately not done in v1 — it risks announcing a turn that ended
/// hours ago as if it just happened.
@MainActor
final class BackgroundRefresh {
    /// Must also appear in `BGTaskSchedulerPermittedIdentifiers`, or
    /// `register` throws at launch.
    static let taskIdentifier = "app.multiplexterm.multiplex.refresh"

    /// A floor, not a period. iOS honours it as "no sooner than" and then
    /// applies its own budget; asking for less does not get you more.
    static let earliestInterval: TimeInterval = 15 * 60

    /// Leave the system's ~30 s budget before it expires — a task killed by
    /// the expiration handler counts against future scheduling.
    private static let workBudget: TimeInterval = 20

    private let store: HostStore
    private let hub: ConnectionHub
    private let attention: AttentionCenter

    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "background"
    )

    init(store: HostStore, hub: ConnectionHub, attention: AttentionCenter) {
        self.store = store
        self.hub = hub
        self.attention = attention
    }

    // MARK: Registration and scheduling

    /// Must run before the app finishes launching — `BGTaskScheduler` rejects
    /// a later registration.
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let refreshTask = task as? BGAppRefreshTask else {
                    return task.setTaskCompleted(success: false)
                }
                self?.run(refreshTask)
            }
        }
    }

    /// Watch for the app leaving — the moment a wake becomes worth asking
    /// for. Separate from `register`, which must run inside
    /// `didFinishLaunchingWithOptions`.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleIfNeeded() }
        }
    }

    /// Ask for the next wake. Called as the app leaves and after every run.
    ///
    /// Gated on there being something to deliver: at least one opted-in host
    /// the app may dial, and alerts actually able to post (Pro + the switch).
    /// Waking to probe when nothing could be shown would spend the user's
    /// battery on nothing.
    func scheduleIfNeeded() {
        guard attention.isActive else { return cancel() }
        let wanted = store.hosts.contains { $0.backgroundKeepAlive && $0.isEnabled }
        guard wanted else { return cancel() }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.earliestInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.logger.debug("refresh scheduled, earliest +\(Int(Self.earliestInterval))s")
        } catch {
            // Simulators refuse to schedule, and the system can decline.
            // Nothing is owed: the assertion path is unaffected.
            Self.logger.debug("refresh not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    // MARK: The run

    private func run(_ task: BGAppRefreshTask) {
        // This object outlives every wake, so the completion latch is per-run.
        finished = false
        // Chain the next wake first: every exit path below must leave one
        // scheduled, and doing it here covers the expiration case too.
        scheduleIfNeeded()

        let hosts = store.hosts.filter { $0.backgroundKeepAlive && $0.isEnabled }
        guard attention.isActive, !hosts.isEmpty else {
            return task.setTaskCompleted(success: true)
        }
        Self.logger.debug("refresh woke for \(hosts.count) host(s)")

        BackgroundActivity.shared.beginBackgroundRefreshWindow()
        let work = Task { [weak self] in
            guard let self else { return }
            await probe(hosts)
        }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.workBudget))
            guard !Task.isCancelled else { return }
            self?.finish(task, work: work, success: true, reason: "budget")
        }
        task.expirationHandler = { [weak self] in
            MainActor.assumeIsolated {
                deadline.cancel()
                // iOS is taking the time back now; report honestly so the
                // scheduler does not learn to give us less.
                self?.finish(task, work: work, success: false, reason: "expired")
            }
        }
        Task { [weak self] in
            _ = await work.value
            deadline.cancel()
            self?.finish(task, work: work, success: true, reason: "done")
        }
    }

    /// What one wake actually does. Extracted from the task plumbing so the
    /// part that matters — probe the opted-in hosts, let the edges reach
    /// `AttentionCenter` — is reachable without a `BGAppRefreshTask`, which
    /// cannot be constructed and which the simulator never schedules.
    private func probe(_ hosts: [Host]) async {
        // One pass per host, concurrently: the budget is wall-clock, so a
        // slow host must not eat a fast one's turn.
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { @MainActor [hub] in
                    await hub.model(for: host).refreshAndWait(ifStaleFor: 0)
                }
            }
        }
    }

    private var finished = false
    private var observer: NSObjectProtocol?

    private func finish(
        _ task: BGAppRefreshTask,
        work: Task<Void, Never>,
        success: Bool,
        reason: String
    ) {
        guard !finished else { return }
        finished = true
        work.cancel()
        // Close the window before completing: the probe loops must not treat
        // a returned budget as permission.
        BackgroundActivity.shared.endBackgroundRefreshWindow()
        Self.logger.debug("refresh finished (\(reason, privacy: .public))")
        task.setTaskCompleted(success: success)
    }

    #if DEBUG
    /// Headless proof of everything a wake does except iOS choosing to wake
    /// us: the simulator never schedules a `BGAppRefreshTask` (submit throws
    /// unavailable) and the type cannot be constructed, so
    /// `xcrun simctl spawn <udid> notifyutil -p
    /// app.multiplexterm.multiplex.debug.bgrefresh` runs the same probe under
    /// the same grant window. Background the app first — that is the state
    /// the run has to work in, and the point is watching the probe reach the
    /// host and an alert post while the app is off screen.
    func installDebugHook() {
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.bgrefresh", &token, .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let hosts = self.store.hosts.filter { $0.backgroundKeepAlive && $0.isEnabled }
                Self.logger.debug(
                    "refresh woke for \(hosts.count) host(s) [debug hook]"
                )
                guard !hosts.isEmpty else { return }
                BackgroundActivity.shared.beginBackgroundRefreshWindow()
                Task {
                    await self.probe(hosts)
                    BackgroundActivity.shared.endBackgroundRefreshWindow()
                    Self.logger.debug("refresh finished (debug hook)")
                }
            }
        }
    }
    #endif
}
