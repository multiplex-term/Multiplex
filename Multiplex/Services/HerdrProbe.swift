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
/// - No API surface reports attached clients, so herdr sessions never
///   claim the ATTACHED lamp: `clientCount` stays 0 and the tile simply
///   doesn't say what nothing can verify.
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
    /// Non-interactive SSH exec often has a minimal PATH. herdr's install
    /// homes are tmux's usual suspects plus `~/.cargo/bin` (cargo installs
    /// a Rust binary where tmux would never live).
    static let pathPrefix =
        "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin\"; "
        + "export PATH; "

    /// The socket protocol this parser was written against. Pre-1.0 herdr
    /// churns; anything older renders an honest UPDATE-NEEDED tile instead
    /// of garbage, while newer protocols pass — decoding ignores unknown
    /// fields, herdr's own forward-compat advice.
    static let minimumProtocol = 17

    // MARK: - Probe command

    private static let noHerdrMarker = "MULTIPLEX_NO_HERDR"
    private static let statusMarker = "MULTIPLEX_HERDR_STATUS"
    private static let sessionsMarker = "MULTIPLEX_HERDR_SESSIONS"
    private static let snapshotMarker = "MULTIPLEX_HERDR_SNAP"
    private static let tailsMarker = "MULTIPLEX_TAILS"

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
    /// PREVIOUS tick's parse: `sessionNames` names the snapshots to take
    /// (`default` is always tried — it's herdr's primary session, so a
    /// cold first tick still paints its spine), `tailTargets` names the
    /// pane reads. Snapshots of new sessions and miniatures therefore lag
    /// topology changes by one tick — the wall already tolerates 5 s of
    /// staleness by design, and a baked target that vanished mid-tick just
    /// yields an empty frame the parser drops.
    static func probeCommand(sessionNames: [String], tailTargets: [TailTarget]) -> String {
        var command = pathPrefix
            + "command -v herdr >/dev/null 2>&1 || { echo \(noHerdrMarker); exit 0; }; "
            + "echo \(statusMarker); herdr status --json 2>/dev/null || true; "
            + "echo \(sessionsMarker); herdr session list --json 2>/dev/null || true; "
        var snapshotSet = sessionNames.filter(bakeableSessionName)
        if !snapshotSet.contains("default") { snapshotSet.append("default") }
        for name in snapshotSet {
            command += "echo \("\(snapshotMarker) \(name)".shellQuoted); "
                + "herdr --session \(name.shellQuoted) api snapshot 2>/dev/null || true; "
        }
        command += "echo \(tailsMarker); "
        for target in tailTargets
        where bakeableSessionName(target.sessionName) && bakeablePaneID(target.paneID) {
            command += "echo \("MPXS \(target.sessionName) \(target.paneID)".shellQuoted); "
                + "herdr --session \(target.sessionName.shellQuoted)"
                + " pane read \(target.paneID.shellQuoted) --source visible"
                + " 2>/dev/null || true; "
        }
        command += "echo MPXE"
        return command
    }

    /// A name the probe may bake into a shell command and a sentinel line:
    /// no control characters (a newline would forge framing through
    /// `echo`) and no leading `-` (clap would read it as a flag even
    /// quoted). Session names are directory names, so real ones pass;
    /// a pathological one just keeps a spine-less tile until renamed.
    static func bakeableSessionName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }
        return name.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    /// Pane ids are server-minted (`w1:p1`) — whitespace-free by shape.
    /// The MPXS sentinel separates session from pane on the LAST space,
    /// which only stays unambiguous while that holds.
    static func bakeablePaneID(_ paneID: String) -> Bool {
        guard !paneID.isEmpty, !paneID.hasPrefix("-") else { return false }
        return paneID.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0)
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

    /// herdr's agent lifecycle states. `done` is derived server-side from
    /// a working → idle report (integrations report only idle/working/
    /// blocked/unknown). Unrecognized future states decode as `.unknown`
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
        var serverVersion: String?
    }

    static func parseProbe(_ output: String) -> ParsedProbe {
        var result = ParsedProbe(
            state: .failed("unreadable herdr probe response"),
            tails: [:], miniatures: [:], paneStatuses: [:],
            tailTargets: [], sessionNames: [], serverVersion: nil
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.contains(where: { $0 == noHerdrMarker }) {
            result.state = .herdrMissing
            return result
        }

        let status = section(in: output, from: statusMarker, to: sessionsMarker)
            .flatMap(decodeStatus)
        result.serverVersion = status?.server.version ?? status?.client.version

        // Version-gate on the client protocol: one binary serves every
        // session, so an old client is an old host — and pre-17 has no
        // `session list --json` to parse anyway.
        if let clientProtocol = status?.client.protocolVersion,
           clientProtocol < minimumProtocol {
            result.state = .updateNeeded(
                installedVersion: status?.client.version ?? "unknown")
            return result
        }

        let region = sessionsRegion(lines)
        guard let list = region.list else {
            if status != nil {
                result.state = .failed("herdr answered status but not the session list")
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
            result.serverVersion = stale.version
            return result
        }
        if result.serverVersion == nil {
            result.serverVersion = snapshots.values.first?.version
        }

        guard !list.sessions.isEmpty else {
            result.state = .noServer
            return result
        }

        let mapped = list.sessions.enumerated().map { index, entry in
            session(entry: entry, index: index, snapshot: snapshots[entry.name])
        }
        var paneStatuses: [String: [String: AgentStatus]] = [:]
        var validPanes: [String: Set<String>] = [:]
        var tailTargets: [TailTarget] = []
        for entry in list.sessions where entry.running {
            guard let snapshot = snapshots[entry.name] else { continue }
            paneStatuses[entry.name] = Dictionary(
                snapshot.panes.map { ($0.paneID, AgentStatus(tolerant: $0.agentStatus)) },
                uniquingKeysWith: { first, _ in first }
            )
            validPanes[entry.name] = Set(snapshot.panes.map(\.paneID))
            if let pane = frontPaneID(of: snapshot), bakeablePaneID(pane) {
                tailTargets.append(TailTarget(sessionName: entry.name, paneID: pane))
            }
        }
        let tails = parseTails(output, validPanes: validPanes)
        return ParsedProbe(
            state: .sessions(mapped),
            tails: tails,
            miniatures: tails.mapValues(TmuxProbe.miniatureTail),
            paneStatuses: paneStatuses,
            tailTargets: tailTargets,
            sessionNames: list.sessions.filter(\.running).map(\.name)
                .filter(bakeableSessionName),
            serverVersion: result.serverVersion
        )
    }

    // MARK: - Wire types (decoded tolerantly — unknown fields ignored)

    private struct Envelope<Payload: Decodable>: Decodable {
        var result: Payload
    }

    private struct SnapshotResult: Decodable {
        var snapshot: Snapshot
    }

    /// `herdr session list --json` — a client verb, so plain JSON with no
    /// envelope. Which session is the default is deliberately not decoded:
    /// nothing app-side may branch on it (the server owns that rule).
    private struct SessionList: Decodable {
        var sessions: [SessionEntry]
    }

    struct SessionEntry: Decodable {
        var name: String
        var running: Bool
    }

    struct Snapshot: Decodable {
        var version: String
        var protocolVersion: Int
        var workspaces: [Workspace]
        var tabs: [Tab]
        var panes: [Pane]
        var layouts: [Layout]
        /// The session's ONE focus — what every attached client shows.
        var focusedWorkspaceID: String?
        var focusedPaneID: String?

        enum CodingKeys: String, CodingKey {
            case version
            case protocolVersion = "protocol"
            case workspaces, tabs, panes, layouts
            case focusedWorkspaceID = "focused_workspace_id"
            case focusedPaneID = "focused_pane_id"
        }
    }

    struct Workspace: Decodable {
        var workspaceID: String
        var number: Int
        var label: String
        var activeTabID: String

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case number, label
            case activeTabID = "active_tab_id"
        }
    }

    struct Tab: Decodable {
        var tabID: String
        var workspaceID: String
        var number: Int
        var label: String

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case workspaceID = "workspace_id"
            case number, label
        }
    }

    struct Pane: Decodable {
        var paneID: String
        var workspaceID: String
        var tabID: String
        var agent: String?
        var agentStatus: String
        var terminalTitleStripped: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case agent
            case agentStatus = "agent_status"
            case terminalTitleStripped = "terminal_title_stripped"
        }
    }

    struct Layout: Decodable {
        var tabID: String
        var focusedPaneID: String?

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case focusedPaneID = "focused_pane_id"
        }
    }

    private struct Status: Decodable {
        var client: StatusClient
        var server: StatusServer
    }

    private struct StatusClient: Decodable {
        var version: String?
        var protocolVersion: Int?

        enum CodingKeys: String, CodingKey {
            case version
            case protocolVersion = "protocol"
        }
    }

    private struct StatusServer: Decodable {
        var running: Bool?
        var version: String?
    }

    private static func decodeSnapshot(_ text: String) -> Snapshot? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(
            Envelope<SnapshotResult>.self, from: data))?.result.snapshot
    }

    private static func decodeSessionList(_ text: String) -> SessionList? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionList.self, from: data)
    }

    private static func decodeStatus(_ text: String) -> Status? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    /// The text between two sentinel lines, nil when the opening sentinel
    /// never printed. The closing sentinel is always emitted by the probe
    /// script itself, but a truncated response still parses as "everything
    /// after the opener".
    private static func section(
        in output: String, from opener: String, to closer: String
    ) -> String? {
        guard let start = output.range(of: opener + "\n") else { return nil }
        let rest = output[start.upperBound...]
        let end = rest.range(of: "\n" + closer)?.lowerBound ?? rest.endIndex
        let text = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The list-and-snapshots region: the first decodable line after the
    /// sessions marker is the list; `MULTIPLEX_HERDR_SNAP <name>` lines
    /// (the name may contain spaces — the whole remainder is the name)
    /// open per-session candidate lines, decoded first-that-parses the way
    /// login-shell noise has always been skipped. Bounded by the tails
    /// marker, so raw pane text can never forge a snapshot.
    private static func sessionsRegion(
        _ lines: [Substring]
    ) -> (list: SessionList?, snapshotLines: [String: [String]]) {
        var list: SessionList?
        var snapshotLines: [String: [String]] = [:]
        var currentName: String?
        var inRegion = false
        for raw in lines {
            let line = String(raw)
            if line == sessionsMarker { inRegion = true; continue }
            guard inRegion else { continue }
            if line == tailsMarker { break }
            if line.hasPrefix(snapshotMarker + " ") {
                currentName = String(line.dropFirst(snapshotMarker.count + 1))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let name = currentName {
                snapshotLines[name, default: []].append(trimmed)
            } else if list == nil {
                list = decodeSessionList(trimmed)
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
            // Synthesized from the list position: nothing renders this as
            // a date (the tile hides sub-day ages), but external actions
            // and the widget sort "most recent" by it, and herdr's own
            // list order is the only order it states.
            created: Date(timeIntervalSince1970: TimeInterval(index)),
            tmuxID: entry.name,
            serverHost: ""
        )
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
        return label.isEmpty ? "workspace \(workspace.number)" : label
    }

    /// The one pane a session fronts — its focused pane, falling back
    /// through the focused workspace's active-tab layout to that tab's
    /// first pane: the read the next probe bakes in for the tile's
    /// miniature.
    static func frontPaneID(of snapshot: Snapshot) -> String? {
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

    /// The PTY attach line `ShellHandoff` injects for a herdr tab: the
    /// full client on the tile's session. Attach auto-creates a missing
    /// session and restarts a stopped one (verified 0.7.5), so a
    /// spine-less tile press and a fresh mint ride the same line. An
    /// empty name (a blind attach from the debug auto-attach hook) lands
    /// on the default session.
    static func attachCommand(sessionName: String) -> String {
        let name = sessionName.isEmpty ? "default" : sessionName
        return pathPrefix + "exec herdr session attach \(name.shellQuoted)"
    }

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

    /// The mint's live existence check — attach auto-creates, so setup
    /// typing must only ever aim at a session THIS mint brought into
    /// being, and the probe's tile list can be a tick stale.
    static let sessionListCommand =
        pathPrefix + "herdr session list --json 2>/dev/null || true"

    static func parseSessionNames(_ output: String) -> [String] {
        for line in output.split(separator: "\n") {
            if let list = decodeSessionList(String(line)) {
                return list.sessions.map(\.name)
            }
        }
        return []
    }

    /// Bring a session up WITHOUT a PTY: the client panics once its TUI
    /// can't init, but only after the session server daemonizes (verified
    /// 0.7.5 — and the command verifies rather than trusts: the trailing
    /// loop waits for the socket to answer a snapshot). Printing that
    /// snapshot is the point: it carries the fresh session's focused pane,
    /// the target for setup typing, so create-and-type is two execs with
    /// no window racing the user's own keyboard.
    static func spawnSessionCommand(sessionName: String) -> String {
        let name = sessionName.shellQuoted
        return pathPrefix
            + "herdr session attach \(name) >/dev/null 2>&1 </dev/null; "
            + "i=0; while [ \"$i\" -lt 4 ]; do "
            + "herdr --session \(name) api snapshot 2>/dev/null && exit 0; "
            + "i=$((i+1)); sleep 1; done; true"
    }

    /// One session-scoped snapshot — the mint's poll when the headless
    /// spawn didn't answer (a PTY attach may be bringing the server up
    /// instead).
    static func snapshotCommand(sessionName: String) -> String {
        pathPrefix
            + "herdr --session \(sessionName.shellQuoted) api snapshot 2>/dev/null || true"
    }

    /// The focused pane out of a lone snapshot exec — where setup typing
    /// lands. A fresh session has exactly one workspace and pane, so
    /// focused and first agree.
    static func parseFocusedPane(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            if let snapshot = decodeSnapshot(String(line)) {
                return frontPaneID(of: snapshot)
            }
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
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    // MARK: - Tails (the deck wall's live miniatures)

    /// Parse the sentinel-framed pane reads into session name → trailing
    /// lines. MPXS markers carry `<session> <pane>` — the app itself baked
    /// both, and the pane id (whitespace-free by the bake guard) sits
    /// after the LAST space, so session names with spaces still frame.
    /// A frame is accepted only when this tick's snapshot still owns that
    /// pane — raw pane text can echo "MPXS …" lines, and an unverifiable
    /// frame is dropped rather than believed. When two frames land on one
    /// session the newer read wins.
    private static func parseTails(
        _ output: String, validPanes: [String: Set<String>]
    ) -> [String: [String]] {
        guard let marker = output.range(of: "\n" + tailsMarker + "\n") else { return [:] }
        var result: [String: [String]] = [:]
        var currentName: String?
        var lines: [String] = []
        func flush() {
            if let name = currentName {
                let tail = visibleTail(lines)
                if !tail.isEmpty || result[name] == nil { result[name] = tail }
            }
            currentName = nil
            lines = []
        }
        for raw in output[marker.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("MPXS ") {
                flush()
                let payload = line.dropFirst(5)
                if let separator = payload.lastIndex(of: " ") {
                    let session = String(payload[..<separator])
                    let pane = String(payload[payload.index(after: separator)...])
                    if validPanes[session]?.contains(pane) == true {
                        currentName = session
                    }
                }
            } else if line == "MPXE" {
                flush()
            } else if currentName != nil {
                lines.append(line)
            }
        }
        flush() // tolerate a truncated response missing its trailing MPXE
        return result
    }

    private static func visibleTail(_ lines: [String]) -> [String] {
        var trimmed = lines.map(rightTrim)
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        return trimmed
    }

    private static func rightTrim(_ line: String) -> String {
        var slice = Substring(line)
        while let last = slice.last, last == " " || last == "\t" { slice = slice.dropLast() }
        return String(slice)
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
    /// maps to `.idle` on purpose: herdr derives it from a working → idle
    /// report, and handing the tracker that same busy → idle edge is what
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
            .failed("herdr \(version) is older than this app speaks — update herdr on the host")
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
        default: return nil
        }
    }
}
