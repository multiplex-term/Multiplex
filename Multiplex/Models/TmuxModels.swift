import Foundation

/// One pane inside a tmux window. The probe retains every pane so the wall
/// can report agents in background splits; `isActive` still identifies the
/// only pane that receives helper-chip keystrokes.
struct TmuxPane: Identifiable, Hashable, Codable {
    var index: Int
    var isActive: Bool
    /// tmux's server-wide pane id (`%7`). Unlike an index, this survives
    /// pane reordering and is shared by linked windows.
    var tmuxID: String
    /// Root process tmux started for this pane. Used only to scope the
    /// fail-soft process-tree fallback.
    var pid: Int
    var tty: String
    var command: String
    var title: String
    var agent: AgentKind?

    var id: String { tmuxID.isEmpty ? String(index) : tmuxID }

    /// Stable while the same foreground program owns the pane. OSC titles
    /// deliberately stay out: agent spinners rewrite them continuously and
    /// must not invalidate the process fallback cache every frame.
    var processFingerprint: TmuxPaneFingerprint {
        TmuxPaneFingerprint(
            tmuxID: tmuxID,
            pid: pid,
            tty: tty,
            command: command
        )
    }
}

struct TmuxPaneFingerprint: Hashable {
    var tmuxID: String
    var pid: Int
    var tty: String
    var command: String
}

/// Result of the terminal window's lightweight focused-pane check. Tmux may
/// return `isDefinitive == false` when direct signals were inconclusive and
/// the scoped process query failed; herdr's canonical agent field is always
/// definitive. Callers retain an inconclusive result only while the pane
/// fingerprint itself remains unchanged.
struct ActivePaneAgentDetection: Equatable {
    var fingerprint: TmuxPaneFingerprint
    var agent: AgentKind?
    var isDefinitive: Bool
}

/// One window inside a tmux session — a cell in the window spine.
struct TmuxWindow: Identifiable, Hashable, Codable {
    var index: Int
    var name: String
    var isActive: Bool
    var hasBell: Bool
    var hasActivity: Bool
    /// CLI agent detected in this window's *active* pane — the pane that
    /// receives keystrokes when the session is attached.
    var agent: AgentKind?
    /// The active pane's OSC title — Claude Code and Codex encode busy/idle
    /// (and Codex its approval wait) here; `AgentAttention` classifies it.
    var paneTitle: String = ""
    /// All panes from a live probe. Optional only so device-local snapshots
    /// written before multi-pane detection continue to decode; new probes
    /// always populate it.
    var panes: [TmuxPane]?

    var id: Int { index }

    var activePane: TmuxPane? {
        panes?.first(where: \.isActive)
    }

    var activeAgent: AgentKind? {
        activePane?.agent ?? agent
    }

    var detectedAgents: [AgentKind] {
        if let panes { return panes.compactMap(\.agent) }
        return agent.map { [$0] } ?? []
    }

    var paneCount: Int {
        panes?.count ?? 1
    }

    /// The active pane's title, or nil when it says nothing worth showing.
    ///
    /// A split window never offers one: the title belongs to the *active*
    /// pane, so presenting it beside the window name would advertise one
    /// pane's business as the whole window's. Those windows report their pane
    /// count instead. Snapshots written before pane inventory existed report
    /// `paneCount == 1`, which fails open — the honest reading of a window we
    /// only ever saw one pane of.
    func displayPaneTitle(serverHost: String) -> String? {
        guard paneCount == 1 else { return nil }
        return PaneTitleDisplay.title(
            paneTitle: paneTitle,
            windowName: name,
            serverHost: serverHost
        )
    }
}

/// Decides whether a pane title is worth showing next to its window name.
/// Pure — the deck spine and the widget projection share it, so the two
/// surfaces can never disagree about what counts as a real title.
enum PaneTitleDisplay {
    /// tmux seeds every new pane's title with the server's own hostname and
    /// replaces it only when the program emits an OSC 0/2 title. An untouched
    /// pane therefore reports the same noise on every window (six of the dev
    /// harness's thirteen panes read `Demo-MBPr14.local`), which is worth
    /// suppressing — but only against the exact string tmux seeded it with.
    /// That string is asked of tmux directly (`#{host}`, carried on the probe's
    /// `H` record) rather than inferred from the Host record: `Host.hostname`
    /// is routinely an IP or a tunnel alias that the remote's `gethostname()`
    /// knows nothing about.
    ///
    /// Short and FQDN forms count as the same host: `gethostname()` reports
    /// either depending on network state, so a pane seeded while the machine
    /// still had its `.local` suffix must not outlive the suppression.
    ///
    /// A title that only repeats the window name is dropped as redundant — on
    /// the tile it would sit directly beneath the name it duplicates.
    static func title(
        paneTitle: String, windowName: String, serverHost: String
    ) -> String? {
        let title = paneTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !isSameHost(title, serverHost) else { return nil }
        let name = windowName.trimmingCharacters(in: .whitespaces)
        guard title.caseInsensitiveCompare(name) != .orderedSame else { return nil }
        return title
    }

