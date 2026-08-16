import XCTest
@testable import Multiplex

/// Pins the agent-detection rules to the experiment matrix recorded in
/// local-plan/agent-harness-helpers.md §1.1 (Claude Code v2.1.206, Codex
/// rust-v0.144.x, Pi v0.80.7, tmux 3.6a — 2026-07-10/15; Grok Build from
/// the xai-org/grok-build source, 2026-08-16). When an agent changes its
/// signature, this file is where the new truth lands.
final class AgentSignatureTests: XCTestCase {
    // MARK: new-session launch commands

    func testLaunchCommandAddsInitialPromptForEveryAgent() {
        let prompt = "Review the SSH path"

        XCTAssertEqual(
            AgentKind.claudeCode.launchCommand(model: nil, initialPrompt: prompt),
            "claude 'Review the SSH path'"
        )
        XCTAssertEqual(
            AgentKind.codex.launchCommand(model: nil, initialPrompt: prompt),
            "codex 'Review the SSH path'"
        )
        XCTAssertEqual(
            AgentKind.pi.launchCommand(model: nil, initialPrompt: prompt),
            "pi 'Review the SSH path'"
        )
        // Grok Build: `grok "fix the bug"` is its documented interactive shape.
        XCTAssertEqual(
            AgentKind.grok.launchCommand(model: nil, initialPrompt: prompt),
            "grok 'Review the SSH path'"
        )
    }

    func testLaunchCommandKeepsPromptInOneShellArgument() {
        let prompt = "Don't run $(touch /tmp/pwned); `id`"

        XCTAssertEqual(
            AgentKind.claudeCode.launchCommand(model: nil, initialPrompt: prompt),
            "claude 'Don'\\''t run $(touch /tmp/pwned); `id`'"
        )
    }

    func testLaunchCommandPreservesMultilinePromptWithoutTypingControlBytes() {
        let prompt = "First line\r\nSecond\tcolumn\\n literal"

        XCTAssertEqual(
            AgentKind.pi.launchCommand(model: nil, initialPrompt: prompt),
            #"pi "$(printf '%b' 'First line\nSecond\tcolumn\\n literal')""#
        )
    }

    func testLaunchCommandIgnoresBlankPromptAndStripsTerminalControls() {
        XCTAssertEqual(
            AgentKind.codex.launchCommand(model: nil, initialPrompt: " \r\n\t "),
            "codex"
        )
        XCTAssertEqual(
            AgentKind.codex.launchCommand(model: nil, initialPrompt: "Fix\u{0003} this"),
            "codex 'Fix this'"
        )
    }

    // Every supported CLI spells the override `--model <value>` (verified
    // 2026-07-27: Claude Code 2.1.220, Codex rust 0.145.0, Pi 0.81.1).
    func testLaunchCommandCarriesModelBeforeThePromptForEveryAgent() {
        XCTAssertEqual(
            AgentKind.claudeCode.launchCommand(model: "opus", initialPrompt: ""),
            "claude --model 'opus'"
        )
        XCTAssertEqual(
            AgentKind.codex.launchCommand(model: "gpt-5-codex", initialPrompt: "go"),
            "codex --model 'gpt-5-codex' 'go'"
        )
        // Pi models may be provider-scoped with a thinking suffix.
        XCTAssertEqual(
            AgentKind.pi.launchCommand(
                model: "anthropic/claude-opus-4:high", initialPrompt: ""),
            "pi --model 'anthropic/claude-opus-4:high'"
        )
        XCTAssertEqual(
            AgentKind.grok.launchCommand(model: "grok-build", initialPrompt: "go"),
            "grok --model 'grok-build' 'go'"
        )
    }

    func testLaunchCommandQuotesModelSoAliasBracketsCannotGlob() {
        // `sonnet[1m]` is a real Claude Code alias; unquoted it is a zsh
        // glob and a failed-match error instead of a launch.
        XCTAssertEqual(
            AgentKind.claudeCode.launchCommand(model: "sonnet[1m]", initialPrompt: ""),
            "claude --model 'sonnet[1m]'"
        )
    }

