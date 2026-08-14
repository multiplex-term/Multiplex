import Foundation

/// One pane's rectangle in the attached client's screen cells, both ends
/// inclusive — the select-text mode's clamp for local selection. tmux
/// answers it from `list-panes -F` geometry; herdr from its snapshot's
/// layout rects (border-inset by the viewport oracle). Screen-relative on
/// purpose: the pane is fixed on screen while the buffer may scroll.
struct PaneScreenRect: Equatable, Sendable {
    var columns: ClosedRange<Int>
    var rows: ClosedRange<Int>

    func contains(col: Int, row: Int) -> Bool {
        columns.contains(col) && rows.contains(row)
    }

    /// The dominant screen direction from one pane to another (rect-center
    /// comparison) — herdr's only focus verb is directional, so this is
    /// how a two-pane layout's "other" pane gets focused.
    static func direction(from: PaneScreenRect, to: PaneScreenRect) -> String? {
        let dx = (to.columns.lowerBound + to.columns.upperBound)
            - (from.columns.lowerBound + from.columns.upperBound)
        let dy = (to.rows.lowerBound + to.rows.upperBound)
            - (from.rows.lowerBound + from.rows.upperBound)
        if dx == 0 && dy == 0 { return nil }
        if abs(dx) >= abs(dy) {
            return dx > 0 ? "right" : "left"
        }
        return dy > 0 ? "down" : "up"
    }
}

/// One visible pane's identity + rectangle + focus flag, both backends'
/// geometry answers normalized: what the select-text mode picks its clamp
/// (and its focus switch) from.
struct PaneScreenRectEntry: Equatable, Sendable {
    var id: String
    var rect: PaneScreenRect
    var isFocused: Bool
}

/// Requires two consecutive identical geometry answers before the
/// select-text clamp may apply. Both backends size ONE shared viewport to
/// the last client that typed or resized (herdr 0.8.0 measured 2026-08-10:
/// an attach or keystroke moves it, snapshots lag the move by up to
/// ~200 ms; tmux `window-size latest` behaves alike), so the snapshot
/// fetched right after the entry gesture — itself the input that
/// reclaims the viewport — can describe the OTHER client's geometry.
/// An agreed pair proves the viewport settled; persistent disagreement
/// (both clients typing) applies nothing, keeping the documented
/// fail-soft whole-screen behavior instead of a wrong clamp.
struct PaneClampSettle {
    static let maxRounds = 3
    static let retryDelayMilliseconds = 300

    private var previous: [PaneScreenRectEntry]?

    /// Feed one answer; returns the settled rects once two consecutive
    /// answers agree, nil while the viewport is still moving.
    mutating func offer(_ panes: [PaneScreenRectEntry]) -> [PaneScreenRectEntry]? {
        let agreed = previous == panes
        previous = panes
        return agreed ? panes : nil
    }
}

/// Builds and parses the `tmux` commands used to discover remote sessions.
/// Pure functions — exercised directly by unit tests.
///
/// Format design: tmux sanitizes control characters in `-F` output (0x1F
/// becomes `_`) — and, unless it is in UTF-8 mode, every multibyte character
/// too, which is why every invocation goes through `tmuxCommand`. Fields are
/// space-separated with the one variable-length
/// field — the name — placed LAST. Fixed fields (`$N` session ids, numeric
/// flags) can never contain spaces, and tail-rejoining absorbs any spaces
/// inside names. Session lines start with S, window lines with W, pane
/// lines with P (variable-length pane *title* last — it feeds agent
/// detection, see `AgentSignature`). After the MULTIPLEX_PS sentinel comes
/// a process table (clipped host-side to the pane process subtrees) for the
/// pane-tree walk, and after MULTIPLEX_TAILS every session's active-pane
/// capture for the wall miniatures — one exec round-trip carries it all.
/// Every stage degrades silently — a host where list-panes or ps misbehaves
/// just loses agent detection, never its session list.
enum TmuxProbe {
    private struct PaneInfo {
        var sessionID: String
        var windowIndex: Int
        var pane: TmuxPane
    }

    private struct WindowKey: Hashable {
        var sessionID: String
        var windowIndex: Int
    }

    /// Non-interactive SSH exec often has a minimal PATH, so common tmux
    /// locations (Homebrew, /usr/local) are appended before any command.
    /// Shared with the mosh bootstrap, which has the same problem for
    /// mosh-server (and for the tmux it wraps).
    static let pathPrefix = RemoteCommandEnvironment.pathPrefix

    /// Every tmux invocation the app makes over an exec channel. An SSH *exec*
    /// channel inherits no locale — `LANG` and `LC_ALL` are both empty — so
    /// tmux falls back to the C locale and its `-F` writer replaces every
    /// multibyte character with `_`, exactly as it does control characters.
    /// That silently gutted three things the app then acted on: the pane title
    /// the deck spine shows (`✳ Claude Code` → `_ Claude Code`), the Braille
    /// spinner `AgentAttention` reads RUNNING out of (U+2800…U+28FF → `_`, so
    /// a title-only classification could never see one) and `AgentSignature`'s
    /// `π - ` prefix for Pi, and `#{pane_current_path}` — a non-ASCII cwd
    /// resolved to a directory that does not exist, aiming file drops at the
    /// wrong place. `-u` is tmux's own "assume UTF-8" flag and needs no locale
    /// to exist on the remote, which matters: Alpine ships none and macOS has
    /// no `C.UTF-8`. Verified against the dev harness 2026-07-26.
    static let tmuxCommand = "tmux -u"

