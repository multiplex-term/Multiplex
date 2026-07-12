import Foundation
import Observation
import os

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
        if let existing = models[host.id] {
            if existing.host == host { return existing }
            // The record changed under the model — edited locally or synced
            // from another device. The old model keeps probing the old
            // address with the old credentials (and would report CONNECTED
            // against an endpoint the record no longer names), so replace
            // it and let the wall's next tick connect fresh.
            let stale = existing
            Task { await stale.disconnect() }
        }
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
            // Only surface .probing before the first result — every later
            // state (sessions, no server, unreachable) is a settled answer.
            // The deck wall re-probes every few seconds, and flipping a
            // settled tile back to the acquiring placeholder each cycle
            // makes the wall shake; the next parse/failure overwrites it.
            if case .unknown = tmux { tmux = .probing }
            let output = try await deadlined { try await connection.exec(TmuxProbe.probeCommand) }
            tmux = TmuxProbe.parse(output)
            lastRefreshed = Date()
            evaluateAttention()
        } catch {
            markFailed(error)
        }
    }

    private func markFailed(_ error: Error) {
        let message = friendlyMessage(for: error)
        phase = .failed(message)
        tmux = .failed(message)
        if let connection {
            // A link that timed out is usually black-holed; tearing it down
            // also unblocks any exec still hung on it. Never await this on
            // the path that renders UNREACHABLE.
            Task { await connection.close() }
        }
        connection = nil
        evaluateAttention()
    }

    private func ensureConnection() async throws -> SSHConnection {
        if let connection, phase == .connected { return connection }
        // Only surface .connecting before the first settled phase — same
        // rule as `.probing` above. The wall retries failed hosts every few
        // seconds, and flashing LINKING ↔ UNREACHABLE each cycle makes the
        // rail churn; a settled UNREACHABLE keeps reading UNREACHABLE until
        // a retry actually lands.
        if phase == .idle { phase = .connecting }
        let fresh = SSHConnection(host: host, secrets: .load(for: host))
        do {
            try await deadlined(seconds: Self.connectDeadline) { try await fresh.connect() }
        } catch {
            Task { await fresh.close() }
            throw error
        }
        connection = fresh
        phase = .connected
        return fresh
    }

    /// Deadline for establishing the control connection (TCP + SSH handshake
    /// + auth); longer than an exec round-trip on an already-live link.
    private static let connectDeadline: Double = 15
    /// Deadline for one exec round-trip on the established connection.
    /// (nonisolated so it can be a default argument of `deadlined`.)
    private nonisolated static let execDeadline: Double = 10

    /// Every control-connection round-trip must eventually resolve: a link
    /// that dies without a FIN/RST (device left Wi-Fi, host powered off)
    /// black-holes TCP, Citadel's futures never complete, and the rail
    /// would show CONNECTED forever while the feed loop hangs. Racing a
    /// deadline turns that into UNREACHABLE on the next probe cycle.
    private func deadlined<T: Sendable>(
        seconds: Double = HostConnectionModel.execDeadline,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            @Sendable func finish(_ result: Result<T, Error>) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(with: result) }
            }
            let work = Task {
                do { finish(.success(try await operation())) }
                catch { finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                finish(.failure(ProbeTimeoutError()))
                work.cancel()
            }
        }
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
        // Deadlined even though failures are soft: the wall's feed loop
        // awaits this inline, so a hung capture would stall every host.
        guard let output = try? await deadlined({
            try await connection.exec(TmuxProbe.captureCommand(for: sessions))
        }) else { return }
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

    /// Create a detached tmux session over the control connection and
    /// return its final name — in `sourceSession`'s active-pane cwd ($HOME
    /// when nil or unresolvable), or in an explicit `directory` (a host
    /// working dir) when there is no source, optionally with `launch` typed
    /// into its fresh shell. The wanted name derives from `base` against the
    /// latest probe; the server settles races (see
    /// `TmuxProbe.newSessionCommand`). Unlike the fail-soft probe helpers
    /// this connects on demand — it's a user-initiated action — and returns
    /// nil on failure.
    func createSession(
        base: String, inDirectoryOf sourceSession: String?,
        startingIn directory: String? = nil, typing launch: String?
    ) async -> String? {
        do {
            let connection = try await ensureConnection()
            let command = TmuxProbe.newSessionCommand(
                name: TmuxProbe.uniqueSessionName(
                    base: base, existing: tmux.sessions.map(\.name)),
                sourceSessionName: sourceSession,
                startDirectory: directory,
                launch: launch
            )
            let name = TmuxProbe.parseNewSession(
                try await deadlined { try await connection.exec(command) })
            // The wall and every open window should see the session now,
            // not on their next tick.
            refresh()
            return name
        } catch {
            markFailed(error)
            return nil
        }
    }

    /// Kill a tmux session on the host over the control connection, then
    /// re-probe. The tile drops as soon as the kill lands; the follow-up
    /// probe is the truth and resurrects it if the kill failed. Fail-soft
    /// like `captureTails` — if the control link dropped, do nothing and
    /// let the next probe cycle surface the failure.
    func killSession(_ session: TmuxSession) async {
        guard phase == .connected, let connection else { return }
        await kill(session, over: connection)
    }

    /// Kill a session by name — the terminal window's CLOSE SESSION action.
    /// Unlike the wall's `killSession(_:)` this connects on demand (the tab
    /// just ended, so the control link may be down too; it's user-initiated,
    /// same policy as `createSession`). The latest probe supplies the
    /// session's tmux id when it has one; otherwise `killCommand` falls back
    /// to an `=name` exact match.
    func killSession(named name: String) async {
        do {
            let connection = try await ensureConnection()
            var session = TmuxSession(name: name, windows: [], created: .distantPast)
            if case .sessions(let list) = tmux,
               let match = list.first(where: { $0.name == name }) {
                session = match
            }
            await kill(session, over: connection)
        } catch {
            markFailed(error)
        }
    }

    private func kill(_ session: TmuxSession, over connection: SSHConnection) async {
        _ = try? await deadlined { try await connection.exec(TmuxProbe.killCommand(for: session)) }
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
        if error is ProbeTimeoutError {
            return "Couldn't reach \(host.name). No response."
        }
        return "Couldn't reach \(host.name). \(error.localizedDescription)"
    }
}

/// A control-connection round-trip outlived its deadline — the link is
/// treated as dead (see `HostConnectionModel.deadlined`).
private struct ProbeTimeoutError: Error {}