    func testNormalizedLaunchModelAcceptsRealIdentifierShapes() {
        XCTAssertEqual(AgentKind.normalizedLaunchModel("  opus  "), "opus")
        XCTAssertEqual(
            AgentKind.normalizedLaunchModel("claude-sonnet-4-5-20250929"),
            "claude-sonnet-4-5-20250929"
        )
        XCTAssertEqual(
            AgentKind.normalizedLaunchModel("google/gemini-2.5-pro:minimal"),
            "google/gemini-2.5-pro:minimal"
        )
    }

    func testNormalizedLaunchModelRejectsNonTokenShapes() {
        // Empty and whitespace-only mean "agent default".
        XCTAssertNil(AgentKind.normalizedLaunchModel(""))
        XCTAssertNil(AgentKind.normalizedLaunchModel("   "))
        // Interior whitespace could smuggle a second shell word.
        XCTAssertNil(AgentKind.normalizedLaunchModel(
            "opus --dangerously-skip-permissions"))
        // A leading dash must never read as another flag.
        XCTAssertNil(AgentKind.normalizedLaunchModel("--help"))
        // Control bytes strip first; what remains must still be a token.
        XCTAssertEqual(AgentKind.normalizedLaunchModel("op\u{0003}us"), "opus")
        XCTAssertNil(AgentKind.normalizedLaunchModel(String(repeating: "m", count: 65)))
    }

    func testLaunchCommandDropsRejectedModels() {
        XCTAssertEqual(
            AgentKind.claudeCode.launchCommand(
                model: "opus extra-word", initialPrompt: "go"),
            "claude 'go'"
        )
    }

    // MARK: classify — comm + title first pass

    func testClassifyByCommand() {
        XCTAssertEqual(AgentSignature.classify(command: "claude", title: ""), .claudeCode)
        XCTAssertEqual(AgentSignature.classify(command: "codex", title: ""), .codex)
        XCTAssertEqual(AgentSignature.classify(command: "pi", title: ""), .pi)
        // Official installs ship `grok`; the cargo artifact keeps its name.
        XCTAssertEqual(AgentSignature.classify(command: "grok", title: ""), .grok)
        XCTAssertEqual(AgentSignature.classify(command: "xai-grok-pager", title: ""), .grok)
        // Live macOS 27 comm: the installer's versioned download target,
        // clipped by the kernel.
        XCTAssertEqual(AgentSignature.classify(command: "grok-1.0.4-maco", title: ""), .grok)
        XCTAssertNil(AgentSignature.classify(command: "grok-notes", title: ""))
        XCTAssertNil(AgentSignature.classify(command: "grok-1", title: ""))
        XCTAssertNil(AgentSignature.classify(command: "zsh", title: ""))
        // Interpreter comm alone must NOT classify — the tree walk decides.
        XCTAssertNil(AgentSignature.classify(command: "node", title: ""))
    }

    func testClassifyMacOSVersionedComm() {
        // Native launcher symlinks into versions/<semver>; macOS comm is the
        // resolved file's basename.
        XCTAssertEqual(AgentSignature.classify(command: "2.1.206", title: ""), .claudeCode)
        XCTAssertEqual(AgentSignature.classify(command: "3.0", title: ""), .claudeCode)
        XCTAssertNil(AgentSignature.classify(command: "2", title: ""))
        XCTAssertNil(AgentSignature.classify(command: "1.2.3.4.5", title: ""))
        XCTAssertNil(AgentSignature.classify(command: "2.1.x", title: ""))
        XCTAssertNil(AgentSignature.classify(command: "1..2", title: ""))
        XCTAssertNil(AgentSignature.classify(command: "", title: ""))
    }