    /// One exec round-trip carrying everything a wall tick needs: session/
    /// window/pane listings, the (pane-subtree-clipped) ps table for agent
    /// detection, and — after the MULTIPLEX_TAILS sentinel — every session's
    /// active-pane capture for the live miniatures. A second capture exec
    /// used to follow the probe; folding it in halves the per-tick channel
    /// opens, login-shell spawns, and round-trips.
    /// The probe proper. Callers go through `probeCommand(discovering:)`,
    /// which prepends the other backend's discovery rider.
    private static let baseProbeCommand: String = {
        let sessionFormat = "S #{session_id} #{session_attached} #{session_created} #{session_name}"
        let windowFormat = "W #{session_id} #{window_index} #{window_active} "
            + "#{window_bell_flag} #{window_activity_flag} #{window_name}"
        let paneLineFormat = paneFormat(tag: "P")
        return pathPrefix
            + "command -v tmux >/dev/null 2>&1 || { echo MULTIPLEX_NO_TMUX; exit 0; }; "
            // The server's own hostname — the exact string tmux seeded every
            // untouched pane title with (see `PaneTitleDisplay`). Its own
            // statement, not a link in the `&&` chain: a host whose tmux
            // declines to answer must still get its session list. `#{host}`
            // is a server-global, so the pane-format rule about
            // display-message (which renders `pane_*` empty for outside
            // clients on 3.6a) does not apply — verified headless over exec.
            + "\(tmuxCommand) display-message -p 'H #{host}' 2>/dev/null; "
            + "\(tmuxCommand) list-sessions -F '\(sessionFormat)' 2>/dev/null "
            + "&& \(tmuxCommand) list-windows -a -F '\(windowFormat)' 2>/dev/null "
            // Keep the pane listing in one shell variable: it is printed for
            // the parser and reused to derive every pane-process root,
            // avoiding a second list-panes call in the process stage.
            + "&& panes=$(\(tmuxCommand) list-panes -a -F '\(paneLineFormat)' 2>/dev/null) "
            + "&& printf '%s\\n' \"$panes\" "
            + "&& { echo MULTIPLEX_PS; \(psPaneSubtreeCommand); } "
            + "|| true; "
            + "echo MULTIPLEX_TAILS; "
            + "\(tmuxCommand) list-sessions -F '#{session_id}' 2>/dev/null | while IFS= read -r s; do "
            + "echo \"MPXS $s\"; "
            + "\(tmuxCommand) capture-pane -p -t \"$s\" -S -\(captureDepth) 2>/dev/null; "
            + "done; echo MPXE"
    }()

    /// One exec round-trip, optionally carrying a discovery rider for each
    /// backend in `discovering` — the mixed-host offer's whole cost
    /// (`BackendDiscovery`). The rider replaced this probe's old
    /// `command -v herdr` presence check: it answers presence *and* session
    /// count for the same ~1 ms, so a primary probe always asks for
    /// `[.herdr]` and only a SECONDARY full probe passes `[]` (it must not
    /// rediscover the primary that scheduled it).
    ///
    /// Deliberately not memoized: two string appends of ~200 bytes once per
    /// 5 s tick is beneath measurement, and a mutable static cache would
    /// need concurrency annotation to buy it.
    static func probeCommand(
        discovering: Set<Host.SessionBackend> = [.herdr]
    ) -> String {
        BackendDiscovery.riderPrefix(discovering: discovering, excluding: .tmux)
            + baseProbeCommand
    }

    /// Everything derived from one probe response. Keeping this pure bundle
    /// together lets callers move the process-tree walk, capture trimming,
    /// and miniature clipping off the UI actor in one hop.
    struct ParsedProbe {
        var state: TmuxState
        var tails: [String: [String]]
        var miniatures: [String: [String]]
        /// What the discovery riders found, keyed by the backend asked.
        /// Empty when the response carried no rider.
        var discovery: [Host.SessionBackend: BackendDiscovery.Result] = [:]

        /// herdr is installed on this host — the dead-tmux tile's switch
        /// hint. Presence only; nothing reads it while tmux is healthy.
        var herdrPresent: Bool { discovery[.herdr]?.isInstalled ?? false }
    }

    static func parseProbe(_ output: String) -> ParsedProbe {
        // One pass reads the riders' answers and hands back the response
        // without their regions, so the record walker and the tails slicer
        // below can never see another backend's list format.
        let reading = BackendDiscovery.read(output)
        let discovery = reading.results
        let output = reading.remainder
        let state = parse(output)
        guard case .sessions(let sessions) = state else {
            return ParsedProbe(
                state: state, tails: [:], miniatures: [:],
                discovery: discovery
            )
        }
        let tails = parseTails(output, sessions: sessions)
        return ParsedProbe(
            state: state,
            tails: tails,
            miniatures: tails.mapValues(miniatureTail),
            discovery: discovery
        )
    }

    /// One host-wide process snapshot, clipped to every tmux pane subtree
    /// before output crosses SSH. The pane listing already carries each root
    /// PID, so a queue walk over one ps snapshot avoids both another tmux
    /// process and awk's repeated whole-table closure. Do not add ps's `tty`
    /// column here: collecting it costs ~70-110 ms on macOS even though the
    /// roots already give us stricter scope. Arguments are clipped to
    /// argv[0]/argv[1] territory. POSIX ps/awk only; failure loses the
    /// fallback signal, never direct comm/title detection.
    private static let psPaneSubtreeCommand =
        #"roots=$(printf '%s\n' "$panes" | awk '$1=="P"{printf "%s ",$7}'); "#
        + #"ps -eo pid=,ppid=,args= 2>/dev/null | awk -v roots="$roots" '"#
        + "BEGIN{n=split(roots,r,\" \");for(i=1;i<=n;i++)"
        + "if(r[i]!=\"\")q[++tail]=r[i]} "
        + "NF>=3{pid=$1;parent=$2;a=$3;for(i=4;i<=NF;i++)a=a\" \"$i;"
        + "line[pid]=pid\" \"parent\" \"substr(a,1,120);"
        + "children[parent]=children[parent]\" \"pid} "
        + "END{while(head<tail){pid=q[++head];if(seen[pid]++)continue;"
        + "if(pid in line)print line[pid];n=split(children[pid],c,\" \");"
        + "for(i=1;i<=n;i++)if(c[i]!=\"\")q[++tail]=c[i]}}'"

