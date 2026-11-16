import Foundation

/// Builds and parses the `rex` CLI commands that put Rex sessions on the deck
/// and create new ones — the sibling of `TmuxProbe` and `HerdrProbe`. Pure functions,
/// exercised by unit tests against output captured from a live server.
///
/// Rex (superlogical.com/rex) is a multiplexer whose sessions are rendered by
/// a native app, not by a client drawing in a terminal. Wire facts, measured
/// against Rex 0.1.0-preview.19 / API revision 14 on 2026-11-16 (a throwaway
/// server; fixtures under MultiplexTests/Fixtures):
/// - **There is nothing to attach.** No `rex attach` exists, and `rex block
///   stream` answers `not implemented`. Live output is only the server's
///   WebSocket data stream, which opens with a Ghostty-format binary
///   snapshot — what `RexSession` speaks for a tab.
/// - `rex do -e <lua> --json` runs a script on ONE control connection and
///   prints its return value as JSON, so a whole wall probe — sessions,
///   layouts, titles, processes, reported statuses, the fronted screen — is
///   one exec and one connection (30 ms and 3 KB for three sessions).
/// - `session.view` and every block method fail with `conflict` until the
///   connection is attached. `session.attach_all` is the attachment that
///   does NOT join a session: the probe is never listed among its clients
///   and no `client_connected` event fires every five seconds.
/// - The CLI autostarts a personal server when none is running. Nothing
///   here does — not a probe every five seconds, and not a mint either.
///   A server started from an SSH login would be the one the host's own
///   Rex app then adopts, and how that server differs from one the app
///   starts in the desktop session was NOT measured; refusing is the
///   choice that cannot change how the user's Rex behaves. So every
///   invocation carries `REX_AUTOSTART=0`; a missing server then exits 4,
///   the CLI's documented "server unreachable" status, and a mint says so
///   instead of starting one (`Host.SessionBackend.canBeDefault` is the
///   same decision as a record rule).
/// - `rex do` takes its arguments as `KEY=VALUE` pairs — typed by how they
///   are spelled, so a label `1e3` arrives as the number 1000 — or as one
///   JSON object through `--args`, which keeps every string a string. The
///   mint uses the JSON form.
/// - A new terminal's `cwd` option is taken literally: `~` is not expanded
///   and a directory that does not exist silently starts in $HOME. The
///   script's Lua runs in the CLI process, so `os.getenv` reads the exec's
///   own environment — how a shell-resolved directory reaches it.
/// - `initial_input` is typed into the fresh shell once it is up; a
///   carriage return is Enter, and several lines run in order.
/// - Labels are not identities: two sessions may share one, and an unnamed
///   session gets a generated one. The id (`session:<uuid>`) is the only
///   unambiguous target — it rides `TmuxSession.tmuxID` — and
///   `sessionNames` makes the displayed names unique.
/// - `--json` output is pretty-printed even when piped, and an empty Lua
///   table encodes as `{}`, never `[]` — hence `LuaArray`.
/// - `format` returns the screen AND its scrollback, oldest first, and its
///   `max_bytes` counts JSON-encoded bytes. The tail is therefore read with
///   `blob_read` at an offset from the end, with no cap of its own.
/// - Programs report idle / working / done / blocked / error through OSC
///   7501 ("Program Status Protocol"), which the server keeps per block.
///   That is the attention authority when present; a block that reports
///   nothing falls back to the title-and-screen heuristics tmux tiles use.
///
/// The parser maps Rex's model onto the existing records — **session →
/// `TmuxSession`, window (a tab) → `TmuxWindow`, terminal block →
/// `TmuxPane`** — so the wall, the snapshot cache, and the attention
/// pipeline keep working untouched.
enum RexProbe {
    static let pathPrefix = RemoteCommandEnvironment.rexPathPrefix

    /// Every `rex` invocation the app makes. Autostart is refused through
    /// the documented environment switch rather than the `--autostart` flag
    /// so a build that predates the flag still answers instead of failing
    /// on an unknown option.
    static let rexCommand = "REX_AUTOSTART=0 rex"

    /// The byte bridge an attach rides (`RexSession`): stdin and stdout
    /// joined to the server's socket. It is the command Rex's own `ssh://`
    /// transport runs on the far side — which is why it finds the server by
    /// itself, on every platform — but it is `__internal`: hidden from
    /// `rex help` and unversioned. If a release renames it the attach fails
    /// with the CLI's own "unknown command" on the tab's ended line.
    static let bridgeCommand = pathPrefix
        + "REX_AUTOSTART=0; export REX_AUTOSTART; exec rex __internal dial-stdio"