    private static func isSameHost(_ candidate: String, _ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if candidate.caseInsensitiveCompare(host) == .orderedSame { return true }
        // Compare first DNS labels, never a substring: `Demo-MBPr14: ~/work`
        // carries no dot and so stays a real title.
        let candidateLabel = String(candidate.prefix { $0 != "." })
        let hostLabel = String(host.prefix { $0 != "." })
        guard !candidateLabel.isEmpty, !hostLabel.isEmpty else { return false }
        return candidateLabel.caseInsensitiveCompare(hostLabel) == .orderedSame
    }
}

/// A tmux session as reported by `tmux list-sessions` / `list-windows`.
struct TmuxSession: Identifiable, Hashable, Codable {
    var name: String
    var windows: [TmuxWindow]
    /// Attached client count (`session_attached` is a count, not a flag).
    var clientCount: Int = 0
    var created: Date
    /// tmux's own id ("$3") — the only unambiguous capture-pane target;
    /// names can prefix-collide.
    var tmuxID: String = ""
    /// Hostname of the tmux server these sessions live on (`#{host}`), as the
    /// probe read it. Carried per session — not per host record — because it
    /// is what tmux seeded every untouched pane title with, and because riding
    /// the session keeps it in device-local snapshots so a cold launch can
    /// still tell a real pane title from that seed. Empty on legacy snapshots
    /// and on hosts whose tmux declined to answer; `PaneTitleDisplay` then
    /// simply suppresses nothing.
    var serverHost: String = ""
    /// Which multiplexer this record came from. Stamped by the parser that
    /// built it (`HerdrProbe.parseProbe` sets `.herdr`; the tmux parser
    /// leaves the default), never read off the host record — a host can
    /// monitor both, and after Host Settings switches its primary an
    /// already-open tab's session still belongs to the backend it was
    /// minted on.
    var backend: Host.SessionBackend = .tmux

    /// The identity every per-session map keys by. A bare name collides
    /// across backends on a mixed host — see `SessionKey`.
    var id: SessionKey { SessionKey(backend: backend, name: name) }
    var isAttached: Bool { clientCount > 0 }
    var windowCount: Int { windows.count }
    /// The window an attached client is looking at.
    var activeWindow: TmuxWindow? {
        windows.first(where: \.isActive)
    }
    /// Agent in the pane an attached client is typing into — the active
    /// window's active pane. Drives the helper strip; FleetWall separately
    /// aggregates every detected pane.
    var activeAgent: AgentKind? {
        activeWindow?.activeAgent
    }
    /// Every detected agent pane, including background splits and inactive
    /// windows. FleetWall uses this broader view; helper chips intentionally
    /// continue to use `activeAgent`.
    var detectedAgents: [AgentKind] {
        windows.flatMap(\.detectedAgents)
    }
    var agentPanes: [TmuxPane] {
        windows.flatMap { $0.panes ?? [] }.filter { $0.agent != nil }
    }
    var paneCount: Int {
        windows.reduce(0) { $0 + $1.paneCount }
    }
}

extension TmuxSession {
    /// Hand-rolled because a property default does NOT make a non-optional key
    /// optional to Swift's synthesized decoder: adding `serverHost` to the
    /// struct alone would have thrown on every `deck-snapshots.json` written by
    /// an older build, costing the whole fleet its instant cold-launch paint
    /// (caught by `DeckSnapshotTests`). Only the three fields with no sensible
    /// default stay required. Encoding stays synthesized, and living in an
    /// extension keeps the memberwise initializer.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            windows: try container.decode([TmuxWindow].self, forKey: .windows),
            clientCount: try container.decodeIfPresent(Int.self, forKey: .clientCount) ?? 0,
            created: try container.decode(Date.self, forKey: .created),
            tmuxID: try container.decodeIfPresent(String.self, forKey: .tmuxID) ?? "",
            serverHost: try container.decodeIfPresent(String.self, forKey: .serverHost) ?? "",
            // Decode via the raw string so a record written by a schema
            // with a third backend degrades to tmux instead of throwing the
            // whole snapshot away — `Host.sessionBackend`'s rule. Absent
            // means tmux, which is what every pre-herdr snapshot holds.
            backend: (try container.decodeIfPresent(String.self, forKey: .backend))
                .flatMap(Host.SessionBackend.init(rawValue:)) ?? .tmux
        )
    }
}