    /// Fixed fields precede the only variable-length field (pane_title).
    /// pane_id makes linked-window duplicates and pane switches stable;
    /// pane_tty enables the scoped process fallback.
    private static func paneFormat(tag: String) -> String {
        "\(tag) #{session_id} #{window_index} #{pane_index} #{pane_active} "
            + "#{pane_id} #{pane_pid} #{pane_tty} #{pane_current_command} #{pane_title}"
    }

    /// Parse combined probe output into a `TmuxState`.
    static func parse(_ output: String) -> TmuxState {
        struct SessionInfo {
            var name: String
            var clients: Int
            var created: Date
        }
        var sessions: [String: SessionInfo] = [:]
        var order: [String] = []
        var serverHost = ""
        var windows: [String: [TmuxWindow]] = [:]
        var panes: [PaneInfo] = []
        var psRows: [PSRow] = []
        var inPSSection = false

        // String.split is eager. Slice before the capture section first so a
        // large wall repaint is not tokenized once as probe records and then
        // again as terminal lines.
        let records = tailsMarker(in: output).map { output[..<$0.lowerBound] }
            ?? output[...]
        for line in records.split(separator: "\n") {
            if line == "MULTIPLEX_NO_TMUX" { return .tmuxMissing }
            if line == "MULTIPLEX_PS" {
                inPSSection = true
                continue
            }
            if inPSSection {
                if let row = parsePSRow(line) { psRows.append(row) }
                continue
            }
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
                .map(String.init)
            switch fields.first {
            case "H" where fields.count >= 2:
                serverHost = fields[1...].joined(separator: " ")
            case "S" where fields.count >= 5:
                let id = fields[1]
                if sessions[id] == nil { order.append(id) }
                sessions[id] = SessionInfo(
                    name: fields[4...].joined(separator: " "),
                    clients: Int(fields[2]) ?? 0,
                    created: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0)
                )
            case "W" where fields.count >= 7:
                let window = TmuxWindow(
                    index: Int(fields[2]) ?? 0,
                    name: fields[6...].joined(separator: " "),
                    isActive: fields[3] == "1",
                    hasBell: fields[4] == "1",
                    hasActivity: fields[5] == "1"
                )
                windows[fields[1], default: []].append(window)
            case "P":
                if let pane = parsePane(fields, tag: "P") { panes.append(pane) }
            default:
                continue
            }
        }

        guard !order.isEmpty else { return .noServer }

        // Resolve every pane from one shared process index. FleetWall reads
        // all of them; a terminal helper still follows only the active pane.
        let unresolvedPIDs = panes.compactMap { info -> Int? in
            AgentSignature.classify(
                command: info.pane.command,
                title: info.pane.title
            ) == nil ? info.pane.pid : nil
        }
        let treeAgents = AgentSignature.agentsInTrees(
            rows: psRows,
            panePIDs: unresolvedPIDs
        )
        var panesByWindow: [WindowKey: [TmuxPane]] = [:]
        for info in panes {
            var pane = info.pane
            pane.agent = AgentSignature.classify(command: pane.command, title: pane.title)
                ?? treeAgents[pane.pid]
            panesByWindow[
                WindowKey(sessionID: info.sessionID, windowIndex: info.windowIndex),
                default: []
            ].append(pane)
        }
        for sessionID in Array(windows.keys) {
            guard var sessionWindows = windows[sessionID] else { continue }
            for index in sessionWindows.indices {
                let key = WindowKey(
                    sessionID: sessionID,
                    windowIndex: sessionWindows[index].index
                )
                guard var windowPanes = panesByWindow[key] else { continue }
                windowPanes.sort { $0.index < $1.index }
                sessionWindows[index].panes = windowPanes
                if let active = windowPanes.first(where: \.isActive) {
                    // Mirror the legacy fields so old snapshots and the
                    // attention path retain their original representation.
                    sessionWindows[index].agent = active.agent
                    sessionWindows[index].paneTitle = active.title
                }
            }
            windows[sessionID] = sessionWindows
        }