    private static let noRexMarker = "MULTIPLEX_NO_REX"
    private static let probeMarker = "MULTIPLEX_REX_PROBE"
    private static let mintMarker = "MULTIPLEX_REX_MINT"
    private static let exitMarker = "MULTIPLEX_REX_EXIT"
    /// The CLI's documented exit status for "the server could not be
    /// reached" — with autostart off, simply "no server is running".
    private static let serverUnreachableExit = 4

    /// How much of the fronted screen each probe reads, from the end. Sized
    /// to cover the tmux probe's 30 captured rows at a wide terminal; the
    /// parser keeps `tailLines` of them.
    private static let tailBytes = 6144
    private static let tailLines = 30

    // MARK: - Probe command

    /// The probe script. Lua, because `rex do` is the one way to make many
    /// API calls over a single connection and get one JSON document back.
    ///
    /// Every call is nil-checked: a block or session can close between two
    /// calls, and `rex.call` then returns nil rather than raising. A session
    /// whose view failed is still listed (a tile with no spine), exactly as
    /// a herdr session without a snapshot is.
    ///
    /// Contains no single quote, so shell-quoting it is one pair of quotes.
    private static let probeScript: String = """
        local T = "com.superlogical.terminal."
        local out = { sessions = {} }
        rex.call("session.attach_all", { event_scope = "session" })
        local list = rex.call("session.list")
        if not list then return out end
        out.ok = true
        for _, s in ipairs(list.sessions or {}) do
          local sid = s.session_id
          local item = { id = sid, label = s.label, windows = {} }
          local apps = rex.call("client.list", { session_id = sid, kinds = { "app" } })
          if apps and apps.clients then item.clients = #apps.clients end
          local view = rex.call("session.view", { session_id = sid })
          if view then
            item.active = view.active_window_id
            local front = nil
            for _, w in ipairs(view.windows or {}) do
              local win = { id = w.window_id, label = w.label, focus = w.focused_block_id, blocks = {} }
              for _, layer in ipairs(w.layers or {}) do
                for _, b in ipairs(layer.blocks or {}) do
                  if b.creator_name == "com.superlogical.terminal" then
                    local a = { session_id = sid, block_id = b.block_id, args = {} }
                    local blk = { id = b.block_id, label = b.label }
                    local t = rex.call(T .. "title", a)
                    if t then blk.title = t.title end
                    local p = rex.call(T .. "process", a)
                    if p and p.foreground then
                      blk.pid = p.foreground.pid
                      blk.name = p.foreground.name
                      blk.argv0 = p.foreground.argv0
                      blk.script = p.foreground.script
                    end
                    local st = rex.call(T .. "program_status", a)
                    if st and st.records then
                      local recs = {}
                      for _, r in ipairs(st.records) do
                        recs[#recs + 1] = { state = r.state, kind = r.kind, app = r.effective_app or r.app }
                      end
                      if #recs > 0 then blk.status = recs end
                    end
                    win.blocks[#win.blocks + 1] = blk
                  end
                end
              end
              if w.window_id == view.active_window_id then front = w.focused_block_id end
              item.windows[#item.windows + 1] = win
            end
            if front then
              local f = rex.call(T .. "format", { session_id = sid, block_id = front,
                args = { format = "text", trim = true, max_bytes = 1 } })
              if f and f.id and f.total then
                local off = 0
                if f.total > \(tailBytes) then off = f.total - \(tailBytes) end
                local rest = rex.call(T .. "blob_read", { session_id = sid, block_id = front,
                  args = { id = f.id, offset = off } })
                if rest then
                  item.tail = rest.data
                  if off > 0 then item.clipped = true end
                end
              elseif f then
                item.tail = f.content
              end
            end
          end
          out.sessions[#out.sessions + 1] = item
        end
        return out
        """
        .split(separator: "\n")
        .map { $0.drop(while: { $0 == " " }) }
        .joined(separator: "\n")

