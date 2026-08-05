import Foundation
import Observation
import OSLog
import UserNotifications

/// Fleet-wide agent alerts: takes attention events from every host's probe
/// (via `ConnectionHub`) and in-band bells from attached tabs, drops the
/// ones about the session the user is actively typing in, and posts local
/// notification banners for the rest.
///
/// **Pro-gated surface.** Detection and the wall's telemetry (agent token,
/// NEEDS YOU badge, RUNNING) stay free — they're the teaser, visible only
/// while you're looking at the deck. The *notifications* — the "ping me
/// about a window I'm not looking at" convenience — are Pro, alongside the
/// helper strip. When locked, events are dropped before delivery; the badge
/// still shows.
///
/// Scope (v1): the app must be running for events to exist at all — probes
/// stop when every scene suspends. On visionOS visible windows stay active,
/// so "Multiplex is open while I work elsewhere" is exactly the case this
/// serves. On iOS a host opted into `Host.backgroundKeepAlive` widens that
/// to the tens of seconds iOS grants a departing app (see
/// `BackgroundActivityPolicy`), which catches a turn that ends just after
/// you look away — but not one that ends a minute later. True background
/// delivery would need a push service.
@MainActor
@Observable
final class AttentionCenter {
    /// Master switch (SETTINGS → Alerts), device-local like themes. Only
    /// takes effect when Pro; the setting persists across lock/unlock so an
    /// upgrade restores the user's choice.
    var alertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: Self.enabledKey)
            // Switching alerts on is the most in-context moment there is to
            // ask for permission — and settles it before the user walks away.
            if alertsEnabled { primeAuthorization() }
        }
    }

    /// The window directory — how an alert's session maps to an open tab.
    /// Weak: the workspace is app-lifetime state that also points back at
    /// controllers holding us.
    weak var workspace: TerminalWorkspace?
    /// The Pro gate. Weak — app-lifetime state, set once at composition.
    weak var entitlements: EntitlementStore?

    /// Alerts deliver only when the user both owns Pro and left the switch on.
    var isActive: Bool {
        (entitlements?.canScheduleAgentAlerts ?? false) && alertsEnabled
    }

    private static let enabledKey = "attention.alertsEnabled"
    private let banner = ForegroundBanner()
    private var authRequested = false
    /// In-band bells can repeat fast (readline beeps on tab-complete);
    /// throttle per tab.
    private var lastBell: [UUID: Date] = [:]
    private static let bellCooldown: TimeInterval = 8

    init() {
        alertsEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        // Banners must show while the app is frontmost — the whole point is
        // pinging the user about a window they're not looking at.
        UNUserNotificationCenter.current().delegate = banner
        banner.onTap = { [weak self] target in self?.handleTap(target) }
    }

    // MARK: Events

    /// Probe-plane event — any session on any host, attached or not.
    func handle(_ alert: AttentionAlert) {
        guard isActive else { return drop(alert.sessionName, "locked") }
        guard !isFocused(
            hostID: alert.host.id,
            sessionName: alert.sessionName,
            backend: alert.host.sessionBackend
        ) else { return drop(alert.sessionName, "focused") }
        post(alert)
    }

    /// Why an alert never became a banner. Debug level, category `attention`
    /// — an alert that silently isn't delivered is otherwise indistinguishable
    /// from one that was never detected, which is exactly what made the
    /// focus-suppression bug (`AttentionFocusPolicy`) so hard to see.
    private func drop(_ sessionName: String, _ reason: String) {
        Self.logger.debug(
            "alert dropped for \(sessionName, privacy: .public): \(reason, privacy: .public)"
        )
    }

    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "attention"
    )

    /// Attention edge classified from a plain shell's own PTY. There is no
    /// tmux session for the fleet model to map back through the workspace, so
    /// the emitting controller is also the exact focus target and stable
    /// notification identity.
    func handleDirectShellEvent(
        _ event: AttentionEvent,
        agent: AgentKind?,
        dialogSummary: String? = nil,
        from controller: TerminalSessionController
    ) {
        guard isActive else { return drop(controller.route.displayName, "locked") }
        guard !isFocused(controller) else {
            return drop(controller.route.displayName, "focused")
        }
        post(AttentionAlert(
            host: controller.host,
            sessionName: controller.route.displayName,
            tabID: controller.route.id,
            agent: agent,
            event: event,
            paneTitle: controller.remoteTitle,
            dialogSummary: dialogSummary
        ))
    }

    /// In-band BEL from an attached tab's byte stream. Opt-in remote config
    /// (Claude Code hooks / terminal_bell, Codex tui.notifications) rings
    /// through the PTY; tmux forwards the active window's bell to attached
    /// clients, so this and the probe's latched bell flag never double-fire
    /// for the same bell.
    func handleBell(from controller: TerminalSessionController) {
        guard isActive else { return }
        let now = Date()
        if let last = lastBell[controller.route.id],
           now.timeIntervalSince(last) < Self.bellCooldown { return }
        lastBell[controller.route.id] = now
        guard !isFocused(controller) else {
            return drop(controller.route.displayName, "focused")
        }
        post(AttentionAlert(
            host: controller.host,
            sessionName: controller.route.displayName,
            tabID: controller.route.id,
            agent: nil,
            event: .bell,
            paneTitle: controller.remoteTitle
        ))
    }

    // MARK: Policy

    /// Whether the app is frontmost — the other half of every focus
    /// suppression here (`AttentionFocusPolicy`). A seam so tests can state
    /// which side of the app lifecycle they are describing; live wiring reads
    /// the same lifecycle the probe gates do.
    @ObservationIgnored
    var appIsFrontmost: () -> Bool = { BackgroundActivity.activity == .active }

    /// Suppress alerts about the terminal the user is typing in — the
    /// arbiter's single app-wide focus owner is exactly "the window the
    /// user is engaged with"; every other surface (unfocused window,
    /// background tab, deck-only, detached session) gets the banner.
    /// Engagement needs the app on screen too: see `AttentionFocusPolicy`
    /// for why keyboard focus alone silences exactly the wrong session.
    private func isFocused(
        hostID: UUID, sessionName: String,
        backend: Host.SessionBackend
    ) -> Bool {
        guard let workspace, let focused = TerminalFocusArbiter.current else { return false }
        let ownsFocus = workspace.windows.contains { entry in
            entry.tabs.contains { tab in
                tab.hostID == hostID
                    && tab.sessionName == sessionName
                    && tab.sessionBackend == backend
                    && workspace.controller(for: tab.id)?.terminalView === focused
            }
        }
        return AttentionFocusPolicy.suppressesAlert(
            appIsFrontmost: appIsFrontmost(),
            sessionOwnsKeyboardFocus: ownsFocus
        )
    }

    /// The same rule for the two event sources that hold the emitting
    /// controller rather than a session identity.
    private func isFocused(_ controller: TerminalSessionController) -> Bool {
        AttentionFocusPolicy.suppressesAlert(
            appIsFrontmost: appIsFrontmost(),
            sessionOwnsKeyboardFocus: TerminalFocusArbiter.current === controller.terminalView
        )
    }

    // MARK: Tap

    /// The fallback's seam, overridable by tests. Live wiring submits to
    /// the process-wide router — the same queue widget taps ride, which
    /// waits behind the app lock and raises the deck scene when the press
    /// launched a fresh process with no context mounted yet.
    @ObservationIgnored var performExternalAction: (ExternalAction) -> Void = {
        ExternalActionRouter.shared.submit($0)
    }

    /// A banner's press gets the user back to the session that pinged them.
    /// An already-open tab reveals directly — tab-scoped alerts by tab id,
    /// session alerts through the same (host, session, backend) identity a
    /// deck tile press uses; tmux and herdr tabs match alike. A session
    /// alert with no open window rides the external-action seam instead:
    /// the widget's status-guarded reveal-or-attach, so the tap still lands
    /// after the window was closed or the process died. Not Pro-gated —
    /// the banner only existed because Pro was active when it posted, and
    /// attach itself is a free surface.
    func handleTap(_ target: AttentionTapTarget) {
        if let tabID = target.tabID, workspace?.focusTab(id: tabID) == true { return }
        if workspace?.focusTab(
            hostID: target.hostID,
            sessionName: target.sessionName,
            backend: target.backend
        ) == true { return }
        guard target.sessionIsAttachable else { return }
        performExternalAction(
            .openShell(host: .id(target.hostID), sessionName: target.sessionName))
    }

    // MARK: Delivery

    private func post(_ alert: AttentionAlert) {
        // This is the final intent gate, adjacent to notification creation.
        // Callers already avoid doing this work when locked, but repeating
        // the policy here prevents a future event source from bypassing Pro.
        guard isActive else { return drop(alert.sessionName, "locked") }
        Self.logger.debug(
            "alert posted for \(alert.sessionName, privacy: .public)"
        )
        let copy = Self.copy(for: alert)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        if let subtitle = copy.subtitle { content.subtitle = subtitle }
        content.body = copy.body
        content.sound = .default
        // The press decodes this to focus the alert's window (or attach it
        // afresh) — see `handleTap`.
        content.userInfo = alert.tapTarget.userInfo
        let sourceID = alert.tabID?.uuidString ?? alert.sessionName
        content.threadIdentifier = "\(alert.host.id)-\(sourceID)"
        // One live banner per tmux session or plain-shell tab: a newer event
        // replaces a stale one instead of stacking. Two plain shells on the
        // same host both display as “shell,” so their tab UUIDs must keep
        // their requests distinct.
        let request = UNNotificationRequest(
            identifier: "attention-\(alert.host.id)-\(sourceID)",
            content: content,
            trigger: nil
        )
        Task {
            let center = UNUserNotificationCenter.current()
            await primeAuthorizationIfNeeded()
            // The authorization sheet may have suspended us long enough for
            // the user to disable alerts or lose the entitlement. Never let
            // an in-flight request cross that intent boundary.
            guard isActive else { return }
            try? await center.add(request)
        }
    }

    /// Ask for notification permission — but only with the app on screen.
    ///
    /// ⚠ Never from the background. The prompt is a system alert: raised for
    /// a backgrounded app it lands on top of whatever the user switched to,
    /// and the alert that triggered it is spent buying the permission instead
    /// of being delivered. That is the worst possible first impression of the
    /// feature, and it is precisely when keep-alive makes a first alert most
    /// likely (verified on iPhone 17 sim, 2026-08-05: the prompt appeared over
    /// Safari and no banner ever showed).
    ///
    /// Frontmost, the ask is in context and the grant is settled before the
    /// user walks away — so `primeAuthorization`'s job is to have happened
    /// already by the time an alert fires away from the screen. A background
    /// alert with permission still undetermined is dropped rather than
    /// converted into a prompt; the wall's NEEDS YOU badge remains the in-app
    /// surface, and the next foreground moment asks properly.
    private func primeAuthorizationIfNeeded() async {
        guard !authRequested, appIsFrontmost() else { return }
        authRequested = true
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Settle notification permission at a moment the user is present, so the
    /// first alert they actually need — typically one raised while they are
    /// away — is delivered instead of spent on a prompt. Called when a scene
    /// becomes active; a no-op once asked, when alerts are off, or without Pro.
    func primeAuthorization() {
        guard isActive, !authRequested else { return }
        Task { await primeAuthorizationIfNeeded() }
    }

    /// The rendered copy of one alert. The body used to open with the
    /// identifiers ("session · host — …"), so a long session name pushed
    /// the meaningful part past the banner/lock-screen truncation and the
    /// notification read as machine soup (user-reported). Content now
    /// leads: the body is what the agent asks (or the task that finished)
    /// and the identifiers move to the subtitle line; only a contentless
    /// alert keeps the place as its body.
    struct NotificationCopy: Equatable {
        var title: String
        var subtitle: String?
        var body: String
    }

    nonisolated static func copy(for alert: AttentionAlert) -> NotificationCopy {
        let agent = alert.agent?.displayName ?? "Session"
        let title: String = switch alert.event {
        case .turnEnded:
            "\(agent) finished"
        case .needsInput(.permission):
            "\(agent) wants permission"
        case .needsInput(.question):
            "\(agent) has a question"
        case .bell:
            alert.agent.map { "\($0.displayName) rang the bell" } ?? "Bell"
        }
        let place = "\(alert.sessionName) · \(alert.host.name)"
        // The dialog's own copy outranks the pane-title task summary, which
        // is flavor and can lag a prompt behind.
        let content = alert.dialogSummary
            ?? AgentAttention.taskSummary(title: alert.paneTitle, agent: alert.agent)
        guard let content else {
            return NotificationCopy(title: title, subtitle: nil, body: place)
        }
        return NotificationCopy(title: title, subtitle: place, body: content)
    }
}

/// Presents banners while the app is foreground (the default is silence)
/// and routes a banner's press back into the center.
private final class ForegroundBanner: NSObject, UNUserNotificationCenterDelegate {
    /// Set once at composition. Delegate callbacks arrive on system queues,
    /// so the hop onto the main actor happens here.
    var onTap: (@MainActor (AttentionTapTarget) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Only the default press is intent — a dismissed banner is not.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let target = AttentionTapTarget(
               userInfo: response.notification.request.content.userInfo) {
            let onTap = onTap
            Task { @MainActor in onTap?(target) }
        }
        completionHandler()
    }
}