    func testClassifyByTitle() {
        XCTAssertEqual(
            AgentSignature.classify(command: "cat", title: "✳ Claude Code"), .claudeCode)
        XCTAssertEqual(
            AgentSignature.classify(command: "sleep", title: "✳ fixing the parser"), .claudeCode)
        XCTAssertEqual(
            AgentSignature.classify(command: "zsh", title: "some Claude Code session"), .claudeCode)
        // npm Pi remains `node` to tmux and identifies the interactive UI
        // with a narrow OSC title.
        XCTAssertEqual(
            AgentSignature.classify(command: "node", title: "π - repo"), .pi)
        XCTAssertEqual(
            AgentSignature.classify(command: "node", title: "π - refactor - repo"), .pi)
        // tmux's default pane title is empty; shell prompts often write a
        // hostname. Neither may classify — and bare "claude" never matches.
        XCTAssertNil(AgentSignature.classify(command: "zsh", title: ""))
        XCTAssertNil(AgentSignature.classify(command: "zsh", title: "devbox.local"))
        XCTAssertNil(AgentSignature.classify(command: "zsh", title: "claude-notes.local"))
        XCTAssertNil(AgentSignature.classify(command: "node", title: "pi project"))
        XCTAssertNil(AgentSignature.classify(command: "node", title: "π calculations"))
        XCTAssertNil(AgentSignature.classify(command: "node", title: "π"))
        // No tmux title rule for Grok — only its process signals classify.
        XCTAssertNil(AgentSignature.classify(command: "zsh", title: "fix parser - grok"))
    }

    func testStalePiTitleDoesNotClassifyReturnedShell() {
        // Pi does not clear its OSC title on exit. Common shells and ordinary
        // foreground commands must therefore ignore the stale title; the
        // authoritative ps fallback can still recognize a live Pi process.
        for command in ["sh", "bash", "zsh", "fish", "cat"] {
            XCTAssertNil(
                AgentSignature.classify(command: command, title: "π - repo"),
                "stale Pi title classified \(command)"
            )
        }
    }

    func testCommandBeatsTitle() {
        XCTAssertEqual(
            AgentSignature.classify(command: "codex", title: "✳ Claude Code"), .codex)
        XCTAssertEqual(
            AgentSignature.classify(command: "claude", title: "π - repo"), .claudeCode)
        XCTAssertEqual(
            AgentSignature.classify(command: "pi", title: "✳ Claude Code"), .pi)
        XCTAssertEqual(
            AgentSignature.classify(command: "grok", title: "✳ Claude Code"), .grok)
    }

    // MARK: argv matching — exact argv[0] basename + interpreter rule

    func testMatchArgv() {
        XCTAssertEqual(AgentSignature.match(argv: "claude --effort max"), .claudeCode)
        XCTAssertEqual(AgentSignature.match(argv: "/home/dev/.local/bin/codex"), .codex)
        XCTAssertEqual(AgentSignature.match(argv: "pi"), .pi)
        XCTAssertEqual(AgentSignature.match(argv: "/usr/local/bin/pi"), .pi)
        XCTAssertEqual(
            AgentSignature.match(argv: "node /usr/lib/node_modules/.bin/claude"), .claudeCode)
        XCTAssertEqual(AgentSignature.match(argv: "bun /x/bin/codex resume"), .codex)
        XCTAssertEqual(AgentSignature.match(argv: "/Users/dev/.grok/bin/grok --cwd /repo"), .grok)
        XCTAssertEqual(AgentSignature.match(argv: "target/release/xai-grok-pager"), .grok)
    }

    func testMatchArgvRejectsTheTraps() {
        // A substring-of-args match would fire on every one of these.
        XCTAssertNil(AgentSignature.match(argv: "node /x/bin/claude-agent-acp"))
        XCTAssertNil(AgentSignature.match(
            argv: "/Applications/Claude.app/Contents/MacOS/Claude Helper --type=utility"))
        XCTAssertNil(AgentSignature.match(argv: "vim --user-data-dir=/Users/x/Claude"))
        XCTAssertNil(AgentSignature.match(argv: "claudette"))
        XCTAssertNil(AgentSignature.match(argv: "pico"))
        XCTAssertNil(AgentSignature.match(argv: "tail -f claude.log"))
        XCTAssertNil(AgentSignature.match(argv: "tail -f pi.log"))
        XCTAssertNil(AgentSignature.match(argv: ""))
    }

    // MARK: pane process-tree walk

    func testAgentInTreeFindsDescendant() {
        let rows = [
            PSRow(pid: 100, ppid: 1, args: "-zsh"),
            PSRow(pid: 200, ppid: 100, args: "claude --effort max"),
            PSRow(pid: 300, ppid: 200, args: "npm exec some-mcp"),
        ]
        XCTAssertEqual(AgentSignature.agentInTree(rows: rows, panePID: 100), .claudeCode)
    }