    /// One exec round trip: presence, then the script's JSON, then the CLI's
    /// exit status — which is how "no server running" (4) is told apart from
    /// a probe that genuinely failed.
    ///
    /// `discovering` carries the mixed-host discovery riders. Rex is only
    /// ever a secondary probe today, so every real caller passes `[]`; the
    /// parameter keeps the three probe builders the same shape. The riders
    /// lead, before this probe's own presence guard, for the reason
    /// `BackendDiscovery.riderPrefix` states.
    static func probeCommand(discovering: Set<Host.SessionBackend> = []) -> String {
        BackendDiscovery.riderPrefix(discovering: discovering, excluding: .rex)
            + pathPrefix
            + "command -v rex >/dev/null 2>&1 || { echo \(noRexMarker); exit 0; }; "
            + "echo \(probeMarker); "
            + "\(rexCommand) do -e \(probeScript.shellQuoted) --json 2>/dev/null; "
            + "echo \"\(exitMarker) $?\""
    }

    // MARK: - Parsed result

    /// What a host's Rex server currently looks like, kept apart from
    /// `TmuxState` so the pure layer states Rex truth and the wall chooses
    /// its vocabulary (`tmuxState`).
    enum State: Equatable {
        case rexMissing
        /// `rex` is installed and no server is running, or one is running
        /// with no sessions. Either way there is nothing to show.
        case noServer
        case sessions([TmuxSession])
        case failed(String)
    }

    /// One state a program reported through OSC 7501. The protocol's own
    /// rule for a value this build has never heard of is "treat it as idle";
    /// `.unknown` keeps that case visible so it makes no claim instead.
    enum ProgramState: String, Equatable {
        case idle, working, done, blocked, error, unknown
    }

    /// One program-status record of one block, reduced to what attention
    /// needs: the state, and what a blocked program is waiting for.
    struct ProgramStatus: Equatable {
        var state: ProgramState
        var kind: AttentionKind?
    }

    /// One session's reported statuses — the attention authority, never
    /// persisted (NEEDS YOU is re-earned live).
    struct SessionSignals: Equatable {
        /// Every record of every block in the session, background windows
        /// included: a blocked program the session is not fronting still
        /// needs you.
        var reported: [ProgramStatus] = []
        /// The fronted block's own records — whether that block produced the
        /// session's verdict decides if an alert may borrow its agent name.
        var front: [ProgramStatus] = []
    }

    /// Everything derived from one probe response, shaped like
    /// `TmuxProbe.ParsedProbe` so the connection model consumes either.
    struct ParsedProbe {
        var state: State
        /// Session name → the fronted block's last lines, unclipped.
        var tails: [String: [String]]
        var miniatures: [String: [String]]
        /// Session name → reported statuses.
        var signals: [String: SessionSignals]
        var discovery: [Host.SessionBackend: BackendDiscovery.Result] = [:]
    }

    static func parseProbe(_ output: String) -> ParsedProbe {
        var result = ParsedProbe(
            state: .failed(String(localized: "unreadable rex probe response")),
            tails: [:], miniatures: [:], signals: [:]
        )
        let reading = BackendDiscovery.read(output)
        result.discovery = reading.results

        let json: String
        switch scriptReply(in: reading.remainder, marker: probeMarker) {
        case .rexMissing:
            result.state = .rexMissing
            return result
        case .unreadable:
            return result
        case .exited(let exitCode):
            result.state = exitCode == serverUnreachableExit
                ? .noServer
                : .failed(String(localized: "rex answered with exit status \(String(exitCode))"))
            return result
        case .json(let text):
            json = text
        }
        guard let document = try? JSONDecoder().decode(
            Document.self, from: Data(json.utf8)),
              document.ok == true
        else { return result }

        let entries = document.sessions.elements
        guard !entries.isEmpty else {
            result.state = .noServer
            return result
        }
        let names = sessionNames(for: entries.map { (id: $0.id, label: $0.label ?? "") })
        var sessions: [TmuxSession] = []
        for (index, entry) in entries.enumerated() {
            let name = names[index]
            sessions.append(session(entry: entry, name: name, index: index))
            result.signals[name] = signals(of: entry)
            guard let tail = entry.tail else { continue }
            var tailLines = tail.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            // A read that started mid-screen starts mid-line.
            if entry.clipped == true, !tailLines.isEmpty { tailLines.removeFirst() }
            let visible = Array(TmuxProbe.visibleTail(tailLines).suffix(Self.tailLines))
            guard !visible.isEmpty else { continue }
            result.tails[name] = visible
            result.miniatures[name] = TmuxProbe.miniatureTail(visible)
        }
        result.state = .sessions(sessions)
        return result
    }

    /// What one `rex do` exec answered: the script's JSON, found between
    /// the command's own marker and the exit line it always prints last.
    private enum ScriptReply {
        case rexMissing
        case unreadable
        /// The CLI's own non-zero exit status.
        case exited(Int)
        case json(String)
    }

