import Foundation

/// Builds and parses the `tmux` commands used to discover remote sessions.
/// Pure functions — exercised directly by unit tests.
///
/// Format design: tmux sanitizes control characters in `-F` output (0x1F
/// becomes `_`), so fields are space-separated with the one variable-length
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
    static let pathPrefix =
        "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin\"; export PATH; "

    /// One exec round-trip carrying everything a wall tick needs: session/
    /// window/pane listings, the (pane-subtree-clipped) ps table for agent
    /// detection, and — after the MULTIPLEX_TAILS sentinel — every session's
    /// active-pane capture for the live miniatures. A second capture exec
    /// used to follow the probe; folding it in halves the per-tick channel
    /// opens, login-shell spawns, and round-trips.
    static let probeCommand: String = {
        let sessionFormat = "S #{session_id} #{session_attached} #{session_created} #{session_name}"
        let windowFormat = "W #{session_id} #{window_index} #{window_active} #{window_bell_flag} #{window_activity_flag} #{window_name}"
        let paneLineFormat = paneFormat(tag: "P")
        return pathPrefix
            + "command -v tmux >/dev/null 2>&1 || { echo MULTIPLEX_NO_TMUX; exit 0; }; "
            + "tmux list-sessions -F '\(sessionFormat)' 2>/dev/null "
            + "&& tmux list-windows -a -F '\(windowFormat)' 2>/dev/null "
            // Keep the pane listing in one shell variable: it is printed for
            // the parser and reused to derive every pane-process root,
            // avoiding a second list-panes call in the process stage.
            + "&& panes=$(tmux list-panes -a -F '\(paneLineFormat)' 2>/dev/null) "
            + "&& printf '%s\\n' \"$panes\" "
            + "&& { echo MULTIPLEX_PS; \(psPaneSubtreeCommand); } "
            + "|| true; "
            + "echo MULTIPLEX_TAILS; "
            + "tmux list-sessions -F '#{session_id}' 2>/dev/null | while IFS= read -r s; do "
            + "echo \"MPXS $s\"; "
            + "tmux capture-pane -p -t \"$s\" -S -\(captureDepth) 2>/dev/null; "
            + "done; echo MPXE"
    }()

    /// Everything derived from one probe response. Keeping this pure bundle
    /// together lets callers move the process-tree walk, capture trimming,
    /// and miniature clipping off the UI actor in one hop.
    struct ParsedProbe {
        var state: TmuxState
        var tails: [String: [String]]
        var miniatures: [String: [String]]
    }

    static func parseProbe(_ output: String) -> ParsedProbe {
        let state = parse(output)
        guard case .sessions(let sessions) = state else {
            return ParsedProbe(state: state, tails: [:], miniatures: [:])
        }
        let tails = parseTails(output, sessions: sessions)
        return ParsedProbe(
            state: state,
            tails: tails,
            miniatures: tails.mapValues(miniatureTail)
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
                tmuxID: id
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
            + "tmux list-panes -t \("=\(sessionName)".shellQuoted) "
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
        return pathPrefix + "tmux kill-session -t \(target.shellQuoted)"
    }

    /// Execute a shortcut's destructive action from an SSH exec channel.
    /// Resolve the session's current pane/window to tmux's own id first:
    /// pane commands reject `=name` targets on tmux 3.6a, and ids also avoid
    /// prefix collisions. The UI has already required the second press, so
    /// these use `kill-*` directly and never open tmux's `:` prompt.
    static func directShortcutCommand(
        _ shortcut: TmuxShortcut, sessionName: String
    ) -> String? {
        let exactSession = "=\(sessionName)".shellQuoted
        let lookup: String
        let kill: String
        switch shortcut {
        case .closePane:
            lookup = "tmux list-panes -t \(exactSession)"
                + " -F '#{?pane_active,#{pane_id},}' 2>/dev/null | grep -m1 ."
            kill = "tmux kill-pane -t \"$target\""
        case .closeWindow:
            lookup = "tmux list-windows -t \(exactSession)"
                + " -F '#{?window_active,#{window_id},}' 2>/dev/null | grep -m1 ."
            kill = "tmux kill-window -t \"$target\""
        default:
            return nil
        }
        return pathPrefix
            + "target=$(\(lookup)); "
            + "if [ -n \"$target\" ]; then \(kill); fi"
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
            + "p=$(tmux list-panes -t \("=\(sessionName)".shellQuoted)"
            + " -F '#{?pane_active,#{pane_current_path},}' 2>/dev/null | grep -m1 .); "
            + "printf '%s\\n' \"$p\"; "
            + "if [ -n \"$p\" ] && command -v git >/dev/null 2>&1"
            + " && [ \"$(git -C \"$p\" rev-parse --is-inside-work-tree 2>/dev/null)\" = true ]; "
            + "then echo MULTIPLEX_GIT; fi"
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
        name: String, sourceSessionName: String?, startDirectory: String? = nil, launch: String?
    ) -> String {
        var command = pathPrefix + TmuxSessionLaunch.persistentRunnerDefinition
        if let source = sourceSessionName {
            command += "p=$(tmux list-panes -t \("=\(source)".shellQuoted)"
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
        if let launch {
            onSuccess += "tmux send-keys -t \"${i%% *}\" -l -- \(launch.shellQuoted); "
                + "tmux send-keys -t \"${i%% *}\" Enter; "
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

    private static func visibleTail(_ lines: [String]) -> [String] {
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
