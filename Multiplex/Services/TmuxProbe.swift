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
/// a `ps` process table for the pane-tree walk; every stage degrades
/// silently — a host where list-panes or ps misbehaves just loses agent
/// detection, never its session list.
enum TmuxProbe {
    /// Non-interactive SSH exec often has a minimal PATH, so common tmux
    /// locations (Homebrew, /usr/local) are appended before any command.
    private static let pathPrefix =
        "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin\"; export PATH; "

    static var probeCommand: String {
        let sessionFormat = "S #{session_id} #{session_attached} #{session_created} #{session_name}"
        let windowFormat = "W #{session_id} #{window_index} #{window_active} #{window_bell_flag} #{window_activity_flag} #{window_name}"
        // No #{s/…/:} substitution on the command: tmux already normalizes
        // pane_current_command to a bare word, and s/// needs tmux ≥ 2.9.
        let paneFormat = "P #{session_id} #{window_index} #{pane_active} #{pane_pid} #{pane_current_command} #{pane_title}"
        return pathPrefix
            + "command -v tmux >/dev/null 2>&1 || { echo MULTIPLEX_NO_TMUX; exit 0; }; "
            + "tmux list-sessions -F '\(sessionFormat)' 2>/dev/null "
            + "&& tmux list-windows -a -F '\(windowFormat)' 2>/dev/null "
            + "&& tmux list-panes -a -F '\(paneFormat)' 2>/dev/null "
            // argv[0]/argv[1] are all the tree walk reads — clip the payload.
            + "&& { echo MULTIPLEX_PS; ps -eo pid=,ppid=,args= 2>/dev/null | cut -c1-120; } "
            + "|| true"
    }

    /// Parse combined probe output into a `TmuxState`.
    static func parse(_ output: String) -> TmuxState {
        if output.contains("MULTIPLEX_NO_TMUX") { return .tmuxMissing }

        struct SessionInfo {
            var name: String
            var clients: Int
            var created: Date
        }
        struct PaneInfo {
            var sessionID: String
            var windowIndex: Int
            var pid: Int
            var command: String
            var title: String
        }
        var sessions: [String: SessionInfo] = [:]
        var order: [String] = []
        var windows: [String: [TmuxWindow]] = [:]
        var activePanes: [PaneInfo] = []
        var psRows: [PSRow] = []
        var inPSSection = false

        for line in output.split(separator: "\n") {
            if line == "MULTIPLEX_PS" {
                inPSSection = true
                continue
            }
            if inPSSection {
                // ps right-aligns numeric columns with leading spaces.
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 3,
                      let pid = Int(fields[0]), let ppid = Int(fields[1])
                else { continue }
                psRows.append(PSRow(
                    pid: pid,
                    ppid: ppid,
                    args: fields[2...].joined(separator: " ")
                ))
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
            case "P" where fields.count >= 6:
                // Only the active pane — that's the one attach keystrokes
                // (and helper chips) reach. Title may legitimately be empty.
                guard fields[3] == "1" else { continue }
                activePanes.append(PaneInfo(
                    sessionID: fields[1],
                    windowIndex: Int(fields[2]) ?? 0,
                    pid: Int(fields[4]) ?? 0,
                    command: fields[5],
                    title: fields.count > 6 ? fields[6...].joined(separator: " ") : ""
                ))
            default:
                continue
            }
        }

        guard !order.isEmpty else { return .noServer }

        // Agent detection: cheap comm/title signals first, the pane's
        // process tree as the authority (catches node/bun wrappers and
        // macOS's versioned-binary comm).
        for pane in activePanes {
            guard let kind = AgentSignature.classify(command: pane.command, title: pane.title)
                ?? AgentSignature.agentInTree(rows: psRows, panePID: pane.pid)
            else { continue }
            guard let i = windows[pane.sessionID]?.firstIndex(where: { $0.index == pane.windowIndex })
            else { continue }
            windows[pane.sessionID]?[i].agent = kind
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

    // MARK: - Session actions

    /// Kill one session (and every process in it). Targets tmux's own id —
    /// `-t` name matching is prefix-based, so a name target could take out
    /// "main-2" when asked for "main"; the `=` fallback forces an exact
    /// name match if the id is somehow missing.
    static func killCommand(for session: TmuxSession) -> String {
        let target = session.tmuxID.isEmpty ? "=\(session.name)" : session.tmuxID
        return pathPrefix + "tmux kill-session -t \(target.shellQuoted)"
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

    // MARK: - Miniatures (the deck wall's live tiles)

    /// Lines a tile shows; the parser keeps the trailing non-blank run.
    static let miniatureLines = 4
    /// Scrollback depth requested per session.
    private static let captureDepth = 30
    /// Tile width clip — anything longer can't render in a tile anyway.
    private static let miniatureWidth = 56

    /// One exec round-trip fetching the last visible lines of every
    /// session's active pane. Sessions are delimited with MPXS <index> /
    /// MPXE marker lines; markers carry list indexes, never names, so
    /// arbitrary session names can't forge or break the framing. Targets
    /// use tmux's own session id ("$3") — names can prefix-collide.
    static func captureCommand(for sessions: [TmuxSession]) -> String {
        var command = pathPrefix
        for (index, session) in sessions.enumerated() {
            let target = session.tmuxID.isEmpty ? session.name : session.tmuxID
            command += "echo 'MPXS \(index)'; "
                + "tmux capture-pane -p -t \(target.shellQuoted) -S -\(captureDepth) 2>/dev/null; "
        }
        command += "echo 'MPXE'"
        return command
    }

    /// Parse `captureCommand` output into session name → last visible lines.
    /// Trailing blank pane rows are dropped, lines are right-trimmed and
    /// clipped to tile width, and only the final `miniatureLines` are kept.
    static func parseCaptures(_ output: String, sessions: [TmuxSession]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var currentIndex: Int?
        var lines: [String] = []
        func flush() {
            if let index = currentIndex, sessions.indices.contains(index) {
                result[sessions[index].name] = visibleTail(lines)
            }
            currentIndex = nil
            lines = []
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("MPXS ") {
                flush()
                currentIndex = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            } else if line == "MPXE" {
                flush()
            } else if currentIndex != nil {
                lines.append(line)
            }
        }
        flush() // tolerate a truncated response missing its trailing MPXE
        return result
    }

    private static func visibleTail(_ lines: [String]) -> [String] {
        var trimmed = lines.map(rightTrim)
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        return trimmed.suffix(miniatureLines).map { String($0.prefix(miniatureWidth)) }
    }

    private static func rightTrim(_ line: String) -> String {
        var s = Substring(line)
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return String(s)
    }
}