    private static func scriptReply(in output: String, marker: String) -> ScriptReply {
        guard let range = markerRange(of: marker, in: output) else {
            // The presence guard `exit`s before the marker prints, so the
            // no-rex marker is only ever looked for in a response that has
            // no script output a screen could have forged it into.
            let missing = output.split(separator: "\n", omittingEmptySubsequences: true)
                .contains { $0.trimmingCharacters(in: .whitespaces) == noRexMarker }
            return missing ? .rexMissing : .unreadable
        }
        // The exit line is the LAST thing the command prints, and the JSON
        // above it is indented and quoted, so only the command's own `echo`
        // can start a line with the marker.
        let lines = output[range.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let exitIndex = lines.lastIndex(where: { $0.hasPrefix(exitMarker + " ") }),
              let exitCode = Int(lines[exitIndex].dropFirst(exitMarker.count + 1)
                  .trimmingCharacters(in: .whitespaces))
        else { return .unreadable }
        guard exitCode == 0 else { return .exited(exitCode) }
        return .json(lines[..<exitIndex].joined(separator: "\n"))
    }

    /// The marker as a whole line, at the head of the response or after a
    /// newline — never mid-line.
    private static func markerRange(
        of marker: String, in output: String
    ) -> Range<String.Index>? {
        output.range(of: marker + "\n", options: .anchored)
            ?? output.range(of: "\n" + marker + "\n")
    }

    // MARK: - Wire types (decoded tolerantly — unknown fields ignored)

    /// A JSON array as Rex's Lua encoder writes it: `[…]` when it has
    /// elements, `{}` when it has none (an empty Lua table carries no hint
    /// that it was a list). Anything that is not an array decodes as empty,
    /// and one malformed element drops that element, not the list.
    private struct LuaArray<Element: Decodable>: Decodable {
        var elements: [Element] = []

        init() {}

        init(from decoder: any Decoder) throws {
            guard var container = try? decoder.unkeyedContainer() else { return }
            while !container.isAtEnd {
                if let element = try? container.decode(Element.self) {
                    elements.append(element)
                } else {
                    // Step past what could not be read, or the loop never ends.
                    _ = try? container.decode(Skipped.self)
                }
            }
        }

        private struct Skipped: Decodable {}
    }

    private struct Document: Decodable {
        /// Set by the script only once `session.list` answered.
        var ok: Bool?
        var sessions: LuaArray<SessionEntry>

        enum CodingKeys: String, CodingKey { case ok, sessions }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
            sessions = (try? container.decode(
                LuaArray<SessionEntry>.self, forKey: .sessions)) ?? LuaArray()
        }
    }

    private struct SessionEntry: Decodable {
        var id: String
        var label: String?
        var active: String?
        var clients: Int?
        var tail: String?
        var clipped: Bool?
        var windows: LuaArray<WindowEntry>?
    }

    private struct WindowEntry: Decodable {
        var id: String
        var label: String?
        var focus: String?
        var blocks: LuaArray<BlockEntry>?
    }

    private struct BlockEntry: Decodable {
        var id: String
        var label: String?
        var title: String?
        var pid: Int?
        var name: String?
        var argv0: String?
        var script: String?
        var status: LuaArray<StatusEntry>?
    }

    private struct StatusEntry: Decodable {
        var state: String?
        var kind: String?
        var app: String?
    }

    // MARK: - Mapping (session → TmuxSession, window → window, block → pane)

    /// Display names, unique per host, in the entries' own order.
    ///
    /// A session's NAME is its identity everywhere above this file
    /// (`SessionKey`), but a Rex label is not one. A label that is unique on
    /// the server is used as is; a label shared by several sessions — or an
    /// empty one — is spelled with the tail of the session id, the way the
    /// CLI's own listing tells them apart (`work …8d7863`).
    ///
    /// EVERY holder of a shared label is suffixed, never "all but the
    /// first": when a second `work` appears the first one's identity
    /// changes, which costs it a saved tile position and one attention
    /// baseline. Keeping the bare name on whichever session happened to be
    /// older would instead hand that name — and its baseline — to a
    /// different session the day the older one is closed, and announce a
    /// turn that never ended.
    static func sessionNames(for entries: [(id: String, label: String)]) -> [String] {
        let labels = entries.map { displayLabel($0.label) }
        var counts: [String: Int] = [:]
        for label in labels { counts[label.lowercased(), default: 0] += 1 }
        var seen = Set<String>()
        return entries.indices.map { index in
            let label = labels[index]
            var name = label
            if label.isEmpty || counts[label.lowercased(), default: 0] > 1 {
                let suffix = "…" + shortID(entries[index].id)
                name = label.isEmpty ? suffix : "\(label) \(suffix)"
            }
            // Ids are unique, so this only fires for a response that repeats
            // one; the full id is the tie-break of last resort.
            if !seen.insert(name).inserted {
                name = "\(name) \(entries[index].id)"
                seen.insert(name)
            }
            return name
        }
    }

