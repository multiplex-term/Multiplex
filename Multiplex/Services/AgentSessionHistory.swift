import Foundation

/// One user prompt extracted from a CLI agent's own session file. The agents
/// keep JSONL transcripts on the host they run on (`~/.claude/projects/…`,
/// `~/.codex/sessions/…`, `~/.pi/agent/sessions/…`); Multiplex reads a
/// bounded tail over the SSH control plane and shows the real prompts —
/// including the full text of messages the TUIs render truncated.
struct AgentUserMessage: Identifiable, Hashable {
    /// Position in the parsed candidate list (file order). Stable within one
    /// load only — files are append-only, so a reload may shift ordinals.
    var ordinal: Int
    var text: String
    var timestamp: Date?

    var id: Int { ordinal }

    /// What a list row previews and what the jump needle derives from.
    var firstLine: String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? text
    }
}

/// Builds and parses the remote commands behind the HISTORY surface: locate
/// the active session file for a pane's agent + cwd, tail its user messages,
/// and (Claude Code) drive the TUI's own PgUp pager to scroll an old message
/// back on screen. Pure functions, exercised directly by unit tests — the
/// same discipline as `TmuxProbe`.
///
/// Formats verified 2026-07-16 against real files on the dev Mac (Claude
/// Code 2.1.211, Codex rollouts, Pi session v3); the experiment record lives
/// in local-plan/agent-message-history.md. Every stage fails soft: a missing
/// file, an unparsable line, or a search miss degrades to "unavailable" or
/// "not found", never an error state.
enum AgentSessionHistory {
    /// Byte budget for the tail read — applied *after* server-side grep
    /// filtering, so tool-result bulk (Claude Code session files reach tens
    /// of MB) can't crowd real prompts out of the window.
    static let tailByteBudget = 262_144
    /// Newest prompts kept after parsing.
    static let maxMessages = 50
    /// Jump search gives up after this many PgUp pages (the remote script
    /// then restores the live view itself).
    static let pageCap = 40
    /// Needles longer than this never help — the target line must fit a
    /// pane row anyway.
    static let needleMaximum = 60

    // MARK: - Locating and reading the session file

    /// The pane cwd query used before a history read on tmux routes — the
    /// active pane's `pane_current_path` follows the foreground process, so
    /// this is the agent's own cwd. `list-panes -F`, never `display-message`
    /// (tmux 3.6a renders pane formats empty for outside clients).
    static func paneCwdCommand(sessionName: String) -> String {
        TmuxProbe.pathPrefix
            + "tmux list-panes -t \("=\(sessionName)".shellQuoted)"
            + " -F '#{?pane_active,#{pane_current_path},}' 2>/dev/null | grep -m1 .; true"
    }

    static func parsePaneCwd(_ output: String) -> String? {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") }
    }

    /// One exec that locates the newest session file for `agent` in `cwd`
    /// and prints a filtered tail of it behind sentinels:
    ///
    ///     MULTIPLEX_HIST_FILE <path>
    ///     MULTIPLEX_HIST_BEGIN
    ///     <candidate JSONL lines>
    ///     MULTIPLEX_HIST_END
    ///
    /// Newest-mtime is deliberately the correlation rule — it is what
    /// `claude --continue` and `pi -c` themselves resume, so the file picked
    /// is the one the user means. Two same-agent panes in one cwd can
    /// misattribute (accepted v1 limit; the peek content makes it visible).
    /// Candidate lines only start with `{` — a JSONL line can never equal a
    /// sentinel, so arbitrary prompt text can't break the framing.
    static func readCommand(agent: AgentKind, cwd: String) -> String {
        let locate: String
        let filter: String
        switch agent {
        case .claudeCode:
            // Project dir = munged cwd; newest jsonl inside it. The grep
            // chain drops assistant/progress lines and the (huge)
            // tool_result user lines server-side.
            locate = "d=\"$HOME/.claude/projects/\"\(claudeProjectDirectoryComponent(forCwd: cwd).shellQuoted); "
                + "f=$(ls -t \"$d\"/*.jsonl 2>/dev/null | head -1); "
            filter = "grep -a '\"type\":\"user\"' \"$f\" 2>/dev/null"
                + " | grep -av '\"tool_use_id\"'"
        case .codex:
            // Rollouts are date-bucketed with no cwd in the path; the
            // session_meta head line carries it. Scan the newest 20.
            locate = "f=$(ls -t \"$HOME\"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null"
                + " | head -20 | while IFS= read -r c; do"
                + " head -c 8192 \"$c\" 2>/dev/null | grep -Fq -- \(codexCwdNeedle(forCwd: cwd).shellQuoted)"
                + " && { printf '%s\\n' \"$c\"; break; }; done); "
            filter = "grep -a '\"user_message\"' \"$f\" 2>/dev/null"
        case .pi:
            locate = "d=\"$HOME/.pi/agent/sessions/\"\(piProjectDirectoryComponent(forCwd: cwd).shellQuoted); "
                + "f=$(ls -t \"$d\"/*.jsonl 2>/dev/null | head -1); "
            filter = "grep -a '\"role\":\"user\"' \"$f\" 2>/dev/null"
        }
        return locate
            + "if [ -n \"$f\" ]; then "
            + "printf 'MULTIPLEX_HIST_FILE %s\\n' \"$f\"; "
            + "echo MULTIPLEX_HIST_BEGIN; "
            + filter + " | tail -c \(tailByteBudget); "
            + "echo; echo MULTIPLEX_HIST_END; "
            + "else echo MULTIPLEX_HIST_NOFILE; fi; true"
    }

