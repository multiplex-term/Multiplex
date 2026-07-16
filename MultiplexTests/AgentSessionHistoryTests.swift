import XCTest
@testable import Multiplex

/// Fixture shapes mirror real session files inspected 2026-07-16 (Claude
/// Code 2.1.211 jsonl, Codex rollout, Pi session v3) — see
/// local-plan/agent-message-history.md for the pollution taxonomy.
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
        {"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Now run the tests"},{"type":"image","source":{}}]},"timestamp":"2026-07-16T03:05:00.000Z"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\\"type\\":\\"user\\" echoed in prose"}]}}
        """
        guard let result = AgentSessionHistory.parseReadOutput(
            wrapped(body), agent: .claudeCode
        ) else { return XCTFail("expected a parse") }

        XCTAssertEqual(result.filePath, "/home/dev/.claude/projects/-home-dev-app/abc.jsonl")
        XCTAssertEqual(result.messages.map(\.text), [
            "Fix the probe parser",
            "Now run the tests",
        ])
        XCTAssertEqual(result.messages.map(\.ordinal), [0, 1])
        XCTAssertNotNil(result.messages[0].timestamp)
    }

    func testNoFileSentinelMeansEmptyResult() {
        let result = AgentSessionHistory.parseReadOutput(
            "MULTIPLEX_HIST_NOFILE", agent: .claudeCode
        )
        XCTAssertEqual(result, AgentSessionHistory.ReadResult(filePath: nil, messages: []))
    }

    func testMissingSentinelsMeanNil() {
        XCTAssertNil(AgentSessionHistory.parseReadOutput("garbage", agent: .claudeCode))
    }

    func testMessageCapKeepsNewest() {
        let lines = (0..<60).map {
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"prompt \($0)\"}}"
        }
        let result = AgentSessionHistory.parseReadOutput(
            wrapped(lines.joined(separator: "\n")), agent: .claudeCode
        )
        XCTAssertEqual(result?.messages.count, AgentSessionHistory.maxMessages)
        XCTAssertEqual(result?.messages.first?.text, "prompt 10")
        XCTAssertEqual(result?.messages.last?.text, "prompt 59")
    }

    // MARK: Codex parsing

    func testCodexExtractsUserMessages() {
        let body = """
        {"timestamp":"2026-07-16T03:09:26.777Z","type":"event_msg","payload":{"type":"user_message","message":"Review the PR"}}
        {"timestamp":"2026-07-16T03:10:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-07-16T03:11:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions>wrapped</user_instructions>"}]}}
        {"timestamp":"2026-07-16T03:12:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"Ship it"}}
        """
        let result = AgentSessionHistory.parseReadOutput(wrapped(body), agent: .codex)
        XCTAssertEqual(result?.messages.map(\.text), ["Review the PR", "Ship it"])
    }

    func testCodexWrapperTextIsFiltered() {
        let body = """
        {"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"<environment_context>cwd stuff</environment_context>"}}
        """
        let result = AgentSessionHistory.parseReadOutput(wrapped(body), agent: .codex)
        XCTAssertEqual(result?.messages, [])
    }

    // MARK: Pi parsing

    func testPiExtractsUserRoleOnly() {
        let body = """
        {"type":"session","version":3,"id":"a","timestamp":"2026-07-16T03:52:00.158Z","cwd":"/Users/dev/app"}
        {"type":"message","id":"m1","parentId":null,"timestamp":"2026-07-16T03:52:06.327Z","message":{"role":"user","content":[{"type":"text","text":"Implement the plan"}]}}
        {"type":"message","id":"m2","parentId":"m1","timestamp":"2026-07-16T03:53:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
        {"type":"message","id":"m3","parentId":"m2","timestamp":"2026-07-16T03:54:00.000Z","message":{"role":"toolResult","content":[{"type":"text","text":"output"}]}}
        {"type":"message","id":"m4","parentId":"m3","timestamp":"2026-07-16T03:55:00.000Z","message":{"role":"user","content":[{"type":"text","text":"fix the pill"}]}}
        """
        let result = AgentSessionHistory.parseReadOutput(wrapped(body), agent: .pi)
        XCTAssertEqual(result?.messages.map(\.text), ["Implement the plan", "fix the pill"])
    }

    // MARK: Munging

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

    func testPiProjectDirectoryComponent() {
        XCTAssertEqual(
            AgentSessionHistory.piProjectDirectoryComponent(
                forCwd: "/Users/jhen/workspace2/Multiplex"
            ),
            "--Users-jhen-workspace2-Multiplex--"
        )
        // Pi keeps dots (verified: --Users-jhen-workspace-llama.rn--).
        XCTAssertEqual(
            AgentSessionHistory.piProjectDirectoryComponent(
                forCwd: "/Users/jhen/workspace/llama.rn"
            ),
            "--Users-jhen-workspace-llama.rn--"
        )
    }

    func testCodexCwdNeedleEscapesJSON() {
        XCTAssertEqual(
            AgentSessionHistory.codexCwdNeedle(forCwd: "/Users/dev/app"),
            "\"cwd\":\"/Users/dev/app\""
        )
        XCTAssertEqual(
            AgentSessionHistory.codexCwdNeedle(forCwd: "/od\"d\\path"),
            "\"cwd\":\"/od\\\"d\\\\path\""
        )
    }

    // MARK: Command builders

    func testReadCommandShapes() {
        let claude = AgentSessionHistory.readCommand(
            agent: .claudeCode, cwd: "/Users/dev/app"
        )
        XCTAssertTrue(claude.contains("$HOME/.claude/projects/"))
        XCTAssertTrue(claude.contains("'-Users-dev-app'"))
        XCTAssertTrue(claude.contains("grep -av '\"tool_use_id\"'"))
        XCTAssertTrue(claude.contains("tail -c \(AgentSessionHistory.tailByteBudget)"))
        XCTAssertTrue(claude.hasSuffix("true"))

        let codex = AgentSessionHistory.readCommand(agent: .codex, cwd: "/Users/dev/app")
        XCTAssertTrue(codex.contains(".codex/sessions"))
        XCTAssertTrue(codex.contains("\"cwd\":\"/Users/dev/app\""))
        XCTAssertTrue(codex.contains("user_message"))

        let pi = AgentSessionHistory.readCommand(agent: .pi, cwd: "/Users/dev/app")
        XCTAssertTrue(pi.contains(".pi/agent/sessions/"))
        XCTAssertTrue(pi.contains("'--Users-dev-app--'"))
    }

    func testPaneCwdCommandUsesExactSessionTarget() {
        let command = AgentSessionHistory.paneCwdCommand(sessionName: "ma in")
        XCTAssertTrue(command.contains("list-panes -t '=ma in'"))
        XCTAssertTrue(command.contains("pane_current_path"))
        XCTAssertFalse(command.contains("display-message"))
        XCTAssertEqual(
            AgentSessionHistory.parsePaneCwd("/Users/dev/app\n"),
            "/Users/dev/app"
        )
        XCTAssertNil(AgentSessionHistory.parsePaneCwd("no path here\n"))
    }

    // MARK: Needle

    private func message(_ text: String) -> AgentUserMessage {
        AgentUserMessage(ordinal: 0, text: text, timestamp: nil)
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

    func testNeedleCutsAtControlCharactersAndTrimsTrailingSpace() {
        XCTAssertEqual(
            AgentSessionHistory.needle(
                for: message("run this \tthing"), paneColumns: 80
            ),
            "run this"
        )
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

    func testJumpFindCommandShape() {
        let command = AgentSessionHistory.jumpFindCommand(
            sessionID: "$4", needle: "it's here"
        )
        XCTAssertTrue(command.contains("sid='$4'"))
        XCTAssertTrue(command.contains("n='it'\\''s here'"))
        XCTAssertTrue(command.contains("send-keys -t \"$sid\" PPage"))
        XCTAssertTrue(command.contains("grep -Fq -- \"$n\""))
        XCTAssertTrue(command.contains("-lt \(AgentSessionHistory.pageCap)"))
        XCTAssertTrue(command.contains("NPage"))
        XCTAssertTrue(command.hasSuffix("true"))
    }

    func testJumpFindResults() {
        XCTAssertEqual(
            AgentSessionHistory.parseJumpFind("MPXJ_FOUND 7"), .found(pages: 7)
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

    func testJumpReturnOvershootsAndClamps() {
        let command = AgentSessionHistory.jumpReturnCommand(sessionID: "$1", pages: 7)
        XCTAssertTrue(command.contains("-lt 9"))
        let clamped = AgentSessionHistory.jumpReturnCommand(sessionID: "$1", pages: 500)
        XCTAssertTrue(clamped.contains("-lt \(AgentSessionHistory.pageCap + 2)"))
    }

    func testCaptureContains() {
        XCTAssertTrue(AgentSessionHistory.captureContains(
            ["a", "❯ Fix the parser and more"], needle: "Fix the parser"
        ))
        XCTAssertFalse(AgentSessionHistory.captureContains(["a"], needle: "missing"))
    }
}