    /// A label as a tile can show it: control characters removed (a label
    /// is user text and lands in a single-line chassis row), ends trimmed.
    private static func displayLabel(_ label: String) -> String {
        String(String.UnicodeScalarView(label.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespaces)
    }

    /// The id's last six characters — the short form Rex's own listings
    /// print and accept as a target.
    private static func shortID(_ id: String) -> String {
        String(id.suffix(6))
    }

    private static func session(
        entry: SessionEntry, name: String, index: Int
    ) -> TmuxSession {
        TmuxSession(
            name: name,
            windows: windows(of: entry),
            clientCount: max(0, entry.clients ?? 0),
            // Rex states no creation time. The list is in creation order,
            // so the position stands in — `HerdrProbe.isSyntheticCreated`
            // is how a tile knows not to render it as an age, while "most
            // recent" still sorts by it.
            created: Date(timeIntervalSince1970: TimeInterval(index)),
            tmuxID: entry.id,
            serverHost: "",
            backend: .rex
        )
    }

    private static func windows(of entry: SessionEntry) -> [TmuxWindow] {
        let entries = entry.windows?.elements ?? []
        // Fail open to the first window when the server named none active:
        // the active window carries the tile's agent/title line.
        let activeID = entry.active ?? entries.first?.id
        return entries.enumerated().map { offset, window in
            let blocks = window.blocks?.elements ?? []
            let focusID = window.focus ?? blocks.first?.id
            let panes = blocks.enumerated().map { blockOffset, block in
                TmuxPane(
                    index: blockOffset,
                    isActive: block.id == focusID,
                    tmuxID: block.id,
                    pid: block.pid ?? 0,
                    tty: "",
                    command: block.name ?? "",
                    title: block.title ?? "",
                    agent: agent(of: block)
                )
            }
            var mapped = TmuxWindow(
                // Tab order, counted from one as Rex's own `-w 2` does.
                index: offset + 1,
                name: windowName(
                    window, position: offset + 1,
                    focusedBlockLabel: blocks.first { $0.id == focusID }?.label),
                isActive: window.id == activeID,
                hasBell: false,
                hasActivity: false,
                panes: panes
            )
            if let active = panes.first(where: \.isActive) {
                mapped.agent = active.agent
                mapped.paneTitle = active.title
            }
            return mapped
        }
    }

    /// A window nobody named carries a generated label built from its own
    /// id (`Window 262b0b23`, observed on preview.19) — noise on a spine
    /// line. Only that exact shape is replaced, so a label someone chose is
    /// never second-guessed, and a server that generates labels differently
    /// simply shows its own.
    ///
    /// The stand-in is the focused block's label (`shell`, or whatever the
    /// block was named — `agent`, `logs`): the nearest thing Rex has to
    /// tmux naming a window after what runs in it. `window N` is the last
    /// resort only, because the spine already leads each line with N and
    /// the first headless run read `1 WINDOW 1`.
    private static func windowName(
        _ window: WindowEntry, position: Int, focusedBlockLabel: String?
    ) -> String {
        let label = displayLabel(window.label ?? "")
        let generated = "Window " + window.id.suffix(8)
        guard label.isEmpty || label == generated else { return label }
        let blockLabel = displayLabel(focusedBlockLabel ?? "")
        return blockLabel.isEmpty ? String(localized: "window \(position)") : blockLabel
    }

    /// Which agent owns a block. The foreground process is the authority;
    /// its OSC title is the tmux probe's own cheap pass; the program's
    /// reported `app` is consulted last, because a status record outlives
    /// the program that wrote it (`done` survives exit by design).
    private static func agent(of block: BlockEntry) -> AgentKind? {
        if let direct = AgentSignature.classify(
            command: block.name ?? "", title: block.title ?? "") {
            return direct
        }
        // `script` names what an interpreter is running (`node …/claude`),
        // the shape `AgentSignature.match` already knows how to read.
        let argv = [block.argv0 ?? block.name, block.script]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if let matched = AgentSignature.match(argv: argv) { return matched }
        return (block.status?.elements ?? []).lazy
            .compactMap(\.app)
            .compactMap(AgentKind.init(programStatusApp:))
            .first
    }

    private static func signals(of entry: SessionEntry) -> SessionSignals {
        var signals = SessionSignals()
        let windows = entry.windows?.elements ?? []
        let activeID = entry.active ?? windows.first?.id
        for window in windows {
            let blocks = window.blocks?.elements ?? []
            let focusID = window.focus ?? blocks.first?.id
            for block in blocks {
                let statuses = (block.status?.elements ?? []).map(programStatus(from:))
                signals.reported += statuses
                if window.id == activeID, block.id == focusID {
                    signals.front = statuses
                }
            }
        }
        return signals
    }

    private static func programStatus(from entry: StatusEntry) -> ProgramStatus {
        // The protocol's three kinds; `auth` (a password or token) is a
        // prompt the user has to answer, which is what `.question` means
        // here. Absent or unrecognized stays nil — the generic prompt.
        let kind: AttentionKind? = switch entry.kind {
        case "permission": .permission
        case "question", "auth": .question
        default: nil
        }
        return ProgramStatus(
            state: ProgramState(rawValue: entry.state ?? "") ?? .unknown,
            kind: kind
        )
    }

    // MARK: - Open Terminal menu

    /// One row of a Rex tile's Open Terminal menu: the window, then what
    /// tells its terminals apart — the program's own title, else the
    /// foreground command, else the terminal's position in the window.
    static func terminalMenuTitle(window: TmuxWindow, pane: TmuxPane) -> String {
        let what = [pane.title, pane.command]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            ?? String(localized: "terminal \(pane.index + 1)")
        return "\(window.name) — \(what)"
    }

    /// The tab mode for one named terminal of a session — the menu row's
    /// press. nil when the record carries no usable session id.
    static func attachMode(
        session: TmuxSession, window: TmuxWindow, pane: TmuxPane
    ) -> TerminalRoute.Mode? {
        guard bakeableSessionID(session.tmuxID), !pane.tmuxID.isEmpty else { return nil }
        return .rexAttach(
            sessionName: session.name,
            sessionID: session.tmuxID,
            block: RexBlockRef(id: pane.tmuxID, label: window.name)
        )
    }

    // MARK: - Session actions

    /// A session id the app may splice into a command: `session:` and a
    /// UUID's characters, nothing a shell could reinterpret. What the parser
    /// reports is truth; what reaches a shell line is vetted here.
    static func bakeableSessionID(_ id: String) -> Bool {
        let prefix = "session:"
        guard id.hasPrefix(prefix), id.utf8.count <= 64 else { return false }
        let rest = id.dropFirst(prefix.count)
        return !rest.isEmpty && rest.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9")
                || (scalar >= "a" && scalar <= "f")
                || (scalar >= "A" && scalar <= "F")
                || scalar == "-"
        }
    }