    func testAgentInTreeNPMCodexWrapper() {
        // npm's codex.js deliberately spawns (not execs) the native binary,
        // so node stays the pane's foreground process and the real codex is
        // a child — the exact shape the walk exists for.
        let rows = [
            PSRow(pid: 10, ppid: 1, args: "-bash"),
            PSRow(pid: 20, ppid: 10, args: "node /usr/lib/node_modules/@openai/codex/bin/codex.js"),
            PSRow(pid: 30, ppid: 20, args: "/usr/lib/node_modules/@openai/codex/vendor/codex"),
        ]
        XCTAssertEqual(AgentSignature.agentInTree(rows: rows, panePID: 10), .codex)
    }

    func testAgentInTreeMatchesThePaneRootItself() {
        let rows = [PSRow(pid: 50, ppid: 1, args: "claude")]
        XCTAssertEqual(AgentSignature.agentInTree(rows: rows, panePID: 50), .claudeCode)

        let piRows = [PSRow(pid: 60, ppid: 1, args: "/opt/pi/bin/pi")]
        XCTAssertEqual(AgentSignature.agentInTree(rows: piRows, panePID: 60), .pi)
    }

    func testAgentInTreeScopesToThePane() {
        // An agent elsewhere on the host must not light up this pane.
        let rows = [
            PSRow(pid: 100, ppid: 1, args: "-zsh"),
            PSRow(pid: 999, ppid: 1, args: "claude"),
        ]
        XCTAssertNil(AgentSignature.agentInTree(rows: rows, panePID: 100))
    }

    func testAgentInTreeSurvivesCyclesAndBadInput() {
        let cyclic = [
            PSRow(pid: 1, ppid: 2, args: "a"),
            PSRow(pid: 2, ppid: 1, args: "b"),
        ]
        XCTAssertNil(AgentSignature.agentInTree(rows: cyclic, panePID: 1))
        XCTAssertNil(AgentSignature.agentInTree(rows: [], panePID: 100))
        XCTAssertNil(AgentSignature.agentInTree(rows: cyclic, panePID: 0))
    }

    func testAgentsInTreesClassifiesMultipleRootsAndDeduplicatesLinkedPane() {
        let rows = [
            PSRow(pid: 10, ppid: 1, args: "-zsh"),
            PSRow(pid: 11, ppid: 10, args: "claude"),
            PSRow(pid: 20, ppid: 1, args: "-zsh"),
            PSRow(pid: 21, ppid: 20, args: "node /opt/codex"),
            PSRow(pid: 30, ppid: 1, args: "-zsh"),
            PSRow(pid: 40, ppid: 1, args: "-zsh"),
            PSRow(pid: 41, ppid: 40, args: "pi"),
        ]
        let agents = AgentSignature.agentsInTrees(
            rows: rows,
            panePIDs: [10, 20, 30, 40, 10]
        )
        XCTAssertEqual(agents[10], .claudeCode)
        XCTAssertEqual(agents[20], .codex)
        XCTAssertNil(agents[30])
        XCTAssertEqual(agents[40], .pi)
        XCTAssertEqual(agents.count, 3)
    }

    // MARK: plain-shell foreground probe + in-band fallback

    func testShellAgentProbeFindsForegroundNativeAgent() {
        let output = """
        noise from a remote profile
        MULTIPLEX_SHELL_PS
        100 1 100 100 /home/dev/.local/bin/claude --effort max
        """
        XCTAssertEqual(
            ShellAgentProbe.parse(output),
            .available(.claudeCode, workingDirectory: nil)
        )
    }

    func testShellAgentProbeFindsForegroundWrapperChild() {
        let output = """
        MULTIPLEX_SHELL_PS
        100 1 100 200 -zsh
        200 100 200 200 node /opt/codex/bin/codex.js
        201 200 200 200 /opt/codex/vendor/codex
        """
        XCTAssertEqual(
            ShellAgentProbe.parse(output),
            .available(.codex, workingDirectory: nil)
        )
    }