        let list = order.compactMap { id -> TmuxSession? in
            guard let info = sessions[id] else { return nil }
            return TmuxSession(
                name: info.name,
                windows: (windows[id] ?? []).sorted { $0.index < $1.index },
                clientCount: info.clients,
                created: info.created,
                tmuxID: id,
                serverHost: serverHost
            )
        }
        return .sessions(list)
    }

    /// Tiny focused-session query used between full fleet ticks. It lists
    /// only the current window's panes and carries no capture or process
    /// table; callers request a TTY-scoped fallback only when direct signals
    /// and their short cache are inconclusive.
    static func activePaneCommand(sessionName: String) -> String {
        pathPrefix
            + "\(tmuxCommand) list-panes -t \("=\(sessionName)".shellQuoted) "
            + "-F '\(paneFormat(tag: "A"))' 2>/dev/null"
    }

    static func parseActivePane(_ output: String) -> TmuxPane? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
                .map(String.init)
            if let info = parsePane(fields, tag: "A"), info.pane.isActive {
                return info.pane
            }
        }
        return nil
    }

    /// Every visible pane's screen rectangle — what the select-text mode
    /// picks its clamp (pressed pane first, focused pane otherwise) from.
    /// Current window only (that is what the attached client shows);
    /// `list-panes -F`, never `display-message` (3.6a renders `pane_*`
    /// empty for outside clients). tmux pane geometry is content cells in
    /// the client's coordinate space — no border inset needed.
    static func paneRectsCommand(sessionName: String) -> String {
        pathPrefix
            + "\(tmuxCommand) list-panes -t \("=\(sessionName)".shellQuoted) "
            + "-F 'MPXRECT #{pane_id} #{pane_active} #{pane_left} #{pane_top} "
            + "#{pane_width} #{pane_height}' 2>/dev/null"
    }

    static func parsePaneRects(_ output: String) -> [PaneScreenRectEntry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 7, fields[0] == "MPXRECT",
                  fields[1].hasPrefix("%"),
                  let left = Int(fields[3]), let top = Int(fields[4]),
                  let width = Int(fields[5]), let height = Int(fields[6]),
                  left >= 0, top >= 0, width > 0, height > 0
            else { return nil }
            return PaneScreenRectEntry(
                id: fields[1],
                rect: PaneScreenRect(
                    columns: left...(left + width - 1),
                    rows: top...(top + height - 1)
                ),
                isFocused: fields[2] == "1"
            )
        }
    }

    /// Every visible pane's screen rectangle plus its working directory —
    /// the file-viewer anchor's one exec. A pressed path resolves against
    /// the pane under the finger (`parsePathAnchorDirectory`), not the
    /// active pane: in a split, the two panes' cwds routinely differ, and
    /// "relative to the pane's directory" must mean the pane that printed
    /// the path. Same `list-panes -F` discipline as `paneRectsCommand`
    /// (3.6a renders `pane_*` empty for `display-message` from outside
    /// clients); the path rides last because it may contain spaces.
    static func pathAnchorCommand(sessionName: String) -> String {
        pathPrefix
            + "\(tmuxCommand) list-panes -t \("=\(sessionName)".shellQuoted) "
            + "-F 'MPXPANE #{pane_active} #{pane_left} #{pane_top} "
            + "#{pane_width} #{pane_height} #{pane_current_path}' 2>/dev/null"
    }

    struct PanePathAnchor: Equatable {
        var rect: PaneScreenRect
        var isActive: Bool
        var cwd: String?
    }

    static func parsePathAnchors(_ output: String) -> [PanePathAnchor] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(
                separator: " ", maxSplits: 6, omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 7, fields[0] == "MPXPANE",
                  let left = Int(fields[2]), let top = Int(fields[3]),
                  let width = Int(fields[4]), let height = Int(fields[5]),
                  left >= 0, top >= 0, width > 0, height > 0
            else { return nil }
            let cwd = fields[6].trimmingCharacters(in: .whitespaces)
            return PanePathAnchor(
                rect: PaneScreenRect(
                    columns: left...(left + width - 1),
                    rows: top...(top + height - 1)
                ),
                isActive: fields[1] == "1",
                cwd: cwd.hasPrefix("/") ? cwd : nil
            )
        }
    }

    /// The cwd a pressed path resolves against: the pane containing the
    /// pressed screen cell when one does (and answered a cwd), the active
    /// pane otherwise — which is also the no-cell answer for the + TAB
    /// browse summon and the debug hooks.
    static func parsePathAnchorDirectory(
        _ output: String, atScreenCell cell: (col: Int, row: Int)?
    ) -> String? {
        let anchors = parsePathAnchors(output)
        if let cell,
           let pressed = anchors.first(where: {
               $0.rect.contains(col: cell.col, row: cell.row)
           }),
           let cwd = pressed.cwd {
            return cwd
        }
        return anchors.first(where: \.isActive)?.cwd
    }

    /// Focus one pane by id — what a click would have done had the
    /// select-text mode not kept the tap local. `%id` pane targets are
    /// exact on 3.6a (only `=name` pane targets misbehave).
    static func focusPaneCommand(paneID: String) -> String {
        pathPrefix + "\(tmuxCommand) select-pane -t \(paneID.shellQuoted) 2>/dev/null"
    }

    /// Process rows for one pane TTY. This is separate from the one-second
    /// pane query and runs only on a pane/foreground-command change or short
    /// cache expiry, not every tick.
    static func paneProcessCommand(tty: String) -> String? {
        let terminal = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard !terminal.isEmpty else { return nil }
        return pathPrefix
            + "ps -t \(terminal.shellQuoted) -o pid=,ppid=,args= 2>/dev/null "
            + "| cut -c1-120"
    }

    static func parsePSRows(_ output: String) -> [PSRow] {
        output.split(separator: "\n").compactMap(parsePSRow)
    }

    private static func parsePane(_ fields: [String], tag: String) -> PaneInfo? {
        guard fields.first == tag, fields.count >= 9,
              let windowIndex = Int(fields[2]),
              let paneIndex = Int(fields[3]),
              let pid = Int(fields[6])
        else { return nil }
        return PaneInfo(
            sessionID: fields[1],
            windowIndex: windowIndex,
            pane: TmuxPane(
                index: paneIndex,
                isActive: fields[4] == "1",
                tmuxID: fields[5],
                pid: pid,
                tty: fields[7],
                command: fields[8],
                title: fields.count > 9 ? fields[9...].joined(separator: " ") : "",
                agent: nil
            )
        )
    }

    private static func parsePSRow(_ line: Substring) -> PSRow? {
        // ps right-aligns numeric columns with leading spaces.
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3,
              let pid = Int(fields[0]), let ppid = Int(fields[1])
        else { return nil }
        return PSRow(
            pid: pid,
            ppid: ppid,
            args: fields[2...].joined(separator: " ")
        )
    }

    // MARK: - Session actions

    /// Kill one session (and every process in it). Targets tmux's own id —
    /// `-t` name matching is prefix-based, so a name target could take out
    /// "main-2" when asked for "main"; the `=` fallback forces an exact
    /// name match if the id is somehow missing.
    static func killCommand(for session: TmuxSession) -> String {
        let target = session.tmuxID.isEmpty ? "=\(session.name)" : session.tmuxID
        return pathPrefix + "\(tmuxCommand) kill-session -t \(target.shellQuoted)"
    }

    enum ShortcutDelivery: Equatable {
        case controlCommand(String)
        case terminalInput([UInt8])
    }

    /// The panel's one dispatch decision. A direct command deliberately wins
    /// whenever one exists — the stock binding bytes stay documented (and
    /// serve hardware-keyboard reference), but panel rows must not depend
    /// on a prefix burst that can lose its Ctrl-B in flight.
    static func shortcutDelivery(
        _ shortcut: TmuxShortcut, sessionName: String, resizeCells: Int = 1
    ) -> ShortcutDelivery? {
        if let command = directShortcutCommand(
            shortcut, sessionName: sessionName, resizeCells: resizeCells
        ) {
            return .controlCommand(command)
        }
        if let input = shortcut.bindingInput {
            return .terminalInput(input)
        }
        return nil
    }

    /// Execute one shortcut through the SSH control plane. Every row that
    /// can run without a tmux client goes direct, because the stock-prefix
    /// burst through the terminal can intermittently lose its Ctrl-B and
    /// type the bare key into the pane (first measured on the splits'
    /// shifted `%` on iPad, on either transport; reported again 2026-08-14
    /// on the window rows). Confirmed closes also avoid tmux's own
    /// confirmation prompt this way. Only two rows stay off it: Copy Mode,
    /// whose binding must travel the ordered terminal pump so the local
    /// selection-UI switch stays in step with it, and Rename Window, whose
    /// stock `,` opens a client-side prompt an exec can neither target
    /// (several clients) nor drive — `command-prompt` from an exec blocks
    /// until the prompt resolves (measured 2026-08-14); the panel collects
    /// the name natively and applies `renameWindowCommand` instead.
    ///
    /// Session-target rows pass `=name` straight to tmux; rows acting on a
    /// pane resolve the session's active pane to tmux's id first — pane
    /// commands reject `=name` targets on tmux 3.6a, and ids avoid prefix
    /// collisions. `#{pane_current_path}` is expanded by tmux against that
    /// target, preserving the stock split binding's working directory.
    /// `resizeCells` widens a resize row's step (the panel's held press);
    /// 1 rides resize-pane's own default and adds no argument.
    static func directShortcutCommand(
        _ shortcut: TmuxShortcut, sessionName: String, resizeCells: Int = 1
    ) -> String? {
        let exactSession = "=\(sessionName)".shellQuoted
        // Verified from a plain exec against tmux 3.x (2026-08-14): the
        // `=name:` window target makes new-window create at the first free
        // index and select it — exactly the stock `c` — and `=name:.+`
        // steps select-pane through the current window's panes.
        switch shortcut {
        case .newWindow:
            return pathPrefix
                + "\(tmuxCommand) new-window -t \("=\(sessionName):".shellQuoted)"
        case .nextWindow:
            return pathPrefix + "\(tmuxCommand) next-window -t \(exactSession)"
        case .previousWindow:
            return pathPrefix + "\(tmuxCommand) previous-window -t \(exactSession)"
        case .lastWindow:
            return pathPrefix + "\(tmuxCommand) last-window -t \(exactSession)"
        case .nextPane:
            return pathPrefix
                + "\(tmuxCommand) select-pane -t \("=\(sessionName):.+".shellQuoted)"
        default:
            break
        }

        let activePaneLookup = "\(tmuxCommand) list-panes -t \(exactSession)"
            + " -F '#{?pane_active,#{pane_id},}' 2>/dev/null | grep -m1 ."
        let lookup: String
        let action: String
        switch shortcut {
        case .splitLeftRight:
            lookup = activePaneLookup
            action = "\(tmuxCommand) split-window -h -t \"$target\""
                + " -c '#{pane_current_path}'"
        case .splitTopBottom:
            lookup = activePaneLookup
            action = "\(tmuxCommand) split-window -t \"$target\""
                + " -c '#{pane_current_path}'"
        case .closePane:
            lookup = activePaneLookup
            action = "\(tmuxCommand) kill-pane -t \"$target\""
        case .resizeLeft, .resizeDown, .resizeUp, .resizeRight:
            lookup = activePaneLookup
            action = "\(tmuxCommand) \(shortcut.command) -t \"$target\""
                + (resizeCells == 1 ? "" : " \(resizeCells)")
        case .togglePaneZoom:
            lookup = activePaneLookup
            action = "\(tmuxCommand) resize-pane -Z -t \"$target\""
        case .chooseWindow:
            // -Zw matches the stock `w` binding (windows view, zoomed);
            // the chooser is pane state, so it opens for the attached
            // client even though no client runs the command.
            lookup = activePaneLookup
            action = "\(tmuxCommand) choose-tree -Zw -t \"$target\""
        case .closeWindow:
            lookup = "\(tmuxCommand) list-windows -t \(exactSession)"
                + " -F '#{?window_active,#{window_id},}' 2>/dev/null | grep -m1 ."
            action = "\(tmuxCommand) kill-window -t \"$target\""
        default:
            return nil
        }
        return pathPrefix
            + "target=$(\(lookup)); "
            + "if [ -n \"$target\" ]; then \(action); fi"
    }

    /// Rename the session's active window — the apply half of the panel's
    /// native rename field (see `directShortcutCommand` for why tmux's own
    /// `,` prompt cannot be driven from an exec). Same id-resolution
    /// discipline as the confirmed closes; `--` guards names that start
    /// with a dash.
    static func renameWindowCommand(sessionName: String, newName: String) -> String {
        let lookup = "\(tmuxCommand) list-windows -t \("=\(sessionName)".shellQuoted)"
            + " -F '#{?window_active,#{window_id},}' 2>/dev/null | grep -m1 ."
        return pathPrefix
            + "target=$(\(lookup)); "
            + "if [ -n \"$target\" ]; then "
            + "\(tmuxCommand) rename-window -t \"$target\" -- \(newName.shellQuoted); fi"
    }

    /// The shortcut panel's window list for one session. Same `-F`
    /// discipline as the probe: space-separated with the variable-length
    /// name last, rejoined on parse.
    static func windowListCommand(sessionName: String) -> String {
        pathPrefix
            + "\(tmuxCommand) list-windows -t \("=\(sessionName)".shellQuoted)"
            + " -F '#{window_id} #{window_index} #{window_active} #{window_name}'"
            + " 2>/dev/null"
    }

    static func parseWindowList(_ output: String) -> [TmuxWindowChoice] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3)
            guard fields.count >= 3,
                  fields[0].hasPrefix("@"),
                  let index = Int(fields[1])
            else { return nil }
            return TmuxWindowChoice(
                tmuxID: String(fields[0]),
                index: index,
                isActive: fields[2] == "1",
                name: fields.count > 3 ? String(fields[3]) : ""
            )
        }
    }

    /// Switch the session to one of its windows from an SSH exec channel.
    /// Targets the window id captured by `windowListCommand`.
    static func selectWindowCommand(windowID: String) -> String {
        pathPrefix + "\(tmuxCommand) select-window -t \(windowID.shellQuoted)"
    }

    /// Where a drop should land for one session: line 1 is the *active*
    /// pane's working directory (while an agent runs there, the agent's own
    /// cwd — `pane_current_path` follows the foreground process), and a
    /// MULTIPLEX_GIT line follows when that directory sits inside a git
    /// worktree (drops then get corralled into `.multiplex-drops/`).
    /// `=` forces an exact name match, same discipline as killCommand.
    ///
    /// Deliberately `list-panes -F`, NOT `display-message -p -t`: on tmux
    /// 3.6a display-message fails to bind the target pane's format context
    /// from an outside client, silently rendering every `pane_*` variable
    /// empty — list-panes always binds. One line per pane of the current
    /// window; only the active pane's line carries the path.
    static func dropDestinationCommand(sessionName: String) -> String {
        pathPrefix
            + "p=$(\(tmuxCommand) list-panes -t \("=\(sessionName)".shellQuoted)"
            + " -F '#{?pane_active,#{pane_current_path},}' 2>/dev/null | grep -m1 .); "
            + "printf '%s\\n' \"$p\"; "
            + "if [ -n \"$p\" ] && \(gitWorktreeCondition(target: "\"$p\"")); "
            + "then echo \(gitWorktreeMarker); fi"
    }

    /// The corral decision when the pane's cwd was already resolved
    /// app-side — the herdr drop path, whose cwd comes home in snapshot
    /// JSON instead of staying in a shell variable. Prints the same
    /// MULTIPLEX_GIT marker so `parseDropDestination` stays the wire
    /// format's one parser (its cwd line simply isn't there to find).
    static func gitWorktreeCheckCommand(directory: String) -> String {
        pathPrefix
            + "if \(gitWorktreeCondition(target: directory.shellQuoted)); "
            + "then echo \(gitWorktreeMarker); fi"
    }

    /// One spelling of "that directory sits inside a git worktree" for
    /// both builders above; `target` arrives already shell-quoted.
    private static func gitWorktreeCondition(target: String) -> String {
        "command -v git >/dev/null 2>&1"
            + " && [ \"$(git -C \(target) rev-parse --is-inside-work-tree 2>/dev/null)\" = true ]"
    }

    private static let gitWorktreeMarker = "MULTIPLEX_GIT"

    /// `dropDestinationCommand` output → the active pane's cwd (the first
    /// `/`-prefixed line; nil when no pane answered) and whether it sits
    /// inside a git worktree. Shared by file drops and the file viewer's
    /// cwd anchor — the wire format has exactly one parser.
    static func parseDropDestination(
        _ output: String
    ) -> (cwd: String?, insideGitWorktree: Bool) {
        let lines = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (
            lines.first { $0.hasPrefix("/") },
            lines.contains(gitWorktreeMarker)
        )
    }

    // MARK: - New sessions (the window's + TAB button, the deck tile's quick options)

    /// Create a detached session and print its final name behind a
    /// MULTIPLEX_NEW sentinel. The create uses `TmuxSessionLaunch`'s
    /// best-effort systemd user scope so a first tmux server is not reaped
    /// with an SSH login scope on Linux. Naming authority stays with the
    /// server: `-s` asks for `name`, and a duplicate-name race just retries
    /// unnamed (the server numbers it), so the printed name is always the
    /// truth.
    ///
    /// - `sourceSessionName`: start in that session's *active-pane* cwd —
    ///   `pane_current_path` follows the foreground process, so "same dir"
    ///   means the agent's own cwd. Queried with `list-panes -F`, never
    ///   `display-message -p -t` (3.6a renders pane formats empty for
    ///   outside clients). nil or unresolvable → $HOME.
    /// - `startDirectory`: an explicit start directory (a host working dir
    ///   picked in the New Session prompt); consulted only when there is no
    ///   source session, and skipped for $HOME when missing on the host.
    /// - `tmuxConf`: the host's new-session tmux options (conf-style text
    ///   from the Host record, never a file on the host), applied before
    ///   anything is typed. Each parsed line becomes its own explicitly
    ///   targeted client call — `tmux set-option -t <new session id> --
    ///   <name> [<value>]` — so the scope is deterministic: session options
    ///   land on the minted session only, window options on its current
    ///   (first) window, while server-scoped options still reach the whole
    ///   server, tmux semantics said in the editor copy (all verified
    ///   against 3.6a). Injection-safe by construction: the name is
    ///   charset-validated and the value rides as one shell-quoted argv.
    ///   Per-line fail-soft (each call silenced individually, a bad option
    ///   skips only itself) — and the calls live inside the success guard,
    ///   never as a `\;` sequence on the create itself: a failing command
    ///   there makes the shared client exit nonzero — the unnamed retry
    ///   would mint a duplicate session — and its error text lands on
    ///   stdout inside `$i`.
    /// - `script`: the host's chosen setup script, typed into the fresh
    ///   shell exactly like `launch` but before it — same shell, so what it
    ///   exports/activates is live for the launch line. Sequential, never
    ///   gated: a failing script leaves its error visible above a launch
    ///   that still runs. (Known limit, documented not solved: a script
    ///   that reads stdin consumes the launch line as its input.)
    /// - `launch`: typed into the fresh shell via send-keys (literal text,
    ///   then Enter) — never the session's command argv, so the agent
    ///   exiting leaves a shell, and the login shell's own PATH resolves it
    ///   exactly as if the user typed it. Agent launches may include the New
    ///   Session sheet's safely quoted, one-shot initial prompt.
    ///
    /// The create prints `#{session_id} #{session_name}` (id fixed-width
    /// first, variable-length name last — the probe's own format
    /// discipline) and send-keys targets the id: 3.6a rejects `=name`
    /// exact-match for *pane* targets outright ("can't find pane"), and a
    /// bare name is prefix-matched. Ids are unambiguous everywhere.
    ///
    /// Always exits 0 — Citadel throws on a non-zero exit status, and a
    /// failed create must read as "no sentinel", not a torn-down control
    /// connection.
    static func newSessionCommand(
        name: String, sourceSessionName: String?, startDirectory: String? = nil,
        tmuxConf: String? = nil, script: String? = nil, launch: String?
    ) -> String {
        var command = pathPrefix + TmuxSessionLaunch.persistentRunnerDefinition
        if let source = sourceSessionName {
            command += "p=$(\(tmuxCommand) list-panes -t \("=\(source)".shellQuoted)"
                + " -F '#{?pane_active,#{pane_current_path},}' 2>/dev/null | grep -m1 .); "
                + "d=\"${p:-$HOME}\"; "
        } else if let directory = startDirectory {
            command += "d=\(directory.shellQuotedDirectory); [ -d \"$d\" ] || d=\"$HOME\"; "
        } else {
            command += "d=\"$HOME\"; "
        }
        let create = "multiplex_tmux new-session -d -P"
            + " -F '#{session_id} #{session_name}' -c \"$d\""
        command += "i=$(\(create) -s \(name.shellQuoted) 2>/dev/null)"
            + " || i=$(\(create) 2>/dev/null); "
        var onSuccess = ""
        for option in tmuxConfOptions(tmuxConf) {
            onSuccess += "\(tmuxCommand) set-option -t \"${i%% *}\" -- \(option.name.shellQuoted)"
            if let value = option.value {
                onSuccess += " \(value.shellQuoted)"
            }
            onSuccess += " 2>/dev/null; "
        }
        for typed in [script, launch].compactMap({ $0 }) {
            onSuccess += "\(tmuxCommand) send-keys -t \"${i%% *}\" -l -- \(typed.shellQuoted); "
                + "\(tmuxCommand) send-keys -t \"${i%% *}\" Enter; "
        }
        onSuccess += "printf 'MULTIPLEX_NEW %s\\n' \"${i#* }\""
        command += "[ -n \"$i\" ] && { \(onSuccess); }; true"
        return command
    }

    /// The session name minted by `newSessionCommand`, or nil when creation
    /// failed. Whole-rest-of-line, so names with spaces survive.
    static func parseNewSession(_ output: String) -> String? {
        let sentinel = "MULTIPLEX_NEW "
        for line in output.split(separator: "\n") where line.hasPrefix(sentinel) {
            let name = String(line.dropFirst(sentinel.count))
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// Open a new window in an EXISTING session over the control connection
    /// — the external action's "launch inside this session" placement (a
    /// window is tmux's one granularity below a session, so herdr's
    /// tab/workspace split both land here). Same discipline as
    /// `newSessionCommand`: `-c` comes from the explicit directory (falling
    /// back to $HOME when it doesn't exist) or from the target session's own
    /// active-pane cwd; `-P` prints the fresh pane id and script/launch
    /// lines are typed at that id (3.6a rejects `=name` for *pane* targets).
    /// No `-d`: the window becomes the session's current window, so clients
    /// already attached — and the attach this triggers — front the agent.
    /// The session's server already exists, so the systemd-scope runner and
    /// the tmux-conf riders deliberately don't apply here. Always exits 0
    /// (Citadel throws on nonzero); failure reads as "no sentinel".
    static func newWindowCommand(
        sessionName: String, startDirectory: String? = nil,
        script: String? = nil, launch: String?
    ) -> String {
        var command = pathPrefix
        let target = "=\(sessionName)".shellQuoted
        if let directory = startDirectory {
            command += "d=\(directory.shellQuotedDirectory); [ -d \"$d\" ] || d=\"$HOME\"; "
        } else {
            command += "p=$(\(tmuxCommand) list-panes -t \(target)"
                + " -F '#{?pane_active,#{pane_current_path},}' 2>/dev/null | grep -m1 .); "
                + "d=\"${p:-$HOME}\"; "
        }
        command += "i=$(\(tmuxCommand) new-window -t \(target)"
            + " -P -F '#{pane_id}' -c \"$d\" 2>/dev/null); "
        var onSuccess = ""
        for typed in [script, launch].compactMap({ $0 }) {
            onSuccess += "\(tmuxCommand) send-keys -t \"$i\" -l -- \(typed.shellQuoted); "
                + "\(tmuxCommand) send-keys -t \"$i\" Enter; "
        }
        onSuccess += "printf 'MULTIPLEX_NEWWIN %s\\n' \"$i\""
        command += "[ -n \"$i\" ] && { \(onSuccess); }; true"
        return command
    }

    /// The pane id minted by `newWindowCommand`, or nil when the window
    /// wasn't created (session gone, tmux gone, control link noise).
    static func parseNewWindow(_ output: String) -> String? {
        let sentinel = "MULTIPLEX_NEWWIN "
        for line in output.split(separator: "\n") where line.hasPrefix(sentinel) {
            let pane = String(line.dropFirst(sentinel.count))
            if !pane.isEmpty { return pane }
        }
        return nil
    }

    /// One parsed new-session conf line, applied as
    /// `set-option -t <session id> -- name [value]`. A nil value is a
    /// deliberate emission: tmux toggles boolean options given no value.
    struct TmuxConfOption: Equatable {
        let name: String
        let value: String?
    }

    /// The canonical bytes persisted for a host's new-session tmux conf —
    /// the custom-command policy (normalize pasted line endings, strip
    /// invisible terminal controls, keep interior tabs and newlines, trim
    /// only the outside), nil when nothing usable remains.
    static func normalizedTmuxConf(_ conf: String?) -> String? {
        guard let conf else { return nil }
        let normalizedLineEndings = conf
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let safeText = normalizedLineEndings.unicodeScalars.reduce(into: "") { result, scalar in
            let allowedControl = scalar.value == 0x09 || scalar.value == 0x0A
            if allowedControl || !CharacterSet.controlCharacters.contains(scalar) {
                result.append(Character(scalar))
            }
        }
        let trimmed = safeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parse conf text into targeted set-option calls, one per line —
    /// `mouse on`, `history-limit 50000`. Forgiving of `.tmux.conf` muscle
    /// memory: a leading `set`/`set-option`/`setw`/`set-window-option` word
    /// and leading scope flags (`-g`, `-w`, …) are dropped, because the
    /// scope here is fixed by the explicit `-t` target. Full-line `#`
    /// comments and blanks are skipped. The name must be option-shaped
    /// (letters/digits/`@-_`, starting with a letter or `@`) or the line is
    /// skipped; the rest of the line is the value, verbatim except for one
    /// unwrapped layer of symmetric quotes (a conf file's parser would have
    /// stripped them too — without this, pasted `status-style "bg=red"`
    /// stores literal quote characters into the option).
    static func tmuxConfOptions(_ conf: String?) -> [TmuxConfOption] {
        guard let conf = normalizedTmuxConf(conf) else { return [] }
        var options: [TmuxConfOption] = []
        for rawLine in conf.split(separator: "\n") {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            func takeToken() -> String? {
                guard !line.isEmpty else { return nil }
                guard let space = line.rangeOfCharacter(from: .whitespaces) else {
                    defer { line = "" }
                    return line
                }
                defer {
                    line = String(line[space.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                }
                return String(line[line.startIndex..<space.lowerBound])
            }

            var candidate = takeToken()
            if let first = candidate,
               ["set", "set-option", "setw", "set-window-option"].contains(first) {
                candidate = takeToken()
            }
            while let flag = candidate, flag.hasPrefix("-") {
                candidate = takeToken()
            }
            guard let name = candidate, isTmuxOptionName(name) else { continue }
            let value = unwrappedTmuxConfValue(line)
            options.append(TmuxConfOption(name: name, value: value.isEmpty ? nil : value))
        }
        return options
    }

    private static func isTmuxOptionName(_ name: String) -> Bool {
        guard let first = name.first, first == "@" || first.isLetter else { return false }
        return name.allSatisfy {
            $0 == "@" || $0 == "-" || $0 == "_" || $0.isLetter || $0.isNumber
        }
    }

    /// Strip one layer of fully wrapping quotes, but only when that quote
    /// character never appears inside — `"a" or "b"` keeps its quotes.
    private static func unwrappedTmuxConfValue(_ value: String) -> String {
        guard value.count >= 2, let quote = value.first,
              quote == "\"" || quote == "'",
              value.last == quote,
              !value.dropFirst().dropLast().contains(quote)
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// tmux target syntax reserves `:` and `.`, and new-session rejects
    /// names containing them — normalize instead of failing, and never
    /// return an empty name.
    static func sanitizedSessionName(_ name: String) -> String {
        let cleaned = name
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return cleaned.isEmpty ? "main" : cleaned
    }

    /// First free name against the probe's session list: base, base-2,
    /// base-3… A concurrent client can still win the race — harmless,
    /// `newSessionCommand`'s unnamed retry absorbs it.
    static func uniqueSessionName(base: String, existing: some Sequence<String>) -> String {
        let base = sanitizedSessionName(base)
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    // MARK: - Miniatures (the deck wall's live tiles)

    /// Lines a tile shows; the parser keeps the trailing non-blank run.
    static let miniatureLines = 4
    /// Scrollback depth requested per session.
    private static let captureDepth = 30
    /// Tile width clip — anything longer can't render in a tile anyway.
    private static let miniatureWidth = 56

    /// Parse the probe's tails section (after MULTIPLEX_TAILS) into session
    /// name → trailing lines: right-trimmed, trailing blank pane rows
    /// dropped, full width. MPXS markers carry tmux's own session ids ("$3"
    /// — server-minted by the probe's shell loop, never names, so arbitrary
    /// session names can't forge or break the framing), matched against the
    /// same output's session listing. This is the attention classifier's
    /// input; `miniatureTail` derives the tile view from the same parse.
    static func parseTails(_ output: String, sessions: [TmuxSession]) -> [String: [String]] {
        var names: [String: String] = [:]
        for session in sessions where !session.tmuxID.isEmpty {
            names[session.tmuxID] = session.name
        }
        var result: [String: [String]] = [:]
        var currentName: String?
        var lines: [String] = []
        func flush() {
            if let name = currentName { result[name] = visibleTail(lines) }
            currentName = nil
            lines = []
        }
        let marker = tailsMarker(in: output)
        guard let marker else { return [:] }
        for raw in output[marker.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("MPXS ") {
                flush()
                currentName = names[String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)]
            } else if line == "MPXE" {
                flush()
            } else if currentName != nil {
                lines.append(line)
            }
        }
        flush() // tolerate a truncated response missing its trailing MPXE
        return result
    }

    /// Session name → what a wall tile shows: the last `miniatureLines`
    /// lines, clipped to tile width.
    static func parseCaptures(_ output: String, sessions: [TmuxSession]) -> [String: [String]] {
        parseTails(output, sessions: sessions).mapValues(miniatureTail)
    }

    /// Clip a parsed tail down to the tile's display window.
    static func miniatureTail(_ lines: [String]) -> [String] {
        lines.suffix(miniatureLines).map { String($0.prefix(miniatureWidth)) }
    }

    /// Internal, not private: `HerdrProbe` trims its pane reads with the
    /// same rules, so what counts as a blank tail row is decided once.
    static func visibleTail(_ lines: [String]) -> [String] {
        var trimmed = lines.map(rightTrim)
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        return trimmed
    }

    private static func rightTrim(_ line: String) -> String {
        var s = Substring(line)
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return String(s)
    }

    private static func tailsMarker(in output: String) -> Range<String.Index>? {
        output.range(of: "\nMULTIPLEX_TAILS\n")
            ?? output.range(of: "MULTIPLEX_TAILS\n", options: .anchored)
    }
}