    /// The deck tile's destructive close. Aimed at the session's ID, never
    /// its label: labels are shared, and `rex kill work` on a server with
    /// two of them refuses both. nil when the record carries no usable id —
    /// a tile restored from a snapshot always has one, so this is only a
    /// response that never named it.
    static func killCommand(for session: TmuxSession) -> String? {
        guard bakeableSessionID(session.tmuxID) else { return nil }
        return pathPrefix
            + "\(rexCommand) kill \(session.tmuxID.shellQuoted) >/dev/null 2>&1; true"
    }

    /// The discovery rider's list verb, without the PATH export: one id per
    /// line. Ids rather than `ls --json`, which is pretty-printed across
    /// lines and would need a document parser for what is only ever counted.
    static let sessionListVerb = "\(rexCommand) ls -q 2>/dev/null || true"

    /// The session ids in a `ls -q` answer. Anything that is not an id —
    /// login-shell noise, a warning — is not a session.
    static func parseSessionIDs(_ lines: [some StringProtocol]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(bakeableSessionID)
    }

    // MARK: - New session

    /// The server's own limit is 128 characters; this leaves room for the
    /// `-N` a taken label gains.
    private static let maxLabelLength = 120
    /// The environment variable a shell-resolved start directory rides in.
    private static let directoryVariable = "MULTIPLEX_REX_CWD"

    /// The label a new session is asked for: read the way a label coming
    /// back is (`displayLabel` — so the name the tab is opened under is the
    /// name the next probe reports), clamped, and never empty. An empty
    /// label makes the server invent one (`quiet-meadow`), which nothing
    /// here could have predicted.
    static func sessionLabel(base: String) -> String {
        let label = String(displayLabel(base).prefix(maxLabelLength))
            .trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "session" : label
    }