    func testShellAgentProbeIgnoresSuspendedBackgroundAgent() {
        // tpgid 100 says the shell owns the tty; the Codex job's pgid 200
        // is not foreground and must not leave helpers/attention behind.
        let output = """
        MULTIPLEX_SHELL_PS
        100 1 100 100 -zsh
        200 100 200 100 codex
        """
        XCTAssertEqual(
            ShellAgentProbe.parse(output),
            .available(nil, workingDirectory: nil)
        )
    }

    func testShellAgentProbeReportsForegroundWorkingDirectory() {
        let output = """
        MULTIPLEX_SHELL_PS
        100 1 100 200 -zsh
        200 100 200 200 claude
        MULTIPLEX_SHELL_CWD
        /Users/dev/project
        """
        XCTAssertEqual(
            ShellAgentProbe.parse(output),
            .available(.claudeCode, workingDirectory: "/Users/dev/project")
        )
        // A cwd stage that produced garbage (no absolute path) degrades to
        // detection-only, and cwd lines must never be read as ps rows.
        let garbled = """
        MULTIPLEX_SHELL_PS
        200 100 200 200 claude
        MULTIPLEX_SHELL_CWD
        readlink: not found
        """
        XCTAssertEqual(
            ShellAgentProbe.parse(garbled),
            .available(.claudeCode, workingDirectory: nil)
        )
    }

    func testShellAgentProbeDistinguishesUnavailableFromNoAgent() {
        XCTAssertEqual(ShellAgentProbe.parse(""), .unavailable)
        XCTAssertEqual(
            ShellAgentProbe.parse("MULTIPLEX_SHELL_PS\nunsupported ps output"),
            .unavailable
        )
        XCTAssertEqual(
            ShellAgentProbe.parse("MULTIPLEX_SHELL_PS\n10 1 10 10 -bash"),
            .available(nil, workingDirectory: nil)
        )
        XCTAssertTrue(ShellAgentProbe.command.contains("$PPID"))
        XCTAssertTrue(ShellAgentProbe.command.contains("pgid=,tpgid="))
        XCTAssertTrue(ShellAgentProbe.command.contains("/proc/$fg/cwd"))
        XCTAssertTrue(ShellAgentProbe.command.contains("lsof -a -p"))
    }

    func testDirectTerminalFallbackUsesOnlyVerifiedSignatures() {
        var evaluatedVisibleLines = false
        func titleFastPathVisibleLines() -> [String] {
            evaluatedVisibleLines = true
            return []
        }
        XCTAssertEqual(
            AgentSignature.classifyTerminal(
                title: "✳ Claude Code",
                visibleLines: titleFastPathVisibleLines(),
                isAlternateScreen: false,
                previous: nil
            ),
            .claudeCode
        )
        XCTAssertFalse(evaluatedVisibleLines)
        XCTAssertEqual(
            AgentSignature.classifyTerminal(
                title: "Multiplex",
                visibleLines: ["│ >_ OpenAI Codex (v0.144.4) │"],
                isAlternateScreen: true,
                previous: nil
            ),
            .codex
        )
        XCTAssertEqual(
            AgentSignature.classifyTerminal(
                title: "⠦ Multiplex",
                visibleLines: [],
                isAlternateScreen: true,
                previous: .codex
            ),
            .codex
        )
        // Pi's title is known to stay stale after exit; only the SSH process
        // probe may authorize it in a direct shell.
        XCTAssertNil(AgentSignature.classifyTerminal(
            title: "π - repo",
            visibleLines: [],
            isAlternateScreen: false,
            previous: nil
        ))
        // Grok's composed " - grok" suffix is live; the bare word is its
        // stale post-exit title.
        XCTAssertEqual(AgentSignature.classifyTerminal(
            title: "⠋ - Thinking - fix the parser - grok",
            visibleLines: [],
            isAlternateScreen: true,
            previous: nil
        ), .grok)
        XCTAssertNil(AgentSignature.classifyTerminal(
            title: "grok",
            visibleLines: [],
            isAlternateScreen: false,
            previous: nil
        ))
        XCTAssertNil(AgentSignature.classifyTerminal(
            title: "ordinary shell",
            visibleLines: ["the docs mention OpenAI Codex without a version masthead"],
            isAlternateScreen: false,
            previous: nil
        ))
    }

    // MARK: command payloads

