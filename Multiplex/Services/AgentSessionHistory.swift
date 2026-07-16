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
    /// Initial backward scan gives up after this many half-page PgUp steps.
    static let pageCap = 40
    /// Claude pins the current user prompt at row 1 throughout its assistant
    /// response. Once found, seek through that response in small batches until
    /// the real turn boundary (or transcript top), with a separate generous
    /// cap for very long tool-heavy turns.
    static let pinnedSeekPageCap = 400
    static let pinnedSeekBatch = 4
    /// Needles longer than this never help — the target line must fit a
    /// pane row anyway.
    static let needleMaximum = 60
    /// A shorter second needle survives TUI truncation / decoration changes
    /// near the right edge without making every search broadly fuzzy.
    static let needleFallbackMaximum = 24
    /// A page redraw is considered settled after two equal captures. At the
    /// transcript boundary, wait up to this many 50 ms polls before deciding
    /// PgUp had no effect; a fixed sleep falsely stopped on busy hosts.
    static let pageSettlePollCap = 20

    // MARK: - Locating and reading the session file

    struct PaneContext: Equatable {
        var cwd: String
        /// Claude Code's exact conversation id, when its per-process registry
        /// is available. nil deliberately falls back to newest-mtime.
        var agentSessionID: String?
    }

    /// Resolve the active pane cwd and, for Claude Code, its exact session id
    /// in one exec. Claude publishes `~/.claude/sessions/<pid>.json`; walking
    /// descendants of `#{pane_pid}` ties that registry entry to this pane,
    /// avoiding the common failure where another Claude process in the same
    /// cwd has the newest transcript. Older versions / hosts without the
    /// registry simply omit the marker and retain the mtime fallback.
    ///
    /// `list-panes -F`, never `display-message` (tmux 3.6a renders pane
    /// formats empty for outside clients).
    static func paneContextCommand(sessionName: String, agent: AgentKind) -> String {
        let target = "=\(sessionName)".shellQuoted
        var command = TmuxProbe.pathPrefix
            + "tmux list-panes -t \(target)"
            + " -F '#{?pane_active,MULTIPLEX_HIST_CWD #{pane_current_path},}'"
            + " 2>/dev/null | grep -m1 '^MULTIPLEX_HIST_CWD '; "
        guard agent == .claudeCode else { return command + "true" }

        command += "root=$(tmux list-panes -t \(target)"
            + " -F '#{?pane_active,#{pane_pid},}' 2>/dev/null | grep -m1 .); "
            + "if [ -n \"$root\" ]; then "
            + "sid=$(ps -eo pid=,ppid= 2>/dev/null | "
            + "awk -v r=\"$root\" '{ parent[$1] = $2 } END { "
            + "print 0, r; for (pid in parent) { if (pid == r) continue; "
            + "p = pid; depth = 0; "
            + "while (p in parent && p != r && depth < 64) { p = parent[p]; depth++ } "
            + "if (p == r) print depth, pid } }' | sort -n | "
            + "while read -r depth p; do "
            + "f=\"$HOME/.claude/sessions/$p.json\"; [ -r \"$f\" ] || continue; "
            + "value=$(sed -n 's/.*\"sessionId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'"
            + " \"$f\" | head -1); "
            + "if [ -n \"$value\" ]; then printf '%s\\n' \"$value\"; break; fi; done); "
            + "[ -n \"$sid\" ] && printf 'MULTIPLEX_HIST_AGENT_SESSION %s\\n' \"$sid\"; "
            + "fi; true"
        return command
    }

    static func parsePaneContext(_ output: String) -> PaneContext? {
        var cwd: String?
        var sessionID: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("MULTIPLEX_HIST_CWD ") {
                let value = line.dropFirst("MULTIPLEX_HIST_CWD ".count)
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("/") { cwd = value }
            } else if line.hasPrefix("MULTIPLEX_HIST_AGENT_SESSION ") {
                sessionID = line.dropFirst("MULTIPLEX_HIST_AGENT_SESSION ".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard let cwd else { return nil }
        return PaneContext(
            cwd: cwd,
            agentSessionID: validatedClaudeSessionID(sessionID)
        )
    }

    /// Registry values become a path component in `readCommand`; accept only
    /// Claude's UUID form, canonicalized for case-sensitive remote filesystems.
    static func validatedClaudeSessionID(_ value: String?) -> String? {
        guard let value, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// One exec that locates the newest session file for `agent` in `cwd`
    /// and prints a filtered tail of it behind sentinels:
    ///
    ///     MULTIPLEX_HIST_FILE <path>
    ///     MULTIPLEX_HIST_BEGIN
    ///     <candidate JSONL lines>
    ///     MULTIPLEX_HIST_END
    ///
    /// Claude Code prefers the exact session id resolved from this pane's
    /// process registry; newest-mtime remains its fail-soft fallback and the
    /// deliberate rule for Pi (the behavior of `pi -c`). Codex first filters
    /// rollout metadata by cwd, then takes newest. Candidate lines only start
    /// with `{` — a JSONL line can never equal a sentinel, so arbitrary prompt
    /// text can't break the framing.
    static func readCommand(
        agent: AgentKind,
        cwd: String,
        preferredSessionID: String? = nil
    ) -> String {
        let locate: String
        let filter: String
        switch agent {
        case .claudeCode:
            // Project dir = munged cwd. Prefer the exact pane-process session
            // from `~/.claude/sessions/<pid>.json`; if that registry is absent
            // or stale, preserve the fail-soft newest-mtime behavior.
            let sessionID = validatedClaudeSessionID(preferredSessionID) ?? ""
            locate = "d=\"$HOME/.claude/projects/\"\(claudeProjectDirectoryComponent(forCwd: cwd).shellQuoted); "
                + "f=; sid=\(sessionID.shellQuoted); "
                + "if [ -n \"$sid\" ] && [ -f \"$d/$sid.jsonl\" ]; then f=\"$d/$sid.jsonl\"; fi; "
                + "[ -n \"$f\" ] || f=$(ls -t \"$d\"/*.jsonl 2>/dev/null | head -1); "
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

    /// Search strings for one prompt. The primary is a first-line prefix cut
    /// to the pane; a 24-column fallback handles right-edge truncation and
    /// small rendering differences. Whitespace is normalized because the TUI
    /// can reflow it differently from JSONL. nil/empty = too short to match.
    static func needles(for message: AgentUserMessage, paneColumns: Int) -> [String] {
        guard let primary = needle(for: message, paneColumns: paneColumns) else { return [] }
        var values = [primary]
        let fallback = terminalPrefix(primary, maxColumns: needleFallbackMaximum)
        if fallback != primary { values.append(fallback) }
        return values
    }

    static func needle(for message: AgentUserMessage, paneColumns: Int) -> String? {
        let line = normalizedSearchText(message.firstLine)
        // The rendered row spends columns on the `❯ ` prefix and the `…`
        // truncation mark; stay well inside it.
        let columnBudget = min(paneColumns - 4, needleMaximum)
        guard columnBudget >= 4 else { return nil }
        let needle = terminalPrefix(line, maxColumns: columnBudget)
        guard needle.count >= 4 else { return nil }
        return needle
    }

    private static func terminalPrefix(_ text: String, maxColumns: Int) -> String {
        var prefix = ""
        var used = 0
        for character in text {
            let cost = displayColumns(of: character)
            if used + cost > maxColumns { break }
            prefix.append(character)
            used += cost
        }
        return prefix.trimmingCharacters(in: .whitespaces)
    }

    /// Collapse whitespace runs and discard C0 controls so JSONL prompt text
    /// and one rendered `❯` row compare independently of spacing details.
    private static func normalizedSearchText(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            let scalars = character.unicodeScalars
            if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                pendingSpace = !result.isEmpty
                continue
            }
            if scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                continue
            }
            if pendingSpace { result.append(" ") }
            result.append(character)
            pendingSpace = false
        }
        return result
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

    enum CaptureMatch: Equatable {
        case none
        /// The actual prompt row is visible below row 1: the turn boundary is
        /// already on screen.
        case visiblePrompt
        /// Claude's sticky row-1 prompt header. This only identifies the turn;
        /// finding must continue toward that turn's beginning.
        case pinnedPrompt
    }

    /// Match only Claude's rendered user-turn rows (`❯ …`). The same prompt
    /// text commonly appears in assistant prose/tool output, while a row-1
    /// user row is sticky for the whole response and is therefore not yet a
    /// final landing point.
    static func captureMatch(_ lines: [String], needles: [String]) -> CaptureMatch {
        let normalizedNeedles = needles
            .map(normalizedSearchText)
            .filter { !$0.isEmpty }
        guard !normalizedNeedles.isEmpty else { return .none }
        for (index, line) in lines.enumerated() {
            guard let prompt = claudePromptText(from: line),
                  normalizedNeedles.contains(where: { prompt.contains($0) })
            else { continue }
            return index == 0 ? .pinnedPrompt : .visiblePrompt
        }
        return .none
    }

    private static func claudePromptText(from line: String) -> String? {
        let trimmed = line.drop(while: { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.whitespaces.contains($0)
            }
        })
        guard trimmed.first == "❯" else { return nil }
        return normalizedSearchText(String(trimmed.dropFirst()))
    }

    /// The whole find runs server-side in ONE exec, independent of network
    /// RTT. It first pages backward until the target's structural `❯` row is
    /// visible. A match below row 1 is the real prompt. A row-1 match is
    /// Claude's sticky turn header, so a second phase keeps paging through the
    /// assistant response in small batches; after crossing into the previous
    /// turn it refines forward until the target returns. Transcript top is
    /// also a valid boundary for the oldest turn.
    ///
    /// Misses and signal cancellation restore in constant time with Ctrl+End,
    /// which Claude maps to scroll-bottom without interrupting a running turn.
    static func jumpFindCommand(sessionID: String, needles: [String]) -> String {
        let usable = needles.filter { !$0.isEmpty }
        let primary = usable.first ?? "MULTIPLEX_HISTORY_NEEDLE_MISSING"
        let fallback = usable.dropFirst().first ?? ""
        return TmuxProbe.pathPrefix
            + "sid=\(sessionID.shellQuoted); n1=\(primary.shellQuoted); n2=\(fallback.shellQuoted); "
            + "capture() { tmux capture-pane -p -t \"$sid\" 2>/dev/null; }; "
            // match=1: actual prompt below row 1; match=2: sticky row-1 header.
            + "classify() { match=0; "
            + "first=$(printf '%s\\n' \"$1\" | "
            + "sed -n '1{s/^[[:space:]]*❯[[:space:]]*//p;}' | tr '\\t\\r' '  '"
            + " | sed 's/[[:space:]][[:space:]]*/ /g'); "
            + "if printf '%s\\n' \"$first\" | grep -Fq -- \"$needle\"; then match=2; return; fi; "
            + "rest=$(printf '%s\\n' \"$1\" | "
            + "sed -n '2,$s/^[[:space:]]*❯[[:space:]]*//p' | tr '\\t\\r' '  '"
            + " | sed 's/[[:space:]][[:space:]]*/ /g'); "
            + "if printf '%s\\n' \"$rest\" | grep -Fq -- \"$needle\"; then match=1; fi; }; "
            + "settle() { base=\"$1\"; changed=0; polls=0; last=\"$base\"; cur=\"$base\"; "
            + "while [ $polls -lt \(pageSettlePollCap) ]; do "
            + "sleep 0.05; cur=$(capture); [ \"$cur\" != \"$base\" ] && changed=1; "
            + "if [ \"$changed\" = 1 ] && [ \"$cur\" = \"$last\" ]; then break; fi; "
            + "last=\"$cur\"; polls=$((polls+1)); done; }; "
            + "restore() { tmux send-keys -t \"$sid\" C-End 2>/dev/null; sleep 0.08; }; "
            + "seek_start() { sought=0; "
            + "while [ $sought -lt \(pinnedSeekPageCap) ]; do "
            + "base=\"$cur\"; sent=0; "
            + "while [ $sent -lt \(pinnedSeekBatch) ] && [ $sought -lt \(pinnedSeekPageCap) ]; do "
            + "tmux send-keys -t \"$sid\" PPage 2>/dev/null || return; "
            + "sent=$((sent+1)); sought=$((sought+1)); i=$((i+1)); sleep 0.03; done; "
            + "settle \"$base\"; "
            + "if [ \"$cur\" = \"$base\" ]; then top=1; found=1; return; fi; "
            + "classify \"$cur\"; "
            + "if [ \"$match\" = 1 ]; then found=1; return; fi; "
            + "if [ \"$match\" = 2 ]; then continue; fi; "
            + "back=0; while [ $back -lt $sent ]; do "
            + "base=\"$cur\"; tmux send-keys -t \"$sid\" NPage 2>/dev/null || return; "
            + "settle \"$base\"; i=$((i-1)); back=$((back+1)); classify \"$cur\"; "
            + "if [ \"$match\" != 0 ]; then found=1; return; fi; done; return; done; }; "
            + "search() { found=0; top=0; i=0; cur=$(capture); classify \"$cur\"; "
            + "if [ \"$match\" = 1 ]; then found=1; return; fi; "
            + "if [ \"$match\" = 2 ]; then seek_start; return; fi; "
            + "while [ $i -lt \(pageCap) ]; do "
            + "base=\"$cur\"; tmux send-keys -t \"$sid\" PPage 2>/dev/null || break; "
            + "settle \"$base\"; i=$((i+1)); "
            + "if [ \"$cur\" = \"$base\" ]; then top=1; break; fi; "
            + "classify \"$cur\"; "
            + "if [ \"$match\" = 1 ]; then found=1; return; fi; "
            + "if [ \"$match\" = 2 ]; then seek_start; return; fi; done; }; "
            + "found=0; top=0; keep=0; i=0; "
            + "trap 'keep=1; restore; exit 1' HUP INT TERM; "
            + "trap 'if [ \"$keep\" != 1 ]; then restore; fi' EXIT; "
            + "needle=\"$n1\"; search; "
            // Only relax the needle after a complete primary miss.
            + "if [ \"$found\" = 0 ] && [ -n \"$n2\" ]; then "
            + "restore; needle=\"$n2\"; search; fi; "
            + "if [ \"$found\" = 1 ]; then "
            + "keep=1; trap - HUP INT TERM EXIT; printf 'MPXJ_FOUND %s\\n' \"$i\"; else "
            + "keep=1; restore; trap - HUP INT TERM EXIT; "
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

    /// BACK TO LIVE: Claude maps Ctrl+End to scroll-bottom. It is constant
    /// time even after a very long pinned turn, and unlike Esc cannot interrupt
    /// a turn that started after finding began.
    static func jumpReturnCommand(sessionID: String, pages _: Int) -> String {
        TmuxProbe.pathPrefix
            + "tmux send-keys -t \(sessionID.shellQuoted) C-End 2>/dev/null; true"
    }
}
