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
    /// Last-known wall state per host — prefills fresh models so a cold
    /// launch paints tiles instantly while connections rebuild.
    private let snapshots = DeckSnapshotStore()

    init(attention: AttentionCenter? = nil) {
        self.attention = attention
    }

    func model(for host: Host) -> HostConnectionModel {
        if let existing = models[host.id] {
            if existing.host.hasSameConnectionModelConfiguration(as: host) {
                return existing
            }
            // Connection-relevant record data changed under the model —
            // edited locally or synced from another device. The old model
            // would keep probing stale settings, so replace it and let the
            // wall's next tick connect fresh. Synced helper-command edits are
            // deliberately excluded: changing a chip must not drop the probe.
            let stale = existing
            Task { await stale.disconnect() }
        }
        let model = HostConnectionModel(host: host)
        model.onAttentionAlert = { [attention] alert in
            attention?.handle(alert)
        }
        model.onSnapshot = { [snapshots] snapshot in
            snapshots.update(snapshot, for: host.id)
        }
        if let snapshot = snapshots.snapshot(for: host.id) {
            model.restore(from: snapshot)
        }
        models[host.id] = model
        return model
    }

    func dropModel(for hostID: UUID) {
        snapshots.remove(for: hostID)
        if let model = models.removeValue(forKey: hostID) {
            Task { await model.disconnect() }
        }
    }

    /// Persist any pending snapshot changes — called when the deck leaves
    /// the foreground, because suspension freezes the debounce timer.
    func flushSnapshots() {
        snapshots.flush()
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
    @ObservationIgnored private var lastRefreshed: Date?
    /// Observation-friendly summaries: views that only need liveness or a
    /// badge count should not subscribe to the full pane/process tree.
    private(set) var hasLiveProbe = false
    private(set) var sessionCount = 0
    /// Session name → last visible lines of its active pane; the deck
    /// wall's live miniatures, refreshed by every probe (the probe's single
    /// exec carries the capture tails).
    private(set) var miniatures: [String: [String]] = [:]
    /// Session name → agent state (busy / idle / needs you), re-derived on
    /// every probe and capture pass. Drives the wall's NEEDS YOU badge.
    private(set) var attention: [String: PaneAgentState] = [:]
    /// Fires on attention *edges* (turn ended, dialog appeared, bell).
    /// Set once by `ConnectionHub`; policy and delivery live in
    /// `AttentionCenter`, never here.
    var onAttentionAlert: ((AttentionAlert) -> Void)?
    /// Fires after every settled probe with the state worth caching for the
    /// next cold launch (nil when the server/sessions are gone). Set once by
    /// `ConnectionHub`; persistence lives in `DeckSnapshotStore`, never here.
    var onSnapshot: ((DeckSnapshot?) -> Void)?

    /// Stage timings for the wall's feed pipeline (debug level; read with
    /// `log stream --predicate 'category == "wall"'`).
    private static let timing = Logger(
        subsystem: "app.multiplexterm.multiplex", category: "wall")

    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var connectRetryBackoff = ConnectRetryBackoff()
    /// Synchronizable Keychain reads are cached across fresh-link retries.
    /// Re-entered credentials can take at most 60 seconds to land, while
    /// editing the host config replaces this model. This extends plaintext
    /// residency between attempts, but a live SSHConnection already retains
    /// the same secrets for its lifetime, so the security posture is unchanged.
    @ObservationIgnored private var cachedSecrets: HostSecrets?
    @ObservationIgnored private var cachedSecretsLoadedAt: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var activePaneProbeInFlight = false
    private struct ActiveAgentCacheEntry {
        var fingerprint: TmuxPaneFingerprint
        var agent: AgentKind?
        var expiresAt: Date
    }
    /// Pane id → process fallback. Direct comm/title matches never need this;
    /// wrappers and negative results expire so a long-lived foreground
    /// process can still change descendants without changing pane identity.
    @ObservationIgnored private var activeAgentCache: [String: ActiveAgentCacheEntry] = [:]
    @ObservationIgnored private var attentionTracker = AttentionTracker()
    /// Deeper, unclipped capture tails (the miniatures' source parse) —
    /// what the question detector reads.
    @ObservationIgnored private var attentionTails: [String: [String]] = [:]

    init(host: Host) {
        self.host = host
    }

    var isBusy: Bool {
        phase == .connecting || tmux == .probing
    }

    /// Prefill the wall's tiles from the previous run's snapshot — only
    /// before the first live result, and never the attention inputs
    /// (NEEDS YOU is re-earned by a live capture). The connection phase is
    /// untouched: the rail's STANDBY → LINKING → CONNECTED stays the truth
    /// about liveness while the tiles show last-known content.
    func restore(from snapshot: DeckSnapshot) {
        guard case .unknown = tmux else { return }
        tmux = .sessions(snapshot.sessions)
        miniatures = snapshot.miniatures
        sessionCount = snapshot.sessions.count
    }

    /// Connect if needed, then re-probe tmux sessions.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation, mayRetry: true)
            guard self.refreshGeneration == generation else { return }
            self.refreshTask = nil
        }
    }

    /// One complete wall update: join the in-flight probe or start one. The
    /// probe's single exec round-trip carries the miniature tails too, so
    /// joining it is the whole tick — a first load paints sessions and
    /// miniatures together instead of deferring tails to the next tick.
    func refreshAndWait(ifStaleFor minimumAge: TimeInterval = 0) async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        if minimumAge > 0,
           let lastRefreshed,
           Date().timeIntervalSince(lastRefreshed) < minimumAge {
            return
        }
        refresh()
        let task = refreshTask
        await task?.value
    }

    /// Fast path for the terminal that currently owns keyboard focus. One
    /// tiny list-panes exec identifies the pane receiving keystrokes. Direct
    /// signals resolve most agents immediately; only a changed/expired
    /// ambiguous pane runs a second query scoped to that pane's TTY.
    ///
    /// nil means the lightweight check itself was unavailable. A nonnil,
    /// non-definitive result still carries the new fingerprint so the UI can
    /// immediately retire helpers that belonged to a different pane.
    func detectActiveAgent(in sessionName: String) async -> ActivePaneAgentDetection? {
        guard !activePaneProbeInFlight,
              refreshTask == nil,
              phase == .connected,
              let connection
        else { return nil }

        activePaneProbeInFlight = true
        defer { activePaneProbeInFlight = false }

        guard let output = try? await deadlined(seconds: 3, {
            try await connection.exec(TmuxProbe.activePaneCommand(sessionName: sessionName))
        }), let pane = TmuxProbe.parseActivePane(output)
        else { return nil }

        let fingerprint = pane.processFingerprint
        if let direct = AgentSignature.classify(command: pane.command, title: pane.title) {
            cache(agent: direct, for: fingerprint)
            return ActivePaneAgentDetection(
                fingerprint: fingerprint,
                agent: direct,
                isDefinitive: true
            )
        }

        if let cached = activeAgentCache[pane.tmuxID],
           cached.fingerprint == fingerprint,
           cached.expiresAt > Date() {
            return ActivePaneAgentDetection(
                fingerprint: fingerprint,
                agent: cached.agent,
                isDefinitive: true
            )
        }

        // A full wall probe may already have classified this pane. Reuse a
        // positive result, but not a missing one: the host-wide ps stage is
        // fail-soft, so nil alone cannot prove that its snapshot succeeded.
        if let known = tmux.sessions
            .first(where: { $0.name == sessionName })?
            .windows
            .flatMap({ $0.panes ?? [] })
            .first(where: {
                $0.processFingerprint == fingerprint && $0.agent != nil
            })?
            .agent {
            cache(agent: known, for: fingerprint)
            return ActivePaneAgentDetection(
                fingerprint: fingerprint,
                agent: known,
                isDefinitive: true
            )
        }

        guard let command = TmuxProbe.paneProcessCommand(tty: pane.tty),
              let processOutput = try? await deadlined(seconds: 3, {
                  try await connection.exec(command)
              })
        else {
            return ActivePaneAgentDetection(
                fingerprint: fingerprint,
                agent: nil,
                isDefinitive: false
            )
        }

        let rows = TmuxProbe.parsePSRows(processOutput)
        guard !rows.isEmpty else {
            return ActivePaneAgentDetection(
                fingerprint: fingerprint,
                agent: nil,
                isDefinitive: false
            )
        }
        let agent = AgentSignature.agentInTree(rows: rows, panePID: pane.pid)
        cache(agent: agent, for: fingerprint)
        return ActivePaneAgentDetection(
            fingerprint: fingerprint,
            agent: agent,
            isDefinitive: true
        )
    }

    private func cache(agent: AgentKind?, for fingerprint: TmuxPaneFingerprint) {
        activeAgentCache[fingerprint.tmuxID] = ActiveAgentCacheEntry(
            fingerprint: fingerprint,
            agent: agent,
            expiresAt: Date().addingTimeInterval(10)
        )
    }

    private func performRefresh(generation: Int, mayRetry: Bool) async {
        guard refreshGeneration == generation, !Task.isCancelled else { return }
        guard connection != nil || connectRetryBackoff.shouldAttempt(now: Date()) else {
            return
        }
        // Whether this pass reuses an already-established link — if that
        // link fails mid-probe (Wi-Fi blip, server restart, socket severed
        // during suspension), one immediate reconnect beats surfacing
        // UNREACHABLE and waiting out a full feed interval.
        let reusedLink = connection != nil && phase == .connected
        do {
            let connection = try await ensureConnection(refreshGeneration: generation)
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            // Only surface .probing before the first result — every later
            // state (sessions, no server, unreachable) is a settled answer.
            // The deck wall re-probes every few seconds, and flipping a
            // settled tile back to the acquiring placeholder each cycle
            // makes the wall shake; the next parse/failure overwrites it.
            if case .unknown = tmux { tmux = .probing }
            let execStart = ContinuousClock.now
            let output = try await deadlined { try await connection.exec(TmuxProbe.probeCommand) }
            let execEnd = ContinuousClock.now
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            let parsed = await Task.detached(priority: .userInitiated) {
                TmuxProbe.parseProbe(output)
            }.value
            let parseEnd = ContinuousClock.now
            guard refreshGeneration == generation, !Task.isCancelled else { return }

            if tmux != parsed.state { tmux = parsed.state }
            if attentionTails != parsed.tails { attentionTails = parsed.tails }
            if miniatures != parsed.miniatures { miniatures = parsed.miniatures }
            if !hasLiveProbe { hasLiveProbe = true }
            let nextSessionCount = parsed.state.sessions.count
            if sessionCount != nextSessionCount { sessionCount = nextSessionCount }
            switch parsed.state {
            case .sessions(let sessions):
                seedActiveAgentCache(from: sessions)
                onSnapshot?(DeckSnapshot(sessions: sessions, miniatures: miniatures))
            case .noServer, .tmuxMissing:
                // A settled "nothing there" clears the cache — ghost tiles
                // at the next launch would outlive the sessions they show.
                onSnapshot?(nil)
            case .unknown, .probing, .failed:
                break
            }
            Self.timing.debug("""
                \(self.host.name, privacy: .public) probe: exec \
                \(Self.ms(execStart, execEnd), privacy: .public)ms, parse \
                \(Self.ms(execEnd, parseEnd), privacy: .public)ms, \
                \(output.utf8.count, privacy: .public)B
                """)
            lastRefreshed = Date()
            evaluateAttention()
        } catch {
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            if reusedLink, mayRetry {
                // Retry silently: the rail keeps reading CONNECTED while a
                // fresh link is attempted (ensureConnection never downgrades
                // a non-idle phase), and only a failed retry surfaces.
                if let connection {
                    Task { await connection.close() }
                }
                connection = nil
                await performRefresh(
                    generation: generation,
                    mayRetry: false
                )
            } else {
                markFailed(error, registerConnectFailure: !reusedLink)
            }
        }
    }

    private func seedActiveAgentCache(from sessions: [TmuxSession]) {
        let panes = sessions.flatMap(\.windows).flatMap { $0.panes ?? [] }
        let liveIDs = Set(panes.map(\.tmuxID))
        activeAgentCache = activeAgentCache.filter { liveIDs.contains($0.key) }
        for pane in panes {
            guard let agent = pane.agent else { continue }
            cache(agent: agent, for: pane.processFingerprint)
        }
    }

    /// Elapsed milliseconds between two clock instants, for the stage logs.
    private static func ms(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Int {
        Int((to - from) / .milliseconds(1))
    }

    private func markFailed(_ error: Error, registerConnectFailure: Bool) {
        if registerConnectFailure {
            connectRetryBackoff.registerFailure(now: Date())
        }
        let message = friendlyMessage(for: error)
        let failedPhase = Phase.failed(message)
        let failedTmux = TmuxState.failed(message)
        if phase != failedPhase { phase = failedPhase }
        if tmux != failedTmux { tmux = failedTmux }
        if sessionCount != 0 { sessionCount = 0 }
        if let connection {
            // A link that timed out is usually black-holed; tearing it down
            // also unblocks any exec still hung on it. Never await this on
            // the path that renders UNREACHABLE.
            Task { await connection.close() }
        }
        connection = nil
        evaluateAttention()
    }

    private func ensureConnection(refreshGeneration expectedGeneration: Int? = nil) async throws -> SSHConnection {
        if let connection, phase == .connected {
            // A link whose last successful round-trip is several feed
            // intervals old was almost certainly severed while the app was
            // suspended (sockets freeze with the process; peers and NATs
            // move on). Reusing it burns a whole exec deadline discovering
            // that — rebuild preemptively instead. State and miniatures
            // stay, and the rail keeps CONNECTED unless the rebuild fails.
            let stale = lastRefreshed.map {
                Date().timeIntervalSince($0) > Self.staleLinkAge
            } ?? false
            if !stale { return connection }
            Task { await connection.close() }
            self.connection = nil
        }
        // Only surface .connecting before the first settled phase — same
        // rule as `.probing` above. The wall retries failed hosts every few
        // seconds, and flashing LINKING ↔ UNREACHABLE each cycle makes the
        // rail churn; a settled UNREACHABLE keeps reading UNREACHABLE until
        // a retry actually lands.
        if phase == .idle { phase = .connecting }
        let secretsStart = ContinuousClock.now
        let now = Date()
        let secrets: HostSecrets
        if let cachedSecrets,
           let cachedSecretsLoadedAt,
           now.timeIntervalSince(cachedSecretsLoadedAt) < Self.secretsCacheTTL {
            secrets = cachedSecrets
        } else {
            let loaded = await HostSecrets.loadOffMain(for: host)
            if let expectedGeneration,
               (expectedGeneration != refreshGeneration || Task.isCancelled) {
                throw CancellationError()
            }
            cachedSecrets = loaded
            cachedSecretsLoadedAt = Date()
            secrets = loaded
        }
        if let expectedGeneration,
           (expectedGeneration != refreshGeneration || Task.isCancelled) {
            throw CancellationError()
        }
        let fresh = SSHConnection(host: host, secrets: secrets)
        let connectStart = ContinuousClock.now
        do {
            try await deadlined(seconds: Self.connectDeadline) { try await fresh.connect() }
        } catch {
            Task { await fresh.close() }
            throw error
        }
        if let expectedGeneration,
           (expectedGeneration != refreshGeneration || Task.isCancelled) {
            await fresh.close()
            throw CancellationError()
        }
        Self.timing.debug("""
            \(self.host.name, privacy: .public) connect: secrets \
            \(Self.ms(secretsStart, connectStart), privacy: .public)ms, ssh \
            \(Self.ms(connectStart, .now), privacy: .public)ms
            """)
        connection = fresh
        phase = .connected
        connectRetryBackoff.reset()
        return fresh
    }

    /// Deadline for establishing the control connection (TCP + SSH handshake
    /// + auth); longer than an exec round-trip on an already-live link.
    private static let connectDeadline: Double = 15
    private static let secretsCacheTTL: TimeInterval = 60
    /// Age of the last successful round-trip beyond which an "established"
    /// link is presumed severed by suspension (several wall ticks — while
    /// the deck is frontmost, every tick refreshes it).
    private static let staleLinkAge: TimeInterval = 30
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
        return try await withCheckedThrowingContinuation { continuation in
            let gate = DeadlineGate(continuation)
            let work = Task {
                do { gate.finish(.success(try await operation()), winner: .work) }
                catch { gate.finish(.failure(error), winner: .work) }
            }
            let timer = Task {
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return }
                gate.finish(.failure(ProbeTimeoutError()), winner: .timer)
            }
            gate.install(work: work, timer: timer)
        }
    }

    /// Re-derive every session's agent state from the latest probe (title)
    /// + capture (dialog content), and emit any edges. Runs after every
    /// probe pass — title and tail inputs arrive together.
    private func evaluateAttention() {
        guard case .sessions(let sessions) = tmux else {
            if !attention.isEmpty { attention = [:] }
            attentionTracker.reset()
            return
        }
        var next: [String: PaneAgentState] = [:]
        for session in sessions {
            let window = session.activeWindow
            let activeAgent = window?.activeAgent
            let activeTitle = window?.activePane?.title ?? window?.paneTitle ?? ""
            // No detected agent, or an agent without verified attention
            // signals, means no state (bells are still tracked below).
            let state = AgentAttention.classifyVerified(
                title: activeTitle,
                tail: attentionTails[session.name] ?? [],
                agent: activeAgent
            )
            if let state {
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
                    agent: activeAgent,
                    event: event,
                    paneTitle: activeTitle
                ))
            }
        }
        attentionTracker.prune(keeping: Set(sessions.map(\.name)))
        if attention != next { attention = next }
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
        resetConnectRetryBackoff()
        let reusedLink = connection != nil && phase == .connected
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
            markFailed(error, registerConnectFailure: !reusedLink)
            return nil
        }
    }

    /// Kill a tmux session on the host over the control connection, then
    /// re-probe. The tile drops as soon as the kill lands; the follow-up
    /// probe is the truth and resurrects it if the kill failed. Fail-soft
    /// like the probe helpers — if the control link dropped, do nothing and
    /// let the next probe cycle surface the failure.
    func killSession(_ session: TmuxSession) async {
        resetConnectRetryBackoff()
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
        resetConnectRetryBackoff()
        let reusedLink = connection != nil && phase == .connected
        do {
            let connection = try await ensureConnection()
            var session = TmuxSession(name: name, windows: [], created: .distantPast)
            if case .sessions(let list) = tmux,
               let match = list.first(where: { $0.name == name }) {
                session = match
            }
            await kill(session, over: connection)
        } catch {
            markFailed(error, registerConnectFailure: !reusedLink)
        }
    }

    /// User actions and a newly-active wall get one immediate fresh attempt.
    func resetConnectRetryBackoff() {
        connectRetryBackoff.reset()
    }

    private func kill(_ session: TmuxSession, over connection: SSHConnection) async {
        _ = try? await deadlined { try await connection.exec(TmuxProbe.killCommand(for: session)) }
        if case .sessions(let list) = tmux {
            let remaining = list.filter { $0.id != session.id }
            tmux = .sessions(remaining)
            sessionCount = remaining.count
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
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        if let connection {
            await connection.close()
        }
        connection = nil
        phase = .idle
        tmux = .unknown
        hasLiveProbe = false
        sessionCount = 0
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

/// Resolves a deadline race once and cancels its losing task. In particular,
/// a successful five-second wall probe no longer leaves a ten-second timer
/// task alive behind it on every host and every tick.
private final class DeadlineGate<Value>: @unchecked Sendable {
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