    func testKeyPayloads() {
        XCTAssertEqual(AgentCommand.mode.payload, Data([0x1B, 0x5B, 0x5A]))     // CSI Z
        XCTAssertEqual(AgentCommand.think.payload, Data([0x1B, 0x5B, 0x5A]))    // CSI Z
        XCTAssertEqual(AgentCommand.transcript.payload, Data([0x14]))           // Ctrl+T
        XCTAssertEqual(AgentCommand.todos.payload, Data([0x14]))                // Ctrl+T
        XCTAssertEqual(AgentCommand.tools.payload, Data([0x0F]))                // Ctrl+O
        XCTAssertEqual(AgentCommand.thinking.payload, Data([0x14]))             // Ctrl+T
        XCTAssertEqual(AgentCommand.pageUp.payload, Data([0x1B, 0x5B, 0x35, 0x7E]))   // CSI 5~
        XCTAssertEqual(AgentCommand.pageDown.payload, Data([0x1B, 0x5B, 0x36, 0x7E])) // CSI 6~
        // Slash chips type text only; the CR is a separate delayed write
        // (Codex's paste-burst detector treats an in-burst Enter as a
        // newline, not a submit).
        XCTAssertEqual(AgentCommand.slash("clear").payload, Data("/clear".utf8))
        XCTAssertTrue(AgentCommand.slash("clear").submitsAfterPause)
        XCTAssertTrue(AgentCommand.slash("clear").consumesSlashChipTaste)
        XCTAssertFalse(AgentCommand.mode.submitsAfterPause)
        XCTAssertFalse(AgentCommand.mode.consumesSlashChipTaste)
        XCTAssertFalse(AgentCommand.think.submitsAfterPause)
        XCTAssertFalse(AgentCommand.think.consumesSlashChipTaste)
        XCTAssertFalse(AgentCommand.transcript.submitsAfterPause)
        XCTAssertFalse(AgentCommand.transcript.consumesSlashChipTaste)
        XCTAssertFalse(AgentCommand.tools.submitsAfterPause)
        XCTAssertFalse(AgentCommand.tools.consumesSlashChipTaste)
        XCTAssertFalse(AgentCommand.thinking.submitsAfterPause)
        XCTAssertFalse(AgentCommand.thinking.consumesSlashChipTaste)
        XCTAssertFalse(AgentCommand.pageUp.submitsAfterPause)
        XCTAssertFalse(AgentCommand.pageUp.consumesSlashChipTaste)
        XCTAssertFalse(AgentCommand.pageDown.submitsAfterPause)
        XCTAssertFalse(AgentCommand.pageDown.consumesSlashChipTaste)
    }

    /// No built-in chip types a bare Escape. The STOP chip did, and it was
    /// withdrawn: Escape is the one byte that interrupts a running turn, every
    /// platform already carries a real ESC key beside the terminal (the
    /// iPad/iPhone key rail, visionOS's ornament cluster), and a chip that
    /// sits a thumb's width from /clear is the wrong place to keep it.
    func testNoBuiltInChipTypesABareEscape() {
        for kind in AgentKind.allCases {
            for command in AgentCommandSet.all(for: kind) {
                XCTAssertNotEqual(
                    command.payload,
                    Data([0x1B]),
                    "\(kind) ships \(command.label) as a bare Escape"
                )
            }
        }
    }

