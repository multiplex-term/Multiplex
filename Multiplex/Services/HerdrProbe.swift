import Foundation

/// Builds and parses the `herdr` CLI commands used to discover remote
/// workspaces — the herdr-mode sibling of `TmuxProbe`. Pure functions,
/// exercised directly by unit tests against captured 0.7.5 output.
///
/// herdr (herdr.dev) is a Rust terminal/agent multiplexer whose CLI verbs
/// wrap a newline-JSON Unix-socket API. Wire facts, verified against
/// herdr 0.7.5 / protocol 17 on 2026-08-01 (fixtures under
/// MultiplexTests/Fixtures):
/// - Socket-wrapper verbs print single-line JSON envelopes
///   (`{"id":"cli:…","result":{…}}`) by default — there is no `--json`
///   flag on them (passing one is a usage error). The client-side
///   `herdr status --json` answers even with no server running, which is
///   what separates "no server" from "unreadable".
/// - `herdr api snapshot` is the one-call probe: version + protocol +
///   workspaces + tabs + panes + per-tab layouts (focused pane) + agents,
///   in one round trip by construction.
/// - `herdr pane read <id> --source visible` prints RAW text, not an
///   envelope — the capture-pane analog feeding the wall miniatures
///   (`recent` carries only rows already scrolled off screen).
/// - API failures print an error envelope or a Rust error line and exit
///   NONZERO — and Citadel throws on a nonzero exit — so every stage is
///   `2>/dev/null`-silenced and `|| true`-guarded, the tmux probe's own
///   discipline.
/// - No API surface reports attached clients (session list, status,
///   snapshot, and the event inventory all lack one), so herdr sessions
///   never claim the ATTACHED lamp: `clientCount` stays 0 and the tile
///   simply doesn't say what nothing can verify.
///
/// The parser maps herdr's model onto the existing tmux records —
/// workspace → `TmuxSession`, tab → `TmuxWindow`, pane → `TmuxPane` — so
/// everything downstream (FleetWall, DeckSnapshotStore, the widget
/// projection) keeps working untouched. herdr's own agent layer replaces
/// the ps-table walk: `pane.agent` is authoritative, so the probe carries
/// no process table at all.
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
    private static let snapshotMarker = "MULTIPLEX_HERDR_SNAPSHOT"
    private static let tailsMarker = "MULTIPLEX_TAILS"

    /// One exec round trip: status (version gate + no-server classifier),
    /// snapshot (the whole topology), then sentinel-framed visible-screen
    /// reads for the wall miniatures.
    ///
    /// `tailPaneIDs` is the previous tick's answer to "which pane fronts
    /// each workspace" (`ParsedProbe.tailPaneIDs`): a shell can't join
    /// JSON, so instead of parsing the snapshot host-side the app bakes
    /// the pane set into the next tick's command. Miniatures therefore lag
    /// topology changes by one tick — the wall already tolerates 5 s of
    /// staleness by design, and a baked id that vanished mid-tick just
    /// yields an empty frame the parser drops. First tick (empty set)
    /// paints from the deck snapshot cache like every cold launch.
    static func probeCommand(tailPaneIDs: [String]) -> String {
        var command = pathPrefix
            + "command -v herdr >/dev/null 2>&1 || { echo \(noHerdrMarker); exit 0; }; "
            + "echo \(statusMarker); herdr status --json 2>/dev/null || true; "
            + "echo \(snapshotMarker); herdr api snapshot 2>/dev/null || true; "
            + "echo \(tailsMarker); "
        for paneID in tailPaneIDs {
            command += "echo \("MPXS \(paneID)".shellQuoted); "
                + "herdr pane read \(paneID.shellQuoted) --source visible 2>/dev/null || true; "
        }
        command += "echo MPXE"
        return command
    }

    // MARK: - Parsed result

    /// What a herdr host's server currently looks like — the herdr-mode
    /// analog of `TmuxState`, kept separate so the pure layer states herdr
    /// truth and the wall chooses its vocabulary.
    enum State: Equatable {
        case herdrMissing
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
    /// herdr's semantic layer: per-pane agent statuses (keyed by pane id —
    /// `TmuxPane.tmuxID` — never persisted; attention is re-earned live)
    /// and the pane set the NEXT probe should read tails for.
    struct ParsedProbe {
        var state: State
        var tails: [String: [String]]
        var miniatures: [String: [String]]
        var paneStatuses: [String: AgentStatus]
        /// pane id → working directory (the foreground process's when herdr
        /// knows it — the same "agent's own cwd" rule as tmux's
        /// `pane_current_path`). Feeds + TAB's same-directory inheritance.
        var paneCWDs: [String: String]
        var tailPaneIDs: [String]
        var serverVersion: String?
    }

    static func parseProbe(_ output: String) -> ParsedProbe {
        var result = ParsedProbe(
            state: .failed("unreadable herdr probe response"),
            tails: [:], miniatures: [:], paneStatuses: [:],
            paneCWDs: [:], tailPaneIDs: [], serverVersion: nil
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.contains(where: { $0 == noHerdrMarker }) {
            result.state = .herdrMissing
            return result
        }

        let status = section(in: output, from: statusMarker, to: snapshotMarker)
            .flatMap(decodeStatus)
        result.serverVersion = status?.server.version ?? status?.client.version

        guard let snapshotText = section(in: output, from: snapshotMarker, to: tailsMarker),
              let snapshot = decodeSnapshot(snapshotText)
        else {
            // No snapshot. Status decides between a quiet server and a
            // broken host: `status --json` exits 0 with `running: false`
            // even serverless, while a herdr too old for `api snapshot`
            // (or `status --json`) lands in the honest failure bucket.
            if let status {
                if let clientProtocol = status.client.protocolVersion,
                   clientProtocol < minimumProtocol {
                    result.state = .updateNeeded(
                        installedVersion: status.client.version ?? "unknown")
                } else if status.server.running != true {
                    result.state = .noServer
                } else {
                    result.state = .failed("herdr server answered status but not snapshot")
                }
            }
            return result
        }

        if snapshot.protocolVersion < minimumProtocol {
            result.state = .updateNeeded(installedVersion: snapshot.version)
            result.serverVersion = snapshot.version
            return result
        }

        let mapped = sessions(from: snapshot)
        let paneNames = paneOwnerNames(snapshot: snapshot, sessions: mapped)
        let tails = parseTails(output, paneNames: paneNames)
        return ParsedProbe(
            state: .sessions(mapped),
            tails: tails,
            miniatures: tails.mapValues(TmuxProbe.miniatureTail),
            paneStatuses: Dictionary(
                snapshot.panes.map { ($0.paneID, AgentStatus(tolerant: $0.agentStatus)) },
                uniquingKeysWith: { first, _ in first }
            ),
            paneCWDs: Dictionary(
                snapshot.panes.compactMap { pane in
                    (pane.foregroundCwd ?? pane.cwd).map { (pane.paneID, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            ),
            tailPaneIDs: frontPaneIDs(snapshot: snapshot),
            serverVersion: snapshot.version
        )
    }

    // MARK: - Wire types (decoded tolerantly — unknown fields ignored)

    private struct Envelope<Payload: Decodable>: Decodable {
        var result: Payload
    }

    private struct SnapshotResult: Decodable {
        var snapshot: Snapshot
    }

    struct Snapshot: Decodable {
        var version: String
        var protocolVersion: Int
        var workspaces: [Workspace]
        var tabs: [Tab]
        var panes: [Pane]
        var layouts: [Layout]

        enum CodingKeys: String, CodingKey {
            case version
            case protocolVersion = "protocol"
            case workspaces, tabs, panes, layouts
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
        var cwd: String?
        var foregroundCwd: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case agent
            case agentStatus = "agent_status"
            case terminalTitleStripped = "terminal_title_stripped"
            case cwd
            case foregroundCwd = "foreground_cwd"
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

    // MARK: - Mapping (workspace → session, tab → window, pane → pane)

    private static func sessions(from snapshot: Snapshot) -> [TmuxSession] {
        let names = uniqueWorkspaceNames(snapshot.workspaces)
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

        return snapshot.workspaces.map { workspace in
            let windows = snapshot.tabs
                .filter { $0.workspaceID == workspace.workspaceID }
                .sorted { $0.number < $1.number }
                .map { tab in
                    window(
                        tab: tab,
                        panes: panesByTab[tab.tabID] ?? [],
                        focusedPaneID: layoutFocus[tab.tabID],
                        isActive: tab.tabID == workspace.activeTabID
                    )
                }
            return TmuxSession(
                name: names[workspace.workspaceID] ?? workspace.label,
                windows: windows,
                clientCount: 0,
                // Synthesized from the workspace ordinal: nothing renders
                // this as a date, but external actions and the widget sort
                // "most recent" by it, and herdr's numbers are its own
                // creation order.
                created: Date(timeIntervalSince1970: TimeInterval(workspace.number)),
                tmuxID: workspace.workspaceID,
                serverHost: ""
            )
        }
    }

    private static func window(
        tab: Tab, panes: [Pane], focusedPaneID: String?, isActive: Bool
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
            index: tab.number,
            name: tab.label,
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

    /// `TmuxSession.id` is the session *name*, and tmux enforces unique
    /// names — herdr does not enforce unique workspace labels (two
    /// workspaces rooted at `~` both label themselves `~`). Collisions get
    /// the workspace ordinal appended, and the pathological case where the
    /// suffixed form collides with a real label falls back to the
    /// workspace id, which herdr does keep unique.
    static func uniqueWorkspaceNames(_ workspaces: [Workspace]) -> [String: String] {
        var counts: [String: Int] = [:]
        for workspace in workspaces {
            counts[displayLabel(workspace), default: 0] += 1
        }
        // Unique labels keep themselves, reserved up front so a suffixed
        // duplicate can never collide into one.
        var taken = Set(counts.filter { $0.value == 1 }.keys)
        var names: [String: String] = [:]
        for workspace in workspaces {
            let label = displayLabel(workspace)
            if counts[label, default: 0] == 1 {
                names[workspace.workspaceID] = label
                continue
            }
            var name = "\(label) ·\(workspace.number)"
            if !taken.insert(name).inserted {
                name = "\(label) ·\(workspace.workspaceID)"
                taken.insert(name)
            }
            names[workspace.workspaceID] = name
        }
        return names
    }

    private static func displayLabel(_ workspace: Workspace) -> String {
        let label = workspace.label.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "workspace \(workspace.number)" : label
    }

    /// The pane each workspace fronts — its active tab's focused pane —
    /// in workspace order: the read set the next probe bakes in.
    static func frontPaneIDs(snapshot: Snapshot) -> [String] {
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
        return snapshot.workspaces.compactMap { workspace in
            layoutFocus[workspace.activeTabID]
                ?? panesByTab[workspace.activeTabID]?.first?.paneID
        }
    }

    /// pane id → owning session's display name, for keying tails the way
    /// the tmux parser does (the wall's miniatures dictionary is keyed by
    /// session name on both backends).
    private static func paneOwnerNames(
        snapshot: Snapshot, sessions: [TmuxSession]
    ) -> [String: String] {
        let sessionNames = Dictionary(
            sessions.map { ($0.tmuxID, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return Dictionary(
            snapshot.panes.compactMap { pane in
                sessionNames[pane.workspaceID].map { (pane.paneID, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Workspace actions

    /// Create a workspace. Unlike tmux's one-shot mint the follow-ups
    /// (script/launch typing) need the root pane id from the create's JSON
    /// envelope, which a shell can't extract — so the mint is two execs:
    /// this create, parsed by `parseNewWorkspace`, then `typeCommand`
    /// against the returned pane. User-initiated, not the probe loop, so
    /// the extra round trip costs nothing that matters. nil `cwd` lets
    /// herdr default to $HOME. There is no tmux-conf analog — herdr owns
    /// its own configuration.
    static func newWorkspaceCommand(label: String, cwd: String?) -> String {
        var command = pathPrefix + "herdr workspace create"
        if let cwd, !cwd.isEmpty {
            command += " --cwd \(cwd.shellQuotedDirectory)"
        }
        command += " --label \(label.shellQuoted) 2>/dev/null || true"
        return command
    }

    struct NewWorkspace: Equatable {
        var workspaceID: String
        var label: String
        var rootPaneID: String
    }

    private struct CreateWorkspaceRef: Decodable {
        var workspaceID: String
        var label: String
        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case label
        }
    }

    private struct CreatePaneRef: Decodable {
        var paneID: String
        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
        }
    }

    private struct CreateResult: Decodable {
        var workspace: CreateWorkspaceRef
        var rootPane: CreatePaneRef
        enum CodingKeys: String, CodingKey {
            case workspace
            case rootPane = "root_pane"
        }
    }

    static func parseNewWorkspace(_ output: String) -> NewWorkspace? {
        // The envelope is one line, but a login shell may print noise
        // around it — decode the first line that parses.
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(
                    Envelope<CreateResult>.self, from: data)
            else { continue }
            return NewWorkspace(
                workspaceID: envelope.result.workspace.workspaceID,
                label: envelope.result.workspace.label,
                rootPaneID: envelope.result.rootPane.paneID
            )
        }
        return nil
    }

    /// Type lines into a pane the way the tmux mint does — literal text,
    /// then Enter, per line; sequential, never `&&`-gated, so a failing
    /// setup script leaves its error visible above a launch that still
    /// runs.
    static func typeCommand(paneID: String, lines: [String]) -> String? {
        let typed = lines.filter { !$0.isEmpty }
        guard !typed.isEmpty else { return nil }
        var command = pathPrefix
        for line in typed {
            command += "herdr pane send-text \(paneID.shellQuoted) \(line.shellQuoted)"
                + " 2>/dev/null || true; "
            command += "herdr pane send-keys \(paneID.shellQuoted) Enter"
                + " 2>/dev/null || true; "
        }
        command += "true"
        return command
    }

    /// Close a workspace (and every process in it) — the herdr analog of
    /// kill-session, targeted by the server-minted workspace id (labels
    /// can duplicate).
    static func closeWorkspaceCommand(workspaceID: String) -> String {
        pathPrefix + "herdr workspace close \(workspaceID.shellQuoted) 2>/dev/null || true"
    }

    /// One agent screen for the Gallery — raw visible-screen text, same
    /// read the miniatures use, framed by nothing (the whole response IS
    /// the screen; errors are silenced so an empty answer reads as an
    /// empty screen, which the pane says honestly).
    static func screenReadCommand(paneID: String) -> String {
        pathPrefix + "herdr pane read \(paneID.shellQuoted) --source visible"
            + " 2>/dev/null || true"
    }

    /// Submit a prompt through herdr's own composer door —
    /// `agent prompt` types with bracketed paste and an encoded Enter
    /// (multiline-safe, submits even a working agent). stderr joins stdout
    /// and the exit is swallowed so Citadel doesn't throw: the *output*
    /// carries the verdict, which `promptVerdict` reads.
    static func promptCommand(paneID: String, text: String) -> String {
        pathPrefix + "herdr agent prompt \(paneID.shellQuoted) \(text.shellQuoted)"
            + " 2>&1 || true"
    }

    enum PromptVerdict: Equatable {
        case delivered
        /// herdr accepted the prompt but the agent's lifecycle never moved
        /// (~5 s) — a real delivery signal, surfaced as a pill, never a
        /// silent drop.
        case stalled
        case failed(String)
    }

    static func promptVerdict(_ output: String) -> PromptVerdict {
        if output.contains("agent_prompt_stalled") { return .stalled }
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(
                    ErrorEnvelope.self, from: data)
            else { continue }
            return .failed(envelope.error.message)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Error") || trimmed.hasPrefix("error:") {
            return .failed(trimmed)
        }
        return .delivered
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            var code: String
            var message: String
        }
        var error: Body
    }

    /// The PTY attach line `ShellHandoff` injects for a herdr tab:
    /// pre-focus the workspace over the socket (fail-soft — a vanished
    /// workspace still attaches to the session), then exec the full herdr
    /// client. `session attach` has no workspace flag (verified 0.7.5),
    /// hence the two commands. An empty workspace id (a blind attach from
    /// the debug auto-attach hook, before any probe named ids) skips the
    /// focus and lands on whatever the session fronts. v1.3 speaks the
    /// default session.
    static func attachCommand(workspaceID: String) -> String {
        var command = pathPrefix
        if !workspaceID.isEmpty {
            command += "herdr workspace focus \(workspaceID.shellQuoted) >/dev/null 2>&1; "
        }
        command += "exec herdr session attach default"
        return command
    }

    // MARK: - Tails (the deck wall's live miniatures)

    /// Parse the sentinel-framed pane reads into session name → trailing
    /// lines. MPXS markers carry the pane ids the app itself baked into
    /// the command — server-minted, never workspace labels, so arbitrary
    /// labels can't forge or break the framing. A frame whose pane no
    /// longer exists in this tick's snapshot resolves to no owner and is
    /// dropped; when two frames land on one workspace the newer read wins,
    /// which keeps a stale baked id from shadowing the live pane.
    private static func parseTails(
        _ output: String, paneNames: [String: String]
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
                currentName = paneNames[
                    String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                ]
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