    struct ReadResult: Equatable {
        var filePath: String?
        var messages: [AgentUserMessage]
    }

    /// nil = the command produced no sentinel at all (transport/short read);
    /// a `ReadResult` with no messages = the file was found but held none.
    static func parseReadOutput(_ output: String, agent: AgentKind) -> ReadResult? {
        if output.contains("MULTIPLEX_HIST_NOFILE") {
            return ReadResult(filePath: nil, messages: [])
        }
        var filePath: String?
        var candidates: [Substring] = []
        var inBody = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("MULTIPLEX_HIST_FILE ") {
                filePath = String(line.dropFirst("MULTIPLEX_HIST_FILE ".count))
            } else if line == "MULTIPLEX_HIST_BEGIN" {
                inBody = true
            } else if line == "MULTIPLEX_HIST_END" {
                inBody = false
            } else if inBody {
                candidates.append(line)
            }
        }
        guard filePath != nil else { return nil }
        let parsed = candidates.compactMap { message(fromLine: $0, agent: agent) }
        let kept = parsed.suffix(maxMessages)
        return ReadResult(
            filePath: filePath,
            messages: kept.enumerated().map { index, message in
                var message = message
                message.ordinal = index
                return message
            }
        )
    }

    /// One candidate JSONL line → a user prompt, or nil for everything else
    /// (tool results, meta entries, system wrappers, the partial first line
    /// of a byte-bounded tail).
    static func message(fromLine line: Substring, agent: AgentKind) -> AgentUserMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let text: String?
        switch agent {
        case .claudeCode: text = claudeCodeText(from: object)
        case .codex: text = codexText(from: object)
        case .pi: text = piText(from: object)
        }
        guard let text, isDisplayablePrompt(text) else { return nil }
        return AgentUserMessage(
            ordinal: 0,
            text: text,
            timestamp: (object["timestamp"] as? String).flatMap(parseTimestamp)
        )
    }

    /// System-injected turns recorded as user messages. Grown empirically —
    /// see the plan doc's pollution taxonomy; extend when a new wrapper
    /// appears rather than loosening the parser.
    private static let systemWrapperTags = [
        "<task-notification>",
        "<command-name>",
        "<local-command-stdout>",
        "<system-reminder>",
        "<user_instructions>",
        "<environment_context>",
    ]

    private static func isDisplayablePrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !systemWrapperTags.contains { trimmed.hasPrefix($0) }
    }

    /// `type:"user"` lines are polluted: tool results are also type user
    /// (dropped server-side via tool_use_id, re-checked here), and meta /
    /// wrapper entries are not prompts.
    private static func claudeCodeText(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "user",
              object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "user"
        else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        var texts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result": return nil
            case "text": (block["text"] as? String).map { texts.append($0) }
            default: continue
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Codex's `event_msg`/`user_message` entries are exactly the submitted
    /// prompts (context wrappers ride separate developer items).
    private static func codexText(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "user_message"
        else { return nil }
        return payload["message"] as? String
    }

    /// Pi session v3: `type:"message"` entries with role user / assistant /
    /// toolResult — the role split is clean. Entries form a branch tree
    /// (id/parentId); file order is append order, so prompts from abandoned
    /// branches may appear (accepted v1 — they were still typed by the user).
    private static func piText(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "message",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "user",
              let blocks = message["content"] as? [[String: Any]]
        else { return nil }
        let texts = blocks.compactMap { block -> String? in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static let fractionalTimestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timestampParser = ISO8601DateFormatter()

    private static func parseTimestamp(_ string: String) -> Date? {
        fractionalTimestampParser.date(from: string) ?? timestampParser.date(from: string)
    }

    // MARK: - Project directory munging

    /// Claude Code: every non-alphanumeric byte of the cwd becomes `-`
    /// (verified: `/Users/jhen/workspace/llama.rn` → `…-llama-rn`).
    static func claudeProjectDirectoryComponent(forCwd cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Pi: `/` → `-` with a `-` prefix and `--` suffix (verified against
    /// real dirs: `/Users/jhen/workspace2/Multiplex` →
    /// `--Users-jhen-workspace2-Multiplex--`; dots survive).
    static func piProjectDirectoryComponent(forCwd cwd: String) -> String {
        "-" + cwd.replacingOccurrences(of: "/", with: "-") + "--"
    }

    /// The fixed string grepped against a rollout's head to match its
    /// session_meta cwd. JSON-escaped the way serde writes it.
    static func codexCwdNeedle(forCwd cwd: String) -> String {
        let escaped = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"cwd\":\"\(escaped)\""
    }

    // MARK: - Jump (Claude Code pages its transcript with PgUp)

    /// Everything the jump needs before touching the pane, in one exec:
    /// tmux's own session id (pane-target commands reject `=name` on 3.6a),
    /// the active pane's width + title, and the current screen. The app
    /// classifies idle from title+capture — paging a running turn fights
    /// streaming repaints, and Esc would interrupt it.
    static func jumpPrologueCommand(sessionName: String) -> String {
        TmuxProbe.pathPrefix
            + "sid=$(tmux list-panes -t \("=\(sessionName)".shellQuoted)"
            + " -F '#{session_id}' 2>/dev/null | head -1); "
            + "if [ -n \"$sid\" ]; then "
            + "printf 'MPXJ_SID %s\\n' \"$sid\"; "
            + "tmux list-panes -t \"$sid\""
            + " -F '#{?pane_active,MPXJ_META #{pane_width} #{pane_title},}' 2>/dev/null"
            + " | grep -m1 MPXJ_META; "
            + "echo MPXJ_CAP; "
            + "tmux capture-pane -p -t \"$sid\" 2>/dev/null; "
            + "echo MPXJ_CAPEND; "
            + "else echo MPXJ_NOSESSION; fi; true"
    }

    struct JumpPrologue: Equatable {
        var sessionID: String
        var paneWidth: Int
        var paneTitle: String
        var capture: [String]
    }

    static func parseJumpPrologue(_ output: String) -> JumpPrologue? {
        guard !output.contains("MPXJ_NOSESSION") else { return nil }
        var sessionID: String?
        var width = 0
        var title = ""
        var capture: [String] = []
        var inCapture = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("MPXJ_SID ") {
                sessionID = line.dropFirst("MPXJ_SID ".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("MPXJ_META ") {
                // Fixed width field first, variable-length title last —
                // the probe's own format discipline.
                let fields = line.dropFirst("MPXJ_META ".count)
                    .split(separator: " ", omittingEmptySubsequences: false)
                width = fields.first.flatMap { Int($0) } ?? 0
                title = fields.dropFirst().joined(separator: " ")
            } else if line == "MPXJ_CAP" {
                inCapture = true
            } else if line == "MPXJ_CAPEND" {
                inCapture = false
            } else if inCapture {
                capture.append(String(line))
            }
        }
        guard let sessionID, !sessionID.isEmpty, width > 0 else { return nil }
        return JumpPrologue(
            sessionID: sessionID,
            paneWidth: width,
            paneTitle: title,
            capture: capture
        )
    }

    /// The literal string searched for on captured screens: a prefix of the
    /// message's first line, cut to fit inside one rendered pane row.
    /// Claude Code renders long prompts as a single line truncated with `…`
    /// at pane width, so text past that limit never appears on screen; wide
    /// (CJK) characters cost two columns. nil = too short to match safely.
    static func needle(for message: AgentUserMessage, paneColumns: Int) -> String? {
        var line = message.firstLine
        if let cut = line.firstIndex(where: { $0.isNewline || $0 == "\t" || $0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) {
            line = String(line[..<cut])
        }
        // The rendered row spends columns on the `❯ ` prefix and the `…`
        // truncation mark; stay well inside it.
        let columnBudget = min(paneColumns - 4, needleMaximum)
        guard columnBudget >= 4 else { return nil }
        var needle = ""
        var used = 0
        for character in line {
            let cost = displayColumns(of: character)
            if used + cost > columnBudget { break }
            needle.append(character)
            used += cost
        }
        while needle.hasSuffix(" ") { needle.removeLast() }
        guard needle.count >= 4 else { return nil }
        return needle
    }

    /// Rough terminal column cost — East Asian wide/fullwidth blocks count
    /// double. Conservative is safe here: a shorter needle still matches.
    private static func displayColumns(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    static func captureContains(_ lines: [String], needle: String) -> Bool {
        lines.contains { $0.contains(needle) }
    }

    /// The whole find runs server-side in ONE exec — page, settle, capture,
    /// grep, repeat — so wall-clock is independent of round-trip time (mosh
    /// users live on high-RTT links). Stops on: needle found (screen is left
    /// on the hit page), two identical consecutive captures (top of the
    /// transcript), or the page cap. On a miss the script restores the live
    /// view itself with PgDn presses — no dangling state to clean up if the
    /// app never follows up.
    static func jumpFindCommand(sessionID: String, needle: String) -> String {
        TmuxProbe.pathPrefix
            + "sid=\(sessionID.shellQuoted); n=\(needle.shellQuoted); "
            + "found=0; top=0; i=0; prev=; "
            + "while [ $i -lt \(pageCap) ]; do "
            + "tmux send-keys -t \"$sid\" PPage 2>/dev/null || break; "
            + "sleep 0.18; "
            + "cur=$(tmux capture-pane -p -t \"$sid\" 2>/dev/null); "
            + "i=$((i+1)); "
            + "if printf '%s' \"$cur\" | grep -Fq -- \"$n\"; then found=1; break; fi; "
            + "if [ -n \"$cur\" ] && [ \"$cur\" = \"$prev\" ]; then top=1; break; fi; "
            + "prev=\"$cur\"; "
            + "done; "
            + "if [ \"$found\" = 1 ]; then printf 'MPXJ_FOUND %s\\n' \"$i\"; else "
            + "j=0; while [ $j -lt $((i+2)) ]; do "
            + "tmux send-keys -t \"$sid\" NPage 2>/dev/null; j=$((j+1)); sleep 0.04; done; "
            + "if [ \"$top\" = 1 ]; then printf 'MPXJ_TOP %s\\n' \"$i\"; "
            + "else printf 'MPXJ_EXHAUSTED %s\\n' \"$i\"; fi; fi; true"
    }

    enum JumpFindResult: Equatable {
        case found(pages: Int)
        case top(pages: Int)
        case exhausted(pages: Int)
    }

    static func parseJumpFind(_ output: String) -> JumpFindResult? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2, let pages = Int(fields[1]) else { continue }
            switch fields[0] {
            case "MPXJ_FOUND": return .found(pages: pages)
            case "MPXJ_TOP": return .top(pages: pages)
            case "MPXJ_EXHAUSTED": return .exhausted(pages: pages)
            default: continue
            }
        }
        return nil
    }

    /// BACK TO LIVE: PgDn past the bottom is a no-op in Claude Code's pager,
    /// so overshooting by two pages is the safe restore — Esc is not used
    /// because a turn could have started mid-jump, and Esc would interrupt it.
    static func jumpReturnCommand(sessionID: String, pages: Int) -> String {
        let presses = max(1, min(pages + 2, pageCap + 2))
        return TmuxProbe.pathPrefix
            + "sid=\(sessionID.shellQuoted); j=0; "
            + "while [ $j -lt \(presses) ]; do "
            + "tmux send-keys -t \"$sid\" NPage 2>/dev/null; j=$((j+1)); sleep 0.04; done; true"
    }
}