/// Pure ordering rules for the deck's per-host session tiles. The backends
/// own the sessions themselves; Multiplex stores only their identities as a
/// device-local presentation preference. New sessions stay at the front in
/// the probe's newest-first order, while stale saved entries simply
/// disappear.
///
/// Saved order is carried as `SessionKey.storageKey` strings, so a list
/// written before mixed hosts existed reads back as tmux keys — exactly
/// what it was — and a user's manual order can interleave both backends.
enum SessionOrdering {
    static func ordered(_ sessions: [TmuxSession], saved: [String]?) -> [TmuxSession] {
        let newestFirst = Array(sessions.reversed())
        guard let saved else { return newestFirst }

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter
        // TRAPS on a duplicate key, and a tmux `main` beside a herdr `main`
        // used to produce exactly that — a fatal error on the deck's render
        // path (the reason `SessionKey` exists). Keys are unique again now,
        // but the render path must not be one line away from a crash if a
        // probe ever repeats an identity.
        let byKey = Dictionary(
            sessions.map { ($0.id.storageKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Normalize each saved entry: a list written before mixed hosts
        // holds bare names, which round-trip through `SessionKey` into tmux
        // keys — what they always meant. Idempotent, so an already-keyed
        // list is untouched, and the next move rewrites the file normalized.
        let normalized = saved.map { SessionKey(storageKey: $0).storageKey }
        let savedKeys = Set(normalized)
        let newSessions = newestFirst.filter { !savedKeys.contains($0.id.storageKey) }
        return newSessions + normalized.compactMap { byKey[$0] }
    }

    /// Applies the destination emitted by SwiftUI's reorder container.
    /// Multiple sources preserve their current visual order.
    static func moving(
        _ sources: [String], before destination: String?, in order: [String]
    ) -> [String] {
        let sourceSet = Set(sources)
        let moving = order.filter(sourceSet.contains)
        guard !moving.isEmpty else { return order }

        var remaining = order.filter { !sourceSet.contains($0) }
        let insertion = destination.flatMap { remaining.firstIndex(of: $0) } ?? remaining.endIndex
        remaining.insert(contentsOf: moving, at: insertion)
        return remaining
    }

    /// Older OS fallback: dropping onto a tile moves the source into that
    /// tile's current slot, regardless of drag direction.
    static func moving(_ source: String, to target: String, in order: [String]) -> [String] {
        guard let sourceIndex = order.firstIndex(of: source),
              let targetIndex = order.firstIndex(of: target),
              sourceIndex != targetIndex
        else { return order }

        var result = order
        let moved = result.remove(at: sourceIndex)
        result.insert(moved, at: targetIndex)
        return result
    }
}

/// Last-known wall state for one host — what a cold launch paints while the
/// probe reconnects (the same staleness the wall already shows between
/// ticks). Attention state is deliberately absent: NEEDS YOU and agent
/// alerts must be re-earned by a live probe, never restored from disk.
struct DeckSnapshot: Codable, Equatable {
    var sessions: [TmuxSession]
    /// Keyed by `SessionKey.storageKey` — a host can now cache tiles from
    /// more than one backend, and a bare name collides across them.
    var miniatures: [String: [String]]
    /// The PRIMARY backend these session records were cached for. Still
    /// whole-file because it answers `restore(from:)`'s question: a host can
    /// switch its primary while this device is offline, and painting the old
    /// backend's same-named sessions under the new one is what this guards.
    /// Which backend an individual session belongs to is `TmuxSession
    /// .backend`, not this.
    var sessionBackend: Host.SessionBackend = .tmux
}

extension DeckSnapshot {
    /// Written `true` by every build that stamps `TmuxSession.backend` and
    /// keys `miniatures` by `SessionKey.storageKey`. Absent means a file
    /// from before mixed hosts, whose whole content belongs to
    /// `sessionBackend` and whose miniature keys are bare names — the
    /// decoder migrates it forward rather than reading a herdr cache as
    /// tmux. Not a version number: it names the one property that changed.
    ///
    /// Deliberately NOT a stored property: it is only ever true of a value
    /// this build can hold, so storing it would put an always-true field in
    /// `Equatable`, in every construction site, and — the reason it matters
    /// — let a caller write `false` and make the next decode re-migrate
    /// miniatures that are already keyed.
    private enum CodingKeys: String, CodingKey {
        case sessions, miniatures, sessionBackend, keysCarryBackend
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every snapshot written before herdr support is a tmux snapshot.
        let backend = try container.decodeIfPresent(
            Host.SessionBackend.self, forKey: .sessionBackend) ?? .tmux
        let sessions = try container.decode([TmuxSession].self, forKey: .sessions)
        let miniatures = try container.decode(
            [String: [String]].self, forKey: .miniatures)
        guard try !(container.decodeIfPresent(
            Bool.self, forKey: .keysCarryBackend) ?? false)
        else {
            self.init(
                sessions: sessions,
                miniatures: miniatures,
                sessionBackend: backend
            )
            return
        }
        // Migrate a single-backend file forward: its session records decoded
        // to the `.tmux` default and its miniature keys are bare names, so
        // on a herdr host both would be wrong until the first live probe —
        // blank miniatures under a TMUX-labelled tile.
        self.init(
            sessions: sessions.map {
                var session = $0
                session.backend = backend
                return session
            },
            miniatures: miniatures.keyed(backend: backend).storageKeyed,
            sessionBackend: backend
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(miniatures, forKey: .miniatures)
        try container.encode(sessionBackend, forKey: .sessionBackend)
        try container.encode(true, forKey: .keysCarryBackend)
    }
}

/// What a host's tmux server currently looks like.
enum TmuxState: Equatable {
    case unknown
    case probing
    case sessions([TmuxSession])
    case noServer          // tmux installed, no server running
    case tmuxMissing       // tmux not on PATH
    case failed(String)

    var sessions: [TmuxSession] {
        if case .sessions(let list) = self { return list }
        return []
    }
}