    /// `sessionLabel`, respelled `-2`, `-3`, … while taken — tmux's own
    /// scheme. Compared without case, as `sessionNames` counts: two labels
    /// that differ only by case would both be shown with an id tail.
    static func uniqueSessionLabel(base: String, existing: some Sequence<String>) -> String {
        let base = sessionLabel(base: base)
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)".lowercased()) { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// The mint script. One connection: read the live labels, settle the
    /// name against them (Rex itself would happily create a second `work`,
    /// and both would then be shown with an id tail), resolve the start
    /// directory, create the session with one shell terminal, and report
    /// the id and the label the server actually stored.
    ///
    /// The source session's directory is its fronted terminal's, the same
    /// one the tile shows; it wins over an explicit directory, and every
    /// miss is $HOME — `TmuxProbe.newSessionCommand`'s own precedence.
    ///
    /// Contains no single quote, so shell-quoting it is one pair of quotes.
    private static let mintScript: String = """
        local T = "com.superlogical.terminal."
        local a = rex.args or {}
        local function text(v) if type(v) == "string" then return v end return "" end
        rex.call("session.attach_all", { event_scope = "session" })
        local list = rex.call("session.list")
        if not list then return { ok = false } end
        local taken = {}
        for _, s in ipairs(list.sessions or {}) do taken[string.lower(text(s.label))] = true end
        local label = text(a.label)
        if taken[string.lower(label)] then
          local n = 2
          while taken[string.lower(label .. "-" .. n)] do n = n + 1 end
          label = label .. "-" .. n
        end
        local cwd = ""
        local source = text(a.source)
        if source ~= "" then
          local view = rex.call("session.view", { session_id = source })
          if view then
            for _, w in ipairs(view.windows or {}) do
              if w.window_id == view.active_window_id and w.focused_block_id then
                local p = rex.call(T .. "process", { session_id = source, block_id = w.focused_block_id, args = {} })
                if p and p.foreground then cwd = text(p.foreground.cwd) end
              end
            end
          end
        elseif os and os.getenv then
          cwd = text(os.getenv("\(directoryVariable)"))
        end
        local block = { flavor = T .. "shell" }
        local options = {}
        if cwd ~= "" then options.cwd = cwd end
        if text(a.input) ~= "" then options.initial_input = text(a.input) end
        if next(options) then block.options = options end
        local made = rex.call("session.create", { label = label, initial_windows = { { layout = { block = block } } } })
        if not made or not made.session_id then return { ok = false } end
        local after = rex.call("session.list")
        for _, s in ipairs((after and after.sessions) or {}) do
          if s.session_id == made.session_id then label = text(s.label) end
        end
        return { ok = true, id = made.session_id, label = label }
        """
        .split(separator: "\n")
        .map { $0.drop(while: { $0 == " " }) }
        .joined(separator: "\n")

