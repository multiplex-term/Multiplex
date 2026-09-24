import Foundation

/// Builds and parses the `herdr` CLI commands used to discover remote
/// sessions — the herdr-mode sibling of `TmuxProbe`. Pure functions,
/// exercised directly by unit tests against captured 0.7.5 output.
///
/// herdr (herdr.dev) is a Rust terminal/agent multiplexer whose CLI verbs
/// wrap a newline-JSON Unix-socket API. Wire facts, verified against
/// herdr 0.7.5 / protocol 17 on 2026-08-02 (fixtures under
/// MultiplexTests/Fixtures):
/// - A herdr *session* is a whole server: its own socket, workspaces,
///   and ONE global focus every attached client mirrors. `herdr session
///   list --json` is a client verb (answers serverless, plain JSON, no
///   envelope); every socket verb scopes with the global `--session
///   <name>` flag, `default` included.
/// - Socket-wrapper verbs print single-line JSON envelopes
///   (`{"id":"cli:…","result":{…}}`) by default — there is no `--json`
///   flag on them (passing one is a usage error). The client-side
///   `herdr status --json` answers even with no server running.
/// - `herdr --session <s> api snapshot` is the per-session probe: version
///   + protocol + workspaces + tabs + panes + per-tab layouts (focused
///   pane) + the session's focused workspace/pane, in one round trip.
///   Between full probes, `pane current` returns only that globally focused
///   pane — including its canonical agent id — for the helper strip.
/// - `herdr pane read <id> --source visible` prints RAW text, not an
///   envelope — the capture-pane analog feeding the wall miniatures.
/// - API failures print an error envelope or a Rust error line and exit
///   NONZERO — and Citadel throws on a nonzero exit — so every stage is
///   `2>/dev/null`-silenced and `|| true`-guarded, the tmux probe's own
///   discipline.
/// - `herdr session attach <name>` auto-creates a missing session and
///   restarts a stopped one; the server outlives the client (it
///   daemonizes), and without a TTY the client dies *after* the server
///   is up — which is what makes a headless mint possible at all.
/// - `session delete` requires `session stop` first, and herdr itself
///   refuses to delete the default session — the app never needs to know
///   which one that is.
/// - No API surface reports attached clients (re-verified 2026-08-02
///   across `session list --json`, `api snapshot`, `status --json`, and
///   the bundled `api schema`: only the socket-only `client.window_title`
///   reply leaks a `no_foreground_client` reason, and no CLI verb reaches
///   it), so `clientCount` stays 0 here and the tile's telemetry says
///   nothing about clients. The LIVE lamp instead answers for the one
///   client the app can verify — its own open terminal tab — through
///   `Host.SessionBackend.isSessionLive`.
///
/// The parser maps herdr's model onto the existing tmux records —
/// **session → `TmuxSession`, workspace → `TmuxWindow`** (represented by
/// its active tab's panes), pane → `TmuxPane` — so everything downstream
/// (FleetWall, DeckSnapshotStore, the widget projection) keeps working
/// untouched. One tile per session is load-bearing: workspaces share
/// their session's single focus, so two workspace tiles could never be
/// two independent windows — sessions can, which is herdr's own
/// multi-window story. herdr's agent layer replaces the ps-table walk:
/// `pane.agent` is authoritative, so the probe carries no process table.
enum HerdrProbe {
    /// Non-interactive SSH exec often has a minimal PATH. herdr shares
    /// tmux's install homes plus `~/.cargo/bin` (cargo installs a Rust
    /// binary where tmux would never live) — composed from the one shared
    /// list so a directory added for every other remote command reaches
    /// herdr commands too.
    static let pathPrefix = RemoteCommandEnvironment.herdrPathPrefix

    /// The socket protocol this parser was written against. Pre-1.0 herdr
    /// churns; anything older renders an honest UPDATE-NEEDED tile instead
    /// of garbage, while newer protocols pass — decoding ignores unknown
    /// fields, herdr's own forward-compat advice.
    private static let minimumProtocol = 17

    /// herdr's primary session — the blind-attach fallback and the one
    /// snapshot a cold first tick takes before any list has been baked.
    /// Nothing else may branch on a session being "the default": the
    /// server owns that rule (it alone refuses deleting it).
    static let primarySessionName = HerdrSessionLaunch.primarySessionName

    // MARK: - Probe command

    private static let noHerdrMarker = "MULTIPLEX_NO_HERDR"
    private static let statusMarker = "MULTIPLEX_HERDR_STATUS"
    private static let sessionsMarker = "MULTIPLEX_HERDR_SESSIONS"
    private static let snapshotMarker = "MULTIPLEX_HERDR_SNAP"
    private static let tailsMarker = "MULTIPLEX_TAILS"
    private static let tailFrameMarker = "MPXS"
    private static let tailEndMarker = "MPXE"

    /// One miniature read the next probe should run: a session and the
    /// pane it fronts. Pane ids (`w1:p1`) are per-session namespaces and
    /// COLLIDE across sessions, so a pane is never named without its
    /// session.
    struct TailTarget: Equatable {
        var sessionName: String
        var paneID: String
    }

    /// One exec round trip: status (version gate), the session list (the
    /// tile set), a snapshot per session, then sentinel-framed
    /// visible-screen reads for the wall miniatures.
    ///
    /// A shell can't join JSON, so both dynamic sets are baked from the
    /// PREVIOUS tick's parse: `sessionNames` names the snapshots to take,
    /// `tailTargets` names the pane reads. Snapshots of new sessions and
    /// miniatures therefore lag topology changes by one tick — the wall
    /// already tolerates 5 s of staleness by design, and a baked target
    /// that vanished mid-tick just yields an empty frame the parser drops.
    /// This is also the ONE place the bake guards apply: what the parser
    /// reports is truth, what gets spliced into a shell line is vetted.
    /// `discovering` carries the mixed-host discovery riders
    /// (`BackendDiscovery`): a PRIMARY herdr probe asks `[.tmux]`, while a
    /// secondary full probe passes `[]` — it must not rediscover the
    /// primary that scheduled it. The riders lead, before this probe's own
    /// presence guard, because that guard `exit`s and a host with no herdr
    /// but live tmux sessions is exactly a case worth discovering.
    static func probeCommand(
        sessionNames: [String]?, tailTargets: [TailTarget],
        discovering: Set<Host.SessionBackend> = [.tmux]
    ) -> String {
        var command = BackendDiscovery.riderPrefix(
            discovering: discovering, excluding: .herdr)
        command += pathPrefix
            + "command -v herdr >/dev/null 2>&1 || { echo \(noHerdrMarker); exit 0; }; "
            + "echo \(statusMarker); herdr status --json 2>/dev/null || true; "
            + "echo \(sessionsMarker); herdr session list --json 2>/dev/null || true; "
        // nil means the model has never parsed a list. Snapshot the primary
        // session on that cold tick so it can paint immediately. An empty
        // nonnil list means the previous tick proved that no session is
        // running; probing default there would pay for a known failure every
        // five seconds forever.
        let candidates = sessionNames ?? [primarySessionName]
        var seen = Set<String>()
        let snapshotSet = candidates.filter {
            bakeableSessionName($0) && seen.insert($0).inserted
        }
        for name in snapshotSet {
            command += "printf '%s\\n' \("\(snapshotMarker) \(name)".shellQuoted); "
                + "herdr --session \(name.shellQuoted) api snapshot 2>/dev/null || true; "
        }
        command += "echo \(tailsMarker); "
        for target in tailTargets
        where bakeableSessionName(target.sessionName) && bakeablePaneID(target.paneID) {
            command += "printf '%s\\n' \("\(tailFrameMarker) \(target.sessionName) \(target.paneID)".shellQuoted); "
                + "herdr --session \(target.sessionName.shellQuoted)"
                + " pane read \(target.paneID.shellQuoted) --source visible"
                + " 2>/dev/null || true; "
        }
        command += "echo \(tailEndMarker)"
        return command
    }

