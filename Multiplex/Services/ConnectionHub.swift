import Foundation
import Observation

/// One `HostConnectionModel` per host, created on demand and shared by
/// every window in the app.
@MainActor
@Observable
final class ConnectionHub {
    private var models: [UUID: HostConnectionModel] = [:]
    /// Fleet-wide alert sink; every model's attention events funnel here.
    private let attention: AttentionCenter?

    init(attention: AttentionCenter? = nil) {
        self.attention = attention
    }

    func model(for host: Host) -> HostConnectionModel {
        if let existing = models[host.id] { return existing }
        let model = HostConnectionModel(host: host)
        model.onAttentionAlert = { [attention] alert in
            attention?.handle(alert)
        }
        models[host.id] = model
        return model
    }

    func dropModel(for hostID: UUID) {
        if let model = models.removeValue(forKey: hostID) {
            Task { await model.disconnect() }
        }
    }
}

/// The deck's view of one host: an SSH control connection used to probe
/// tmux state. Terminal windows open their own dedicated connections.
@MainActor
@Observable
final class HostConnectionModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    let host: Host
    private(set) var phase: Phase = .idle
    private(set) var tmux: TmuxState = .unknown
    private(set) var lastRefreshed: Date?
    /// Session name → last visible lines of its active pane; the deck
    /// wall's live miniatures, refreshed by `captureTails()`.
    private(set) var miniatures: [String: [String]] = [:]
    /// Session name → agent state (busy / idle / needs you), re-derived on
    /// every probe and capture pass. Drives the wall's NEEDS YOU badge.
    private(set) var attention: [String: PaneAgentState] = [:]
    /// Fires on attention *edges* (turn ended, dialog appeared, bell).
    /// Set once by `ConnectionHub`; policy and delivery live in
    /// `AttentionCenter`, never here.
    var onAttentionAlert: ((AttentionAlert) -> Void)?

    private var connection: SSHConnection?
    private var refreshTask: Task<Void, Never>?
    private var attentionTracker = AttentionTracker()
    /// Deeper, unclipped capture tails (the miniatures' source parse) —
    /// what the question detector reads.
    private var attentionTails: [String: [String]] = [:]

    init(host: Host) {
        self.host = host
    }

    var isBusy: Bool {
        phase == .connecting || tmux == .probing
    }

    /// Connect if needed, then re-probe tmux sessions.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            await performRefresh()
        }
    }

    private func performRefresh() async {
        do {
            let connection = try await ensureConnection()
            // Only surface .probing before the first result — the deck wall
            // re-probes every few seconds, and flipping state on each cycle
            // would crossfade live tiles against the acquiring placeholder.
            if case .sessions = tmux {} else { tmux = .probing }
            let output = try await connection.exec(TmuxProbe.probeCommand)
            tmux = TmuxProbe.parse(output)
            lastRefreshed = Date()
            evaluateAttention()
        } catch {
            let message = friendlyMessage(for: error)
            phase = .failed(message)
            tmux = .failed(message)
            connection = nil
            evaluateAttention()
        }
    }

    private func ensureConnection() async throws -> SSHConnection {
        if let connection, phase == .connected { return connection }
        phase = .connecting
        let fresh = SSHConnection(host: host, secrets: .load(for: host))
        try await fresh.connect()
        connection = fresh
        phase = .connected
        return fresh
    }

    /// Refresh the wall miniatures over the existing control connection —
    /// one exec round-trip for every session on the host. Failures are
    /// soft: stale miniatures beat a flickering wall, and the next probe
    /// refresh handles real connection loss.
    func captureTails() async {
        guard phase == .connected,
              case .sessions(let sessions) = tmux, !sessions.isEmpty,
              let connection
        else { return }
        guard let output = try? await connection.exec(TmuxProbe.captureCommand(for: sessions))
        else { return }
        let tails = TmuxProbe.parseTails(output, sessions: sessions)
        attentionTails = tails
        miniatures = tails.mapValues(TmuxProbe.miniatureTail)
        evaluateAttention()
    }

    /// Re-derive every session's agent state from the latest probe (title)
    /// + capture (dialog content), and emit any edges. Runs after both
    /// probe and capture passes — whichever input moved, states follow.
    private func evaluateAttention() {
        guard case .sessions(let sessions) = tmux else {
            attention = [:]
            attentionTracker.reset()
            return
        }
        var next: [String: PaneAgentState] = [:]
        for session in sessions {
            let window = session.activeWindow
            // No detected agent → no state (bells still tracked below).
            var state: PaneAgentState?
            if let window, window.agent != nil {
                state = AgentAttention.classify(
                    title: window.paneTitle,
                    tail: attentionTails[session.name] ?? []
                )
                next[session.name] = state
            }
            let events = attentionTracker.update(
                session: session.name,
                state: state,
                hasBell: session.windows.contains(where: \.hasBell)
            )
            // One banner per session per tick — the most actionable edge
            // wins (they share a notification slot, and delivery order
            // across independent posts isn't guaranteed).
            if let event = events.max(by: { $0.priority < $1.priority }) {
                onAttentionAlert?(AttentionAlert(
                    host: host,
                    sessionName: session.name,
                    agent: window?.agent,
                    event: event,
                    paneTitle: window?.paneTitle ?? ""
                ))
            }
        }
        attentionTracker.prune(keeping: Set(sessions.map(\.name)))
        attention = next
    }

    /// Kill a tmux session on the host over the control connection, then
    /// re-probe. The tile drops as soon as the kill lands; the follow-up
    /// probe is the truth and resurrects it if the kill failed. Fail-soft
    /// like `captureTails` — if the control link dropped, do nothing and
    /// let the next probe cycle surface the failure.
    func killSession(_ session: TmuxSession) async {
        guard phase == .connected, let connection else { return }
        _ = try? await connection.exec(TmuxProbe.killCommand(for: session))
        if case .sessions(let list) = tmux {
            tmux = .sessions(list.filter { $0.id != session.id })
        }
        miniatures[session.name] = nil
        attentionTails[session.name] = nil
        attention[session.name] = nil
        // A probe already in flight may predate the kill — let it land,
        // then re-probe so the wall settles on reality.
        await refreshTask?.value
        refresh()
    }

    func disconnect() async {
        refreshTask?.cancel()
        refreshTask = nil
        if let connection {
            await connection.close()
        }
        connection = nil
        phase = .idle
        tmux = .unknown
        miniatures = [:]
        attentionTails = [:]
        attention = [:]
        attentionTracker.reset()
    }

    private func friendlyMessage(for error: Error) -> String {
        if let sshError = error as? SSHConnectionError {
            return sshError.userMessage(host: host)
        }
        return "Couldn't reach \(host.name). \(error.localizedDescription)"
    }
}
