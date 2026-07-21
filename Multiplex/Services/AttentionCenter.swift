import Foundation
import Observation
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
/// serves. True background delivery would need a push service.
@MainActor
@Observable
final class AttentionCenter {
    /// Master switch (SETTINGS → Alerts), device-local like themes. Only
    /// takes effect when Pro; the setting persists across lock/unlock so an
    /// upgrade restores the user's choice.
    var alertsEnabled: Bool {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: Self.enabledKey) }
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
    }

    // MARK: Events

    /// Probe-plane event — any session on any host, attached or not.
    func handle(_ alert: AttentionAlert) {
        guard isActive,
              !isFocused(hostID: alert.host.id, sessionName: alert.sessionName)
        else { return }
        post(alert)
    }

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
        guard isActive,
              TerminalFocusArbiter.current !== controller.terminalView
        else { return }
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
        guard TerminalFocusArbiter.current !== controller.terminalView else { return }
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

    /// Suppress alerts about the terminal the user is typing in — the
    /// arbiter's single app-wide focus owner is exactly "the window the
    /// user is engaged with"; every other surface (unfocused window,
    /// background tab, deck-only, detached session) gets the banner.
    private func isFocused(hostID: UUID, sessionName: String) -> Bool {
        guard let workspace, let focused = TerminalFocusArbiter.current else { return false }
        return workspace.windows.contains { entry in
            entry.tabs.contains { tab in
                tab.hostID == hostID
                    && tab.sessionName == sessionName
                    && workspace.controller(for: tab.id)?.terminalView === focused
            }
        }
    }

    // MARK: Delivery

    private func post(_ alert: AttentionAlert) {
        // This is the final intent gate, adjacent to notification creation.
        // Callers already avoid doing this work when locked, but repeating
        // the policy here prevents a future event source from bypassing Pro.
        guard isActive else { return }
        let copy = Self.copy(for: alert)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        if let subtitle = copy.subtitle { content.subtitle = subtitle }
        content.body = copy.body
        content.sound = .default
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
            if !authRequested {
                authRequested = true
                // First alert asks; afterwards this resolves instantly from
                // the recorded grant/denial. Denied → add() no-ops, and the
                // wall's NEEDS YOU badge remains the in-app surface.
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            // The authorization sheet may have suspended us long enough for
            // the user to disable alerts or lose the entitlement. Never let
            // an in-flight request cross that intent boundary.
            guard isActive else { return }
            try? await center.add(request)
        }
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

/// Presents banners while the app is foreground (the default is silence).
private final class ForegroundBanner: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
