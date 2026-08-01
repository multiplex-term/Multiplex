import Foundation

/// One user prompt extracted from Claude Code's own session file. Claude
/// keeps a JSONL transcript per conversation on the host it runs on
/// (`<config root>/projects/<munged-cwd>/<sessionId>.jsonl`, where the config
/// root is `$CLAUDE_CONFIG_DIR` when set and `~/.claude` otherwise); Multiplex
/// reads a bounded tail over the SSH control plane and shows the real
/// prompts — including the full text of messages the TUI renders truncated.
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
    /// Calibrated on a ~100×30 desktop pane; `jumpSendBudget(paneWidth:
    /// paneHeight:)` scales it up for narrow/short panes, where the same
    /// transcript rewraps into several times the rows and each half-page
    /// step covers fewer of them (an iPhone jump EXHAUSTED at 400 on
    /// content a desktop pane crossed in 76).
    static let jumpSendBudget = 400
    /// Ceiling for the scaled budget — a phone-sized pane with the keyboard
    /// up quadruples the step count, but a walk longer than this is a
    /// runaway whatever the geometry.
    static let jumpSendBudgetMax = 1600
    /// Steps per settle while row 1's turn is provably at least TWO turns
    /// newer than the target (each PgUp moves half the transcript region).
    /// Only there is a big leap safe: the next header to cross belongs to
    /// a known non-target turn, whose pin reports the crossing.
    static let oracleFarBatch = 6
    /// Upward batch anywhere the NEXT header to cross could be the
    /// target's row — inside the target's own response, in the turn just
    /// newer than it (the target's whole turn can be shorter than one
    /// leap), under an unknown pin, and while counting twins: two
    /// half-pages stay within one viewport of rows, so the row cannot
    /// pass through unseen between captures. A faster batch here skipped
    /// a 20-row message whose upstream neighbor was the recovery's only
    /// known pin (user-reported "fix FAIL … scrolled to top").
    static let twinSafeBatch = 2
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
        /// The config root that actually held this pane's registry — Claude
        /// honors `CLAUDE_CONFIG_DIR`, so `~/.claude` is a default, not a
        /// fact. nil lets `readCommand` fall back to the exec shell's own
        /// env / the default root.
        var configDir: String?
    }

    /// Resolve the active pane cwd and Claude Code's exact session id in one
    /// exec. Claude publishes `<config root>/sessions/<pid>.json`; walking
    /// descendants of `#{pane_pid}` ties that registry entry to this pane,
    /// avoiding the common failure where another Claude process in the same
    /// cwd has the newest transcript. Older versions / hosts without the
    /// registry simply omit the marker and retain the mtime fallback.
    ///
    /// The config root honors `CLAUDE_CONFIG_DIR`, tried per candidate pid
    /// most-specific first: the *process's own* environ (Linux `/proc` —
    /// exact even when the var was exported only inside the pane, e.g. by a
    /// session setup script, where the exec channel's env never sees it),
    /// then `ps -E` (pre-Darwin-27 macOS; 27 strips procargs env even for
    /// same-user children — verified — so this rung reads empty there),
    /// then the exec shell's exported value, then `~/.claude`. Every rung
    /// is a *candidate*: `reg` accepts a root only if it actually holds
    /// this pid's registry, so a garbled `ps -E` parse (its env join is
    /// space-ambiguous) can misdirect nothing. The root that held the
    /// registry is reported so `readCommand` reads the matching
    /// `projects/` tree — the same process wrote both.
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
            + "reg() { c=\"$1\"; [ -n \"$c\" ] || return 1; "
            + "f=\"$c/sessions/$p.json\"; [ -r \"$f\" ] || return 1; "
            + "value=$(sed -n 's/.*\"sessionId\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p'"
            + " \"$f\" | head -1); [ -n \"$value\" ]; }; "
            + "out=$(ps -eo pid=,ppid= 2>/dev/null | "
            + "awk -v r=\"$root\" '{ parent[$1] = $2 } END { "
            + "print 0, r; for (pid in parent) { if (pid == r) continue; "
            + "p = pid; depth = 0; "
            + "while (p in parent && p != r && depth < 64) { p = parent[p]; depth++ } "
            + "if (p == r) print depth, pid } }' | sort -n | "
            + "while read -r depth p; do "
            + "pe=; [ -r \"/proc/$p/environ\" ] && "
            + "pe=$(tr '\\0' '\\n' < \"/proc/$p/environ\" 2>/dev/null | "
            + "sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -1); "
            + "[ -n \"$pe\" ] || pe=$(ps -E -o command= -p \"$p\" 2>/dev/null | "
            + "sed -n 's/.* CLAUDE_CONFIG_DIR=\\([^ ]*\\).*/\\1/p' | head -1); "
            + "if reg \"$pe\" || reg \"$CLAUDE_CONFIG_DIR\" || reg \"$HOME/.claude\"; then "
            + "printf '%s\\n%s\\n' \"$value\" \"$c\"; break; fi; done); "
            + "sid=$(printf '%s\\n' \"$out\" | sed -n 1p); "
            + "cfg=$(printf '%s\\n' \"$out\" | sed -n 2p); "
            + "[ -n \"$sid\" ] && printf 'MULTIPLEX_HIST_AGENT_SESSION %s\\n' \"$sid\"; "
            + "[ -n \"$cfg\" ] && printf 'MULTIPLEX_HIST_CONFIG_DIR %s\\n' \"$cfg\"; "
            + "fi; true"
    }

    static func parsePaneContext(_ output: String) -> PaneContext? {
        var cwd: String?
        var sessionID: String?
        var configDir: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("MULTIPLEX_HIST_CWD ") {
                let value = line.dropFirst("MULTIPLEX_HIST_CWD ".count)
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("/") { cwd = value }
            } else if line.hasPrefix("MULTIPLEX_HIST_AGENT_SESSION ") {
                sessionID = line.dropFirst("MULTIPLEX_HIST_AGENT_SESSION ".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("MULTIPLEX_HIST_CONFIG_DIR ") {
                let value = line.dropFirst("MULTIPLEX_HIST_CONFIG_DIR ".count)
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("/") { configDir = value }
            }
        }
        guard let cwd else { return nil }
        return PaneContext(
            cwd: cwd,
            agentSessionID: validatedClaudeSessionID(sessionID),
            configDir: configDir
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
    ///
    /// `configDir` is the pane-resolved config root (the one that held the
    /// registry); without it the exec shell's own `CLAUDE_CONFIG_DIR` — the
    /// case a plain `.shell` tab and registry-less hosts can still cover —
    /// then `~/.claude` apply, mirroring Claude's own resolution. No
    /// cross-root rescue on a miss: `claude --continue` would not look in
    /// `~/.claude` either while the var is set, and a stale wrong-session
    /// transcript is worse than an honest NO SESSION FILE.
    static func readCommand(
        cwd: String, preferredSessionID: String? = nil, configDir: String? = nil
    ) -> String {
        let sessionID = validatedClaudeSessionID(preferredSessionID) ?? ""
        // Relative/garbage roots are dropped, not interpolated — same
        // posture as the session id above (quoting keeps any string inert,
        // but a non-absolute root could only ever be wrong).
        let resolvedRoot = configDir?.hasPrefix("/") == true ? configDir ?? "" : ""
        return "c=\(resolvedRoot.shellQuoted); "
            + "[ -n \"$c\" ] || c=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"; "
            + "d=\"$c/projects/\"\(claudeProjectDirectoryComponent(forCwd: cwd).shellQuoted); "
            + "f=; sid=\(sessionID.shellQuoted); "
            + "if [ -n \"$sid\" ] && [ -f \"$d/$sid.jsonl\" ]; then f=\"$d/$sid.jsonl\"; fi; "
            + "[ -n \"$f\" ] || f=$(ls -t \"$d\"/*.jsonl 2>/dev/null | head -1); "
            + "if [ -n \"$f\" ]; then "
            + "printf 'MULTIPLEX_HIST_FILE %s\\n' \"$f\"; "
            + "echo MULTIPLEX_HIST_BEGIN; "
            + "grep -a '\"type\":\"user\"' \"$f\" 2>/dev/null"
            + " | grep -av '\"tool_use_id\"'"
            // One pasted screenshot inlines hundreds of KB of base64 into a
            // single user line and would eat the whole tail budget, cutting
            // every older prompt out of the list (observed: a 380 KB line in
            // a 5-prompt session). Blank long base64 "data" values before
            // the cut — the parser reads text blocks only, and an escaped
            // \"data\" inside typed prompt text can't match the unescaped
            // JSON key.
            + " | sed -E 's/\"data\":\"[A-Za-z0-9+\\/=]{200,}\"/\"data\":\"\"/g'"
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
    /// the active pane's width + title, the current screen, and how many
    /// DISTINCT client sizes are attached. The app classifies idle from
    /// title+capture — paging a running turn fights streaming repaints,
    /// and Esc would interrupt it. The client-size count names the one
    /// failure the walk cannot beat: `window-size latest` flips the window
    /// whenever a differently-sized second client acts, Claude reflows and
    /// resets its pager, and the walk's coordinates die mid-run
    /// (user-reported against a session with an 89×36 Mac terminal and the
    /// 52×44 app attached at once).
    ///
    /// The mouse flags gate the walk's header clicks: a click is an SGR
    /// byte sequence written to the pane's stdin, safe only while Claude
    /// has mouse reporting on (otherwise the bytes would land in the
    /// composer as text). Unknown format variables render empty on old
    /// tmux, which parses as "no clicks" — fail-soft.
    static func jumpPrologueCommand(sessionName: String) -> String {
        TmuxProbe.pathPrefix
            + "sid=$(tmux list-panes -t \("=\(sessionName)".shellQuoted)"
            + " -F '#{session_id}' 2>/dev/null | head -1); "
            + "if [ -n \"$sid\" ]; then "
            + "printf 'MPXJ_SID %s\\n' \"$sid\"; "
            + "printf 'MPXJ_SIZES %s\\n' \"$(tmux list-clients -t \"$sid\""
            + " -F '#{client_width}x#{client_height}' 2>/dev/null | sort -u | grep -c .)\"; "
            + "tmux list-panes -t \"$sid\""
            + " -F '#{?pane_active,MPXJ_META #{pane_width} #{mouse_any_flag}"
            + " #{mouse_sgr_flag} #{pane_title},}' 2>/dev/null"
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
        /// Distinct attached-client sizes (0 when unknown). More than one
        /// means another client can resize this session under the walk.
        var clientSizeCount: Int = 0
        /// The pane has mouse reporting on with SGR encoding, so the walk
        /// may click Claude's sticky turn header (verified 2.1.214: a click
        /// on the row-1 sticky scrolls straight to that turn's start).
        var supportsHeaderClicks: Bool = false
    }

    static func parseJumpPrologue(_ output: String) -> JumpPrologue? {
        guard !output.contains("MPXJ_NOSESSION") else { return nil }
        var sessionID: String?
        var width = 0
        var title = ""
        var capture: [String] = []
        var sizeCount = 0
        var headerClicks = false
        var inCapture = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("MPXJ_SID ") {
                sessionID = line.dropFirst("MPXJ_SID ".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("MPXJ_SIZES ") {
                sizeCount = Int(
                    line.dropFirst("MPXJ_SIZES ".count)
                        .trimmingCharacters(in: .whitespaces)
                ) ?? 0
            } else if line.hasPrefix("MPXJ_META ") {
                // Fixed-width fields first, variable-length title last —
                // the probe's own format discipline. Old tmux renders the
                // mouse flags empty (positions preserved), which reads as
                // "no clicks".
                let fields = line.dropFirst("MPXJ_META ".count)
                    .split(separator: " ", omittingEmptySubsequences: false)
                width = fields.first.flatMap { Int($0) } ?? 0
                headerClicks = fields.count >= 3
                    && Int(fields[1]) == 1 && Int(fields[2]) == 1
                title = fields.dropFirst(3).joined(separator: " ")
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
            capture: capture,
            clientSizeCount: sizeCount,
            supportsHeaderClicks: headerClicks
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

    /// Search strings for one prompt. The primary is a wrap-safe first-line
    /// prefix cut to the pane; a 24-column fallback handles residual
    /// rendering drift (column-accounting differences, version changes).
    /// Whitespace is normalized because the TUI can reflow it differently
    /// from JSONL. nil/empty = too short to match.
    static func needles(for message: AgentUserMessage, paneColumns: Int) -> [String] {
        guard let primary = needle(for: message, paneColumns: paneColumns) else { return [] }
        var values = [primary]
        let fallback = wrapSafePrefix(primary, maxColumns: needleFallbackMaximum)
        if fallback != primary, fallback.count >= 4 { values.append(fallback) }
        return values
    }

    static func needle(for message: AgentUserMessage, paneColumns: Int) -> String? {
        let line = normalizedSearchText(message.firstLine)
        // Only the sticky header flattens the prompt into one `…`-truncated
        // row (its text budget is width − 4); a REAL transcript row renders
        // the body word-wrapped, so its first row ends at the last word
        // boundary before the width. The needle must be a prefix of BOTH:
        // budget in two extra columns of safety, then retreat to a word
        // boundary in `wrapSafePrefix`.
        let columnBudget = min(paneColumns - 6, needleMaximum)
        guard columnBudget >= 4 else { return nil }
        let needle = wrapSafePrefix(line, maxColumns: columnBudget)
        guard needle.count >= 4 else { return nil }
        return needle
    }

    /// A prefix that cannot run past the first rendered row of a wrapped
    /// prompt: hard-cut to the column budget, then retreat to the last word
    /// boundary — Claude wraps prose at spaces, and a mid-word cut extends
    /// past the row's wrap point exactly when the pane is narrow (the
    /// iPhone failure). A line that fits whole keeps itself; a cut that
    /// already lands on a word boundary, or a leading token spanning the
    /// entire budget (paths, CJK runs — Claude hard-splits those on the
    /// row too), keeps the hard cut. Retreating is always match-safe: a
    /// shorter prefix of the same flow; lost specificity is absorbed by
    /// the from-the-bottom twin count.
    static func wrapSafePrefix(_ text: String, maxColumns: Int) -> String {
        let hard = terminalPrefix(text, maxColumns: maxColumns)
        guard hard != text, hard.count < text.count else { return hard }
        let continuation = text[text.index(text.startIndex, offsetBy: hard.count)...]
        if continuation.first == " " { return hard }
        guard let boundary = hard.lastIndex(of: " ") else { return hard }
        let cut = String(hard[..<boundary]).trimmingCharacters(in: .whitespaces)
        return cut.count >= 4 ? cut : hard
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
    ///   fam  — 1 when the row-1 header itself starts with the target
    ///          needle. Identical prompts ("commit") share one needle, so
    ///          the pin INDEX cannot say which twin's response we are in;
    ///          the driver treats any family pin as the target's turn.
    ///   real — first (topmost) row 2..(h-chrome) whose `❯` text starts
    ///          with the target needle: an actual prompt row, on screen.
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
        + "END { h = NR; pin = -1; fam = 0; real = 0; "
        + "line = rows[1]; sub(/^ +/, \"\", line); "
        + "if (index(line, pfx) == 1) { "
        + "txt = norm(substr(line, length(pfx) + 1)); pin = 0; "
        + "if (tgt != \"\" && index(txt, tgt) == 1) { fam = 1 } "
        + "for (i = 1; i <= m; i++) { split(L[i], kv, \"\\t\"); "
        + "if (kv[2] != \"\" && index(txt, kv[2]) == 1) { pin = kv[1]; break } } } "
        + "lim = h - \(bottomChromeRows); if (lim < 2) lim = h; "
        + "for (r = 2; r <= lim; r++) { line = rows[r]; sub(/^ +/, \"\", line); "
        + "if (index(line, pfx) != 1) continue; "
        + "txt = norm(substr(line, length(pfx) + 1)); "
        + "if (tgt != \"\" && index(txt, tgt) == 1) { real = r; break } } "
        + "printf \"pin=%d fam=%d real=%d h=%d\\n\", pin, fam, real, h }"

    /// Scale the send budget to the pane: the 400 base was calibrated on a
    /// ~100-column, ~30-row desktop pane (transcript region ≈ 24 rows). At
    /// 44 columns the same transcript rewraps into ~2.3× the rows, and with
    /// a docked keyboard the half-page step shrinks too — an unscaled stop
    /// turned real iPhone jumps into false "not found"s.
    static func jumpSendBudget(paneWidth: Int, paneHeight: Int) -> Int {
        var budget = jumpSendBudget
        let width = max(paneWidth, 20)
        if width < 100 { budget = budget * 100 / width }
        let region = max(paneHeight - bottomChromeRows, 8)
        if region < 24 { budget = budget * 24 / region }
        return min(max(budget, jumpSendBudget), jumpSendBudgetMax)
    }

    /// One server-side exec that walks Claude's pager to the target message
    /// and leaves its real `❯` row in the top half of the screen — the
    /// header oracle replaces the old blind needle hunt:
    ///
    /// - `real` in the top half → landed (that IS the message row).
    /// - `real` lower → one PgDn per classify converges (half-page steps
    ///   can't skip the window).
    /// - pin == target → inside the target's response: climb within one
    ///   viewport per capture, so the crossing MUST surface `real`.
    /// - pin ≥ two turns newer → far scan in big leaps (the next header to
    ///   cross is a known non-target turn), no absolute page cap: the send
    ///   budget is a runaway stop, not a search radius. Exactly one turn
    ///   newer → viewport-safe steps; the target's whole turn can be
    ///   shorter than a leap, and a skipped row is only recoverable when a
    ///   KNOWN older pin sits above it (wrapper turns and pre-window
    ///   prompts pin as unknown — user-reported "fix FAIL" skip).
    /// - pin older than target → overshot (or approaching from above): page
    ///   down singles; `real` enters from the bottom and the landing rule
    ///   finishes.
    /// - unknown/no pin (wrapper turns, the banner region) → keep the
    ///   current direction, viewport-safe upward (unknown says nothing
    ///   about distance).
    ///
    /// Two upward crossings past the target without ever seeing its row
    /// mean the primary needle doesn't match this rendering — retry once
    /// with the shorter fallback, then give up honestly. Reaching
    /// scroll-top with the fallback still unused takes the same retry (an
    /// unmatched oldest message never produces the older-pin crossings the
    /// first trigger needs — the original iPhone blind spot). Both retries
    /// RESTART from live, so the upward twin-counting semantics stay valid
    /// under the swapped needle. Misses, stalls, and signal cancellation
    /// restore in constant time with Ctrl+End (Claude's scroll-bottom
    /// binding; never Esc — Esc can interrupt a turn that started
    /// mid-find). A pane too short for the oracle (< 12 rows — a docked
    /// phone keyboard in landscape) reports MPXJ_SHORT instead of
    /// pretending the message is gone.
    ///
    /// Identical prompts ("commit", "continue") share a needle, so the
    /// walk counts the target family from the bottom: climbing upward, each
    /// twin's row enters the viewport from the top exactly once, and the
    /// (newerTwinCount + 1)-th first-appearance is the requested one.
    /// Counting only happens on upward motion, family pins always read as
    /// the target's turn, and every upward batch shrinks to 2 half-pages
    /// (less than one viewport) so no twin row can slip between captures.
    /// The shorter fallback needle can widen the family, so the swap
    /// installs its own `fallbackTwinCount`.
    ///
    /// `headerClicks` arms the sticky header's click-to-jump (verified
    /// 2.1.214: ONLY the row-1 sticky is clickable — a click there scrolls
    /// straight to that turn's start; real `❯` rows, plain content, and the
    /// banner are no-ops). While climbing, any `❯` sticky is clicked
    /// instead of batch-scrolled: one send skips the rest of that turn
    /// however long its response is (the walk's cost stops depending on
    /// response length — the documented pathologies were all length-driven).
    /// On the target's own sticky the click lands the turn top, and the one
    /// PgUp that follows drops the header to 1 + region/2 — always inside
    /// the top-half landing window, so the ordinary acceptance fires. If no
    /// row appears after that PgUp, the row never renders (rebuilt
    /// transcripts omit long multiline bodies) and the walk shortcuts to
    /// the existing NEAR descent. A click that moves nothing disarms
    /// clicking for the rest of the walk and the scroll walk continues
    /// (older Claude without click support, or a coincidental turn-top
    /// start). Clicks stay off for twin targets: the from-the-bottom count
    /// needs rows to drift continuously through the viewport, and a warp
    /// can surface an older twin above the jumped turn's header while that
    /// header sits at row 1 — invisible to `real`, an undercount that
    /// would land on the wrong twin.
    static func jumpFindCommand(
        sessionID: String,
        needles: [JumpNeedle],
        targetIndex: Int,
        targetNeedles: [String],
        newerTwinCount: Int = 0,
        fallbackTwinCount: Int? = nil,
        sendBudget: Int = jumpSendBudget,
        headerClicks: Bool = false
    ) -> String {
        // Longest needle first so nested prefixes ("fix the" / "fix the
        // build") resolve to the more specific message, with the ordinal as
        // a deterministic tie-break; 1-based indexes keep 0 free as the
        // unknown sentinel. Twin needles share their text, so a sticky
        // header matching one cannot say WHICH twin's turn owns the top
        // row — reporting the oldest twin's ordinal made the driver
        // "descend from an overshoot" while it was actually below the
        // target (live view, newest twin pinned). Twins embed as 0:
        // direction-neutral, while the target's own family still rides
        // the fam flag.
        var textCounts: [String: Int] = [:]
        for needle in needles { textCounts[needle.text, default: 0] += 1 }
        let ordered = needles
            .sorted {
                $0.text.utf8.count != $1.text.utf8.count
                    ? $0.text.utf8.count > $1.text.utf8.count
                    : $0.index < $1.index
            }
            .map { "\(textCounts[$0.text, default: 0] > 1 ? 0 : $0.index + 1)\t\($0.text)" }
        let listArguments = ordered.isEmpty
            ? "''"
            : ordered.map(\.shellQuoted).joined(separator: " ")
        let primary = targetNeedles.first ?? "MULTIPLEX_HISTORY_NEEDLE_MISSING"
        let fallback = targetNeedles.dropFirst().first ?? ""
        let twins = max(0, newerTwinCount)
        let fallbackTwins = max(twins, fallbackTwinCount ?? twins)
        // Twin-safe batches everywhere when EITHER needle has a family —
        // the fallback can swap in mid-walk, and its viewport guarantee
        // must already hold. Even for unique targets, only the far scan
        // (row 1 provably ≥ 2 turns newer) may leap.
        let anyTwins = max(twins, fallbackTwins) > 0
        let farBatch = anyTwins ? twinSafeBatch : oracleFarBatch
        // Header clicks warp the viewport, which is exactly what the twin
        // count cannot survive — unique targets only.
        let clicks = headerClicks && !anyTwins
        return TmuxProbe.pathPrefix
            + "sid=\(sessionID.shellQuoted); "
            + "ndl=$(printf '%s\\n' \(listArguments)); "
            + "n1=\(primary.shellQuoted); n2=\(fallback.shellQuoted); "
            + "t=\(targetIndex + 1); k=\(twins); k2=\(fallbackTwins); "
            + "prog='\(classifierProgram)'; "
            + "capture() { tmux capture-pane -p -t \"$sid\" 2>/dev/null; }; "
            + "classify() { vals=$(printf '%s\\n' \"$cur\" | "
            + "MPXNDL=\"$ndl\" MPXPFX='❯' MPXTGT=\"$tgt\" awk \"$prog\"); "
            + "pin=-1; fam=0; real=0; h=0; eval \"$vals\"; "
            + "if [ \"$fam\" = 1 ]; then pin=$t; fi; }; "
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
            // Wait out an in-flight redraw from an UNKNOWN base — a C-End
            // from a deep scroll can repaint for longer than a fixed sleep,
            // and a stale capture would anchor the next settle against the
            // pre-restore screen.
            + "stab() { cur=$(capture); p=0; while [ $p -lt \(pageSettlePollCap) ]; do "
            + "sleep 0.05; nxt=$(capture); [ \"$nxt\" = \"$cur\" ] && break; "
            + "cur=\"$nxt\"; p=$((p+1)); done; }; "
            + "found=0; near=0; top=0; short=0; keep=0; sent=0; osc=0; fbused=0; dir=u; "
            + "seen=0; lastr=0; h0=0; rsz=0; sawt=0; sawreal=0; nb=0; "
            + "ck=\(clicks ? 1 : 0); ckt=0; "
            // SGR press+release on row 1 column 2 — Claude's sticky turn
            // header. Only injected while ck=1 (pane mouse reporting on,
            // unique target) and only over a `❯` sticky the classifier
            // just saw.
            + "mseq=$(printf '\\033[<0;2;1M\\033[<0;2;1m'); "
            + "tgt=\"$n1\"; "
            + "trap 'keep=1; restore; exit 1' HUP INT TERM; "
            + "trap 'if [ \"$keep\" != 1 ]; then restore; fi' EXIT; "
            // Restart the walk from live — the only position where the
            // upward twin-count semantics are known-valid. A pending
            // click-verify flag dies with the old position.
            + "rebase() { osc=0; seen=0; lastr=0; ckt=0; dir=u; restore; stab; }; "
            // Swap in the fallback needle. The fallback family can be
            // wider, so its own twin count comes along.
            + "swapfb() { tgt=\"$n2\"; k=$k2; fbused=1; rebase; }; "
            // One upward batch. Hitting scroll-top before the fallback has
            // had its turn is a needle-mismatch signal, not a miss: an
            // unmatched OLDEST message can never produce the older-pin
            // crossings the other fallback trigger needs. Scroll-top after
            // BOTH needles, when the target's turn was pinned but its row
            // never rendered, enters the nearby descent instead.
            + "climb() { stepk \"$1\" PPage || return 1; "
            + "if [ \"$moved\" = 0 ]; then "
            + "if [ $fbused = 0 ] && [ -n \"$n2\" ]; then swapfb; stepk 1 PPage || return 1; "
            + "elif [ $sawt = 1 ] && [ $sawreal = 0 ] && [ $nb = 0 ]; then nb=1; dir=d; "
            + "else top=1; return 1; fi; fi; }; "
            // Click the sticky at row 1: one send jumps to that turn's
            // start, then one PgUp crosses its header so the next classify
            // sees it as a real row (or reports the crossing to the
            // oracle). A click that moved nothing disarms clicking — this
            // Claude doesn't jump, or the view already sat at the turn's
            // top — and the scroll walk resumes without it.
            + "hclick() { tmux send-keys -t \"$sid\" -l \"$mseq\" 2>/dev/null || return 1; "
            + "sent=$((sent+1)); settle \"$cur\"; "
            + "printf 'MPXJ_C %s %s\\n' \"$sent\" \"$moved\"; }; "
            + "cskip() { dir=u; hclick || return 1; "
            + "if [ \"$moved\" = 1 ]; then climb 1 || return 1; else ck=0; fi; }; "
            // Normalize the start: the user may have scrolled the pager
            // anywhere by hand, and from an unknown position the oracle's
            // first direction would be a guess (a top start stalled it).
            // From live, one PgUp always enters the pager with row-1 pin
            // semantics in force — the LIVE view's row 1 is ordinary
            // transcript and must not be classified.
            + "restore; stab; "
            + "stepk 1 PPage || true; "
            + "while [ $sent -lt \(sendBudget) ]; do "
            + "classify; "
            + "printf 'MPXJ_T %s %s %s %s\\n' \"$sent\" \"$pin\" \"$real\" \"$seen\"; "
            + "[ \"$h\" -ge 12 ] 2>/dev/null || { short=1; break; }; "
            // A capture-height change mid-walk = another attached client
            // resized the window (`window-size latest`): Claude reflowed
            // and reset its pager, so the position — and possibly the
            // needles, which are baked for the prologue width — is void.
            // Restart once for a transient flip; a second flip is a
            // standing size fight the walk cannot win.
            + "if [ \"$h0\" = 0 ]; then h0=$h; fi; "
            + "if [ \"$h\" != \"$h0\" ]; then "
            + "if [ \"$rsz\" = 0 ]; then rsz=1; h0=$h; rebase; "
            + "stepk 1 PPage || break; continue; else break; fi; fi; "
            // Verify the capture after a target-header click + PgUp. The
            // row should now be real (~1 + region/2, inside the landing
            // window) and the ordinary branches finish. No row while the
            // pin moved on = the row never renders (rebuilt transcript) —
            // go straight to the NEAR descent instead of burning the
            // crossing/fallback machinery. Still pinned to the target with
            // no row = the click didn't land the turn top — disarm and let
            // the scroll walk continue.
            + "if [ \"$ckt\" = 1 ]; then ckt=0; "
            + "if [ \"$real\" = 0 ]; then "
            + "if [ \"$pin\" = \"$t\" ]; then ck=0; "
            + "else nb=1; dir=d; continue; fi; fi; fi; "
            + "if [ \"$real\" -gt 0 ]; then "
            + "sawreal=1; "
            // Rows only drift DOWN while climbing, so a topmost match that
            // appeared from nothing or jumped upward is a twin seen for the
            // first time.
            + "if [ \"$dir\" = u ]; then "
            + "if [ \"$lastr\" = 0 ] || [ \"$real\" -lt \"$lastr\" ]; then "
            + "seen=$((seen+1)); fi; lastr=$real; fi; "
            // A unique target lands on ANY sighting — a batched climb can
            // cross the header between captures, and the recovery descent
            // then sights the row while dir=d, where the upward count
            // never runs (a k=0 walk once re-climbed a 90-page turn twice
            // over exactly this). Only twins need the count discipline.
            + "if [ \"$k\" = 0 ] || [ \"$seen\" -gt \"$k\" ]; then "
            + "if [ \"$real\" -le $((h / 2)) ]; then found=1; break; fi; "
            + "dir=d; stepk 1 NPage || break; "
            + "[ \"$moved\" = 0 ] && break; continue; fi; "
            // A newer twin: climb through it.
            + "dir=u; climb \(twinSafeBatch) || break; continue; fi; "
            + "lastr=0; "
            + "if [ \"$pin\" = \"$t\" ]; then "
            + "sawt=1; "
            // Nearby descent: the first view owned by the target's turn
            // coming DOWN from above is the turn's top — its sticky IS the
            // message's flattened row. The exact row never rendered (a
            // rebuilt transcript omits long multiline prompt bodies), so
            // this is the closest true landing that exists.
            + "if [ \"$nb\" = 1 ]; then near=1; break; fi; "
            // The target's own sticky: click it. The jump lands the turn
            // top and cskip's PgUp surfaces the header as a real row in
            // the landing window — 2 sends instead of climbing the whole
            // response. ckt marks the next classify as the verify pass.
            + "if [ \"$ck\" = 1 ]; then ckt=1; cskip || break; continue; fi; "
            + "dir=u; climb \(twinSafeBatch) || break; continue; fi; "
            + "if [ \"$nb\" = 1 ]; then "
            // Descend in singles toward the turn; overshooting to a NEWER
            // pin steps back up one.
            + "if [ \"$pin\" -gt \"$t\" ] 2>/dev/null; then "
            + "dir=u; stepk 1 PPage || break; else "
            + "dir=d; stepk 1 NPage || break; fi; "
            + "[ \"$moved\" = 0 ] && break; continue; fi; "
            + "if [ \"$pin\" -gt \"$t\" ] 2>/dev/null; then "
            // Row 1's turn is newer than the target. With clicks armed,
            // skip its whole remaining response in one send — between here
            // and its start every row belongs to this turn, so nothing can
            // pass unseen. Otherwise: two or more turns away, the next
            // header to cross is a known non-target turn — leap. Just one
            // turn away, the NEXT crossing is the target's own row and the
            // target's whole turn can be shorter than a leap: stay within
            // one viewport per capture.
            + "if [ \"$ck\" = 1 ]; then cskip || break; continue; fi; "
            + "if [ \"$pin\" -gt $((t + 1)) ]; then "
            + "dir=u; climb \(farBatch) || break; continue; fi; "
            + "dir=u; climb \(twinSafeBatch) || break; continue; fi; "
            + "if [ \"$pin\" -gt 0 ] 2>/dev/null; then "
            // A known turn OLDER than the target owns the top row: we are
            // above the message (an overshoot, or a needle mismatch).
            + "if [ \"$dir\" = u ]; then osc=$((osc+1)); fi; "
            + "if [ $osc -ge 2 ]; then "
            + "if [ $fbused = 0 ] && [ -n \"$n2\" ]; then "
            + "swapfb; stepk 1 PPage || break; continue; "
            // Both needles crossed the pinned target turn without its row
            // ever rendering: land nearby instead of lying "not found".
            + "elif [ $sawt = 1 ] && [ $sawreal = 0 ] && [ $nb = 0 ]; then "
            + "nb=1; dir=d; continue; else break; fi; fi; "
            + "dir=d; stepk 1 NPage || break; "
            + "[ \"$moved\" = 0 ] && break; continue; fi; "
            // Unknown ❯ turn (wrapper/meta or older than the list) or the
            // banner region: keep the current direction. A clickable
            // unknown sticky (pin 0, not the bannered -1) is still a turn
            // header — clicking skips its response like any other, the
            // biggest win of all here since unknown turns otherwise crawl
            // viewport-safe. Unknown says nothing about distance, so a
            // scroll upward stays viewport-safe — a wrapper turn can sit
            // directly below the target.
            + "if [ \"$dir\" = u ]; then "
            + "if [ \"$ck\" = 1 ] && [ \"$pin\" = 0 ]; then cskip || break; continue; fi; "
            + "climb \(twinSafeBatch) || break; "
            + "else stepk 1 NPage || break; [ \"$moved\" = 0 ] && break; fi; "
            + "done; "
            + "if [ \"$found\" = 1 ]; then "
            + "keep=1; trap - HUP INT TERM EXIT; printf 'MPXJ_FOUND %s\\n' \"$sent\"; "
            + "elif [ \"$near\" = 1 ]; then "
            + "keep=1; trap - HUP INT TERM EXIT; printf 'MPXJ_NEAR %s\\n' \"$sent\"; else "
            + "keep=1; restore; trap - HUP INT TERM EXIT; "
            // Any failure after a detected flip reports the flip: the
            // needles were built for the prologue geometry, so a post-flip
            // TOP/EXHAUSTED is not evidence the message is gone.
            + "if [ \"$rsz\" = 1 ]; then printf 'MPXJ_RESIZED %s\\n' \"$sent\"; "
            + "elif [ \"$short\" = 1 ]; then printf 'MPXJ_SHORT %s\\n' \"$sent\"; "
            + "elif [ \"$top\" = 1 ]; then printf 'MPXJ_TOP %s\\n' \"$sent\"; "
            + "else printf 'MPXJ_EXHAUSTED %s\\n' \"$sent\"; fi; fi; true"
    }

    enum JumpFindResult: Equatable {
        case found(pages: Int)
        /// Landed at the target turn's top — its sticky header IS the
        /// message's flattened row — because the exact row never rendered:
        /// a REBUILT transcript (resume, or the reflow after any resize)
        /// omits a long multiline prompt's body entirely; only live-drawn
        /// rows from the original submission ever show it.
        case near(pages: Int)
        case top(pages: Int)
        case exhausted(pages: Int)
        /// The pane is too short for the header oracle (docked keyboard on
        /// a phone in landscape) — an actionable state, not a missing
        /// message.
        case short(pages: Int)
        /// The window was resized mid-walk (another attached client under
        /// `window-size latest`): the pager reset and the needles' geometry
        /// is void, so the miss says nothing about the message.
        case resized(pages: Int)
    }

    static func parseJumpFind(_ output: String) -> JumpFindResult? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2, let pages = Int(fields[1]) else { continue }
            switch fields[0] {
            case "MPXJ_FOUND": return .found(pages: pages)
            case "MPXJ_NEAR": return .near(pages: pages)
            case "MPXJ_TOP": return .top(pages: pages)
            case "MPXJ_EXHAUSTED": return .exhausted(pages: pages)
            case "MPXJ_SHORT": return .short(pages: pages)
            case "MPXJ_RESIZED": return .resized(pages: pages)
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
