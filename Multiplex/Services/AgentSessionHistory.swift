import Foundation

/// One user prompt extracted from Claude Code's own session file. Claude
/// keeps a JSONL transcript per conversation on the host it runs on
/// (`~/.claude/projects/<munged-cwd>/<sessionId>.jsonl`); Multiplex reads a
/// bounded tail over the SSH control plane and shows the real prompts —
/// including the full text of messages the TUI renders truncated.
struct AgentUserMessage: Identifiable, Hashable {
    /// Position in the parsed candidate list (file order). Stable within one
    /// load only — files are append-only, so a reload may shift ordinals.
    var ordinal: Int
    var text: String
    var timestamp: Date?
    /// Whether the rendered transcript can still contain this prompt.
    /// `/compact` resets Claude's pager view: prompts older than the last
    /// compact boundary exist only in the file — peek works, JUMP would
    /// walk to the top and miss, so it is withheld.
    var reachable: Bool = true

    var id: Int { ordinal }

    /// What a list row previews and what the jump needle derives from.
    var firstLine: String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? text
    }
}

/// Builds and parses the remote commands behind the HISTORY surface: locate
/// the pane's exact Claude Code session file, tail its user messages, and
/// drive Claude's own pager to scroll an old message back on screen. Pure
/// functions, exercised directly by unit tests — the same discipline as
/// `TmuxProbe`. Claude Code only: Codex/Pi support was withdrawn 2026-07-16
/// to concentrate on making this exact (see the plan doc).
///
/// Formats and pager behavior verified 2026-07-16 against real Claude Code
/// 2.1.211 under tmux 3.6a; the experiment record lives in
/// local-plan/agent-message-history.md. Every stage fails soft: a missing
/// file, an unparsable line, or a search miss degrades to "unavailable" or
/// "not found", never an error state.
enum AgentSessionHistory {
    /// Byte budget for the tail read — applied *after* server-side grep
    /// filtering, so tool-result bulk (Claude Code session files reach tens
    /// of MB) can't crowd real prompts out of the window.
    static let tailByteBudget = 262_144
    /// Newest prompts kept after parsing.
    static let maxMessages = 50
    /// Total pager keystrokes one find may send. The header oracle makes
    /// every step directed, so this is a runaway stop, not a search radius.
    static let jumpSendBudget = 400
    /// Steps per settle while traversing turns known to be newer than the
    /// target (each PgUp moves half the transcript region).
    static let oracleFarBatch = 6
    /// Steps per settle while inside the target turn's own response; the
    /// landing rules recover an overshoot in a step or two.
    static let oracleBodyBatch = 4
    /// Needles longer than this never help — the target line must fit a
    /// pane row anyway.
    static let needleMaximum = 60
    /// A shorter second needle survives TUI truncation / decoration changes
    /// near the right edge without making every search broadly fuzzy.
    static let needleFallbackMaximum = 24
    /// A page redraw is considered settled after two equal captures. At the
    /// transcript boundary, wait up to this many 50 ms polls before deciding
    /// paging had no effect; a fixed sleep falsely stopped on busy hosts.
    static let pageSettlePollCap = 20
    /// Rows excluded from the bottom of every capture before matching: the
    /// composer (its `❯` would false-match a drafted prompt), separators,
    /// and the status strip are fixed chrome, not transcript.
    static let bottomChromeRows = 6

    // MARK: - Locating and reading the session file

    struct PaneContext: Equatable {
        var cwd: String
        /// Claude Code's exact conversation id, when its per-process registry
        /// is available. nil deliberately falls back to newest-mtime.
        var agentSessionID: String?
    }