    /// A session name the probe may splice into a command and sentinel.
    /// herdr 0.7.5 enforces this exact ASCII grammar and a 64-byte ceiling;
    /// validating the wire fact here keeps framing inert even if a future or
    /// corrupted session-list response tries to hand us shell prose. Leading
    /// dots/dashes are legal for host-created sessions (the app's own namer
    /// avoids them as a UX choice), and herdr accepts them as option values.
    static func bakeableSessionName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..",
              name.utf8.count <= 64
        else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    /// Pane ids are server-minted (`w1:p1`). They are not session names, so
    /// validate only the framing invariants: nonempty, no controls or
    /// whitespace, and no unbounded response-derived argument.
    static func bakeablePaneID(_ paneID: String) -> Bool {
        guard !paneID.isEmpty, paneID.utf8.count <= 128 else { return false }
        return paneID.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    // MARK: - Parsed result

    /// What a herdr host currently looks like — the herdr-mode analog of
    /// `TmuxState`, kept separate so the pure layer states herdr truth and
    /// the wall chooses its vocabulary.
    enum State: Equatable {
        case herdrMissing
        /// herdr is installed but lists no sessions at all — the deck's
        /// + NEW SESSION mints the first one.
        case noServer
        /// Installed herdr speaks an older protocol than this parser.
        case updateNeeded(installedVersion: String)
        case sessions([TmuxSession])
        case failed(String)
    }

    /// herdr's agent lifecycle states. Integrations report only idle/
    /// working/blocked/unknown; the server may retain a settled off-focus
    /// pane as `done` (a focused pane settles as `idle`). Unrecognized future
    /// states decode as `.unknown`
    /// rather than failing the pane.
    enum AgentStatus: String, Equatable {
        case idle, working, blocked, done, unknown
    }

    /// Everything derived from one probe response, `TmuxProbe.ParsedProbe`
    /// shaped so the connection model can consume either. The extras are
    /// herdr's semantic layer (per-pane agent statuses — the attention
    /// authority, never persisted) and the two sets the NEXT probe bakes
    /// into its command.
    struct ParsedProbe {
        var state: State
        var tails: [String: [String]]
        var miniatures: [String: [String]]
        /// Session name → pane id → lifecycle status, for EVERY pane the
        /// snapshot carries — background tabs included, so a blocked agent
        /// the session isn't fronting still turns its tile amber.
        var paneStatuses: [String: [String: AgentStatus]]
        var tailTargets: [TailTarget]
        /// Running sessions to snapshot next tick.
        var sessionNames: [String]
        /// What the discovery riders found, keyed by the backend asked.
        /// Empty when the response carried no rider.
        var discovery: [Host.SessionBackend: BackendDiscovery.Result] = [:]
    }

    static func parseProbe(_ output: String) -> ParsedProbe {
        var result = ParsedProbe(
            state: .failed(String(localized: "unreadable herdr probe response")),
            tails: [:], miniatures: [:], paneStatuses: [:],
            tailTargets: [], sessionNames: []
        )
        // One pass reads the riders' answers and removes their regions: a
        // tmux session list is `D `-tagged lines, and this parser's own
        // session region hunts for the first decodable JSON line. Removing
        // the regions is what guarantees the two can never meet.
        let reading = BackendDiscovery.read(output)
        result.discovery = reading.results
        let output = reading.remainder
        // Slice at the tails marker first: everything structural lives in
        // the head, and the tail region — one visible screen per session,
        // the bulk of every response — is walked exactly once, by
        // `parseTails`.
        let tailsRange = output.range(of: "\n" + tailsMarker + "\n")
        let head = output[..<(tailsRange?.lowerBound ?? output.endIndex)]
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.contains(where: { $0 == noHerdrMarker }) {
            result.state = .herdrMissing
            return result
        }

        let status = section(in: head, from: statusMarker, to: sessionsMarker)
            .flatMap { firstDecodedLine(in: $0, decodeStatus) }

        // Version-gate on the client protocol: one binary serves every
        // session, so an old client is an old host — and pre-17 has no
        // `session list --json` to parse anyway.
        if let clientProtocol = status?.client.protocolVersion,
           clientProtocol < minimumProtocol {
            result.state = .updateNeeded(
                installedVersion: status?.client.version ?? String(localized: "unknown"))
            return result
        }

        let region = sessionsRegion(lines)
        guard let list = region.list else {
            if status != nil {
                result.state = .failed(
                    String(localized: "herdr answered status but not the session list")
                )
            }
            return result
        }

        var snapshots: [String: Snapshot] = [:]
        for (name, candidates) in region.snapshotLines {
            for candidate in candidates {
                if let snapshot = decodeSnapshot(candidate) {
                    snapshots[name] = snapshot
                    break
                }
            }
        }
        if let stale = snapshots.values.first(where: { $0.protocolVersion < minimumProtocol }) {
            result.state = .updateNeeded(installedVersion: stale.version)
            return result
        }

        guard !list.sessions.isEmpty else {
            result.state = .noServer
            return result
        }

        result.state = .sessions(list.sessions.enumerated().map { index, entry in
            session(entry: entry, index: index, snapshot: snapshots[entry.name])
        })
        for entry in list.sessions where entry.running {
            guard let snapshot = snapshots[entry.name] else { continue }
            result.paneStatuses[entry.name] = Dictionary(
                snapshot.panes.map { ($0.paneID, AgentStatus(tolerant: $0.agentStatus)) },
                uniquingKeysWith: { first, _ in first }
            )
            if let pane = frontPaneID(of: snapshot) {
                result.tailTargets.append(
                    TailTarget(sessionName: entry.name, paneID: pane))
            }
        }
        result.sessionNames = list.sessions.filter(\.running).map(\.name)
        if let tailsRange {
            result.tails = parseTails(
                output[tailsRange.upperBound...],
                paneStatuses: result.paneStatuses
            )
            result.miniatures = result.tails.mapValues(TmuxProbe.miniatureTail)
        }
        return result
    }

    // MARK: - Wire types (decoded tolerantly — unknown fields ignored)

    private struct Envelope<Payload: Decodable>: Decodable {
        var result: Payload
    }

    private struct SnapshotResult: Decodable {
        var snapshot: Snapshot
    }

    /// `herdr session list --json` — a client verb, so plain JSON with no
    /// envelope. `running` is the classifier (a stopped session is still
    /// a tile; `herdr status`'s server state deliberately is NOT — it
    /// speaks only for the default session's server). Which session is
    /// the default is deliberately not decoded: nothing app-side may
    /// branch on it.
    private struct SessionList: Decodable {
        var sessions: [SessionEntry]
    }

    private struct SessionEntry: Decodable {
        var name: String
        var running: Bool
    }

    private struct Snapshot: Decodable {
        var version: String
        var protocolVersion: Int
        var workspaces: [Workspace]
        var panes: [Pane]
        var layouts: [Layout]
        /// The session's ONE focus — what every attached client shows.
        var focusedWorkspaceID: String?
        var focusedTabID: String?
        var focusedPaneID: String?

        enum CodingKeys: String, CodingKey {
            case version
            case protocolVersion = "protocol"
            case workspaces, panes, layouts
            case focusedWorkspaceID = "focused_workspace_id"
            case focusedTabID = "focused_tab_id"
            case focusedPaneID = "focused_pane_id"
        }
    }

    private struct Workspace: Decodable {
        var workspaceID: String
        var number: Int
        var label: String
        var activeTabID: String
        /// Present in `workspace list` entries (and snapshots); the snapshot
        /// path keeps deciding focus by `focusedWorkspaceID`.
        var focused: Bool?

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case number, label
            case activeTabID = "active_tab_id"
            case focused
        }
    }