    /// Create a session with one shell terminal, over the control
    /// connection — the Rex arm of `HostConnectionModel.createSession`.
    ///
    /// - `label`: what `sessionLabel` made of the requested name. The
    ///   script settles it against the server's live labels.
    /// - `sourceSessionID`: start where that session's fronted terminal is.
    /// - `directory`: an explicit start directory, consulted only without a
    ///   source. The SHELL resolves it — `~`, a path relative to $HOME, a
    ///   directory that is not there — because the server takes `cwd`
    ///   literally; what it resolved to rides the environment into the
    ///   script, and nothing at all when it does not exist.
    /// - `lines`: typed into the fresh shell in order, each followed by
    ///   Enter — the setup script, then the launch line. Same shell, so
    ///   what the first exports is live for the second.
    ///
    /// The values the user typed travel as ONE JSON argument, never as
    /// script text, so no label or prompt can become Lua. Always exits 0
    /// (Citadel throws on a non-zero status); the CLI's own status is the
    /// last line, as in the probe.
    static func mintCommand(
        label: String, inDirectoryOf sourceSessionID: String?,
        startingIn directory: String?, typing lines: [String]
    ) -> String {
        var arguments = ["label": label]
        var environment = ""
        var resolve = ""
        if let sourceSessionID {
            arguments["source"] = sourceSessionID
        } else if let directory {
            resolve = "d=\(directory.shellQuotedDirectory); "
                + "d=$(CDPATH= cd -- \"$d\" 2>/dev/null && pwd); "
            environment = "\(directoryVariable)=\"$d\" "
        }
        let input = lines.map { $0 + "\r" }.joined()
        if !input.isEmpty { arguments["input"] = input }
        let json = (try? JSONSerialization.data(
            withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes]
        )).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return pathPrefix
            + "command -v rex >/dev/null 2>&1 || { echo \(noRexMarker); exit 0; }; "
            + resolve
            + "echo \(mintMarker); "
            + environment
            + "\(rexCommand) do -e \(mintScript.shellQuoted) --args \(json.shellQuoted)"
            + " --json 2>/dev/null; "
            + "echo \"\(exitMarker) $?\""
    }

    /// How a mint ended.
    enum MintOutcome: Equatable {
        /// `name` is the session's name as the next probe will report it.
        case created(name: String, id: String)
        case rexMissing
        /// `rex` is installed and no server is running. Multiplex does not
        /// start one, so there was nothing to create the session in.
        case noServer
        case failed
    }

    private struct MintReply: Decodable {
        var ok: Bool?
        var id: String?
        var label: String?
    }

    static func parseMint(_ output: String) -> MintOutcome {
        switch scriptReply(in: output, marker: mintMarker) {
        case .rexMissing:
            return .rexMissing
        case .unreadable:
            return .failed
        case .exited(let exitCode):
            return exitCode == serverUnreachableExit ? .noServer : .failed
        case .json(let json):
            guard let reply = try? JSONDecoder().decode(MintReply.self, from: Data(json.utf8)),
                  reply.ok == true, let id = reply.id, bakeableSessionID(id)
            else { return .failed }
            // Spelled as `sessionNames` would spell a session that is alone
            // under its label — which the script just made true.
            let label = displayLabel(reply.label ?? "")
            return .created(name: label.isEmpty ? "…" + shortID(id) : label, id: id)
        }
    }

    // MARK: - Attention

    /// A session tile's attention when its programs report status: the fold
    /// of every record in the session. Any blocked program needs you; else
    /// any working one means busy; else anything that vouched for itself
    /// means idle; nothing but `unknown` makes no claim. `done` and `error`
    /// fold to idle on purpose — handing the tracker that busy → idle edge
    /// is what announces the turn exactly once, herdr's own rule.
    static func sessionAgentState(
        _ statuses: some Sequence<ProgramStatus>
    ) -> PaneAgentState? {
        var sawWorking = false
        var sawKnown = false
        var blocked: AttentionKind?
        for status in statuses {
            switch status.state {
            case .blocked:
                // A question outranks a bare permission prompt only in that
                // the first blocked record names the kind; either way the
                // tile needs you.
                if blocked == nil { blocked = status.kind ?? .permission }
            case .working: sawWorking = true
            case .idle, .done, .error: sawKnown = true
            case .unknown: break
            }
        }
        if let blocked { return .needsYou(blocked) }
        if sawWorking { return .busy }
        return sawKnown ? .idle : nil
    }

    /// Whether the fronted block's own records agree with the session-level
    /// verdict. Alert metadata only: a blocked background window must not
    /// borrow the fronted block's agent name or screen.
    static func frontProducedSessionState(
        _ state: PaneAgentState?, front: [ProgramStatus]
    ) -> Bool {
        guard let state, !front.isEmpty else { return false }
        return sessionAgentState(front) == state
    }
}

extension RexProbe.State {
    /// The wall consumes `TmuxState`; Rex states fold onto it. Rex is only
    /// ever a secondary, so `missing` and `no server` render nothing — the
    /// user asked to see its sessions if they exist.
    var tmuxState: TmuxState {
        switch self {
        case .rexMissing: .tmuxMissing
        case .noServer: .noServer
        case .sessions(let sessions): .sessions(sessions)
        case .failed(let message): .failed(message)
        }
    }
}

extension AgentKind {
    /// The `app` a program names itself with in an OSC 7501 report. The
    /// protocol's own example is `claude-code`; every other spelling here
    /// is the agent's command name, the only thing it can plausibly report.
    /// Unrecognized apps (`cargo`, `terraform`) are programs, not agents.
    init?(programStatusApp app: String) {
        switch app.lowercased() {
        case "claude-code", "claude": self = .claudeCode
        case "codex": self = .codex
        case "pi": self = .pi
        case "grok": self = .grok
        case "antigravity", "agy": self = .antigravity
        case "hermes", "hermes-agent": self = .hermes
        default: return nil
        }
    }
}