    /// Resolve the active pane cwd and Claude Code's exact session id in one
    /// exec. Claude publishes `~/.claude/sessions/<pid>.json`; walking
    /// descendants of `#{pane_pid}` ties that registry entry to this pane,
    /// avoiding the common failure where another Claude process in the same
    /// cwd has the newest transcript. Older versions / hosts without the
    /// registry simply omit the marker and retain the mtime fallback.
    ///
    /// `list-panes -F`, never `display-message` (tmux 3.6a renders pane
    /// formats empty for outside clients).
    static func paneContextCommand(sessionName: String) -> String {
        let target = "=\(sessionName)".shellQuoted
        return TmuxProbe.pathPrefix
            + "tmux list-panes -t \(target)"
            + " -F '#{?pane_active,MULTIPLEX_HIST_CWD #{pane_current_path},}'"
            + " 2>/dev/null | grep -m1 '^MULTIPLEX_HIST_CWD '; "
            + "root=$(tmux list-panes -t \(target)"
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

    /// One exec that locates the pane's session file and prints a filtered
    /// tail of it behind sentinels:
    ///
    ///     MULTIPLEX_HIST_FILE <path>
    ///     MULTIPLEX_HIST_BEGIN
    ///     <candidate JSONL lines>
    ///     MULTIPLEX_HIST_END
    ///
    /// The exact session id resolved from this pane's process registry wins;
    /// newest-mtime remains the fail-soft fallback for hosts/versions without
    /// the registry (it is what `claude --continue` resumes). The grep chain
    /// drops assistant/progress lines and the (huge) tool_result user lines
    /// server-side. Candidate lines only start with `{` — a JSONL line can
    /// never equal a sentinel, so arbitrary prompt text can't break framing.
    static func readCommand(cwd: String, preferredSessionID: String? = nil) -> String {
        let sessionID = validatedClaudeSessionID(preferredSessionID) ?? ""
        return "d=\"$HOME/.claude/projects/\"\(claudeProjectDirectoryComponent(forCwd: cwd).shellQuoted); "
            + "f=; sid=\(sessionID.shellQuoted); "
            + "if [ -n \"$sid\" ] && [ -f \"$d/$sid.jsonl\" ]; then f=\"$d/$sid.jsonl\"; fi; "
            + "[ -n \"$f\" ] || f=$(ls -t \"$d\"/*.jsonl 2>/dev/null | head -1); "
            + "if [ -n \"$f\" ]; then "
            + "printf 'MULTIPLEX_HIST_FILE %s\\n' \"$f\"; "
            + "echo MULTIPLEX_HIST_BEGIN; "
            + "grep -a '\"type\":\"user\"' \"$f\" 2>/dev/null"
            + " | grep -av '\"tool_use_id\"'"
            + " | tail -c \(tailByteBudget); "
            + "echo; echo MULTIPLEX_HIST_END; "
            + "else echo MULTIPLEX_HIST_NOFILE; fi; true"
    }

    struct ReadResult: Equatable {
        var filePath: String?
        var messages: [AgentUserMessage]
    }

    /// nil = the command produced no sentinel at all (transport/short read);
    /// a `ReadResult` with no messages = the file was found but held none.
    static func parseReadOutput(_ output: String) -> ReadResult? {
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
        var parsed: [AgentUserMessage] = []
        // Prompts older than the last `/compact` are gone from the rendered
        // transcript; track the boundary so JUMP is withheld for them.
        var reachableFrom = 0
        for line in candidates {
            switch classifyLine(line) {
            case .prompt(let message):
                parsed.append(message)
            case .compactBoundary:
                reachableFrom = parsed.count
            case .ignored:
                continue
            }
        }
        let kept = parsed.suffix(maxMessages)
        let dropped = parsed.count - kept.count
        let boundary = max(0, reachableFrom - dropped)
        return ReadResult(
            filePath: filePath,
            messages: kept.enumerated().map { index, message in
                var message = message
                message.ordinal = index
                message.reachable = index >= boundary
                return message
            }
        )
    }

    enum ParsedLine: Equatable {
        case prompt(AgentUserMessage)
        /// A compact summary entry: Claude replaced the rendered transcript
        /// with it — everything parsed before is file-only history.
        case compactBoundary
        case ignored
    }

    /// One candidate JSONL line → a user prompt, the compact boundary, or
    /// nothing (tool results, meta entries, system wrappers, slash
    /// commands, the partial first line of a byte-bounded tail).
    static func classifyLine(_ line: Substring) -> ParsedLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .ignored }
        // Compact summaries are never prompts, but they are NOT a boundary:
        // they come from auto-compaction and continued-out-of-context
        // sessions, which do not wipe the rendered transcript (hiding JUMP
        // there was a real false negative). Only the *typed* /compact —
        // verified to reset the view on 2.1.211 — marks one below; an
        // old-version manual compact degrades to an honest miss pill.
        if object["isCompactSummary"] as? Bool == true { return .ignored }
        guard let text = claudeCodeText(from: object), isDisplayablePrompt(text)
        else { return .ignored }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTranscriptResettingCommand(content) { return .compactBoundary }
        if isSlashCommand(content) { return .ignored }
        return .prompt(AgentUserMessage(
            ordinal: 0,
            text: text,
            timestamp: (object["timestamp"] as? String).flatMap(parseTimestamp)
        ))
    }

    /// `/compact` and `/clear` replace the rendered transcript — prompts
    /// before them are file-only history.
    private static func isTranscriptResettingCommand(_ text: String) -> Bool {
        for command in ["/compact", "/clear"] {
            if text == command || text.hasPrefix(command + " ") { return true }
        }
        return false
    }

    /// Typed slash commands appear as bare user lines ("/create-pr …") next
    /// to their `<command-…>` wrapper entries. They are actions, not
    /// prompts: the TUI renders them specially and collapses them, so they
    /// are neither listed nor used as jump targets. A path-like "/etc/hosts
    /// broke" deliberately does not match.
    static func isSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let word = text.dropFirst().prefix { character in
            character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == ":"
        }
        guard !word.isEmpty else { return false }
        let rest = text.dropFirst(1 + word.count)
        return rest.isEmpty || rest.first == " "
    }

    /// System-injected turns recorded as user messages. Grown empirically —
    /// see the plan doc's pollution taxonomy; extend when a new wrapper
    /// appears rather than loosening the parser. Slash commands write
    /// `<command-message>…</command-message>\n<command-name>/…` (message
    /// first), so both tags are needed.
    private static let systemWrapperTags = [
        "<task-notification>",
        "<command-message>",
        "<command-name>",
        "<local-command-stdout>",
        "<system-reminder>",
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

    private static let fractionalTimestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timestampParser = ISO8601DateFormatter()

    private static func parseTimestamp(_ string: String) -> Date? {
        fractionalTimestampParser.date(from: string) ?? timestampParser.date(from: string)
    }

    /// Claude Code: every non-alphanumeric byte of the cwd becomes `-`
    /// (verified: `/Users/jhen/workspace/llama.rn` → `…-llama-rn`).
    static func claudeProjectDirectoryComponent(forCwd cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    // MARK: - Jump prologue

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

    // MARK: - Needles

    /// One entry of the header oracle's index: the ordinal of a loaded
    /// message and the normalized prefix its rendered `❯` row starts with.
    struct JumpNeedle: Equatable {
        var index: Int
        var text: String
    }

    /// The oracle's full index: a needle per loaded message that has one.
    /// Messages whose rendering can't be matched (too short, pure-paste)
    /// simply read as unknown turns during navigation; pre-compact prompts
    /// no longer render at all, so they stay out of the index.
    static func needleEntries(
        for messages: [AgentUserMessage], paneColumns: Int
    ) -> [JumpNeedle] {
        messages.compactMap { message in
            guard message.reachable else { return nil }
            return needle(for: message, paneColumns: paneColumns).map {
                JumpNeedle(index: message.ordinal, text: $0)
            }
        }
    }

    /// Search strings for one prompt. The primary is a first-line prefix cut
    /// to the pane; a 24-column fallback handles right-edge truncation and
    /// small rendering differences. Whitespace is normalized because the TUI
    /// can reflow it differently from JSONL. nil/empty = too short to match.
    static func needles(for message: AgentUserMessage, paneColumns: Int) -> [String] {
        guard let primary = needle(for: message, paneColumns: paneColumns) else { return [] }
        var values = [primary]
        let fallback = terminalPrefix(primary, maxColumns: needleFallbackMaximum)
        if fallback != primary, fallback.count >= 4 { values.append(fallback) }
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
    static func normalizedSearchText(_ text: String) -> String {
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

    // MARK: - Jump find (header-oracle navigation)

    /// The per-capture classifier, shared by every step of the find script.
    /// Claude's pager pins the header of the turn that OWNS THE TOP ROW at
    /// row 1 (verified: scrolling inside a response shows that turn's `❯`
    /// prompt pinned; one PgUp past its beginning flips the pin to the
    /// previous turn while the real header becomes an ordinary row below).
    /// The awk program reports, per settled capture:
    ///
    ///   pin  — 1-based needle index of the row-1 header, 0 for a `❯` row
    ///          matching no known message (wrapper/meta turns, turns older
    ///          than the loaded list), -1 when row 1 is not a `❯` row (the
    ///          banner region above the first turn).
    ///   real — first row 2..(h-chrome) whose `❯` text starts with the
    ///          target needle: the actual prompt row, on screen.
    ///   h    — capture height, for the landing threshold.
    ///
    /// Matching is prefix-only over normalized text and never looks at
    /// assistant prose; the bottom chrome rows are excluded so a drafted
    /// composer line can't false-match.
    private static let classifierProgram =
        "function norm(s) { gsub(/[\\t\\r]/, \" \", s); gsub(\"\\302\\240\", \" \", s); "
        + "gsub(/  +/, \" \", s); sub(/^ +/, \"\", s); sub(/ +$/, \"\", s); return s } "
        + "BEGIN { m = split(ENVIRON[\"MPXNDL\"], L, \"\\n\"); "
        + "pfx = ENVIRON[\"MPXPFX\"]; tgt = ENVIRON[\"MPXTGT\"] } "
        + "{ rows[NR] = $0 } "
        + "END { h = NR; pin = -1; real = 0; "
        + "line = rows[1]; sub(/^ +/, \"\", line); "
        + "if (index(line, pfx) == 1) { "
        + "txt = norm(substr(line, length(pfx) + 1)); pin = 0; "
        + "for (i = 1; i <= m; i++) { split(L[i], kv, \"\\t\"); "
        + "if (kv[2] != \"\" && index(txt, kv[2]) == 1) { pin = kv[1]; break } } } "
        + "lim = h - \(bottomChromeRows); if (lim < 2) lim = h; "
        + "for (r = 2; r <= lim; r++) { line = rows[r]; sub(/^ +/, \"\", line); "
        + "if (index(line, pfx) != 1) continue; "
        + "txt = norm(substr(line, length(pfx) + 1)); "
        + "if (tgt != \"\" && index(txt, tgt) == 1) { real = r; break } } "
        + "printf \"pin=%d real=%d h=%d\\n\", pin, real, h }"

    /// One server-side exec that walks Claude's pager to the target message
    /// and leaves its real `❯` row in the top half of the screen — the
    /// header oracle replaces the old blind needle hunt:
    ///
    /// - `real` in the top half → landed (that IS the message row).
    /// - `real` lower → one PgDn per classify converges (half-page steps
    ///   can't skip the window).
    /// - pin == target → inside the target's response: page up in small
    ///   batches; the crossing produces `real` near the top by construction.
    /// - pin newer than target → directed far scan upward, no absolute page
    ///   cap: the send budget is a runaway stop, not a search radius.
    /// - pin older than target → overshot (or approaching from above): page
    ///   down singles; `real` enters from the bottom and the landing rule
    ///   finishes.
    /// - unknown/no pin (wrapper turns, the banner region) → keep the
    ///   current direction one batch at a time.
    ///
    /// Two upward crossings past the target without ever seeing its row
    /// mean the primary needle doesn't match this rendering — retry once
    /// with the shorter fallback, then give up honestly. Misses, stalls,
    /// and signal cancellation restore in constant time with Ctrl+End
    /// (Claude's scroll-bottom binding; never Esc — Esc can interrupt a
    /// turn that started mid-find).
    static func jumpFindCommand(
        sessionID: String,
        needles: [JumpNeedle],
        targetIndex: Int,
        targetNeedles: [String]
    ) -> String {
        // Longest needle first so nested prefixes ("fix the" / "fix the
        // build") resolve to the more specific message; 1-based indexes keep
        // 0 free as the unknown sentinel.
        let ordered = needles
            .sorted { $0.text.utf8.count > $1.text.utf8.count }
            .map { "\($0.index + 1)\t\($0.text)" }
        let listArguments = ordered.isEmpty
            ? "''"
            : ordered.map(\.shellQuoted).joined(separator: " ")
        let primary = targetNeedles.first ?? "MULTIPLEX_HISTORY_NEEDLE_MISSING"
        let fallback = targetNeedles.dropFirst().first ?? ""
        return TmuxProbe.pathPrefix
            + "sid=\(sessionID.shellQuoted); "
            + "ndl=$(printf '%s\\n' \(listArguments)); "
            + "n1=\(primary.shellQuoted); n2=\(fallback.shellQuoted); "
            + "t=\(targetIndex + 1); "
            + "prog='\(classifierProgram)'; "
            + "capture() { tmux capture-pane -p -t \"$sid\" 2>/dev/null; }; "
            + "classify() { vals=$(printf '%s\\n' \"$cur\" | "
            + "MPXNDL=\"$ndl\" MPXPFX='❯' MPXTGT=\"$tgt\" awk \"$prog\"); "
            + "pin=-1; real=0; h=0; eval \"$vals\"; }; "
            + "settle() { base=\"$1\"; moved=0; polls=0; last=\"$base\"; cur=\"$base\"; "
            + "while [ $polls -lt \(pageSettlePollCap) ]; do "
            + "sleep 0.05; cur=$(capture); [ \"$cur\" != \"$base\" ] && moved=1; "
            + "if [ \"$moved\" = 1 ] && [ \"$cur\" = \"$last\" ]; then break; fi; "
            + "last=\"$cur\"; polls=$((polls+1)); done; }; "
            + "stepk() { count=$1; key=$2; s=0; "
            + "while [ $s -lt $count ]; do "
            + "tmux send-keys -t \"$sid\" \"$key\" 2>/dev/null || return 1; "
            + "s=$((s+1)); sent=$((sent+1)); sleep 0.03; done; "
            + "settle \"$cur\"; }; "
            + "restore() { tmux send-keys -t \"$sid\" C-End 2>/dev/null; sleep 0.08; }; "
            + "found=0; top=0; keep=0; sent=0; osc=0; fbused=0; dir=u; "
            + "tgt=\"$n1\"; "
            + "trap 'keep=1; restore; exit 1' HUP INT TERM; "
            + "trap 'if [ \"$keep\" != 1 ]; then restore; fi' EXIT; "
            // Normalize the start: the user may have scrolled the pager
            // anywhere by hand, and from an unknown position the oracle's
            // first direction would be a guess (a top start stalled it).
            // From live, one PgUp always enters the pager with row-1 pin
            // semantics in force — the LIVE view's row 1 is ordinary
            // transcript and must not be classified.
            + "restore; sleep 0.1; "
            + "cur=$(capture); "
            + "stepk 1 PPage || true; "
            + "while [ $sent -lt \(jumpSendBudget) ]; do "
            + "classify; "
            + "printf 'MPXJ_T %s %s %s\\n' \"$sent\" \"$pin\" \"$real\"; "
            + "[ \"$h\" -ge 12 ] 2>/dev/null || break; "
            + "if [ \"$real\" -gt 0 ]; then "
            + "if [ \"$real\" -le $((h / 2)) ]; then found=1; break; fi; "
            + "dir=d; stepk 1 NPage || break; "
            + "[ \"$moved\" = 0 ] && break; continue; fi; "
            + "if [ \"$pin\" = \"$t\" ]; then "
            + "dir=u; stepk \(oracleBodyBatch) PPage || break; "
            + "[ \"$moved\" = 0 ] && { top=1; break; }; continue; fi; "
            + "if [ \"$pin\" -gt \"$t\" ] 2>/dev/null; then "
            + "dir=u; stepk \(oracleFarBatch) PPage || break; "
            + "[ \"$moved\" = 0 ] && { top=1; break; }; continue; fi; "
            + "if [ \"$pin\" -gt 0 ] 2>/dev/null; then "
            // A known turn OLDER than the target owns the top row: we are
            // above the message (an overshoot, or a needle mismatch).
            + "if [ \"$dir\" = u ]; then osc=$((osc+1)); fi; "
            + "if [ $osc -ge 2 ]; then "
            + "if [ $fbused = 0 ] && [ -n \"$n2\" ]; then "
            + "tgt=\"$n2\"; fbused=1; osc=0; else break; fi; fi; "
            + "dir=d; stepk 1 NPage || break; "
            + "[ \"$moved\" = 0 ] && break; continue; fi; "
            // Unknown ❯ turn (wrapper/meta or older than the list) or the
            // banner region: keep the current direction.
            + "if [ \"$dir\" = u ]; then stepk \(oracleBodyBatch) PPage || break; "
            + "[ \"$moved\" = 0 ] && { top=1; break; }; "
            + "else stepk 1 NPage || break; [ \"$moved\" = 0 ] && break; fi; "
            + "done; "
            + "if [ \"$found\" = 1 ]; then "
            + "keep=1; trap - HUP INT TERM EXIT; printf 'MPXJ_FOUND %s\\n' \"$sent\"; else "
            + "keep=1; restore; trap - HUP INT TERM EXIT; "
            + "if [ \"$top\" = 1 ]; then printf 'MPXJ_TOP %s\\n' \"$sent\"; "
            + "else printf 'MPXJ_EXHAUSTED %s\\n' \"$sent\"; fi; fi; true"
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
    /// time even after a very long seek, and unlike Esc cannot interrupt a
    /// turn that started after finding began.
    static func jumpReturnCommand(sessionID: String, pages _: Int) -> String {
        TmuxProbe.pathPrefix
            + "tmux send-keys -t \(sessionID.shellQuoted) C-End 2>/dev/null; true"
    }
}