    private struct Pane: Decodable {
        var paneID: String
        var tabID: String
        var agent: String?
        var agentStatus: String
        /// The raw OSC title, spinner/status glyphs intact — what the
        /// history jump's idle classifier reads (the stripped variant
        /// removes exactly the glyphs it needs).
        var terminalTitle: String?
        var terminalTitleStripped: String?
        /// The pane's shell cwd and the foreground process's cwd (0.7.5
        /// reports both) — `foreground_cwd` is `pane_current_path`'s
        /// analog: while an agent runs there, the agent's own directory.
        var cwd: String?
        var foregroundCwd: String?
        /// 0.7.5 reports per-pane scroll state; `viewport_rows` is the
        /// content height inside the pane rect — the border-inset oracle
        /// for the select-text clamp.
        var scroll: PaneScroll?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case tabID = "tab_id"
            case agent
            case agentStatus = "agent_status"
            case terminalTitle = "terminal_title"
            case terminalTitleStripped = "terminal_title_stripped"
            case cwd
            case foregroundCwd = "foreground_cwd"
            case scroll
        }
    }

    private struct PaneScroll: Decodable {
        var viewportRows: Int?

        enum CodingKeys: String, CodingKey {
            case viewportRows = "viewport_rows"
        }
    }

    private struct Layout: Decodable {
        var tabID: String
        var focusedPaneID: String?
        /// Screen-cell rects per pane (0.7.5) — already in the attached
        /// client's coordinate space, sidebar and tab bar accounted for.
        var panes: [LayoutPane]?

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case focusedPaneID = "focused_pane_id"
            case panes
        }
    }

    private struct LayoutPane: Decodable {
        var paneID: String
        var focused: Bool?
        var rect: LayoutRect?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case focused, rect
        }
    }

    private struct LayoutRect: Decodable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    private struct CurrentPaneResult: Decodable {
        var pane: Pane
    }

    private struct Status: Decodable {
        var client: StatusClient
    }

    private struct StatusClient: Decodable {
        var version: String?
        var protocolVersion: Int?

        enum CodingKeys: String, CodingKey {
            case version
            case protocolVersion = "protocol"
        }
    }

    private static func decodeSnapshot(_ text: String) -> Snapshot? {
        (try? JSONDecoder().decode(
            Envelope<SnapshotResult>.self, from: Data(text.utf8)))?.result.snapshot
    }

    private static func decodeSessionList(_ text: String) -> SessionList? {
        try? JSONDecoder().decode(SessionList.self, from: Data(text.utf8))
    }

    private static func decodeCurrentPane(_ text: String) -> Pane? {
        (try? JSONDecoder().decode(
            Envelope<CurrentPaneResult>.self, from: Data(text.utf8)))?.result.pane
    }

    private static func decodeStatus(_ text: String) -> Status? {
        try? JSONDecoder().decode(Status.self, from: Data(text.utf8))
    }

    /// The text between two sentinel lines, nil when the opening sentinel
    /// never printed. The closing sentinel is always emitted by the probe
    /// script itself, but a truncated response still parses as "everything
    /// after the opener".
    private static func section(
        in output: Substring, from opener: String, to closer: String
    ) -> String? {
        guard let start = output.range(of: opener + "\n") else { return nil }
        let rest = output[start.upperBound...]
        let end = rest.range(of: "\n" + closer)?.lowerBound ?? rest.endIndex
        let text = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The list-and-snapshots region: the first decodable line after the
    /// sessions marker is the list; `MULTIPLEX_HERDR_SNAP <name>` lines
    /// (the whole remainder is retained defensively, though 0.7.5 names are
    /// whitespace-free ASCII tokens)
    /// open per-session candidate lines, decoded first-that-parses the way
    /// login-shell noise has always been skipped. The head slice already
    /// ends at the tails marker, so raw pane text can never forge a
    /// snapshot.
    private static func sessionsRegion(
        _ lines: [Substring]
    ) -> (list: SessionList?, snapshotLines: [String: [String]]) {
        var list: SessionList?
        var snapshotLines: [String: [String]] = [:]
        var currentName: String?
        var inRegion = false
        for line in lines {
            if line == sessionsMarker { inRegion = true; continue }
            guard inRegion, !line.isEmpty else { continue }
            if line.hasPrefix(snapshotMarker + " ") {
                currentName = String(line.dropFirst(snapshotMarker.count + 1))
                continue
            }
            if let name = currentName {
                snapshotLines[name, default: []].append(String(line))
            } else if list == nil {
                list = decodeSessionList(String(line))
            }
        }
        return (list, snapshotLines)
    }

    // MARK: - Mapping (session → TmuxSession, workspace → window)

    private static func session(
        entry: SessionEntry, index: Int, snapshot: Snapshot?
    ) -> TmuxSession {
        TmuxSession(
            name: entry.name,
            // A stopped session — or a running one the previous tick
            // hadn't listed yet — has no snapshot and renders as a
            // spine-less tile. Attach restarts/creates it, so the tile
            // stays pressable.
            windows: snapshot.map(windows(from:)) ?? [],
            clientCount: 0,
            // Synthesized from the list position: `isSyntheticCreated`
            // is how a tile knows not to render this as an age, while
            // external actions and the widget still sort "most recent"
            // by it — herdr's own list order is the only order it states.
            created: Date(timeIntervalSince1970: TimeInterval(index)),
            tmuxID: entry.name,
            serverHost: "",
            // The one place a herdr record learns it is one. Everything
            // downstream keys off `TmuxSession.id`, which reads it — never
            // off `Host.sessionBackend`, which a mixed host answers for its
            // primary alone.
            backend: .herdr
        )
    }

    /// True for the near-epoch stand-ins `session(entry:index:snapshot:)`
    /// mints — herdr states no creation time, so a tile must render these
    /// as no age at all. The one decoder of that encoding; keep them in
    /// step.
    static func isSyntheticCreated(_ date: Date) -> Bool {
        date.timeIntervalSince1970 <= 86_400
    }

    private static func windows(from snapshot: Snapshot) -> [TmuxWindow] {
        let layoutFocus = Dictionary(
            snapshot.layouts.compactMap { layout in
                layout.focusedPaneID.map { (layout.tabID, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        var panesByTab: [String: [Pane]] = [:]
        for pane in snapshot.panes {
            panesByTab[pane.tabID, default: []].append(pane)
        }
        let ordered = snapshot.workspaces.sorted { $0.number < $1.number }
        // Fail open to the first workspace when the server named no focus:
        // the active window carries the tile's agent/title line, and an
        // all-inactive spine would blank both.
        let focusedWorkspaceID = snapshot.focusedWorkspaceID
            ?? ordered.first?.workspaceID
        return ordered.map { workspace in
            window(
                workspace: workspace,
                // A workspace is represented by its ACTIVE tab — the panes
                // it fronts. Other tabs stay herdr's own UI granularity;
                // their agents still count through the snapshot-wide
                // status map.
                panes: panesByTab[workspace.activeTabID] ?? [],
                focusedPaneID: layoutFocus[workspace.activeTabID],
                isActive: workspace.workspaceID == focusedWorkspaceID
            )
        }
    }

    private static func window(
        workspace: Workspace, panes: [Pane], focusedPaneID: String?, isActive: Bool
    ) -> TmuxWindow {
        let mapped = panes.enumerated().map { offset, pane in
            TmuxPane(
                index: offset,
                // Per-tab front pane comes from the layout; a tab whose
                // layout went missing fails open to its first pane so the
                // window always has one keystroke target.
                isActive: focusedPaneID.map { $0 == pane.paneID } ?? (offset == 0),
                tmuxID: pane.paneID,
                // herdr's agent layer replaces the pid/tty/ps machinery
                // wholesale, so the process fields carry nothing.
                pid: 0,
                tty: "",
                command: pane.agent ?? "",
                title: pane.terminalTitleStripped ?? "",
                agent: pane.agent.flatMap(AgentKind.init(herdrAgent:))
            )
        }
        var window = TmuxWindow(
            index: workspace.number,
            name: displayLabel(workspace),
            isActive: isActive,
            hasBell: false,
            hasActivity: false,
            panes: mapped
        )
        if let active = mapped.first(where: \.isActive) {
            window.agent = active.agent
            window.paneTitle = active.title
        }
        return window
    }

    /// Workspace labels are spine lines now, and windows routinely share
    /// names in tmux-land too — duplicates are fine, only emptiness isn't.
    private static func displayLabel(_ workspace: Workspace) -> String {
        let label = workspace.label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty
            ? String(localized: "workspace \(workspace.number)")
            : label
    }

    /// The one pane a session fronts — its focused pane, falling back
    /// through the focused workspace's active-tab layout to that tab's
    /// first pane: the read the next probe bakes in for the tile's
    /// miniature.
    private static func frontPaneID(of snapshot: Snapshot) -> String? {
        if let focused = snapshot.focusedPaneID { return focused }
        let ordered = snapshot.workspaces.sorted { $0.number < $1.number }
        guard let workspace = ordered.first(where: {
            $0.workspaceID == snapshot.focusedWorkspaceID
        }) ?? ordered.first else { return nil }
        if let focus = snapshot.layouts.first(where: {
            $0.tabID == workspace.activeTabID
        })?.focusedPaneID {
            return focus
        }
        return snapshot.panes.first { $0.tabID == workspace.activeTabID }?.paneID
    }

    // MARK: - Session actions

    /// The deck tile's destructive close: stop the session's server (every
    /// process in it dies — kill-session's analog), then delete its state
    /// dir. herdr itself refuses deleting the default session, so that
    /// one stays listed as a stopped tile — the app deliberately doesn't
    /// know which session is the default.
    static func closeSessionCommand(sessionName: String) -> String {
        pathPrefix
            + "herdr session stop \(sessionName.shellQuoted) --json >/dev/null 2>&1; "
            + "herdr session delete \(sessionName.shellQuoted) --json >/dev/null 2>&1; "
            + "true"
    }

    /// Probe records carry the name in `tmuxID`, but a restored or not-yet-
    /// probed terminal route may only have `name`. Herdr's session name is
    /// its identity, so closing by name must keep working in that state.
    static func closeSessionCommand(for session: TmuxSession) -> String {
        closeSessionCommand(
            sessionName: session.tmuxID.isEmpty ? session.name : session.tmuxID)
    }

    /// The mint's live existence check — attach auto-creates, so setup
    /// typing must only ever aim at a session THIS mint brought into
    /// being, and the probe's tile list can be a tick stale.
    ///
    /// It carries the probe's own presence guard because it is the FIRST
    /// exec of a New Session press: with herdr absent the list verb prints
    /// nothing (`2>/dev/null || true`), which is indistinguishable from
    /// garbage, and the mint used to fail silently. The marker lets
    /// `readSessionList` name the real cause so the press can say
    /// "herdr isn't installed" instead of nothing at all.
    static let sessionListCommand = pathPrefix
        + "command -v herdr >/dev/null 2>&1 || { echo \(noHerdrMarker); exit 0; }; "
        + sessionListVerb

    /// The list invocation without the PATH export, for callers that have
    /// already exported it (the discovery rider). One spelling of the shape
    /// `parseSessionNames` reads, wherever it is asked for.
    static let sessionListVerb = "herdr session list --json 2>/dev/null || true"

    /// nil distinguishes an unreadable list from a valid empty one. The mint
    /// must prove absence before it may type setup lines into a name: treating
    /// garbage as [] could attach to an existing session and type into it.
    static func parseSessionNames(_ output: String) -> [String]? {
        firstDecodedLine(in: output, decodeSessionList)?.sessions.map(\.name)
    }

    /// What `sessionListCommand` answered. `parseSessionNames`' nil says
    /// only "not a list"; the mint needs the one cause it can explain, so a
    /// host with no herdr on its PATH reads as `.herdrMissing` rather than
    /// as unreadable garbage.
    enum SessionListReading: Equatable {
        case names([String])
        case herdrMissing
        case unreadable
    }

    static func readSessionList(_ output: String) -> SessionListReading {
        // Same leading-noise tolerance as the probe's own read: a remote
        // `.bashrc` may echo before the guard runs.
        if output.split(separator: "\n", omittingEmptySubsequences: false)
            .contains(where: { $0.trimmingCharacters(in: .whitespaces) == noHerdrMarker }) {
            return .herdrMissing
        }
        guard let names = parseSessionNames(output) else { return .unreadable }
        return .names(names)
    }

    /// One snapshot invocation, spelled once: the spawn's verify loop and
    /// the mint's poll must stay the same exec.
    private static func snapshotInvocation(sessionName: String) -> String {
        "herdr --session \(sessionName.shellQuoted) api snapshot 2>/dev/null"
    }

    /// Bring a session up WITHOUT a PTY: the client panics once its TUI
    /// can't init, but only after the session server daemonizes (verified
    /// 0.7.5 — and the command verifies rather than trusts: the trailing
    /// loop waits for the socket to answer a snapshot). Printing that
    /// snapshot is the point: it carries the fresh session's focused pane,
    /// the target for setup typing, so create-and-type is two execs with
    /// no window racing the user's own keyboard.
    ///
    /// `directory` roots the fresh session's world: herdr has no
    /// start-directory flag, but the session server inherits the spawning
    /// process's cwd (verified 0.7.5), so the mint cds first — guarded
    /// like the tmux mint's `-c` (`~` forms expand, a directory missing
    /// on the host falls to $HOME, never a failed spawn). Revives pass
    /// nil: a restarted session restores the world it already had.
    static func spawnSessionCommand(
        sessionName: String, directory: String? = nil
    ) -> String {
        var command = pathPrefix
        if let directory {
            command += "d=\(directory.shellQuotedDirectory); "
                + "[ -d \"$d\" ] || d=\"$HOME\"; cd \"$d\" 2>/dev/null; "
        }
        command += "herdr session attach \(sessionName.shellQuoted) >/dev/null 2>&1 </dev/null; "
            + "i=0; while [ \"$i\" -lt 4 ]; do "
            + snapshotInvocation(sessionName: sessionName) + " && exit 0; "
            + "i=$((i+1)); sleep 1; done; true"
        return command
    }

    /// One session-scoped snapshot — the mint's poll when the headless
    /// spawn didn't answer (a PTY attach may be bringing the server up
    /// instead).
    static func snapshotCommand(sessionName: String) -> String {
        pathPrefix + snapshotInvocation(sessionName: sessionName) + " || true"
    }

    /// The small between-probe query: unlike `api snapshot`, `pane current`
    /// returns only the session's globally focused pane. That is enough to
    /// move helper chips as soon as a herdr tab/workspace switch lands.
    static func activePaneCommand(sessionName: String) -> String {
        pathPrefix
            + "herdr --session \(sessionName.shellQuoted) pane current 2>/dev/null || true"
    }

    /// The focused pane out of a lone snapshot exec — where setup typing
    /// lands. A fresh session has exactly one workspace and pane, so
    /// focused and first agree.
    static func parseFocusedPane(_ output: String) -> String? {
        firstDecodedLine(in: output, decodeSnapshot).flatMap(frontPaneID(of:))
    }

    /// Lightweight helper-strip answer from one `pane current` envelope.
    /// Herdr's current pane and canonical agent id are server authority, so a
    /// decoded pane with no supported agent is definitive — unlike tmux, no
    /// process fallback is needed. The synthetic process fingerprint lets the
    /// shared terminal policy retire a previous pane's helpers immediately.
    static func parseActiveAgent(_ output: String) -> ActivePaneAgentDetection? {
        guard let pane = firstDecodedLine(in: output, decodeCurrentPane)
        else { return nil }
        return ActivePaneAgentDetection(
            fingerprint: TmuxPaneFingerprint(
                tmuxID: pane.paneID,
                pid: 0,
                tty: "",
                command: pane.agent ?? ""
            ),
            agent: pane.agent.flatMap(AgentKind.init(herdrAgent:)),
            isDefinitive: true
        )
    }

    /// The agent-history jump's view of one `pane current` envelope: the
    /// pane id the walk will aim captures and key sends at, the RAW
    /// terminal title (glyphs intact — see `Pane.terminalTitle`), and the
    /// spliceable working directory, foreground process first.
    struct CurrentPaneSummary: Equatable {
        var paneID: String
        var title: String
        var workingDirectory: String?
    }

    static func parseCurrentPaneSummary(_ output: String) -> CurrentPaneSummary? {
        guard let pane = firstDecodedLine(in: output, decodeCurrentPane)
        else { return nil }
        return CurrentPaneSummary(
            paneID: pane.paneID,
            title: pane.terminalTitle ?? "",
            workingDirectory: [pane.foregroundCwd, pane.cwd]
                .compactMap { $0 }
                .first(where: isSpliceablePath)
        )
    }

    // MARK: - File drops (and the file viewer's cwd anchor)

    /// The focused pane's working directory out of one snapshot exec —
    /// where a drop's typed path will land, so strictly the pane the
    /// server names focused, never a guess (`parseFocusedCloseTarget`'s
    /// discipline). Prefers the foreground process's cwd — tmux
    /// `pane_current_path`'s analog: while an agent runs there, the
    /// agent's own directory — over the pane's shell cwd. The value is
    /// respliced into the git-corral check and aimed at by SFTP, so only
    /// a clean absolute path may answer; nil falls back to $HOME with
    /// absolute typed paths, the tmux path's own posture when no pane
    /// answers.
    static func parseFocusedPaneWorkingDirectory(_ output: String) -> String? {
        guard let snapshot = firstDecodedLine(in: output, decodeSnapshot),
              let focusedID = snapshot.focusedPaneID,
              let pane = snapshot.panes.first(where: { $0.paneID == focusedID })
        else { return nil }
        return [pane.foregroundCwd, pane.cwd]
            .compactMap { $0 }
            .first(where: isSpliceablePath)
    }

    /// The cwd a pressed path resolves against, out of the same snapshot
    /// exec: the pane whose screen rectangle contains the pressed cell when
    /// one does (and carries a spliceable directory — foreground process
    /// first, `parseFocusedPaneWorkingDirectory`'s discipline), the focused
    /// pane otherwise. In a split, the two panes' cwds routinely differ,
    /// and "relative to the pane's directory" must mean the pane that
    /// printed the path.
    static func parsePaneWorkingDirectory(
        _ output: String, atScreenCell cell: (col: Int, row: Int)?
    ) -> String? {
        if let cell,
           let pressed = parsePaneScreenRects(output).first(where: {
               $0.rect.contains(col: cell.col, row: cell.row)
           }),
           let snapshot = firstDecodedLine(in: output, decodeSnapshot),
           let pane = snapshot.panes.first(where: { $0.paneID == pressed.id }),
           let directory = [pane.foregroundCwd, pane.cwd]
               .compactMap({ $0 })
               .first(where: isSpliceablePath) {
            return directory
        }
        return parseFocusedPaneWorkingDirectory(output)
    }

    /// Every visible pane's screen rectangle out of one snapshot exec — the
    /// select-text mode's clamp candidates. The layout rects are already in
    /// the attached client's screen cells (sidebar and tab bar included in
    /// x/y), but they count drawn borders; each pane's `viewport_rows` names
    /// its content height, so the difference halves into a symmetric inset.
    /// Focus comes from the layout's `focused` flags backed by the
    /// snapshot's global focused pane; any missing piece drops that pane
    /// (an empty answer keeps the caller on whole-screen behavior).
    static func parsePaneScreenRects(_ output: String) -> [PaneScreenRectEntry] {
        guard let snapshot = firstDecodedLine(in: output, decodeSnapshot),
              let focusedTab = snapshot.focusedTabID,
              let layout = snapshot.layouts.first(where: { $0.tabID == focusedTab }),
              let panes = layout.panes
        else { return [] }
        let focusedPaneID = layout.focusedPaneID ?? snapshot.focusedPaneID
        return panes.compactMap { pane in
            guard let rect = pane.rect,
                  rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0
            else { return nil }
            var inset = 0
            if let viewportRows = snapshot.panes
                .first(where: { $0.paneID == pane.paneID })?.scroll?.viewportRows,
               viewportRows > 0, viewportRows <= rect.height {
                inset = (rect.height - viewportRows) / 2
            }
            let colLo = rect.x + inset
            let colHi = rect.x + rect.width - 1 - inset
            let rowLo = rect.y + inset
            let rowHi = rect.y + rect.height - 1 - inset
            guard colLo <= colHi, rowLo <= rowHi else { return nil }
            return PaneScreenRectEntry(
                id: pane.paneID,
                rect: PaneScreenRect(columns: colLo...colHi, rows: rowLo...rowHi),
                isFocused: pane.focused ?? (pane.paneID == focusedPaneID)
            )
        }
    }

    /// herdr 0.7.5 has no focus-pane-by-id — `pane focus` is strictly
    /// directional — so the select-text mode's auto-focus fires one step,
    /// and only when the layout is two panes (where a single step is
    /// exact). Direction values are herdr's own: left/right/up/down.
    static func focusPaneDirectionCommand(
        sessionName: String, direction: String
    ) -> String {
        pathPrefix
            + "herdr --session \(sessionName.shellQuoted) pane focus"
            + " --direction \(direction.shellQuoted) 2>/dev/null || true"
    }

    /// Absolute and control-free — the only directory shape safe to hand
    /// SFTP and requote into a follow-up shell exec.
    private static func isSpliceablePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    /// The first line of a (possibly noisy) exec response that decodes —
    /// login shells print around the one envelope line.
    private static func firstDecodedLine<T>(
        in output: String, _ decode: (String) -> T?
    ) -> T? {
        for line in output.split(separator: "\n") {
            if let value = decode(String(line)) { return value }
        }
        return nil
    }

    /// Type lines into a pane the way the tmux mint does — literal text,
    /// then Enter, per line; sequential, never `&&`-gated, so a failing
    /// setup script leaves its error visible above a launch that still
    /// runs.
    static func typeCommand(sessionName: String, paneID: String, lines: [String]) -> String? {
        let typed = lines.filter { !$0.isEmpty }
        guard !typed.isEmpty else { return nil }
        let session = sessionName.shellQuoted
        var command = pathPrefix
        for line in typed {
            command += "herdr --session \(session) pane send-text"
                + " \(paneID.shellQuoted) \(line.shellQuoted) 2>/dev/null || true; "
            command += "herdr --session \(session) pane send-keys"
                + " \(paneID.shellQuoted) Enter 2>/dev/null || true; "
        }
        command += "true"
        return command
    }

    /// Create a new tab in the session's FOCUSED workspace — where the
    /// session is looking right now (0.7.5 defaults `tab create` to the
    /// focused workspace, so no snapshot parse races the create). The
    /// external action's "open in the existing workspace" placement, and
    /// the terminal window's New Tab in Workspace entry — which passes
    /// neither rider, so herdr numbers the tab and starts it in the
    /// focused pane's directory (the press means "another one here").
    static func createTabCommand(
        sessionName: String, label: String?, directory: String?
    ) -> String {
        createCommand(
            verb: "tab", sessionName: sessionName, label: label,
            directory: directory)
    }

    /// Create a whole new workspace in the session — the external action's
    /// "create new" placement; its label becomes a deck spine line.
    static func createWorkspaceCommand(
        sessionName: String, label: String, directory: String?
    ) -> String {
        createCommand(
            verb: "workspace", sessionName: sessionName, label: label,
            directory: directory)
    }

    /// Both create verbs share one shape and answer one envelope. `--focus`
    /// is explicit — 0.7.5 creates unfocused by default, and the point is
    /// that the attach which follows (and every already-attached client,
    /// via the session's ONE focus) fronts the fresh pane. `--cwd` rides
    /// the shell's own `$HOME` expansion; a missing directory fails soft to
    /// $HOME host-side (herdr's behavior, verified 0.7.5), so no `[ -d ]`
    /// guard — and an omitted one inherits the focused pane's directory.
    /// An omitted label leaves herdr's own numbering; callers that pass one
    /// pass app-authored text only.
    private static func createCommand(
        verb: String, sessionName: String, label: String?, directory: String?
    ) -> String {
        var command = pathPrefix
            + "herdr --session \(sessionName.shellQuoted) \(verb) create"
        if let label, !label.isEmpty {
            command += " --label \(label.shellQuoted)"
        }
        if let directory, !directory.isEmpty {
            command += " --cwd \(directory.shellQuotedDirectory)"
        }
        command += " --focus 2>/dev/null || true"
        return command
    }

    /// The fresh pane out of a `tab create` / `workspace create` envelope —
    /// where the placement's setup typing lands. Both verbs answer
    /// `result.root_pane.pane_id` (verified 0.7.5); nil means the create
    /// didn't happen and the launch must fail visibly, never type blind.
    static func parseCreatedPane(_ output: String) -> String? {
        firstDecodedLine(in: output, decodeCreatedPane)
    }

    private struct CreatedResult: Decodable {
        var rootPane: CreatedPane

        enum CodingKeys: String, CodingKey {
            case rootPane = "root_pane"
        }
    }

    private struct CreatedPane: Decodable {
        var paneID: String

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
        }
    }

    private static func decodeCreatedPane(_ text: String) -> String? {
        (try? JSONDecoder().decode(
            Envelope<CreatedResult>.self, from: Data(text.utf8)))?
            .result.rootPane.paneID
    }

    // MARK: - Shortcut panel (HRDR)

    /// The shortcut panel's workspace list for one session — the herdr
    /// analog of `TmuxProbe.windowListCommand`, one envelope exec.
    static func workspaceListCommand(sessionName: String) -> String {
        pathPrefix
            + "herdr --session \(sessionName.shellQuoted) workspace list"
            + " 2>/dev/null || true"
    }

    /// Workspaces as the panel's switch rows, reusing the tmux choice record
    /// the way the probe reuses `TmuxSession` — `tmuxID` carries herdr's
    /// workspace id. nil when nothing decodes; the panel then simply shows
    /// no switch section.
    static func parseWorkspaceChoices(_ output: String) -> [TmuxWindowChoice]? {
        guard let list = firstDecodedLine(in: output, decodeWorkspaceList)
        else { return nil }
        return list.workspaces
            .sorted { $0.number < $1.number }
            .map { workspace in
                TmuxWindowChoice(
                    tmuxID: workspace.workspaceID,
                    index: workspace.number,
                    isActive: workspace.focused ?? false,
                    name: displayLabel(workspace)
                )
            }
    }

    private struct WorkspaceListResult: Decodable {
        var workspaces: [Workspace]
    }

    private static func decodeWorkspaceList(_ text: String) -> WorkspaceListResult? {
        (try? JSONDecoder().decode(
            Envelope<WorkspaceListResult>.self, from: Data(text.utf8)))?.result
    }

    /// Switch the session's ONE global focus to a workspace — every attached
    /// client follows, exactly like the panel's tmux `select-window`. The id
    /// is response-derived, so it passes the same framing vet as pane ids;
    /// nil means the row is not actionable.
    static func focusWorkspaceCommand(
        sessionName: String, workspaceID: String
    ) -> String? {
        guard bakeablePaneID(workspaceID) else { return nil }
        return pathPrefix
            + "herdr --session \(sessionName.shellQuoted)"
            + " workspace focus \(workspaceID.shellQuoted) 2>/dev/null || true"
    }

    /// The target a confirmed destructive close aims at, resolved from one
    /// snapshot exec: strictly what the server names focused — a close must
    /// never guess. The focused tab falls back to the focused workspace's
    /// active tab (the same tab by definition, stated two ways).
    static func parseFocusedCloseTarget(
        _ output: String, scope: HerdrShortcut.CloseScope
    ) -> String? {
        guard let snapshot = firstDecodedLine(in: output, decodeSnapshot)
        else { return nil }
        let target: String? = switch scope {
        case .pane:
            snapshot.focusedPaneID
        case .tab:
            snapshot.focusedTabID ?? snapshot.workspaces.first {
                $0.workspaceID == snapshot.focusedWorkspaceID
            }?.activeTabID
        case .workspace:
            snapshot.focusedWorkspaceID
        }
        return target.flatMap { bakeablePaneID($0) ? $0 : nil }
    }

    /// Close one resolved target. The UI has already required the second
    /// press, and the CLI verbs close without their own confirmation.
    static func closeShortcutCommand(
        sessionName: String, scope: HerdrShortcut.CloseScope, targetID: String
    ) -> String? {
        guard bakeablePaneID(targetID) else { return nil }
        return pathPrefix
            + "herdr --session \(sessionName.shellQuoted)"
            + " \(scope.rawValue) close \(targetID.shellQuoted)"
            + " 2>/dev/null || true"
    }

    /// A user-entered name reduced to what a herdr session (a directory
    /// on the host) can safely be called: ASCII alphanumerics plus `._-`,
    /// runs of anything else collapse to one `-`, leading dots/dashes
    /// trimmed (hidden dirs, flag lookalikes), capped at 64. Empty in,
    /// `session` out — the mint always has a name.
    static func sessionNameArgument(_ raw: String) -> String {
        var collapsed = ""
        var pendingSeparator = false
        for scalar in raw.unicodeScalars {
            let isAllowed = (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "." || scalar == "_" || scalar == "-"
            if isAllowed {
                if pendingSeparator, !collapsed.isEmpty { collapsed.append("-") }
                pendingSeparator = false
                collapsed.append(Character(scalar))
            } else {
                pendingSeparator = true
            }
        }
        while let first = collapsed.first, first == "-" || first == "." {
            collapsed.removeFirst()
        }
        while let last = collapsed.last, last == "-" || last == "." {
            collapsed.removeLast()
        }
        if collapsed.count > 64 {
            collapsed = String(collapsed.prefix(64))
        }
        // Truncation can expose a dot/dash that was interior before the cap.
        while let last = collapsed.last, last == "-" || last == "." {
            collapsed.removeLast()
        }
        return collapsed.isEmpty ? "session" : collapsed
    }

    /// First free name against the tile list: base, base-2, base-3… (its
    /// own loop, not `TmuxProbe.uniqueSessionName`, whose tmux sanitizer
    /// would strip the dots herdr names may keep). A concurrent client
    /// can still win the race — harmless, attach joins what exists.
    static func uniqueSessionName(base: String, existing: some Sequence<String>) -> String {
        let base = sessionNameArgument(base)
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var suffix = 2
        while true {
            let ending = "-\(suffix)"
            var stem = String(base.prefix(max(1, 64 - ending.count)))
            while let last = stem.last, last == "-" || last == "." {
                stem.removeLast()
            }
            if stem.isEmpty { stem = "session" }
            let candidate = stem + ending
            if !taken.contains(candidate) { return candidate }
            suffix += 1
        }
    }

    // MARK: - Tails (the deck wall's live miniatures)

    /// Parse the sentinel-framed pane reads (the region after the tails
    /// marker) into session name → trailing lines. MPXS markers carry
    /// `<session> <pane>` — the app itself baked both, and the pane id
    /// (whitespace-free by the bake guard) sits after the LAST space, so
    /// even a future session-name grammar with spaces would frame. A frame
    /// is accepted only
    /// when this tick's snapshot still owns that pane — raw pane text can
    /// echo "MPXS …" lines, and an unverifiable frame is dropped rather
    /// than believed. When two frames land on one session the newer read
    /// wins.
    private static func parseTails(
        _ region: Substring, paneStatuses: [String: [String: AgentStatus]]
    ) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var currentName: String?
        var lines: [String] = []
        func flush() {
            if let name = currentName {
                let tail = TmuxProbe.visibleTail(lines)
                if !tail.isEmpty || result[name] == nil { result[name] = tail }
            }
            currentName = nil
            lines = []
        }
        for raw in region.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix(tailFrameMarker + " ") {
                flush()
                let payload = raw.dropFirst(tailFrameMarker.count + 1)
                if let separator = payload.lastIndex(of: " ") {
                    let session = String(payload[..<separator])
                    let pane = String(payload[payload.index(after: separator)...])
                    if paneStatuses[session]?[pane] != nil {
                        currentName = session
                    }
                }
            } else if raw == tailEndMarker {
                flush()
            } else if currentName != nil {
                lines.append(String(raw))
            }
        }
        flush() // tolerate a truncated response missing its trailing MPXE
        return result
    }
}

extension HerdrProbe.AgentStatus {
    /// Forward-tolerant: a state this build has never heard of is
    /// `.unknown`, never a dropped pane.
    init(tolerant raw: String) {
        self = HerdrProbe.AgentStatus(rawValue: raw) ?? .unknown
    }
}

extension HerdrProbe {
    /// In herdr mode the reported lifecycle status IS the pane's attention
    /// authority — the needle heuristics (spinner titles, dialog shapes)
    /// are bypassed, which is what makes Pi's states real here. `done`
    /// maps to `.idle` on purpose: it is herdr's settled off-focus state,
    /// and handing the tracker that same busy → idle edge is what
    /// produces the turn-ended alert exactly once. `unknown` (herdr can't
    /// say, or a state this build predates) is no claim at all, matching
    /// the tmux path's unverified-agent posture.
    ///
    /// herdr's `blocked` doesn't distinguish permission dialogs from
    /// questions; `.permission` is the honest generic ("blocked" is
    /// deliberately strict in herdr's manifests — known approval/question
    /// UI only).
    static func paneAgentState(_ status: AgentStatus?) -> PaneAgentState? {
        switch status {
        case .working: .busy
        case .blocked: .needsYou(.permission)
        case .done, .idle: .idle
        case .unknown, nil: nil
        }
    }

    /// Whether the front pane itself produced the session-level verdict.
    /// This is alert metadata only: aggregate attention still folds every
    /// pane. In particular, idle is not enough to claim a turn-end — a
    /// background pane may have finished while the front stayed idle.
    static func paneProducedSessionState(
        _ state: PaneAgentState?,
        current: AgentStatus?,
        previous: AgentStatus?
    ) -> Bool {
        switch state {
        case .busy:
            current == .working
        case .needsYou:
            current == .blocked
        case .idle:
            current == .done || (previous == .working && current == .idle)
        case nil:
            false
        }
    }

    /// A session tile's attention is the fold of EVERY pane in the
    /// session — every workspace, background tabs included: any blocked
    /// pane needs you; else any working pane means busy; else any pane
    /// herdr vouched for at all means idle; a session of nothing but
    /// `unknown` makes no claim.
    static func sessionAgentState(
        _ statuses: some Sequence<AgentStatus>
    ) -> PaneAgentState? {
        var sawWorking = false
        var sawKnown = false
        for status in statuses {
            switch status {
            case .blocked: return .needsYou(.permission)
            case .working: sawWorking = true
            case .done, .idle: sawKnown = true
            case .unknown: break
            }
        }
        if sawWorking { return .busy }
        return sawKnown ? .idle : nil
    }
}

extension HerdrProbe.State {
    /// The wall consumes `TmuxState`; herdr states fold onto it and the
    /// tile chooses backend-aware copy (`Host.sessionBackend` is on the
    /// tile's host). `updateNeeded` rides the failed lane with its own
    /// sentence — an honest tile, never garbage from a protocol this
    /// parser predates.
    var tmuxState: TmuxState {
        switch self {
        case .herdrMissing: .tmuxMissing
        case .noServer: .noServer
        case .updateNeeded(let version):
            .failed(String(
                localized: "herdr \(version) is older than this app speaks — update herdr on the host"
            ))
        case .sessions(let sessions): .sessions(sessions)
        case .failed(let message): .failed(message)
        }
    }
}

extension AgentKind {
    /// herdr's canonical agent ids (it canonicalizes aliases itself —
    /// reporting `claude-code` stores `claude`). Kinds Multiplex has no
    /// helper set for map to nil: the pane keeps its herdr status, it just
    /// isn't claimed as a known agent.
    init?(herdrAgent: String) {
        switch herdrAgent {
        case "claude": self = .claudeCode
        case "codex": self = .codex
        case "pi": self = .pi
        // herdr's canonical id for Grok Build is unverified (2026-08-16);
        // the raw command name is the one spelling it can plausibly report.
        case "grok": self = .grok
        case "antigravity", "agy": self = .antigravity
        case "hermes", "hermes-agent": self = .hermes
        default: return nil
        }
    }
}
