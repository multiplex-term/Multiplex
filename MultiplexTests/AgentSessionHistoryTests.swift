import XCTest
@testable import Multiplex

/// Fixture shapes mirror real Claude Code 2.1.211 session files and pager
/// behavior inspected 2026-07-16 — see local-plan/agent-message-history.md
/// for the pollution taxonomy and the header-oracle experiment record.
final class AgentSessionHistoryTests: XCTestCase {

    // MARK: Claude Code parsing

    private func wrapped(_ body: String) -> String {
        """
        MULTIPLEX_HIST_FILE /home/dev/.claude/projects/-home-dev-app/abc.jsonl
        MULTIPLEX_HIST_BEGIN
        \(body)
        MULTIPLEX_HIST_END
        """
    }

    func testClaudeCodeExtractsRealPromptsOnly() {
        let body = """
        ge","content":[{"type":"tool_result","tool_use_id":"t1","content":"cut tail line"}]}}
        {"type":"user","isMeta":true,"message":{"role":"user","content":"caveat text"},"timestamp":"2026-07-16T03:00:00.000Z"}
        {"type":"user","message":{"role":"user","content":"Fix the probe parser"},"timestamp":"2026-07-16T03:01:02.500Z"}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"big"}]}}
        {"type":"user","message":{"role":"user","content":"<task-notification>agent finished</task-notification>"}}
        {"type":"user","message":{"role":"user","content":"<command-message>compact</command-message>\\n<command-name>/compact</command-name>"}}
        {"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Now run the tests"},{"type":"image","source":{}}]},"timestamp":"2026-07-16T03:05:00.000Z"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\\"type\\":\\"user\\" echoed in prose"}]}}
        """
        guard let result = AgentSessionHistory.parseReadOutput(wrapped(body))
        else { return XCTFail("expected a parse") }

        XCTAssertEqual(result.filePath, "/home/dev/.claude/projects/-home-dev-app/abc.jsonl")
        XCTAssertEqual(result.messages.map(\.text), [
            "Fix the probe parser",
            "Now run the tests",
        ])
        XCTAssertEqual(result.messages.map(\.ordinal), [0, 1])
        XCTAssertEqual(result.messages.map(\.reachable), [true, true])
        XCTAssertNotNil(result.messages[0].timestamp)
    }

    func testCompactSummaryIsFilteredButIsNotABoundary() {
        // The compact summary is itself a type:user entry (no isMeta): it
        // must not appear as a prompt. It is NOT a boundary either — it
        // comes from auto-compaction / continued sessions, which keep the
        // rendered transcript, so hiding JUMP before it was a false
        // negative (user-reported).
        let body = """
        {"type":"user","message":{"role":"user","content":"Old prompt one"}}
        {"type":"user","message":{"role":"user","content":"Old prompt two"}}
        {"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context…"}}
        {"type":"user","message":{"role":"user","content":"Fresh prompt"}}
        """
        let result = AgentSessionHistory.parseReadOutput(wrapped(body))
        XCTAssertEqual(result?.messages.map(\.text), [
            "Old prompt one", "Old prompt two", "Fresh prompt",
        ])
        XCTAssertEqual(result?.messages.map(\.reachable), [true, true, true])

        // Every listed turn stays in the oracle index.
        let entries = AgentSessionHistory.needleEntries(
            for: result?.messages ?? [], paneColumns: 100
        )
        XCTAssertEqual(entries.map(\.index), [0, 1, 2])
    }

    func testTypedCompactCommandIsAlsoABoundary() {
        // 2.1.211 records manual /compact as a plain "/compact" user line
        // (no isCompactSummary entry) plus <command-…> wrappers.
        let body = """
        {"type":"user","message":{"role":"user","content":"Old prompt"}}
        {"type":"user","message":{"role":"user","content":"/compact"}}
        {"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>\\n<command-message>compact</command-message>"}}
        {"type":"user","message":{"role":"user","content":"Fresh prompt"}}
        """
        let result = AgentSessionHistory.parseReadOutput(wrapped(body))
        XCTAssertEqual(result?.messages.map(\.text), ["Old prompt", "Fresh prompt"])
        XCTAssertEqual(result?.messages.map(\.reachable), [false, true])
    }

