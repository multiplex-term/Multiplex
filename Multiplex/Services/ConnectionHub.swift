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
            //
            // Every monitored backend's sessions. Safe because rows on a
            // mixed host now carry `backendRaw` and their deep links emit
            // `backend=`, so a tap resolves in the right namespace instead
            // of matching a same-named session on the other one.
            let snapshot: DeckSnapshot?
            if let model, model.hasLiveProbe {
                snapshot = DeckSnapshot(
                    sessions: model.allSessions,
                    miniatures: model.miniatures.storageKeyed,
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
    /// The PRIMARY backend's probe state. Read from many call sites, and
    /// deliberately still the answer to "what does this host look like": the
    /// rail's STANDBY/LINKING/CONNECTED phase, the NO TMUX / NO SERVER
    /// tiles, and every external-action failure message speak for the one
    /// connection and the one backend that mints sessions.
    private(set) var tmux: TmuxState = .unknown
    /// Opted-in secondary backends' probe states, keyed by backend
    /// (`Host.secondaryBackends`). Empty on the overwhelmingly common
    /// single-backend host.
    private(set) var secondaryStates: [Host.SessionBackend: TmuxState] = [:]

    /// One monitored backend's sessions, from whichever slot it occupies.
    func sessions(on backend: Host.SessionBackend) -> [TmuxSession] {
        backend == host.sessionBackend
            ? tmux.sessions
            : secondaryStates[backend]?.sessions ?? []
    }

    /// Every monitored backend's sessions, primary's block first — what the
    /// wall renders and what `sessionCount` counts. A secondary answering
    /// "missing" or "no sessions" contributes nothing rather than a tile:
    /// the user asked to see its sessions if they exist, not to be told
    /// they don't.
    var allSessions: [TmuxSession] {
        guard !secondaryStates.isEmpty else { return tmux.sessions }
        return host.monitoredBackends.flatMap { backend in
            backend == host.sessionBackend
                ? tmux.sessions
                : secondaryStates[backend]?.sessions ?? []
        }
    }
    /// Set when the private key is encrypted and its absent/stale passphrase
    /// could not unlock it. Background wall polling never presents UI by
    /// itself; FleetWall asks only after the user presses the failed host.
    private(set) var keyPassphraseChallenge: SSHKeyPassphraseChallenge?
    @ObservationIgnored private var lastRefreshed: Date?
    /// Observation-friendly summaries: views that only need liveness or a
    /// badge count should not subscribe to the full pane/process tree.
    private(set) var hasLiveProbe = false
    private(set) var sessionCount = 0
    /// herdr is installed on this host (the discovery rider answers every
    /// tick). Read only by the dead-tmux tile's switch hint.
    private(set) var herdrPresent = false
    /// What the discovery riders found on the last settled probe, keyed by
    /// the backend asked (`BackendDiscovery`). Live-only: never snapshotted
    /// and never in `widget-state.json`, because an offer is about what is
    /// running right now. Cleared by `disconnect()` alongside the herdr bake
    /// state — a dead probe has no discovery to report.
    private(set) var discovery: [Host.SessionBackend: BackendDiscovery.Result] = [:]

    /// Backends this host is NOT monitoring that are nonetheless holding
    /// sessions right now — what the rail offers to start showing. Never
    /// acted on automatically; the press is the whole design.
    var offeredBackends: [BackendDiscovery.Result] {
        let monitored = Set(host.monitoredBackends)
        return Host.SessionBackend.allCases.compactMap { backend in
            guard !monitored.contains(backend),
                  let result = discovery[backend],
                  result.offersSessions
            else { return nil }
            return result
        }
    }
    /// Session → last visible lines of its active pane; the deck wall's
    /// live miniatures, refreshed by every probe (the probe's single exec
    /// carries the capture tails). Keyed by `SessionKey`, not name: a
    /// mixed host's tmux `main` and herdr `main` are two tiles.
    private(set) var miniatures: [SessionKey: [String]] = [:]
    /// Session → agent state (busy / idle / needs you), re-derived on
    /// every probe and capture pass. Drives the wall's NEEDS YOU badge.
    private(set) var attention: [SessionKey: PaneAgentState] = [:]
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
    @ObservationIgnored private var attentionTracker = AttentionTracker<SessionKey>()
    /// Deeper, unclipped capture tails (the miniatures' source parse) —
    /// what the question detector reads.
    @ObservationIgnored private var attentionTails: [SessionKey: [String]] = [:]
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
    /// herdr mode: session → pane id → lifecycle status from the last
    /// snapshots, EVERY pane included (pane ids collide across sessions, so
    /// a pane is never keyed without its session) — the attention
    /// authority. Never persisted; NEEDS YOU is re-earned live.
    @ObservationIgnored private var herdrPaneStatuses: [SessionKey: [String: HerdrProbe.AgentStatus]] = [:]
    /// The immediately preceding status table, retained only long enough to
    /// attribute an aggregate busy → idle edge to the front pane without
    /// borrowing its agent name when a background pane actually finished.
    @ObservationIgnored private var previousHerdrPaneStatuses: [SessionKey: [String: HerdrProbe.AgentStatus]] = [:]
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
        // Split by each record's own backend rather than pouring the lot
        // into the primary's state: a cached mixed host would otherwise make
        // `sessions(on: .tmux)` answer with herdr sessions until the first
        // live probe, and the mint uniques new names against that answer.
        tmux = .sessions(snapshot.sessions.filter { $0.backend == host.sessionBackend })
        for backend in host.monitoredBackends.dropFirst() {
            secondaryStates[backend] = .sessions(
                snapshot.sessions.filter { $0.backend == backend })
        }
        miniatures = snapshot.miniatures.sessionKeyed
        sessionCount = allSessions.count
    }

    /// Probe parsers answer for ONE backend, so their maps are name-keyed;
    /// the model merges backends, so its maps are `SessionKey`-keyed. This
    /// is the one seam between the two spaces.
    private static func keyed<Value>(
        _ byName: [String: Value], backend: Host.SessionBackend
    ) -> [SessionKey: Value] {
        Dictionary(
            byName.map { (SessionKey(backend: backend, name: $0.key), $0.value) },
            uniquingKeysWith: { _, later in later }
        )
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

    /// Fast path for the terminal that currently owns keyboard focus. Tmux
    /// uses one tiny list-panes exec, then a TTY-scoped process query only for
    /// a changed/expired ambiguous pane. Herdr's `pane current` returns its
    /// globally focused pane and canonical agent id directly.
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

        if host.sessionBackend == .herdr {
            // `pane current` carries no protocol field. Require a supported
            // full probe first; that pass owns the version gate and proves
            // the backend is serving sessions before the one-second path.
            guard HerdrProbe.bakeableSessionName(sessionName),
                  case .sessions = tmux,
                  let output = try? await deadlined(seconds: 3, {
                      try await connection.exec(
                          HerdrProbe.activePaneCommand(sessionName: sessionName))
                  })
            else { return nil }
            return HerdrProbe.parseActiveAgent(output)
        }

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
            // Discovery rides the primary probe for every backend this host
            // does NOT already monitor. A monitored one gets a full probe of
            // its own below, which would make the rider redundant work.
            let discovering = Set(Host.SessionBackend.allCases)
                .subtracting(host.monitoredBackends)
            let secondaries = host.monitoredBackends.dropFirst()

            // Two exec channels on the SAME connection, concurrently —
            // measured 105 ms against 176 ms concatenated (Citadel opens a
            // fresh channel per `executeCommand`, and the app already
            // multiplexes SFTP beside a live PTY). The reason that actually
            // decides it is containment: a secondary's failure must not be
            // able to reach `markFailed`, `phase`, or the dead-link rebuild,
            // and separate channels make that structural rather than
            // careful. Started BEFORE the primary is awaited so they
            // genuinely overlap.
            let secondaryProbes = secondaries.map { backend in
                (backend, Task { [weak self] in
                    guard let self else { return BackendProbe?.none }
                    do {
                        return try await self.runProbe(
                            backend: backend,
                            discovering: [],
                            over: connection,
                            generation: generation
                        )
                    } catch {
                        // Contained by design: log and leave every
                        // host-wide fact alone. `markFailed`, `phase`, and
                        // the dead-link rebuild belong to the primary
                        // probe, because a host's reachability is one fact
                        // about one connection.
                        Self.timing.debug("""
                            \(self.host.name, privacy: .public) secondary \
                            \(backend.rawValue, privacy: .public) probe failed: \
                            \(String(describing: error), privacy: .public)
                            """)
                        return nil
                    }
                })
            }

            let primary = try await runProbe(
                backend: host.sessionBackend,
                discovering: discovering,
                over: connection,
                generation: generation
            )
            let execEnd = ContinuousClock.now
            guard refreshGeneration == generation, !Task.isCancelled else {
                secondaryProbes.forEach { $0.1.cancel() }
                return
            }
            var nextSecondaryStates: [Host.SessionBackend: TmuxState] = [:]
            var results = [primary]
            for (backend, task) in secondaryProbes {
                guard let result = await task.value else {
                    // A secondary that failed keeps its LAST state rather
                    // than dropping to a stand-in: its sessions are still
                    // there, and one bad round-trip is not evidence they
                    // went away. It also stays out of `answered` below, so
                    // its attention baseline survives untouched.
                    nextSecondaryStates[backend] = secondaryStates[backend]
                    continue
                }
                nextSecondaryStates[backend] = result.parsed.state
                results.append(result)
            }
            let parseEnd = ContinuousClock.now
            guard refreshGeneration == generation, !Task.isCancelled else { return }

            let backend = host.sessionBackend
            var nextTails: [SessionKey: [String]] = [:]
            var nextMiniatures: [SessionKey: [String]] = [:]
            for result in results {
                nextTails.merge(
                    Self.keyed(result.parsed.tails, backend: result.backend)
                ) { _, later in later }
                nextMiniatures.merge(
                    Self.keyed(result.parsed.miniatures, backend: result.backend)
                ) { _, later in later }
            }
            if tmux != primary.parsed.state { tmux = primary.parsed.state }
            if secondaryStates != nextSecondaryStates {
                secondaryStates = nextSecondaryStates
            }
            if attentionTails != nextTails { attentionTails = nextTails }
            if miniatures != nextMiniatures { miniatures = nextMiniatures }
            if herdrPresent != primary.parsed.herdrPresent {
                herdrPresent = primary.parsed.herdrPresent
            }
            if discovery != primary.parsed.discovery {
                discovery = primary.parsed.discovery
            }
            if !hasLiveProbe { hasLiveProbe = true }
            let sessions = allSessions
            if sessionCount != sessions.count { sessionCount = sessions.count }
            switch primary.parsed.state {
            case .sessions:
                seedActiveAgentCache(from: sessions)
                onSnapshot?(DeckSnapshot(
                    sessions: sessions,
                    miniatures: miniatures.storageKeyed,
                    sessionBackend: host.sessionBackend
                ))
            case .noServer, .tmuxMissing:
                // A settled "nothing there" clears the cache — ghost tiles
                // at the next launch would outlive the sessions they show.
                // Keyed off the PRIMARY: it is what `restore(from:)` guards
                // on, so a cache it would refuse is a cache worth dropping.
                onSnapshot?(nil)
            case .unknown, .probing, .failed:
                break
            }
            Self.timing.debug("""
                \(self.host.name, privacy: .public) probe: exec \
                \(Self.ms(execStart, execEnd), privacy: .public)ms, parse \
                \(Self.ms(execEnd, parseEnd), privacy: .public)ms, \
                \(Self.byteBreakdown(results), privacy: .public)
                """)
            lastRefreshed = Date()
            // Only the backends that actually ANSWERED. A failed
            // secondary's sessions must keep both their displayed attention
            // and their edge baseline — pruning them is the 2026-08-05 bug's
            // exact shape (see `evaluateAttention`).
            evaluateAttention(answered: Set(results.map(\.backend)))
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

    /// One backend's full probe: exec, parse, and — for herdr — the bake
    /// state its NEXT command needs. Only one backend on a host can be
    /// herdr (primary or secondary, never both), so that state stays a
    /// single set.
    private struct BackendProbe {
        var backend: Host.SessionBackend
        var parsed: TmuxProbe.ParsedProbe
        var outputBytes: Int
    }

    /// Runs one backend's probe over the shared control connection.
    ///
    /// Throws on exec or deadline failure. The CALLER decides what that
    /// means: the primary's throw reaches `markFailed` and the dead-link
    /// rebuild, a secondary's is caught and logged.
    private func runProbe(
        backend: Host.SessionBackend,
        discovering: Set<Host.SessionBackend>,
        over connection: SSHConnection,
        generation: Int
    ) async throws -> BackendProbe {
        switch backend {
        case .tmux:
            let output = try await deadlined {
                try await connection.exec(
                    TmuxProbe.probeCommand(discovering: discovering))
            }
            try Task.checkCancellation()
            let parsed = await Task.detached(priority: .userInitiated) {
                TmuxProbe.parseProbe(output)
            }.value
            guard refreshGeneration == generation else { throw CancellationError() }
            return BackendProbe(
                backend: .tmux, parsed: parsed, outputBytes: output.utf8.count)
        case .herdr:
            let output = try await deadlined {
                try await connection.exec(HerdrProbe.probeCommand(
                    sessionNames: self.herdrSessionNames,
                    tailTargets: self.herdrTailTargets,
                    discovering: discovering
                ))
            }
            try Task.checkCancellation()
            let herdrParsed = await Task.detached(priority: .userInitiated) {
                HerdrProbe.parseProbe(output)
            }.value
            // Parsing runs off-actor; a backend switch or suspension can
            // invalidate this generation while it is in flight. Do not let
            // that stale pass prime the next herdr command or its
            // attention-edge baseline.
            guard refreshGeneration == generation else { throw CancellationError() }
            herdrSessionNames = herdrParsed.sessionNames
            herdrTailTargets = herdrParsed.tailTargets
            previousHerdrPaneStatuses = herdrPaneStatuses
            herdrPaneStatuses = Self.keyed(
                herdrParsed.paneStatuses, backend: .herdr)
            return BackendProbe(
                backend: .herdr,
                parsed: TmuxProbe.ParsedProbe(
                    state: herdrParsed.state.tmuxState,
                    tails: herdrParsed.tails,
                    miniatures: herdrParsed.miniatures,
                    discovery: herdrParsed.discovery
                ),
                outputBytes: output.utf8.count
            )
        }
    }

    /// `3478B tmux` — or `3478B tmux + 25324B herdr` on a mixed host, so the
    /// 2026-07 probe baseline stays comparable per backend.
    private static func byteBreakdown(_ results: [BackendProbe]) -> String {
        results
            .map { "\($0.outputBytes)B \($0.backend.rawValue)" }
            .joined(separator: " + ")
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
        clearDisplayedAttention()
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
    ///
    /// `answered` names the backends whose probe actually came back this
    /// pass. ⚠ It is the whole safety property of the mixed-host version: a
    /// backend that failed (or was never probed) has NOT proved its sessions
    /// are gone, so its displayed attention and — much more importantly —
    /// its `AttentionTracker` baseline must survive untouched. Handing this
    /// the union of everything *expected* reproduces the bug fixed
    /// 2026-08-05 exactly: a reachable session's NEEDS YOU silently cleared
    /// by an unrelated probe's failure, invisible outside the `attention`
    /// log, and "the agent finished while you were away" made
    /// unannounceable.
    private func evaluateAttention(answered: Set<Host.SessionBackend>) {
        guard !answered.isEmpty else { return }
        let sessions = allSessions.filter { answered.contains($0.backend) }
        // Start from what the backends that did NOT answer are still
        // showing. Their verdicts are not this pass's to retract; a backend
        // that DID answer has its keys rebuilt below, so answering with no
        // sessions correctly clears its own.
        var next = attention.filter { !answered.contains($0.key.backend) }
        for session in sessions {
            let verdict = sessionAttentionVerdict(for: session)
            if let state = verdict.state {
                next[session.id] = state
            }
            let events = attentionTracker.update(
                session: session.id,
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
                        in: attentionTails[session.id] ?? [], kind: kind)
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
        // Prune only within the backends that answered: an unanswered one's
        // baselines must survive, or the next successful pass has nothing to
        // compare against and emits no edge at all.
        attentionTracker.prune { key in
            !answered.contains(key.backend) || sessions.contains { $0.id == key }
        }
        if attention != next { attention = next }
    }

    /// The control link died. Stop *claiming* attention we can no longer see
    /// — NEEDS YOU is re-earned live, never asserted from a dead probe — but
    /// keep every edge baseline.
    ///
    /// A lost connection is not evidence that an agent's state changed, and
    /// the baseline is the only record of what it was: reset here, the
    /// reconnect's first pass has nothing to compare against and emits
    /// nothing. That is precisely the suspend → socket dies → wake →
    /// reconnect path, so clearing it made "the agent finished while you
    /// were away" unannounceable — the case background keep-alive and the
    /// background refresh both exist to serve. A session that really is gone
    /// is dropped by `prune` on the next successful pass.
    private func clearDisplayedAttention() {
        if !attention.isEmpty { attention = [:] }
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
        // The SESSION's backend, not the host's: a mixed host runs both, and
        // the classifier that applies is the one that produced the record.
        switch session.backend {
        case .tmux:
            let window = session.activeWindow
            let agent = window?.activeAgent
            let title = window?.activePane?.title ?? window?.paneTitle ?? ""
            return AttentionVerdict(
                // No detected agent, or an agent without verified attention
                // signals, means no state (bells are still tracked).
                state: AgentAttention.classifyVerified(
                    title: title,
                    tail: attentionTails[session.id] ?? [],
                    agent: agent
                ),
                agent: agent,
                paneTitle: title,
                hasBell: session.windows.contains(where: \.hasBell),
                offersDialogSummary: true
            )
        case .herdr:
            let statuses = herdrPaneStatuses[session.id] ?? [:]
            let state = HerdrProbe.sessionAgentState(statuses.values)
            // Alert metadata speaks for the fronted pane only when its own
            // status produced the session's verdict — a blocked background
            // tab must not borrow the front pane's agent name.
            let pane = session.activeWindow?.activePane
            let frontStatus = pane.flatMap { statuses[$0.tmuxID] }
            let previousFrontStatus = pane.flatMap {
                previousHerdrPaneStatuses[session.id]?[$0.tmuxID]
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
                    in: attentionTails[session.id] ?? [])
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
    /// `backend` names which multiplexer mints. Defaults to the host's
    /// primary — the only answer on a single-backend host, and still the
    /// default everywhere else; a mixed host's New Session sheet passes the
    /// user's explicit choice.
    func createSession(
        base: String, backend: Host.SessionBackend? = nil,
        inDirectoryOf sourceSession: String?,
        startingIn directory: String? = nil, applying tmuxConf: String? = nil,
        running script: String? = nil, typing launch: String?
    ) async -> TerminalRoute.Mode? {
        resetConnectRetryBackoff()
        let reusedLink = connection != nil && phase == .connected
        let backend = backend ?? host.sessionBackend
        do {
            let connection = try await ensureConnection()
            if backend == .herdr {
                // The tmux conf rider applies to the tmux path only; the
                // two directory riders resolve inside the herdr mint (the
                // session server inherits the spawn's cwd).
                return await createHerdrSession(
                    base: base, inDirectoryOf: sourceSession,
                    startingIn: directory, running: script, typing: launch,
                    over: connection
                )
            }
            let command = TmuxProbe.newSessionCommand(
                // Unique within TMUX's namespace only: a herdr session of
                // the same name is a different server, and the two never
                // collide (`SessionKey`). The server settles real races.
                name: TmuxProbe.uniqueSessionName(
                    base: base, existing: sessions(on: .tmux).map(\.name)),
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
    /// types the setup lines once a pane exists (that fallback spawns at
    /// the PTY's login $HOME: the directory riders are best-effort). A
    /// live list is read first and the requested name is uniqued against
    /// it: typing must only ever aim at a session this mint brought into
    /// being.
    ///
    /// The directory riders are the tmux mint's, one exec louder: a
    /// source session's focused-pane cwd is asked from the snapshot the
    /// drop path already reads (tmux gets it server-side in the create),
    /// and an explicit directory is consulted only without a source —
    /// `newSessionCommand`'s own precedence. Either rides the spawn as a
    /// guarded cd; every miss is $HOME, never a failed mint.
    private func createHerdrSession(
        base: String, inDirectoryOf sourceSession: String?,
        startingIn directory: String?, running script: String?,
        typing launch: String?, over connection: SSHConnection
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
        var startDirectory: String?
        if let sourceSession {
            let snapshot = try? await deadlined {
                try await connection.exec(
                    HerdrProbe.snapshotCommand(sessionName: sourceSession))
            }
            startDirectory = snapshot.flatMap(
                HerdrProbe.parseFocusedPaneWorkingDirectory)
        } else {
            startDirectory = directory
        }
        let spawn = try? await deadlined {
            try await connection.exec(HerdrProbe.spawnSessionCommand(
                sessionName: name, directory: startDirectory))
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

    /// Create a tab in `session`'s focused workspace, typing the same
    /// setup `script` a freshly minted session gets — the `+ TAB` menu's
    /// herdr-only New Tab in Workspace entry. The already-attached client
    /// renders it, so nothing here mints a route; the entries that DO mint
    /// one (New Session and the agents, the menu's leading rows on every
    /// backend) go through `createSession`, which is also the agent road —
    /// this row types no launch (external `in=tab` launches keep
    /// `launchInHerdrSession`).
    ///
    /// The backend is the caller's, read off the tab's own route rather
    /// than `host.sessionBackend` (same rule as `killSession(named:
    /// backend:)`): an open herdr tab keeps meaning herdr after Host
    /// Settings switches the deck's backend, and these are herdr commands
    /// either way. Connects on demand like `createSession`, and returns
    /// false when the create answered with no pane — a stopped session,
    /// or a herdr too old for `tab create`.
    ///
    /// Unlike `launchInHerdrSession` this does NOT spawn first: an external
    /// launch names a session it may have to revive, while a press means
    /// "another tab in what I'm looking at". A session that isn't running
    /// fails the create, and the window says so — reviving it headlessly
    /// would put the new tab somewhere nobody is attached.
    func createHerdrTab(
        inSession session: String, running script: String?
    ) async -> Bool {
        guard HerdrProbe.bakeableSessionName(session) else { return false }
        resetConnectRetryBackoff()
        let reusedLink = connection != nil && phase == .connected
        do {
            let connection = try await ensureConnection()
            let created = try await deadlined {
                try await connection.exec(HerdrProbe.createTabCommand(
                    sessionName: session, label: nil, directory: nil))
            }
            guard let pane = HerdrProbe.parseCreatedPane(created) else { return false }
            if let typing = HerdrProbe.typeCommand(
                sessionName: session,
                paneID: pane,
                lines: [script].compactMap { $0 }
            ) {
                _ = try? await deadlined { try await connection.exec(typing) }
            }
            // The wall's miniature and pane counts moved with the press.
            refresh()
            return true
        } catch {
            markFailed(error, registerConnectFailure: !reusedLink)
            return false
        }
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

    /// Launch inside an EXISTING session — the external action's session
    /// target. tmux: one exec opens a new window in the session and types
    /// `script` then `launch` into its fresh pane. herdr: make sure the
    /// session's server is up (attach auto-restarts a stopped one — the
    /// tile list keeps stopped sessions pressable, and this path honors
    /// that), create a new tab in the focused workspace or a new workspace
    /// per `placement`, then type into the pane the create envelope named.
    /// `label` names the herdr tab/workspace (tmux windows name themselves
    /// from the running command); nil leaves herdr's own tab numbering —
    /// the deck's shell-only tab creates; `directory` carries the Working Directory
    /// semantics — callers pass the explicit choice or the host's first
    /// configured dir, exactly like the fresh-session mint, so the one
    /// field means the same thing wherever the agent lands. Only a host
    /// with nothing configured reaches nil, which falls to the session's
    /// own world (tmux: the active-pane cwd; herdr: the server default).
    /// Returns the session's attach mode (the fresh pane is now what the
    /// session fronts); nil on failure — never a fallback mint, which
    /// would hide the failure behind a surprise second session.
    /// `backend` is the TARGET session's, resolved by the caller against
    /// the probe list — never `host.sessionBackend`, which on a mixed host
    /// answers only for the primary.
    func launchInSession(
        named sessionName: String,
        backend: Host.SessionBackend? = nil,
        placement: ExternalSessionPlacement,
        directory: String?,
        label: String?,
        running script: String? = nil,
        typing launch: String?
    ) async -> TerminalRoute.Mode? {
        resetConnectRetryBackoff()
        let reusedLink = connection != nil && phase == .connected
        do {
            let connection = try await ensureConnection()
            if (backend ?? host.sessionBackend) == .herdr {
                return await launchInHerdrSession(
                    named: sessionName, placement: placement,
                    directory: directory, label: label,
                    running: script, typing: launch,
                    over: connection)
            }
            let command = TmuxProbe.newWindowCommand(
                sessionName: sessionName,
                startDirectory: directory,
                script: script,
                launch: launch
            )
            guard TmuxProbe.parseNewWindow(
                try await deadlined { try await connection.exec(command) }
            ) != nil else { return nil }
            refresh()
            return .attach(sessionName: sessionName)
        } catch {
            markFailed(error, registerConnectFailure: !reusedLink)
            return nil
        }
    }

    /// The herdr side of `launchInSession`. The spawn is the liveness step,
    /// not a mint: `session attach` no-ops on a running server and revives
    /// a stopped one, and the create verbs need the socket answering. The
    /// typed lines aim at the pane id the CREATE itself returned, so —
    /// unlike the mint, whose attach auto-creates — there is no stale-name
    /// window where typing could land in somebody else's shell.
    private func launchInHerdrSession(
        named sessionName: String, placement: ExternalSessionPlacement,
        directory: String?, label: String?,
        running script: String?, typing launch: String?,
        over connection: SSHConnection
    ) async -> TerminalRoute.Mode? {
        // The name arrived from a URL/Shortcut value. Callers match it
        // against the probe list first, but only a name herdr itself could
        // list may ever be spliced into a shell line.
        guard HerdrProbe.bakeableSessionName(sessionName) else { return nil }
        _ = try? await deadlined {
            try await connection.exec(
                HerdrProbe.spawnSessionCommand(sessionName: sessionName))
        }
        let create = placement == .workspace
            ? HerdrProbe.createWorkspaceCommand(
                sessionName: sessionName, label: label ?? "", directory: directory)
            : HerdrProbe.createTabCommand(
                sessionName: sessionName, label: label, directory: directory)
        guard let output = try? await deadlined({
            try await connection.exec(create)
        }), let pane = HerdrProbe.parseCreatedPane(output)
        else { return nil }
        let lines = [script, launch].compactMap { $0 }
        if let typing = HerdrProbe.typeCommand(
            sessionName: sessionName, paneID: pane, lines: lines) {
            _ = try? await deadlined { try await connection.exec(typing) }
        }
        refresh()
        return .herdrAttach(sessionName: sessionName)
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
            // The stand-in must carry the CALLER's backend: `session.id` is
            // what the optimistic tile removal below filters by, so a
            // tmux-stamped default would fail to drop a herdr tile.
            var session = TmuxSession(
                name: name, windows: [], created: .distantPast, backend: backend)
            // Match on the full identity, never the name alone: an older
            // open tab may intentionally belong to a backend this host no
            // longer monitors, and a mixed host can hold the same name
            // twice. `allSessions` records carry their own backend, so the
            // lookup cannot cross that boundary.
            if let match = allSessions.first(where: { $0.id == session.id }) {
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
        // Drop the tile optimistically from whichever backend's state holds
        // it; the follow-up probe is the truth and resurrects it if the
        // close failed.
        if backend == host.sessionBackend, case .sessions(let list) = tmux {
            tmux = .sessions(list.filter { $0.id != session.id })
        } else if case .sessions(let list) = secondaryStates[backend] {
            secondaryStates[backend] = .sessions(
                list.filter { $0.id != session.id })
        }
        sessionCount = allSessions.count
        miniatures[session.id] = nil
        attentionTails[session.id] = nil
        attention[session.id] = nil
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
        secondaryStates = [:]
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
        discovery = [:]
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
