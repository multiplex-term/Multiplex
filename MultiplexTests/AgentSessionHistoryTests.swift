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
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(
            AgentSessionHistory.needle(for: message(long), paneColumns: 100)?.count,
            AgentSessionHistory.needleMaximum
        )
        XCTAssertEqual(
            AgentSessionHistory.needle(for: message(long), paneColumns: 40)?.count,
            36
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
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].count, AgentSessionHistory.needleMaximum)
        XCTAssertLessThanOrEqual(values[1].count, AgentSessionHistory.needleFallbackMaximum)
        XCTAssertTrue(values[0].hasPrefix(values[1]))
    }

    func testNeedleCountsWideCharactersDouble() {
        let wide = String(repeating: "個", count: 50)
        let needle = AgentSessionHistory.needle(for: message(wide), paneColumns: 44)
        // 40-column budget → 20 double-width characters.
        XCTAssertEqual(needle?.count, 20)
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
        MPXJ_META 120 ✳ Claude Code
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
            targetNeedles: ["it's the Bravo turn", "it's the Bravo"]
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
        XCTAssertTrue(command.contains("printf \"pin=%d real=%d h=%d\\n\""))
        XCTAssertTrue(command.contains("h - \(AgentSessionHistory.bottomChromeRows)"))
        XCTAssertTrue(command.contains("gsub(\"\\302\\240\""))
        // Navigation branches: landing threshold, inside-body batch, far
        // scan, overshoot descent, fallback swap after two crossings.
        XCTAssertTrue(command.contains("-le $((h / 2))"))
        XCTAssertTrue(command.contains("stepk \(AgentSessionHistory.oracleBodyBatch) PPage"))
        XCTAssertTrue(command.contains("stepk \(AgentSessionHistory.oracleFarBatch) PPage"))
        XCTAssertTrue(command.contains("[ \"$pin\" -gt \"$t\" ]"))
        XCTAssertTrue(command.contains("tgt=\"$n2\"; fbused=1"))
        XCTAssertTrue(command.contains("-lt \(AgentSessionHistory.jumpSendBudget)"))
        XCTAssertTrue(command.contains("-lt \(AgentSessionHistory.pageSettlePollCap)"))
        XCTAssertTrue(command.contains("trap 'keep=1; restore; exit 1' HUP INT TERM"))
        XCTAssertTrue(command.contains("C-End"))
        // A hand-scrolled pager start is unknowable; the walk normalizes to
        // live before its first PgUp.
        let normalizeRange = command.range(of: "restore; sleep 0.1; ")
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
        XCTAssertNil(AgentSessionHistory.parseJumpFind("nothing"))
    }

    func testJumpReturnUsesConstantTimeScrollBottom() {
        let command = AgentSessionHistory.jumpReturnCommand(sessionID: "$1", pages: 500)
        XCTAssertTrue(command.contains("send-keys -t '$1' C-End"))
        XCTAssertFalse(command.contains("NPage"))
        XCTAssertFalse(command.contains("Escape"))
    }
}