    func testImageMessageKeepsTextAfterDataBlanking() {
        // What the read command yields for a pasted-screenshot prompt after
        // the sed pass blanked the base64: the text block still lists.
        let body = """
        {"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":""}},{"type":"text","text":"[Image #1] there is a problem, bottom area should be full width"}]},"timestamp":"2026-07-16T10:00:00.000Z"}
        """
        let result = AgentSessionHistory.parseReadOutput(wrapped(body))
        XCTAssertEqual(
            result?.messages.map(\.text),
            ["[Image #1] there is a problem, bottom area should be full width"]
        )
    }

    func testSlashCommandsAreActionsNotPrompts() {
        let body = """
        {"type":"user","message":{"role":"user","content":"/create-pr with a title"}}
        {"type":"user","message":{"role":"user","content":"/slack:standup"}}
        {"type":"user","message":{"role":"user","content":"/etc/hosts is broken, fix it"}}
        """
        let result = AgentSessionHistory.parseReadOutput(wrapped(body))
        XCTAssertEqual(result?.messages.map(\.text), ["/etc/hosts is broken, fix it"])
        XCTAssertTrue(AgentSessionHistory.isSlashCommand("/compact"))
        XCTAssertTrue(AgentSessionHistory.isSlashCommand("/rewind now"))
        XCTAssertFalse(AgentSessionHistory.isSlashCommand("/etc/hosts is broken"))
        XCTAssertFalse(AgentSessionHistory.isSlashCommand("not /a command"))
    }