    func testCommandSetMembership() {
        // Ctrl+T toggles Codex's transcript overlay; Claude Code has no
        // such binding.
        let codexPrimary = AgentCommandSet.primary(for: .codex)
        let codexOverflow = AgentCommandSet.overflow(for: .codex)
        XCTAssertTrue(codexPrimary.contains(.transcript))
        XCTAssertFalse(AgentCommandSet.primary(for: .claudeCode).contains(.transcript))

        // Compacting is occasionally useful in Codex, but does not need a
        // permanent slot in the command bar.
        XCTAssertFalse(codexPrimary.contains(.slash("compact")))
        XCTAssertTrue(codexOverflow.contains(.slash("compact")))

        let claude = AgentCommandSet.primary(for: .claudeCode)
        let claudeOverflow = AgentCommandSet.overflow(for: .claudeCode)
        XCTAssertTrue(claude.contains(.slash("effort")))
        XCTAssertFalse(claudeOverflow.contains(.slash("effort")))
        XCTAssertTrue(claude.contains(.slash("rewind")))
        XCTAssertFalse(claudeOverflow.contains(.slash("rewind")))
        XCTAssertFalse(claude.contains(.slash("context")))
        XCTAssertTrue(claudeOverflow.contains(.slash("context")))
        #if os(visionOS)
        // No key rail on visionOS — transcript paging rides the strip.
        XCTAssertEqual(Array(claude.suffix(2)), [.pageUp, .pageDown])
        #else
        // iPad's TerminalKeyBar already carries autorepeating PgUp/PgDn.
        XCTAssertFalse(claude.contains(.pageUp))
        XCTAssertFalse(claude.contains(.pageDown))
        #endif
        XCTAssertFalse(codexPrimary.contains(.pageUp))

        let pi = AgentCommandSet.primary(for: .pi)
        let piOverflow = AgentCommandSet.overflow(for: .pi)
        XCTAssertEqual(
            pi,
            [.slash("new"), .slash("resume"), .slash("compact"),
             .slash("model"), .slash("tree"), .think, .tools]
        )
        XCTAssertTrue(piOverflow.contains(.thinking))
        XCTAssertTrue(piOverflow.contains(.slash("copy")))
        XCTAssertFalse(pi.contains(.mode))
        XCTAssertFalse(pi.contains(.transcript))

        // Grok Build: Shift+Tab cycles Normal → Plan → Always-approve, so
        // MODE applies; Ctrl+T is its todos pane, not a transcript.
        let grok = AgentCommandSet.primary(for: .grok)
        let grokOverflow = AgentCommandSet.overflow(for: .grok)
        XCTAssertEqual(
            grok,
            [.slash("new"), .slash("resume"), .slash("compact"),
             .slash("rewind"), .slash("model"), .slash("effort"), .mode]
        )
        XCTAssertTrue(grokOverflow.contains(.todos))
        XCTAssertTrue(grokOverflow.contains(.slash("plan")))
        XCTAssertFalse(grok.contains(.transcript))
        XCTAssertFalse(grokOverflow.contains(.transcript))
    }

    func testBuiltInPlacementOverridesMoveCommandsWithoutChangingDefaults() {
        let overrides: [String: AgentCommandPlacement] = [
            "/clear": .more,
            "/context": .bar,
            "removed-command": .bar,
        ]

        let bar = AgentCommandSet.commands(
            in: .bar,
            for: .claudeCode,
            placementOverrides: overrides
        )
        let more = AgentCommandSet.commands(
            in: .more,
            for: .claudeCode,
            placementOverrides: overrides
        )

        XCTAssertFalse(bar.contains(.slash("clear")))
        XCTAssertTrue(more.contains(.slash("clear")))
        XCTAssertTrue(bar.contains(.slash("context")))
        XCTAssertFalse(more.contains(.slash("context")))
        XCTAssertEqual(
            AgentCommandSet.normalizedPlacementOverrides(
                overrides,
                for: .claudeCode
            ),
            ["/clear": .more, "/context": .bar]
        )

        // Choices matching the curated layout are not persisted as overrides.
        XCTAssertTrue(AgentCommandSet.normalizedPlacementOverrides(
            ["/clear": .bar, "/context": .more],
            for: .claudeCode
        ).isEmpty)
    }

    func testEveryCommandIsSafeToType() {
        for kind in AgentKind.allCases {
            let all = AgentCommandSet.primary(for: kind) + AgentCommandSet.overflow(for: kind)
            XCTAssertFalse(all.isEmpty)
            for command in all {
                // Never the remote tmux prefix.
                XCTAssertFalse(command.payload.contains(0x02),
                               "\(command.label) would be eaten as the tmux prefix")
                if command.label.hasPrefix("/") {
                    // Slash chips type exactly their label; submission is the
                    // deferred CR, never part of the burst.
                    XCTAssertEqual(String(decoding: command.payload, as: UTF8.self), command.label)
                    XCTAssertFalse(command.payload.contains(0x0D), "\(command.label) must not submit in-burst")
                    XCTAssertTrue(command.submitsAfterPause, "\(command.label) must still submit")
                }
            }
        }
    }
}
