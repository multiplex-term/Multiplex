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
    /// App Group snapshot for the widget process, republished after settled
    /// probes and host-list changes.
    @ObservationIgnored private let widgetState = WidgetStatePublisher()
    /// The host list from the deck's last `publishWidgetState(hosts:)` —
    /// probe-driven republishes reuse it between host-list changes.
    @ObservationIgnored private var widgetHosts: [Host] = []
    /// Per-host recency carried across launches so a cold app start doesn't
    /// reset every widget's SEEN stamp to "never".
    @ObservationIgnored private lazy var widgetProbeDates: [UUID: Date] = Dictionary(
        uniqueKeysWithValues: (SharedStateStore.load()?.hosts ?? [])
            .compactMap { host in host.probedAt.map { (host.id, $0) } }
    )

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
        model.onSnapshot = { [weak self, snapshots] snapshot in
            snapshots.update(snapshot, for: host.id)
            self?.scheduleWidgetStatePublish()
        }
        if let snapshot = snapshots.snapshot(for: host.id) {
            model.restore(from: snapshot)
        }
        models[host.id] = model
        return model
    }

    /// The host was switched off. Nothing asks for its model again while it
    /// stays off, so the live one would keep its control connection (and the
    /// wall's stale idea of it) forever — drop it and disconnect. The deck
    /// snapshot deliberately survives, unlike `dropModel`: switching the host
    /// back on repaints its last-known tiles while the probe rebuilds.
    /// Idempotent, because the disable action and the wall feed both call it
    /// (the feed is how a disable synced from another device lands here).
    func suspendModel(for hostID: UUID) {
        guard let model = models.removeValue(forKey: hostID) else { return }
        Task { await model.disconnect() }
    }

    func dropModel(for hostID: UUID) {
        snapshots.remove(for: hostID)
        widgetProbeDates.removeValue(forKey: hostID)
        if let model = models.removeValue(forKey: hostID) {
            Task { await model.disconnect() }
        }
    }

    /// One passphrase answer can unblock the wall probe and every terminal
    /// tab for this host. Persistence is handled once by the prompt; the hub
    /// only refreshes models that were specifically waiting for it.
    func resumeConnectionsWaitingForKeyPassphrase(hostID: UUID) {
        models[hostID]?.resumeAfterKeyPassphraseUpdate()
    }

    /// The device's network path changed — every model's control link is
    /// suspect at once, so rebuild them all instead of letting each host
    /// discover its dead socket against a full exec deadline.
    func reconnectAfterNetworkChange() {
        for model in models.values {
            model.reconnectAfterNetworkChange()
        }
    }

    /// Persist any pending snapshot changes — called when the deck leaves
    /// the foreground, because suspension freezes the debounce timers. The
    /// widget snapshot always reloads timelines here: this is the moment the
    /// Home Screen becomes visible, so it must show the final state.
    func flushSnapshots() {
        snapshots.flush()
        widgetState.flush(reloadAlways: true)
    }

    // MARK: Widget snapshot

    /// The deck calls this on appear and whenever the host list changes;
    /// settled probes republish through `onSnapshot` with the same list.
    func publishWidgetState(hosts: [Host]) {
        widgetHosts = hosts
        scheduleWidgetStatePublish()
    }

    private func scheduleWidgetStatePublish() {
        guard !widgetHosts.isEmpty else {
            // An empty fleet is still a truth worth publishing (all hosts
            // removed) — but only once a deck has reported at all.
            widgetState.schedule(WidgetFleetState(hosts: [], generatedAt: Date()))
            return
        }
        let states = widgetHosts.map { host -> WidgetHostState in
            let model = models[host.id]
            // Live probe state when the model has one; otherwise the same
            // last-known snapshot the deck's tiles restore from.
            let snapshot: DeckSnapshot?
            if let model, model.hasLiveProbe {
                snapshot = DeckSnapshot(
                    sessions: model.tmux.sessions,
                    miniatures: model.miniatures,
                    sessionBackend: host.sessionBackend
                )
                widgetProbeDates[host.id] = Date()
            } else {
                let cached = snapshots.snapshot(for: host.id)
                snapshot = cached?.sessionBackend == host.sessionBackend
                    ? cached : nil
            }
            return WidgetStateBuilder.hostState(
                host: host,
                sessions: snapshot?.sessions ?? [],
                miniatures: snapshot?.miniatures ?? [:],
                probedAt: widgetProbeDates[host.id]
            )
        }
        widgetState.schedule(WidgetFleetState(hosts: states, generatedAt: Date()))
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
    /// Set when the private key is encrypted and its absent/stale passphrase
    /// could not unlock it. Background wall polling never presents UI by
    /// itself; FleetWall asks only after the user presses the failed host.
    private(set) var keyPassphraseChallenge: SSHKeyPassphraseChallenge?
    @ObservationIgnored private var lastRefreshed: Date?
    /// Observation-friendly summaries: views that only need liveness or a
    /// badge count should not subscribe to the full pane/process tree.
    private(set) var hasLiveProbe = false
    private(set) var sessionCount = 0
    /// herdr is installed on this host (the tmux probe checks presence
    /// every tick). Read only by the dead-tmux tile's switch hint.
    private(set) var herdrPresent = false
    /// Session name → last visible lines of its active pane; the deck
    /// wall's live miniatures, refreshed by every probe (the probe's single
    /// exec carries the capture tails).
    private(set) var miniatures: [String: [String]] = [:]
    /// Session name → agent state (busy / idle / needs you), re-derived on
    /// every probe and capture pass. Drives the wall's NEEDS YOU badge.
    private(set) var attention: [String: PaneAgentState] = [:]
    /// The macOS locked-keychain tip (see `KeychainLockCheck`): set while a
    /// Claude pane sits on its sign-in screen AND the host-side check
    /// confirms the login keychain is locked over SSH. Free host plumbing
    /// like the FAQ entry it mirrors, not an agent-helper surface.
    private(set) var keychainNotice: KeychainLockNotice?
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
    /// Other re-entered credentials can take at most 60 seconds to land, while
    /// the connection-time passphrase cache overlays this immediately. This
    /// extends plaintext residency between attempts, but a live SSHConnection
    /// already retains the same secrets for its lifetime, so the security
    /// posture is unchanged.
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
    /// herdr mode: the two sets the NEXT probe bakes into its command —
    /// the running sessions to snapshot and the pane each one fronts for
    /// its miniature read. A shell can't join JSON, so the app bakes last
    /// tick's answer into this tick's command (one tick of lag, inside
    /// the wall's staleness budget).
    /// nil is the cold-tick sentinel; [] means a parsed list proved no
    /// session is running. Conflating those states would probe a stopped
    /// default session forever.
    @ObservationIgnored private var herdrSessionNames: [String]?
    @ObservationIgnored private var herdrTailTargets: [HerdrProbe.TailTarget] = []
    /// herdr mode: session name → pane id → lifecycle status from the
    /// last snapshots, EVERY pane included (pane ids collide across
    /// sessions, so a pane is never keyed without its session) — the
    /// attention authority. Never persisted; NEEDS YOU is re-earned live.
    @ObservationIgnored private var herdrPaneStatuses: [String: [String: HerdrProbe.AgentStatus]] = [:]
    /// The immediately preceding status table, retained only long enough to
    /// attribute an aggregate busy → idle edge to the front pane without
    /// borrowing its agent name when a background pane actually finished.
    @ObservationIgnored private var previousHerdrPaneStatuses: [String: [String: HerdrProbe.AgentStatus]] = [:]
    /// Last keychain check answer + when it landed. `.notMacOS` is
    /// structural and never re-asked on this connection; other verdicts
    /// refresh after `keychainVerdictTTL` while the symptom persists.
    @ObservationIgnored private var keychainVerdict: (verdict: KeychainLockCheck.Verdict, at: Date)?
    @ObservationIgnored private var keychainCheckInFlight = false

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
        guard snapshot.sessionBackend == host.sessionBackend,
              case .unknown = tmux
        else { return }
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
        // herdr mode has no list-panes fast path; the snapshot's agent layer
        // already answers at the probe cadence, and a nil here just means
        // callers keep the probe's verdict (their documented fallback).
        guard host.sessionBackend == .tmux else { return nil }
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
        if let challenge = keyPassphraseChallenge {
            let revision = SSHKeyPassphraseSession.snapshot(for: host.id).revision
            // Another window (or Host Settings) supplied a newer answer.
            // Otherwise leave the settled failure alone: a five-second wall
            // feed must never keep asking for the same passphrase.
            guard revision > challenge.attemptedRevision else { return }
            keyPassphraseChallenge = nil
        }
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
            let parsed: TmuxProbe.ParsedProbe
            let execEnd: ContinuousClock.Instant
            let outputBytes: Int
            switch host.sessionBackend {
            case .tmux:
                let output = try await deadlined {
                    try await connection.exec(TmuxProbe.probeCommand)
                }
                execEnd = ContinuousClock.now
                outputBytes = output.utf8.count
                guard refreshGeneration == generation, !Task.isCancelled else { return }
                parsed = await Task.detached(priority: .userInitiated) {
                    TmuxProbe.parseProbe(output)
                }.value
            case .herdr:
                let command = HerdrProbe.probeCommand(
                    sessionNames: herdrSessionNames,
                    tailTargets: herdrTailTargets
                )
                let output = try await deadlined { try await connection.exec(command) }
                execEnd = ContinuousClock.now
                outputBytes = output.utf8.count
                guard refreshGeneration == generation, !Task.isCancelled else { return }
                let herdrParsed = await Task.detached(priority: .userInitiated) {
                    HerdrProbe.parseProbe(output)
                }.value
                // Parsing runs off-actor; a backend switch or suspension can
                // invalidate this generation while it is in flight. Do not
                // let that stale pass prime the next herdr command or its
                // attention-edge baseline.
                guard refreshGeneration == generation, !Task.isCancelled else { return }
                herdrSessionNames = herdrParsed.sessionNames
                herdrTailTargets = herdrParsed.tailTargets
                previousHerdrPaneStatuses = herdrPaneStatuses
                herdrPaneStatuses = herdrParsed.paneStatuses
                parsed = TmuxProbe.ParsedProbe(
                    state: herdrParsed.state.tmuxState,
                    tails: herdrParsed.tails,
                    miniatures: herdrParsed.miniatures
                )
            }
            let parseEnd = ContinuousClock.now
            guard refreshGeneration == generation, !Task.isCancelled else { return }

            if tmux != parsed.state { tmux = parsed.state }
            if attentionTails != parsed.tails { attentionTails = parsed.tails }
            if miniatures != parsed.miniatures { miniatures = parsed.miniatures }
            if herdrPresent != parsed.herdrPresent { herdrPresent = parsed.herdrPresent }
            if !hasLiveProbe { hasLiveProbe = true }
            let nextSessionCount = parsed.state.sessions.count
            if sessionCount != nextSessionCount { sessionCount = nextSessionCount }
            switch parsed.state {
            case .sessions(let sessions):
                seedActiveAgentCache(from: sessions)
                onSnapshot?(DeckSnapshot(
                    sessions: sessions,
                    miniatures: miniatures,
                    sessionBackend: host.sessionBackend
                ))
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
                \(outputBytes, privacy: .public)B
                """)
            lastRefreshed = Date()
            evaluateAttention()
            await evaluateKeychainTip(connection: connection, generation: generation)
        } catch {
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            if reusedLink, mayRetry {
                // The established link failed a real round-trip — an event,
                // not the periodic retry loop the anti-flash rule guards.
                // Read as LINKING while the immediate fresh attempt runs
                // (up to a whole connect deadline against a host that just
                // left the network): a rail still claiming CONNECTED there
                // is a lie the user watches (user-reported). Sessions and
                // miniatures stay; the attempt settles the phase itself.
                if phase != .connecting { phase = .connecting }
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
        let passphraseReason = (error as? SSHConnectionError)?.keyPassphraseReason
        if registerConnectFailure, passphraseReason == nil {
            connectRetryBackoff.registerFailure(now: Date())
        }
        if let passphraseReason {
            keyPassphraseChallenge = SSHKeyPassphraseChallenge(
                host: host,
                reason: passphraseReason
            )
        } else {
            keyPassphraseChallenge = nil
        }
        let message = friendlyMessage(for: error)
        let failedPhase = Phase.failed(message)
        let failedTmux = TmuxState.failed(message)
        if phase != failedPhase { phase = failedPhase }
        if tmux != failedTmux { tmux = failedTmux }
        if sessionCount != 0 { sessionCount = 0 }
        if keychainNotice != nil { keychainNotice = nil }
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
            secrets = cachedSecrets.applyingSessionPassphrase(for: host.id)
            self.cachedSecrets = secrets
        } else {
            let loaded = await HostSecrets.loadOffMain(for: host)
            if let expectedGeneration,
               expectedGeneration != refreshGeneration || Task.isCancelled {
                throw CancellationError()
            }
            cachedSecrets = loaded
            cachedSecretsLoadedAt = Date()
            secrets = loaded
        }
        if let expectedGeneration,
           expectedGeneration != refreshGeneration || Task.isCancelled {
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
           expectedGeneration != refreshGeneration || Task.isCancelled {
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
                do {
                    gate.finish(.success(try await operation()), winner: .work)
                } catch {
                    gate.finish(.failure(error), winner: .work)
                }
            }
            let timer = Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
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
            let verdict = sessionAttentionVerdict(for: session)
            if let state = verdict.state {
                next[session.name] = state
            }
            let events = attentionTracker.update(
                session: session.name,
                state: verdict.state,
                hasBell: verdict.hasBell
            )
            // One banner per session per tick — the most actionable edge
            // wins (they share a notification slot, and delivery order
            // across independent posts isn't guaranteed).
            if let event = events.max(by: { $0.priority < $1.priority }) {
                var dialogSummary: String?
                if verdict.offersDialogSummary, case .needsInput(let kind) = event {
                    dialogSummary = AgentAttention.dialogSummary(
                        in: attentionTails[session.name] ?? [], kind: kind)
                }
                onAttentionAlert?(AttentionAlert(
                    host: host,
                    sessionName: session.name,
                    agent: verdict.agent,
                    event: event,
                    paneTitle: verdict.paneTitle,
                    dialogSummary: dialogSummary
                ))
            }
        }
        attentionTracker.prune(keeping: Set(sessions.map(\.name)))
        if attention != next { attention = next }
    }

    private struct AttentionVerdict {
        var state: PaneAgentState?
        var agent: AgentKind?
        var paneTitle: String
        var hasBell: Bool
        var offersDialogSummary: Bool
    }

    /// The ONE per-backend step of `evaluateAttention` — everything
    /// downstream (tracker edges, one-banner-per-tick selection, pruning)
    /// is shared so alert policy can't drift by backend. tmux classifies
    /// the fronted pane's title + capture through the needle heuristics.
    /// herdr's reported lifecycle statuses are authoritative instead —
    /// which is what makes Pi's alerts real there — and fold across EVERY
    /// pane in the session, background tabs included: a blocked agent the
    /// session isn't fronting still needs you. herdr offers no dialog
    /// summary (0.7.5 surfaces the blocked message nowhere readable,
    /// verified 2026-08-01) and no bells; its derived `done` arrives as
    /// the busy → idle edge, exactly the turn-ended shape.
    private func sessionAttentionVerdict(for session: TmuxSession) -> AttentionVerdict {
        switch host.sessionBackend {
        case .tmux:
            let window = session.activeWindow
            let agent = window?.activeAgent
            let title = window?.activePane?.title ?? window?.paneTitle ?? ""
            return AttentionVerdict(
                // No detected agent, or an agent without verified attention
                // signals, means no state (bells are still tracked).
                state: AgentAttention.classifyVerified(
                    title: title,
                    tail: attentionTails[session.name] ?? [],
                    agent: agent
                ),
                agent: agent,
                paneTitle: title,
                hasBell: session.windows.contains(where: \.hasBell),
                offersDialogSummary: true
            )
        case .herdr:
            let statuses = herdrPaneStatuses[session.name] ?? [:]
            let state = HerdrProbe.sessionAgentState(statuses.values)
            // Alert metadata speaks for the fronted pane only when its own
            // status produced the session's verdict — a blocked background
            // tab must not borrow the front pane's agent name.
            let pane = session.activeWindow?.activePane
            let frontStatus = pane.flatMap { statuses[$0.tmuxID] }
            let previousFrontStatus = pane.flatMap {
                previousHerdrPaneStatuses[session.name]?[$0.tmuxID]
            }
            // Busy/blocked are winning states, so a matching front pane
            // participated in the verdict. Idle is different: a background
            // pane may have produced the aggregate busy → idle edge while
            // the front pane merely stayed idle. Herdr's explicit `done`, or
            // this pane's own observed working → idle edge, proves it did.
            let front = HerdrProbe.paneProducedSessionState(
                state,
                current: frontStatus,
                previous: previousFrontStatus
            ) ? pane : nil
            return AttentionVerdict(
                state: state,
                agent: front?.agent,
                paneTitle: front?.title ?? "",
                hasBell: false,
                offersDialogSummary: false
            )
        }
    }

    /// Re-derive the wall's KEYCHAIN LOCKED tip after a settled probe.
    /// Symptom first: only a Claude pane visibly parked on its sign-in
    /// screen (needle in the capture tail, agent confirmed on that pane)
    /// triggers the one-exec host check, so healthy hosts never run
    /// `security` at all. The check reuses the probe connection and
    /// transports a sentinel — the credential itself never leaves the host
    /// (see `KeychainLockCheck.checkCommand`). Fail-soft like every probe
    /// stage: an unreadable answer just clears the tip.
    private func evaluateKeychainTip(connection: SSHConnection, generation: Int) async {
        guard case .sessions(let sessions) = tmux else {
            applyKeychainVerdict(nil, sessions: [])
            return
        }
        let affected = sessions.filter { session in
            session.activeAgent == .claudeCode
                && KeychainLockCheck.showsClaudeLoginScreen(
                    in: attentionTails[session.name] ?? [])
        }.map(\.name)
        guard !affected.isEmpty else {
            applyKeychainVerdict(nil, sessions: [])
            return
        }
        #if DEBUG
        if let forced = Self.forcedKeychainVerdict {
            applyKeychainVerdict(forced, sessions: affected)
            return
        }
        #endif
        if let cached = keychainVerdict,
           cached.verdict == .notMacOS
               || Date().timeIntervalSince(cached.at) < Self.keychainVerdictTTL {
            applyKeychainVerdict(cached.verdict, sessions: affected)
            return
        }
        guard !keychainCheckInFlight else { return }
        keychainCheckInFlight = true
        defer { keychainCheckInFlight = false }
        let output = try? await deadlined {
            try await connection.exec(KeychainLockCheck.checkCommand)
        }
        guard refreshGeneration == generation, !Task.isCancelled else { return }
        let verdict = output.map(KeychainLockCheck.parse) ?? .indeterminate
        keychainVerdict = (verdict, Date())
        // Field-debuggable (`log stream --predicate 'category == "wall"'`):
        // the one line that says the symptom was seen and what the host
        // answered — the difference between "needle never matched" and
        // "check said unlocked" when a tip doesn't appear.
        Self.timing.debug("""
            \(self.host.name, privacy: .public) keychain check: \
            \(String(describing: verdict), privacy: .public) — sign-in screen in \
            \(affected.joined(separator: ","), privacy: .public)
            """)
        applyKeychainVerdict(verdict, sessions: affected)
    }

    #if DEBUG
    /// `MULTIPLEX_KEYCHAIN_TIP=locked|unlocked|missing` forces the check's
    /// verdict — the sign-in-screen gate still applies — so the rail tip
    /// can be driven headlessly against the harness's fake agent pane
    /// without a genuinely locked keychain.
    private static let forcedKeychainVerdict: KeychainLockCheck.Verdict? = {
        switch ProcessInfo.processInfo.environment["MULTIPLEX_KEYCHAIN_TIP"] {
        case "locked": .locked
        case "unlocked": .unlocked
        case "missing": .credentialsMissing
        default: nil
        }
    }()
    #endif

    private func applyKeychainVerdict(
        _ verdict: KeychainLockCheck.Verdict?, sessions: [String]
    ) {
        let notice = verdict == .locked
            ? KeychainLockNotice(sessionNames: sessions) : nil
        if keychainNotice != notice { keychainNotice = notice }
    }

    /// While the sign-in screen persists, re-confirm the lock at this
    /// cadence (the tip clears instantly when the screen moves on — that
    /// path needs no exec; this catches an unlock behind an unchanged
    /// screen without re-reading the keychain every five-second tick).
    private static let keychainVerdictTTL: TimeInterval = 60

    /// Create a detached tmux session over the control connection and
    /// return its final name — in `sourceSession`'s active-pane cwd ($HOME
    /// when nil or unresolvable), or in an explicit `directory` (a host
    /// working dir) when there is no source, optionally applying `tmuxConf`
    /// (the host's new-session tmux options, `set-option -t` the fresh
    /// session) before `script` (a host setup script) then `launch` are
    /// typed into its fresh shell. Like `script`, callers thread `tmuxConf`
    /// from the live host record: the field is excluded from the connection
    /// model's identity so edits don't drop the probe link, which means
    /// `self.host` can hold a stale copy. The wanted name derives from
    /// `base` against the latest probe; the server settles races (see
    /// `TmuxProbe.newSessionCommand`). Unlike the fail-soft probe helpers
    /// this connects on demand — it's a user-initiated action — and returns
    /// nil on failure.
    /// Returns the attach mode for the created session — the one value every
    /// caller actually wants, and what preserves the selected backend in the
    /// terminal route before the next probe has seen the new session.
    func createSession(
        base: String, inDirectoryOf sourceSession: String?,
        startingIn directory: String? = nil, applying tmuxConf: String? = nil,
        running script: String? = nil, typing launch: String?
    ) async -> TerminalRoute.Mode? {
        resetConnectRetryBackoff()
        let reusedLink = connection != nil && phase == .connected
        do {
            let connection = try await ensureConnection()
            if host.sessionBackend == .herdr {
                // Sessions have no start directory (herdr owns each
                // session's world) and no tmux conf — those two riders
                // apply to the tmux path only.
                return await createHerdrSession(
                    base: base, running: script, typing: launch,
                    over: connection
                )
            }
            let command = TmuxProbe.newSessionCommand(
                name: TmuxProbe.uniqueSessionName(
                    base: base, existing: tmux.sessions.map(\.name)),
                sourceSessionName: sourceSession,
                startDirectory: directory,
                tmuxConf: tmuxConf,
                script: script,
                launch: launch
            )
            let name = TmuxProbe.parseNewSession(
                try await deadlined { try await connection.exec(command) })
            // The wall and every open window should see the session now,
            // not on their next tick.
            refresh()
            return name.map { .attach(sessionName: $0) }
        } catch {
            markFailed(error, registerConnectFailure: !reusedLink)
            return nil
        }
    }

    /// The herdr mint: a session is created by attaching to it, so the
    /// mint IS the attach route — but the client needs a PTY, and setup
    /// typing needs the fresh session's pane id. `spawnSessionCommand`
    /// bridges: it brings the session's server up headlessly and prints
    /// its snapshot, so create-and-type completes over the control
    /// connection BEFORE the terminal window dials in — the script lands
    /// first, the tmux mint's own ordering. If the spawn can't confirm a
    /// pane (a future herdr may die before daemonizing), the route still
    /// attaches — the PTY client creates the session — and a short poll
    /// types the setup lines once a pane exists. A live list is read first
    /// and the requested name is uniqued against it: typing must only ever
    /// aim at a session this mint brought into being.
    private func createHerdrSession(
        base: String, running script: String?, typing launch: String?,
        over connection: SSHConnection
    ) async -> TerminalRoute.Mode? {
        let lines = [script, launch].compactMap { $0 }
        // The probe's tile list can be a tick stale. Read the live list and
        // distinguish a valid empty result from garbage: setup text may only
        // target a name whose absence this mint actually proved. Re-unique
        // against that live answer rather than silently attaching a session
        // another device created after the last wall tick.
        let listOutput = try? await deadlined {
            try await connection.exec(HerdrProbe.sessionListCommand)
        }
        guard let listOutput,
              let existing = HerdrProbe.parseSessionNames(listOutput)
        else { return nil }
        let name = HerdrProbe.uniqueSessionName(base: base, existing: existing)
        let spawn = try? await deadlined {
            try await connection.exec(HerdrProbe.spawnSessionCommand(sessionName: name))
        }
        if !lines.isEmpty {
            if let pane = spawn.flatMap(HerdrProbe.parseFocusedPane),
               let typing = HerdrProbe.typeCommand(
                sessionName: name, paneID: pane, lines: lines) {
                _ = try? await deadlined { try await connection.exec(typing) }
            } else {
                schedulePendingHerdrTyping(session: name, lines: lines)
            }
        }
        refresh()
        return .herdrAttach(sessionName: name)
    }

    /// Setup lines waiting for a pane: the PTY attach is creating the
    /// session, so poll its snapshot over the control connection and type
    /// once. Bounded — a session that never comes up types nothing, and
    /// the window's own failure is the visible story. The user can beat
    /// this to the fresh prompt; the tmux path's stdin-reading-script
    /// footgun already documents that shape.
    private func schedulePendingHerdrTyping(session: String, lines: [String]) {
        Task { [weak self] in
            for attempt in 1...8 {
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 1500 : 1200))
                guard let self, self.phase == .connected, let connection = self.connection
                else { return }
                guard let output = try? await self.deadlined({
                    try await connection.exec(
                        HerdrProbe.snapshotCommand(sessionName: session))
                }), let pane = HerdrProbe.parseFocusedPane(output)
                else { continue }
                if let typing = HerdrProbe.typeCommand(
                    sessionName: session, paneID: pane, lines: lines) {
                    _ = try? await self.deadlined { try await connection.exec(typing) }
                }
                return
            }
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
        await kill(session, backend: host.sessionBackend, over: connection)
    }

    /// Kill a session by name — the terminal window's CLOSE SESSION action.
    /// Unlike the wall's `killSession(_:)` this connects on demand (the tab
    /// just ended, so the control link may be down too; it's user-initiated,
    /// same policy as `createSession`). The latest probe supplies the
    /// session's tmux id when it has one; otherwise `killCommand` falls back
    /// to an `=name` exact match.
    func killSession(named name: String, backend: Host.SessionBackend) async {
        resetConnectRetryBackoff()
        let reusedLink = connection != nil && phase == .connected
        do {
            let connection = try await ensureConnection()
            var session = TmuxSession(name: name, windows: [], created: .distantPast)
            // The model's probe records only belong to its configured
            // backend. An older open tab may intentionally belong to the
            // other backend after Host Settings changes, so never borrow a
            // same-named record across that boundary.
            if backend == host.sessionBackend,
               case .sessions(let list) = tmux,
               let match = list.first(where: { $0.name == name }) {
                session = match
            }
            await kill(session, backend: backend, over: connection)
        } catch {
            markFailed(error, registerConnectFailure: !reusedLink)
        }
    }

    /// User actions and a newly-active wall get one immediate fresh attempt.
    func resetConnectRetryBackoff() {
        connectRetryBackoff.reset()
    }

    /// The device's network path changed under a live wall (Wi-Fi ↔
    /// cellular, VPN toggle, connectivity returning). An established control
    /// link is bound to the old path — presume it severed instead of burning
    /// an exec deadline discovering it, the same policy as the suspension
    /// stale-link rebuild: sessions and miniatures stay, and the rail keeps
    /// CONNECTED unless the rebuild fails. A host waiting out retry backoff
    /// gets a fresh attempt now — its failures belonged to the old network.
    func reconnectAfterNetworkChange() {
        connectRetryBackoff.reset()
        if let connection {
            // Closing also unblocks a probe hung on the dead link; the
            // in-flight refresh's silent retry then rebuilds on the new path.
            Task { await connection.close() }
            self.connection = nil
        }
        // Read as LINKING while the attempt runs — `ensureConnection` only
        // surfaces it from idle, an anti-flash rule aimed at the periodic
        // retry loop, and a network change is a one-shot edge. That covers
        // CONNECTED too: the old socket is bound to the departed path, so
        // keeping CONNECTED up during the rebuild is a lie the user watches
        // for the whole connect deadline when the new path can't reach the
        // host (user-reported). The attempt settles back to CONNECTED or
        // UNREACHABLE on its own. A pending passphrase challenge keeps
        // NEEDS PASSPHRASE: its refresh early-returns, and flipping would
        // strand the rail on LINKING.
        if keyPassphraseChallenge == nil, phase != .idle, phase != .connecting {
            phase = .connecting
        }
        refresh()
    }

    /// The failed rail/tile was pressed. Reissue the same challenge so a
    /// cancelled alert can be opened again. If another surface has supplied
    /// a newer process-only answer meanwhile, resume without asking twice.
    @discardableResult
    func requestKeyPassphrase() -> SSHKeyPassphraseChallenge? {
        guard let challenge = keyPassphraseChallenge else { return nil }
        let revision = SSHKeyPassphraseSession.snapshot(for: host.id).revision
        if revision > challenge.attemptedRevision {
            resumeAfterKeyPassphraseUpdate()
            return nil
        }
        let reissued = challenge.reissued()
        keyPassphraseChallenge = reissued
        return reissued
    }

    func resumeAfterKeyPassphraseUpdate() {
        guard keyPassphraseChallenge != nil else { return }
        keyPassphraseChallenge = nil
        if let cachedSecrets {
            self.cachedSecrets = cachedSecrets.applyingSessionPassphrase(for: host.id)
            cachedSecretsLoadedAt = Date()
        }
        connectRetryBackoff.reset()
        refresh()
    }

    private func kill(
        _ session: TmuxSession, backend: Host.SessionBackend,
        over connection: SSHConnection
    ) async {
        let command: String?
        switch backend {
        case .tmux:
            command = TmuxProbe.killCommand(for: session)
        case .herdr:
            // Stop the session's server (everything in it dies —
            // kill-session's analog), then delete its state dir. herdr
            // itself refuses deleting the default session; that tile just
            // parks as stopped. Session names are herdr's own unique
            // identity, so the name is the target.
            command = HerdrProbe.closeSessionCommand(for: session)
        }
        if let command {
            _ = try? await deadlined { try await connection.exec(command) }
        }
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
        keyPassphraseChallenge = nil
        hasLiveProbe = false
        sessionCount = 0
        miniatures = [:]
        attentionTails = [:]
        attention = [:]
        attentionTracker.reset()
        herdrSessionNames = nil
        herdrTailTargets = []
        herdrPaneStatuses = [:]
        previousHerdrPaneStatuses = [:]
        herdrPresent = false
        keychainNotice = nil
        keychainVerdict = nil
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

// The deadline race itself (first-wins resolution, loser cancelled both
// ways) is the shared `DeadlineGate` in `Deadline.swift`; only the probe's
// timeout error type is local.