    func testCompactBoundarySurvivesMessageCapSlice() {
        var lines = (0..<8).map {
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"early \($0)\"}}"
        }
        lines.append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"/compact\"}}")
        lines += (0..<60).map {
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"late \($0)\"}}"
        }
        let result = AgentSessionHistory.parseReadOutput(
            wrapped(lines.joined(separator: "\n"))
        )
        // The early prompts fell off the 50-message cap entirely; everything
        // kept is post-compact and reachable.
        XCTAssertEqual(result?.messages.count, AgentSessionHistory.maxMessages)
        XCTAssertEqual(result?.messages.first?.text, "late 10")
        XCTAssertTrue(result?.messages.allSatisfy(\.reachable) ?? false)
    }

    func testNoFileSentinelMeansEmptyResult() {
        let result = AgentSessionHistory.parseReadOutput("MULTIPLEX_HIST_NOFILE")
        XCTAssertEqual(result, AgentSessionHistory.ReadResult(filePath: nil, messages: []))
    }

    func testMissingSentinelsMeanNil() {
        XCTAssertNil(AgentSessionHistory.parseReadOutput("garbage"))
    }

    func testMessageCapKeepsNewest() {
        let lines = (0..<60).map {
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"prompt \($0)\"}}"
        }
        let result = AgentSessionHistory.parseReadOutput(
            wrapped(lines.joined(separator: "\n"))
        )
        XCTAssertEqual(result?.messages.count, AgentSessionHistory.maxMessages)
        XCTAssertEqual(result?.messages.first?.text, "prompt 10")
        XCTAssertEqual(result?.messages.last?.text, "prompt 59")
    }

    // MARK: Locating

    func testClaudeProjectDirectoryComponent() {
        XCTAssertEqual(
            AgentSessionHistory.claudeProjectDirectoryComponent(
                forCwd: "/Users/jhen/workspace2/Multiplex"
            ),
            "-Users-jhen-workspace2-Multiplex"
        )
        // Dots and underscores flatten too (verified: llama.rn → llama-rn).
        XCTAssertEqual(
            AgentSessionHistory.claudeProjectDirectoryComponent(
                forCwd: "/Users/jhen/workspace/llama.rn"
            ),
            "-Users-jhen-workspace-llama-rn"
        )
        XCTAssertEqual(
            AgentSessionHistory.claudeProjectDirectoryComponent(forCwd: "/tmp/a_b c"),
            "-tmp-a-b-c"
        )
    }

    func testReadCommandPrefersRegistrySessionAndFallsBackToMtime() {
        let sessionID = "359827c7-0214-435f-b01b-0ce0dbb29b06"
        let command = AgentSessionHistory.readCommand(
            cwd: "/Users/dev/app",
            preferredSessionID: sessionID
        )
        XCTAssertTrue(command.contains("$HOME/.claude/projects/"))
        XCTAssertTrue(command.contains("'-Users-dev-app'"))
        XCTAssertTrue(command.contains("sid='\(sessionID)'"))
        XCTAssertTrue(command.contains("$d/$sid.jsonl"))
        XCTAssertTrue(command.contains("[ -n \"$f\" ] || f=$(ls -t"))
        XCTAssertTrue(command.contains("grep -av '\"tool_use_id\"'"))
        // Attachment base64 is blanked BEFORE the byte cut, or one pasted
        // screenshot crowds every older prompt out of the window.
        XCTAssertTrue(command.contains(
            "sed -E 's/\"data\":\"[A-Za-z0-9+\\/=]{200,}\"/\"data\":\"\"/g'"
        ))
        XCTAssertTrue(
            command.range(of: "sed -E")!.lowerBound
                < command.range(of: "tail -c")!.lowerBound
        )
        XCTAssertTrue(command.contains("tail -c \(AgentSessionHistory.tailByteBudget)"))
        XCTAssertTrue(command.hasSuffix("true"))

        // Registry values become a path component: anything but Claude's
        // UUID shape is discarded rather than interpolated.
        let invalid = AgentSessionHistory.readCommand(
            cwd: "/Users/dev/app",
            preferredSessionID: "../../etc/passwd"
        )
        XCTAssertTrue(invalid.contains("sid=''"))
        XCTAssertFalse(invalid.contains("../../etc/passwd"))
    }

    func testPaneContextCommandUsesExactTargetAndClaudeProcessRegistry() {
        let command = AgentSessionHistory.paneContextCommand(sessionName: "ma in")
        XCTAssertTrue(command.contains("list-panes -t '=ma in'"))
        XCTAssertTrue(command.contains("pane_current_path"))
        XCTAssertTrue(command.contains("pane_pid"))
        XCTAssertTrue(command.contains("$HOME/.claude/sessions/$p.json"))
        XCTAssertTrue(command.contains("sessionId"))
        XCTAssertFalse(command.contains("display-message"))
    }

    func testPaneContextParsesAndValidatesPreferredSessionID() {
        let id = "359827C7-0214-435F-B01B-0CE0DBB29B06"
        XCTAssertEqual(
            AgentSessionHistory.parsePaneContext(
                "noise\nMULTIPLEX_HIST_CWD /Users/dev/my app\n"
                    + "MULTIPLEX_HIST_AGENT_SESSION \(id)\n"
            ),
            AgentSessionHistory.PaneContext(
                cwd: "/Users/dev/my app",
                agentSessionID: id.lowercased()
            )
        )
        XCTAssertEqual(
            AgentSessionHistory.parsePaneContext(
                "MULTIPLEX_HIST_CWD /Users/dev/app\n"
                    + "MULTIPLEX_HIST_AGENT_SESSION ../../etc/passwd\n"
            ),
            AgentSessionHistory.PaneContext(
                cwd: "/Users/dev/app", agentSessionID: nil
            )
        )
        XCTAssertNil(AgentSessionHistory.parsePaneContext("no path here\n"))
    }

    // MARK: Needles

    private func message(_ text: String, ordinal: Int = 0) -> AgentUserMessage {
        AgentUserMessage(ordinal: ordinal, text: text, timestamp: nil)
    }

    func testNeedleUsesFirstLinePrefix() {
        let needle = AgentSessionHistory.needle(
            for: message("Fix the parser\nand then some detail"),
            paneColumns: 100
        )
        XCTAssertEqual(needle, "Fix the parser")
    }

    func testNeedleCapsAtPaneWidthAndMaximum() {
        // A single unbroken token keeps the hard cut — Claude hard-splits
        // it on the row too.
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(
            AgentSessionHistory.needle(for: message(long), paneColumns: 100)?.count,
            AgentSessionHistory.needleMaximum
        )
        XCTAssertEqual(
            AgentSessionHistory.needle(for: message(long), paneColumns: 40)?.count,
            34
        )
    }

    func testNeedleRetreatsToWordBoundaryAtNarrowPanes() {
        // 44-column iPhone pane, budget 38. The real transcript row wraps
        // "@desktop-…-desktop Implement…" after the 36-column token, so a
        // mid-word needle ("…-desktop Im") could never prefix-match it —
        // the verified iPhone failure.
        let line = "@desktop-apps/bricks-project-desktop Implement new BottomArea"
        XCTAssertEqual(
            AgentSessionHistory.needle(for: message(line), paneColumns: 44),
            "@desktop-apps/bricks-project-desktop"
        )
        let prose = "top bar: right area toggle button always position on right"
        XCTAssertEqual(
            AgentSessionHistory.needle(for: message(prose), paneColumns: 44),
            "top bar: right area toggle button"
        )
        // Wide panes still cap at the 60-column maximum, boundary-aligned.
        XCTAssertEqual(
            AgentSessionHistory.needle(for: message(line), paneColumns: 100),
            "@desktop-apps/bricks-project-desktop Implement new"
        )
        // A first line that fits its budget whole is untouched.
        XCTAssertEqual(
            AgentSessionHistory.needle(for: message(prose), paneColumns: 100),
            prose
        )
    }

    func testWrapSafePrefixKeepsBoundaryAlignedCuts() {
        // The budget edge falls right before a space: the hard cut IS the
        // word boundary, nothing to retreat.
        XCTAssertEqual(
            AgentSessionHistory.wrapSafePrefix("alpha beta gamma", maxColumns: 10),
            "alpha beta"
        )
        // Mid-word cut retreats to the last space.
        XCTAssertEqual(
            AgentSessionHistory.wrapSafePrefix("alpha beta gamma", maxColumns: 12),
            "alpha beta"
        )
        // A retreat below four characters keeps the hard cut instead.
        XCTAssertEqual(
            AgentSessionHistory.wrapSafePrefix("ok Megatoken", maxColumns: 8),
            "ok Megat"
        )
        // Fitting whole never cuts.
        XCTAssertEqual(
            AgentSessionHistory.wrapSafePrefix("fits whole", maxColumns: 40),
            "fits whole"
        )
    }

    func testNeedleNormalizesWhitespaceAndDropsControls() {
        XCTAssertEqual(
            AgentSessionHistory.needle(
                for: message("  run   this \t thing\u{0007} now  "),
                paneColumns: 80
            ),
            "run this thing now"
        )
    }

    func testNeedlesIncludeShortFallbackForRenderedTruncation() {
        let values = AgentSessionHistory.needles(
            for: message(String(repeating: "abcdefghij ", count: 10)),
            paneColumns: 100
        )
        XCTAssertEqual(values, [
            "abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij",
            "abcdefghij abcdefghij",
        ])
        XCTAssertLessThanOrEqual(values[1].count, AgentSessionHistory.needleFallbackMaximum)
        XCTAssertTrue(values[0].hasPrefix(values[1]))
    }

    func testNeedleCountsWideCharactersDouble() {
        let wide = String(repeating: "個", count: 50)
        let needle = AgentSessionHistory.needle(for: message(wide), paneColumns: 44)
        // 38-column budget → 19 double-width characters; an unbroken CJK
        // run keeps the hard cut (the row hard-splits it too).
        XCTAssertEqual(needle?.count, 19)
    }

    func testNeedleRefusesTinyMessages() {
        XCTAssertNil(AgentSessionHistory.needle(for: message("hi"), paneColumns: 100))
        XCTAssertNil(AgentSessionHistory.needle(for: message("ok  "), paneColumns: 100))
    }

    func testNeedleEntriesKeepOrdinalsAndSkipUnmatchable() {
        let entries = AgentSessionHistory.needleEntries(
            for: [
                message("Alpha turn: reply with OK", ordinal: 0),
                message("no", ordinal: 1),
                message("Charlie turn: print numbers", ordinal: 2),
            ],
            paneColumns: 100
        )
        XCTAssertEqual(entries, [
            AgentSessionHistory.JumpNeedle(index: 0, text: "Alpha turn: reply with OK"),
            AgentSessionHistory.JumpNeedle(index: 2, text: "Charlie turn: print numbers"),
        ])
    }

    // MARK: Jump prologue / find parsing

    func testJumpPrologueParses() {
        let output = """
        MPXJ_SID $4
        MPXJ_SIZES 2
        MPXJ_META 120 1 1 ✳ Claude Code
        MPXJ_CAP
        line one
        ❯ old prompt
        MPXJ_CAPEND
        """
        let prologue = AgentSessionHistory.parseJumpPrologue(output)
        XCTAssertEqual(prologue?.sessionID, "$4")
        XCTAssertEqual(prologue?.paneWidth, 120)
        XCTAssertEqual(prologue?.paneTitle, "✳ Claude Code")
        XCTAssertEqual(prologue?.capture, ["line one", "❯ old prompt"])
        XCTAssertEqual(prologue?.clientSizeCount, 2)
        XCTAssertEqual(prologue?.supportsHeaderClicks, true)

        // Clicks need mouse reporting AND the SGR encoding the click bytes
        // use.
        let noSGR = AgentSessionHistory.parseJumpPrologue(
            "MPXJ_SID $4\nMPXJ_META 80 1 0 t\nMPXJ_CAP\nrow\nMPXJ_CAPEND"
        )
        XCTAssertEqual(noSGR?.supportsHeaderClicks, false)
        XCTAssertEqual(noSGR?.paneTitle, "t")

        // Old tmux renders unknown format variables empty — positions
        // survive, clicks read as unsupported, the title stays intact.
        let oldTmux = AgentSessionHistory.parseJumpPrologue(
            "MPXJ_SID $4\nMPXJ_META 80   ✳ Claude Code\nMPXJ_CAP\nrow\nMPXJ_CAPEND"
        )
        XCTAssertEqual(oldTmux?.supportsHeaderClicks, false)
        XCTAssertEqual(oldTmux?.paneTitle, "✳ Claude Code")

        // Older or partial output without the size marker stays valid.
        let bare = AgentSessionHistory.parseJumpPrologue(
            "MPXJ_SID $4\nMPXJ_META 80 1 1 t\nMPXJ_CAP\nrow\nMPXJ_CAPEND"
        )
        XCTAssertEqual(bare?.clientSizeCount, 0)
    }

    func testJumpPrologueNoSession() {
        XCTAssertNil(AgentSessionHistory.parseJumpPrologue("MPXJ_NOSESSION"))
    }

    func testJumpFindCommandCarriesHeaderOracle() {
        let command = AgentSessionHistory.jumpFindCommand(
            sessionID: "$4",
            needles: [
                .init(index: 0, text: "Alpha turn"),
                .init(index: 1, text: "it's the Bravo turn"),
                .init(index: 2, text: "Charlie"),
            ],
            targetIndex: 1,
            targetNeedles: ["it's the Bravo turn", "it's the Bravo"],
            headerClicks: true
        )
        XCTAssertTrue(command.contains("sid='$4'"))
        // The oracle index rides along: 1-based ordinals, longest needle
        // first so nested prefixes resolve to the more specific message.
        XCTAssertTrue(command.contains("'2\tit'\\''s the Bravo turn'"))
        XCTAssertTrue(command.contains("'1\tAlpha turn' '3\tCharlie'"))
        XCTAssertTrue(
            command.range(of: "it'\\''s the Bravo turn")!.lowerBound
                < command.range(of: "'1\tAlpha turn'")!.lowerBound
        )
        XCTAssertTrue(command.contains("t=2; "))
        XCTAssertTrue(command.contains("n1='it'\\''s the Bravo turn'"))
        XCTAssertTrue(command.contains("n2='it'\\''s the Bravo'"))
        // The classifier is one awk program fed through env (needle list,
        // the ❯ prefix, the current target); its verdict is eval'd.
        XCTAssertTrue(command.contains("MPXNDL=\"$ndl\" MPXPFX='❯' MPXTGT=\"$tgt\""))
        XCTAssertTrue(command.contains("printf \"pin=%d fam=%d real=%d h=%d\\n\""))
        XCTAssertTrue(command.contains("h - \(AgentSessionHistory.bottomChromeRows)"))
        XCTAssertTrue(command.contains("gsub(\"\\302\\240\""))
        // Navigation branches: landing threshold, inside-body batch, far
        // scan, overshoot descent, fallback swap after two crossings.
        XCTAssertTrue(command.contains("-le $((h / 2))"))
        // The far leap is gated on row 1 being ≥ 2 turns newer than the
        // target; anywhere the next crossing could be the target's own row
        // the climb stays within one viewport per capture (a 4-page batch
        // skipped a whole 20-row message between captures).
        XCTAssertTrue(command.contains("if [ \"$pin\" -gt $((t + 1)) ]; then"))
        XCTAssertTrue(command.contains("climb \(AgentSessionHistory.twinSafeBatch) ||"))
        XCTAssertTrue(command.contains("climb \(AgentSessionHistory.oracleFarBatch) ||"))
        XCTAssertTrue(command.contains("[ \"$pin\" -gt \"$t\" ]"))
        // The fallback swap restarts from live with its own twin count, and
        // hitting scroll-top before the swap takes the same retry (an
        // unmatched oldest message never produces older-pin crossings).
        XCTAssertTrue(command.contains(
            "rebase() { osc=0; seen=0; lastr=0; ckt=0; dir=u; restore; stab; }"
        ))
        XCTAssertTrue(command.contains("swapfb() { tgt=\"$n2\"; k=$k2; fbused=1; rebase; }"))
        // A mid-walk capture-height change means another attached client
        // resized the window: restart once, then report the flip rather
        // than a fake miss.
        XCTAssertTrue(command.contains("if [ \"$h\" != \"$h0\" ]; then"))
        XCTAssertTrue(command.contains("if [ \"$rsz\" = 0 ]; then rsz=1; h0=$h; rebase;"))
        XCTAssertTrue(command.contains("MPXJ_RESIZED"))
        // When both needles crossed the pinned target turn but its row
        // never rendered (rebuilt transcripts omit long multiline prompt
        // bodies), the walk descends to the turn's top and reports NEAR
        // instead of a fake miss.
        XCTAssertTrue(command.contains("sawt=1;"))
        XCTAssertTrue(command.contains("sawreal=1;"))
        XCTAssertTrue(command.contains(
            "elif [ $sawt = 1 ] && [ $sawreal = 0 ] && [ $nb = 0 ]; then nb=1; dir=d; continue;"
        ))
        XCTAssertTrue(command.contains("if [ \"$nb\" = 1 ]; then near=1; break; fi;"))
        XCTAssertTrue(command.contains("MPXJ_NEAR"))
        // A unique target lands on any sighting; only twins gate on the
        // upward count.
        XCTAssertTrue(command.contains("if [ \"$k\" = 0 ] || [ \"$seen\" -gt \"$k\" ]; then"))
        XCTAssertTrue(command.contains(
            "if [ $fbused = 0 ] && [ -n \"$n2\" ]; then swapfb; stepk 1 PPage || return 1; "
                + "elif [ $sawt = 1 ] && [ $sawreal = 0 ] && [ $nb = 0 ]; then nb=1; dir=d; "
                + "else top=1; return 1; fi"
        ))
        // Header clicks (unique target, mouse on): the SGR press+release
        // targets row 1 column 2 — the sticky — and every upward branch
        // click-skips instead of batch-scrolling; a no-move click disarms.
        XCTAssertTrue(command.contains("ck=1; ckt=0;"))
        XCTAssertTrue(command.contains(
            "mseq=$(printf '\\033[<0;2;1M\\033[<0;2;1m')"
        ))
        XCTAssertTrue(command.contains("send-keys -t \"$sid\" -l \"$mseq\""))
        XCTAssertTrue(command.contains(
            "cskip() { dir=u; hclick || return 1; "
                + "if [ \"$moved\" = 1 ]; then climb 1 || return 1; else ck=0; fi; }"
        ))
        // The target's own sticky sets the verify flag; the verify pass
        // shortcuts an unrendered row to the NEAR descent and disarms when
        // the click failed to land the turn top.
        XCTAssertTrue(command.contains("if [ \"$ck\" = 1 ]; then ckt=1; cskip || break;"))
        XCTAssertTrue(command.contains("if [ \"$ckt\" = 1 ]; then ckt=0;"))
        XCTAssertTrue(command.contains(
            "if [ \"$pin\" = \"$t\" ]; then ck=0; else nb=1; dir=d; continue; fi"
        ))
        // Unknown stickies click only over a real ❯ row (pin 0), never the
        // bannered -1.
        XCTAssertTrue(command.contains(
            "if [ \"$ck\" = 1 ] && [ \"$pin\" = 0 ]; then cskip || break; continue; fi"
        ))

        // A too-short pane is reported as its own state, not a missing
        // message.
        XCTAssertTrue(command.contains("{ short=1; break; }"))
        XCTAssertTrue(command.contains("MPXJ_SHORT"))
        XCTAssertTrue(command.contains("-lt \(AgentSessionHistory.jumpSendBudget)"))
        XCTAssertTrue(command.contains("-lt \(AgentSessionHistory.pageSettlePollCap)"))
        XCTAssertTrue(command.contains("trap 'keep=1; restore; exit 1' HUP INT TERM"))
        XCTAssertTrue(command.contains("C-End"))
        // A hand-scrolled pager start is unknowable; the walk normalizes to
        // live before its first PgUp.
        let normalizeRange = command.range(of: "restore; stab; ")
        let loopRange = command.range(of: "while [ $sent -lt ")
        XCTAssertNotNil(normalizeRange)
        XCTAssertNotNil(loopRange)
        XCTAssertTrue(normalizeRange!.lowerBound < loopRange!.lowerBound)
        XCTAssertTrue(command.hasSuffix("true"))
        // The awk program is embedded in single quotes — it must not
        // contain one itself.
        let program = command.components(separatedBy: "prog='")[1]
            .components(separatedBy: "'; ")[0]
        XCTAssertFalse(program.contains("'"))
    }

    func testJumpFindCommandCountsDuplicateTwinsFromTheBottom() {
        let command = AgentSessionHistory.jumpFindCommand(
            sessionID: "$0",
            needles: [
                .init(index: 1, text: "commit"),
                .init(index: 3, text: "top bar: right area toggle"),
                .init(index: 4, text: "commit"),
            ],
            targetIndex: 1,
            targetNeedles: ["commit"],
            newerTwinCount: 1,
            headerClicks: true
        )
        // The walk knows one newer twin must scroll past first…
        XCTAssertTrue(command.contains("t=2; k=1;"))
        // …and header clicks stay disarmed even with mouse support: a
        // click warps the viewport, and the from-the-bottom twin count
        // needs rows to drift continuously through it.
        XCTAssertTrue(command.contains("ck=0; ckt=0;"))
        XCTAssertTrue(command.contains("[ \"$seen\" -gt \"$k\" ]"))
        // …family pins read as the target's own turn…
        XCTAssertTrue(command.contains("fam=%d"))
        XCTAssertTrue(command.contains("if [ \"$fam\" = 1 ]; then pin=$t; fi"))
        // …and every upward batch stays under one viewport so no twin row
        // can slip through between captures.
        XCTAssertTrue(command.contains("climb \(AgentSessionHistory.twinSafeBatch) ||"))
        XCTAssertFalse(command.contains("climb \(AgentSessionHistory.oracleFarBatch) ||"))
        // Twin needles embed as the 0 sentinel: a sticky header matching
        // one cannot say WHICH twin owns the turn, and an ordinal would
        // steer the walk (the oldest twin's index read as "overshot →
        // descend" straight from the live view). The unique needle keeps
        // its ordinal.
        XCTAssertFalse(command.contains("'2\tcommit'"))
        XCTAssertFalse(command.contains("'5\tcommit'"))
        XCTAssertEqual(command.components(separatedBy: "'0\tcommit'").count - 1, 2)
        XCTAssertTrue(command.contains("'4\ttop bar: right area toggle'"))

        // A unique target keeps the fast batches; without the prologue's
        // mouse capability the clicks stay disarmed by default.
        let unique = AgentSessionHistory.jumpFindCommand(
            sessionID: "$0",
            needles: [.init(index: 0, text: "only prompt")],
            targetIndex: 0,
            targetNeedles: ["only prompt"]
        )
        XCTAssertTrue(unique.contains("k=0; k2=0;"))
        XCTAssertTrue(unique.contains("climb \(AgentSessionHistory.oracleFarBatch) ||"))
        XCTAssertTrue(unique.contains("ck=0; ckt=0;"))

        // A target unique under the primary needle but conflated under the
        // shorter fallback must already pace for twins: the fallback can
        // swap in mid-walk, and its viewport guarantee has to hold from
        // the first batch.
        let fallbackFamily = AgentSessionHistory.jumpFindCommand(
            sessionID: "$0",
            needles: [
                .init(index: 0, text: "deploy the staging environment now"),
                .init(index: 2, text: "deploy the staging environment again"),
            ],
            targetIndex: 0,
            targetNeedles: ["deploy the staging environment now", "deploy the staging"],
            newerTwinCount: 0,
            fallbackTwinCount: 1,
            headerClicks: true
        )
        XCTAssertTrue(fallbackFamily.contains("k=0; k2=1;"))
        XCTAssertTrue(fallbackFamily.contains("climb \(AgentSessionHistory.twinSafeBatch) ||"))
        XCTAssertFalse(fallbackFamily.contains("climb \(AgentSessionHistory.oracleFarBatch) ||"))
        // The fallback family counts too: its needle can swap in mid-walk.
        XCTAssertTrue(fallbackFamily.contains("ck=0; ckt=0;"))
    }

    func testJumpSendBudgetScalesWithPaneGeometry() {
        // The desktop calibration point keeps the base.
        XCTAssertEqual(
            AgentSessionHistory.jumpSendBudget(paneWidth: 100, paneHeight: 30),
            AgentSessionHistory.jumpSendBudget
        )
        // An iPhone-portrait pane rewraps the transcript into ~2.3× the
        // rows.
        XCTAssertEqual(
            AgentSessionHistory.jumpSendBudget(paneWidth: 44, paneHeight: 41),
            909
        )
        // Narrow AND short (docked keyboard) hits the ceiling.
        XCTAssertEqual(
            AgentSessionHistory.jumpSendBudget(paneWidth: 44, paneHeight: 18),
            AgentSessionHistory.jumpSendBudgetMax
        )
        // Wider than the calibration never shrinks below the base.
        XCTAssertEqual(
            AgentSessionHistory.jumpSendBudget(paneWidth: 180, paneHeight: 60),
            AgentSessionHistory.jumpSendBudget
        )
        // The scaled budget is what the built command runs with.
        let command = AgentSessionHistory.jumpFindCommand(
            sessionID: "$0",
            needles: [.init(index: 0, text: "only prompt")],
            targetIndex: 0,
            targetNeedles: ["only prompt"],
            sendBudget: 909
        )
        XCTAssertTrue(command.contains("while [ $sent -lt 909 ]"))
    }

    func testJumpFindCommandSurvivesEmptyOracle() {
        let command = AgentSessionHistory.jumpFindCommand(
            sessionID: "$1",
            needles: [],
            targetIndex: 0,
            targetNeedles: ["Only message"]
        )
        XCTAssertTrue(command.contains("ndl=$(printf '%s\\n' '')"))
        XCTAssertTrue(command.contains("n2=''"))
        XCTAssertTrue(command.hasSuffix("true"))
    }

    func testJumpFindResults() {
        XCTAssertEqual(
            AgentSessionHistory.parseJumpFind("MPXJ_T 4 3 0\nMPXJ_FOUND 7"),
            .found(pages: 7)
        )
        XCTAssertEqual(
            AgentSessionHistory.parseJumpFind("MPXJ_TOP 12"), .top(pages: 12)
        )
        XCTAssertEqual(
            AgentSessionHistory.parseJumpFind("MPXJ_EXHAUSTED 40"),
            .exhausted(pages: 40)
        )
        XCTAssertEqual(
            AgentSessionHistory.parseJumpFind("MPXJ_T 1 -1 0 0\nMPXJ_SHORT 1"),
            .short(pages: 1)
        )
        XCTAssertEqual(
            AgentSessionHistory.parseJumpFind("MPXJ_T 9 4 0 0\nMPXJ_RESIZED 12"),
            .resized(pages: 12)
        )
        XCTAssertEqual(
            AgentSessionHistory.parseJumpFind("MPXJ_T 60 7 0 0\nMPXJ_NEAR 64"),
            .near(pages: 64)
        )
        // Click trace lines ride along without confusing the outcome.
        XCTAssertEqual(
            AgentSessionHistory.parseJumpFind("MPXJ_C 3 1\nMPXJ_T 4 2 13 0\nMPXJ_FOUND 5"),
            .found(pages: 5)
        )
        XCTAssertNil(AgentSessionHistory.parseJumpFind("nothing"))
    }

    func testJumpReturnUsesConstantTimeScrollBottom() {
        let command = AgentSessionHistory.jumpReturnCommand(sessionID: "$1", pages: 500)
        XCTAssertTrue(command.contains("send-keys -t '$1' C-End"))
        XCTAssertFalse(command.contains("NPage"))
        XCTAssertFalse(command.contains("Escape"))
    }
}
