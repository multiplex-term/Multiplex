import XCTest
@testable import Multiplex

final class TmuxProbeTests: XCTestCase {
    func testParsesSessionsAndWindows() {
        let output = """
        S $0 1 1751500000 main
        S $3 0 1751600000 scratch
        W $0 0 0 0 0 editor
        W $0 1 1 0 1 server
        W $3 0 1 0 0 zsh
        """

        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertEqual(sessions.map(\.name), ["main", "scratch"])

        let main = sessions[0]
        XCTAssertTrue(main.isAttached)
        XCTAssertEqual(main.windowCount, 2)
        XCTAssertEqual(main.windows[1].name, "server")
        XCTAssertTrue(main.windows[1].isActive)
        XCTAssertTrue(main.windows[1].hasActivity)
        XCTAssertFalse(main.windows[0].isActive)
        XCTAssertEqual(main.created, Date(timeIntervalSince1970: 1_751_500_000))

        XCTAssertFalse(sessions[1].isAttached)
        XCTAssertEqual(sessions[1].windowCount, 1)
    }

    func testEmptyOutputMeansNoServer() {
        XCTAssertEqual(TmuxProbe.parse(""), .noServer)
        XCTAssertEqual(TmuxProbe.parse("\n"), .noServer)
    }

    func testMissingTmuxSentinel() {
        XCTAssertEqual(TmuxProbe.parse("MULTIPLEX_NO_TMUX\n"), .tmuxMissing)
    }

    func testNamesWithSpacesAndUnicodeSurviveTailRejoin() {
        let output = """
        S $1 0 0 my project ✨
        W $1 0 1 0 0 build && watch
        """
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertEqual(sessions[0].name, "my project ✨")
        XCTAssertEqual(sessions[0].windows[0].name, "build && watch")
    }

    func testMultipleAttachedClientsCountAsAttached() {
        let output = "S $2 3 0 shared"
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertTrue(sessions[0].isAttached)
        XCTAssertEqual(sessions[0].clientCount, 3)
        XCTAssertEqual(sessions[0].tmuxID, "$2")
    }

    // MARK: Agent detection (P lines + MULTIPLEX_PS section)

    func testAgentFromPaneCommand() {
        let output = """
        S $0 1 0 main
        W $0 0 1 0 0 editor
        P $0 0 0 1 %0 4242 /dev/pts/0 claude ✳ Claude Code
        """
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertEqual(sessions[0].windows[0].agent, .claudeCode)
        XCTAssertEqual(sessions[0].activeAgent, .claudeCode)
    }

    func testAgentFromTitleTailRejoin() {
        // Harness-style fake: comm is unhelpful (cat), the OSC title — with
        // spaces, in tail position — carries the signal.
        let output = """
        S $0 0 0 agent
        W $0 0 1 0 0 cc
        P $0 0 0 1 %0 77 /dev/pts/0 cat ✳ Claude Code
        """
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertEqual(sessions[0].activeAgent, .claudeCode)
    }

    func testAgentViaProcessTreeSection() {
        // npm codex: pane comm is node, title empty — the ps walk decides.
        let output = """
        S $0 0 0 work
        W $0 0 1 0 0 sh
        P $0 0 0 1 %0 100 /dev/pts/0 node
        MULTIPLEX_PS
          100     1 node /usr/lib/node_modules/@openai/codex/bin/codex.js
          200   100 /usr/lib/node_modules/@openai/codex/vendor/codex
          300     1 claude
        """
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        // …and pid 300's stray claude outside the pane tree must not win.
        XCTAssertEqual(sessions[0].activeAgent, .codex)
    }

    func testAllPanesFeedWallWhileActivePaneFeedsHelpers() {
        let output = """
        S $0 1 0 main
        W $0 0 0 0 0 editor
        W $0 1 1 0 0 agent
        P $0 0 0 1 %0 10 /dev/pts/0 claude
        P $0 1 0 0 %1 20 /dev/pts/1 node
        P $0 1 1 1 %2 30 /dev/pts/2 zsh
        MULTIPLEX_PS
          20 1 node /opt/codex.js
          21 20 /opt/codex/vendor/codex
        """
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        // Window 0 (inactive window, active pane) still records its agent.
        XCTAssertEqual(sessions[0].windows[0].agent, .claudeCode)
        // Window 1's background Codex is retained for FleetWall, while its
        // active shell keeps the helper strip off.
        XCTAssertNil(sessions[0].windows[1].agent)
        XCTAssertEqual(sessions[0].windows[1].detectedAgents, [.codex])
        XCTAssertNil(sessions[0].activeAgent)
        XCTAssertEqual(sessions[0].detectedAgents, [.claudeCode, .codex])
        XCTAssertEqual(sessions[0].paneCount, 3)
        XCTAssertEqual(sessions[0].windows[1].paneCount, 2)
        XCTAssertEqual(sessions[0].windows[1].activePane?.tmuxID, "%2")
    }

    func testMalformedAgentLinesNeverHurtSessions() {
        let output = """
        S $0 1 0 main
        W $0 0 1 0 0 editor
        P $0 short
        P $9 0 0 1 %9 11 /dev/pts/9 claude
        MULTIPLEX_PS
        garbage row
          notpid  1 claude
        """
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertEqual(sessions.map(\.name), ["main"])
        XCTAssertNil(sessions[0].activeAgent)
    }

    func testProbeCommandCarriesDetectionStages() {
        let command = TmuxProbe.probeCommand
        XCTAssertTrue(command.contains("tmux list-panes -a"))
        XCTAssertTrue(command.contains(
            "#{pane_id} #{pane_pid} #{pane_tty} #{pane_current_command} #{pane_title}"))
        XCTAssertTrue(command.contains("echo MULTIPLEX_PS"))
        XCTAssertTrue(command.contains("ps -eo pid=,ppid=,args="))
        XCTAssertFalse(command.contains("pid=,ppid=,tty="))
        // Pane output is reused to build the subtree roots; do not re-run
        // list-panes just to discover them.
        XCTAssertEqual(command.components(separatedBy: "tmux list-panes -a").count - 1, 1)
        XCTAssertTrue(command.contains(#"roots=$(printf '%s\n' "$panes""#))
        XCTAssertTrue(command.contains(#"if(seen[pid]++)continue"#))
        XCTAssertTrue(command.contains("substr(a,1,120)"))
        // The original sentinel + fail-soft contract survives.
        XCTAssertTrue(command.contains("MULTIPLEX_NO_TMUX"))
        XCTAssertTrue(command.contains("|| true; "))
    }

    func testFocusedPaneProbeIsSmallAndParsesTheActiveSplit() {
        let command = TmuxProbe.activePaneCommand(sessionName: "my project")
        XCTAssertTrue(command.contains("tmux list-panes -t '=my project'"))
        XCTAssertTrue(command.contains("-F 'A #{session_id}"))
        XCTAssertFalse(command.contains("capture-pane"))
        XCTAssertFalse(command.contains("ps -"))

        let output = """
        A $3 2 0 0 %8 80 /dev/pts/8 zsh
        A $3 2 1 1 %9 90 /dev/pts/9 node project agent
        """
        let pane = TmuxProbe.parseActivePane(output)
        XCTAssertEqual(pane?.tmuxID, "%9")
        XCTAssertEqual(pane?.index, 1)
        XCTAssertEqual(pane?.pid, 90)
        XCTAssertEqual(pane?.tty, "/dev/pts/9")
        XCTAssertEqual(pane?.command, "node")
        XCTAssertEqual(pane?.title, "project agent")
    }

    func testFocusedPaneProcessFallbackTargetsOnlyItsTTY() {
        let command = TmuxProbe.paneProcessCommand(tty: "/dev/pts/9")
        XCTAssertTrue(command?.contains("ps -t 'pts/9'") == true)
        XCTAssertTrue(command?.contains("cut -c1-120") == true)
        XCTAssertNil(TmuxProbe.paneProcessCommand(tty: ""))

        XCTAssertEqual(
            TmuxProbe.parsePSRows("  10  1 -zsh\n  20 10 codex --model gpt-5"),
            [
                PSRow(pid: 10, ppid: 1, args: "-zsh"),
                PSRow(pid: 20, ppid: 10, args: "codex --model gpt-5"),
            ]
        )
    }

    func testProbeCommandCarriesCaptureTails() {
        // The miniatures ride the same exec: a server-side loop captures
        // every session behind MULTIPLEX_TAILS, with markers carrying tmux's
        // own session ids — never names, which could forge the framing.
        let command = TmuxProbe.probeCommand
        XCTAssertTrue(command.contains("echo MULTIPLEX_TAILS"))
        XCTAssertTrue(command.contains(
            "tmux list-sessions -F '#{session_id}' 2>/dev/null | while IFS= read -r s; do"))
        XCTAssertTrue(command.contains("echo \"MPXS $s\""))
        XCTAssertTrue(command.contains("tmux capture-pane -p -t \"$s\" -S -30"))
        // The command must exit 0 on every path — Citadel throws on a
        // non-zero exit status.
        XCTAssertTrue(command.hasSuffix("done; echo MPXE"))
    }

    func testRouteSessionNames() {
        let host = UUID()
        XCTAssertEqual(
            TerminalRoute(hostID: host, mode: .attach(sessionName: "main")).sessionName, "main")
        XCTAssertEqual(
            TerminalRoute(hostID: host, mode: .create(sessionName: "new")).sessionName, "new")
        XCTAssertNil(TerminalRoute(hostID: host, mode: .shell).sessionName)
    }

    // MARK: Miniatures

    private func session(_ name: String, id: String) -> TmuxSession {
        TmuxSession(name: name, windows: [], created: Date(timeIntervalSince1970: 0), tmuxID: id)
    }

    func testSessionOrderingKeepsNewSessionsAheadOfSavedOrder() {
        let sessions = [
            session("main", id: "$0"),
            session("scratch", id: "$1"),
            session("deploy", id: "$2"),
        ]

        XCTAssertEqual(
            SessionOrdering.ordered(sessions, saved: nil).map(\.name),
            ["deploy", "scratch", "main"]
        )
        XCTAssertEqual(
            SessionOrdering.ordered(
                sessions,
                saved: ["gone", "scratch", "main"]
            ).map(\.name),
            ["deploy", "scratch", "main"]
        )
    }

    func testSessionOrderingAppliesReorderContainerDestination() {
        let order = ["deploy", "scratch", "main", "agent"]
        XCTAssertEqual(
            SessionOrdering.moving(["main"], before: "deploy", in: order),
            ["main", "deploy", "scratch", "agent"]
        )
        XCTAssertEqual(
            SessionOrdering.moving(["scratch", "main"], before: nil, in: order),
            ["deploy", "agent", "scratch", "main"]
        )
    }

    func testSessionOrderingFallbackMovesIntoTargetSlot() {
        let order = ["deploy", "scratch", "main", "agent"]
        XCTAssertEqual(
            SessionOrdering.moving("deploy", to: "main", in: order),
            ["scratch", "main", "deploy", "agent"]
        )
        XCTAssertEqual(
            SessionOrdering.moving("agent", to: "scratch", in: order),
            ["deploy", "agent", "scratch", "main"]
        )
    }

    func testKillCommandTargetsSessionID() {
        let command = TmuxProbe.killCommand(for: session("my project", id: "$3"))
        XCTAssertTrue(command.contains("tmux kill-session -t '$3'"))
        // Names never appear in targets — ids are unambiguous.
        XCTAssertFalse(command.contains("my project"))
    }

    func testKillCommandFallsBackToExactNameMatch() {
        // No id: `-t name` is prefix-matched by tmux, `=` forces exact.
        let command = TmuxProbe.killCommand(for: session("main", id: ""))
        XCTAssertTrue(command.contains("tmux kill-session -t '=main'"))
    }

    func testDropDestinationCommandTargetsExactSession() {
        let command = TmuxProbe.dropDestinationCommand(sessionName: "my project")
        // list-panes, NOT display-message: 3.6a's display-message renders
        // pane formats empty for outside clients.
        XCTAssertTrue(command.contains("tmux list-panes -t '=my project'"))
        XCTAssertTrue(command.contains("#{?pane_active,#{pane_current_path},}"))
        // Git worktrees are flagged so drops go into .multiplex-drops/.
        XCTAssertTrue(command.contains("rev-parse --is-inside-work-tree"))
        XCTAssertTrue(command.contains("echo MULTIPLEX_GIT"))
    }

    // MARK: New sessions (the + TAB button, the deck tile's quick options)

    func testNewSessionCommandInheritsSourceDirectoryAndTypesLaunch() {
        let command = TmuxProbe.newSessionCommand(
            name: "claude", sourceSessionName: "my project", launch: "claude")
        // Same dir = the source session's ACTIVE pane cwd, via list-panes
        // (never display-message — 3.6a renders pane formats empty there),
        // falling back to $HOME when unresolvable.
        XCTAssertTrue(command.contains("tmux list-panes -t '=my project'"))
        XCTAssertTrue(command.contains("#{?pane_active,#{pane_current_path},}"))
        XCTAssertTrue(command.contains("d=\"${p:-$HOME}\""))
        // A first tmux server on systemd Linux escapes the SSH login scope;
        // hosts without a usable user manager take the ordinary tmux path.
        XCTAssertTrue(command.contains(
            "systemd-run --user --scope --quiet -- tmux \"$@\""))
        XCTAssertTrue(command.contains("fi; tmux \"$@\"; };"))
        // Wanted name first, then the unnamed retry — the server settles
        // duplicate-name races and its printed id+name pair is the truth.
        XCTAssertTrue(command.contains(
            "i=$(multiplex_tmux new-session -d -P -F '#{session_id} #{session_name}' -c \"$d\" -s 'claude' 2>/dev/null)"))
        XCTAssertTrue(command.contains(
            "|| i=$(multiplex_tmux new-session -d -P -F '#{session_id} #{session_name}' -c \"$d\" 2>/dev/null)"))
        // The launch is TYPED into the shell (literal text, then Enter),
        // targeting the session ID — 3.6a send-keys rejects `=name`
        // exact-match pane targets, and a bare name is prefix-matched.
        XCTAssertTrue(command.contains("tmux send-keys -t \"${i%% *}\" -l -- 'claude'"))
        XCTAssertTrue(command.contains("tmux send-keys -t \"${i%% *}\" Enter"))
        // The sentinel carries the NAME (the tail — names keep spaces);
        // attach routes are name-based.
        XCTAssertTrue(command.contains("printf 'MULTIPLEX_NEW %s\\n' \"${i#* }\""))
        // Citadel throws on non-zero exit: failure must read as a missing
        // sentinel, never a torn-down control connection.
        XCTAssertTrue(command.hasSuffix("; true"))
    }

    func testNewSessionCommandWithoutSourceOrLaunch() {
        let command = TmuxProbe.newSessionCommand(
            name: "main", sourceSessionName: nil, launch: nil)
        XCTAssertFalse(command.contains("list-panes"))
        XCTAssertTrue(command.contains("d=\"$HOME\""))
        XCTAssertFalse(command.contains("send-keys"))
        XCTAssertTrue(command.contains("-s 'main'"))
        XCTAssertTrue(command.contains("MULTIPLEX_NEW"))
    }

    func testNewSessionCommandStartsInExplicitDirectory() {
        let command = TmuxProbe.newSessionCommand(
            name: "main", sourceSessionName: nil, startDirectory: "/srv/app", launch: nil)
        // A working dir missing on the host falls back to $HOME — a bad
        // path must not make the create fail outright.
        XCTAssertTrue(command.contains("d='/srv/app'; [ -d \"$d\" ] || d=\"$HOME\"; "))
        XCTAssertFalse(command.contains("list-panes"))
    }

    func testNewSessionCommandExpandsTildeInDirectory() {
        let command = TmuxProbe.newSessionCommand(
            name: "main", sourceSessionName: nil, startDirectory: "~/projects/app", launch: nil)
        // ~ has no meaning inside single quotes — it rides as "$HOME".
        XCTAssertTrue(command.contains("d=\"$HOME\"/'projects/app'; "))
    }

    func testNewSessionCommandSourceSessionOutranksDirectory() {
        // The + TAB path inherits the source pane's cwd; an explicit
        // directory only applies when there is no source to inherit from.
        let command = TmuxProbe.newSessionCommand(
            name: "main", sourceSessionName: "work", startDirectory: "/srv/app", launch: nil)
        XCTAssertTrue(command.contains("d=\"${p:-$HOME}\""))
        XCTAssertFalse(command.contains("/srv/app"))
    }

    func testParseNewSession() {
        XCTAssertEqual(TmuxProbe.parseNewSession("MULTIPLEX_NEW claude\n"), "claude")
        // Names keep their spaces; stray output around the sentinel is noise.
        XCTAssertEqual(
            TmuxProbe.parseNewSession("noise\nMULTIPLEX_NEW my project 2\n"),
            "my project 2")
        XCTAssertNil(TmuxProbe.parseNewSession("duplicate session: claude\n"))
        XCTAssertNil(TmuxProbe.parseNewSession(""))
    }

    func testUniqueSessionNameCountsUpFromTaken() {
        XCTAssertEqual(TmuxProbe.uniqueSessionName(base: "claude", existing: ["main"]), "claude")
        XCTAssertEqual(TmuxProbe.uniqueSessionName(base: "claude", existing: ["claude"]), "claude-2")
        XCTAssertEqual(
            TmuxProbe.uniqueSessionName(base: "claude", existing: ["claude", "claude-2"]),
            "claude-3")
    }

    func testSessionNameSanitization() {
        // tmux target syntax reserves : and . — normalize like the deck's
        // naming alert always has, and never mint an empty name.
        XCTAssertEqual(TmuxProbe.uniqueSessionName(base: "v1.2:beta", existing: []), "v1-2-beta")
        XCTAssertEqual(TmuxProbe.uniqueSessionName(base: "  ", existing: ["main"]), "main-2")
        XCTAssertEqual(TmuxProbe.sanitizedSessionName(" release.notes "), "release-notes")
        XCTAssertEqual(TmuxProbe.sanitizedSessionName(""), "main")
    }

    func testParseCapturesKeepsTrailingNonBlankTail() {
        let sessions = [session("main", id: "$0"), session("scratch", id: "$1")]
        let output = """
        MULTIPLEX_TAILS
        MPXS $0
        one
        two
        three
        four
        five

        \u{20}\u{20}
        MPXS $1
        % vim notes.md
        MPXE
        """
        let captures = TmuxProbe.parseCaptures(output, sessions: sessions)
        // Blank pane rows below the cursor are dropped; last 4 lines kept.
        XCTAssertEqual(captures["main"], ["two", "three", "four", "five"])
        XCTAssertEqual(captures["scratch"], ["% vim notes.md"])
    }

    func testParseCapturesToleratesTruncationAndBogusIDs() {
        let sessions = [session("main", id: "$0")]
        let output = """
        MULTIPLEX_TAILS
        MPXS $9
        not a real session
        MPXS $0
        tail line
        """
        // No trailing MPXE, and $9 is unknown — both tolerated.
        let captures = TmuxProbe.parseCaptures(output, sessions: sessions)
        XCTAssertEqual(captures, ["main": ["tail line"]])
    }

    func testParseCapturesIgnoresEverythingBeforeTailsSentinel() {
        // Listing/ps sections precede the sentinel; an MPXS-looking ps args
        // row or pane title must not open a capture frame.
        let sessions = [session("main", id: "$0")]
        let output = """
        S $0 1 0 main
        MULTIPLEX_PS
          10 1 echo MPXS $0
        forged line
        MULTIPLEX_TAILS
        MPXS $0
        real tail
        MPXE
        """
        let captures = TmuxProbe.parseCaptures(output, sessions: sessions)
        XCTAssertEqual(captures, ["main": ["real tail"]])
    }

    func testParseStopsAtTailsSentinel() {
        // Pane content is arbitrary bytes — an S/W/P or ps-shaped line in a
        // captured tail must never leak into the session list or ps rows.
        let output = """
        S $0 1 0 main
        W $0 0 1 0 0 editor
        P $0 0 0 1 %0 100 /dev/pts/0 node
        MULTIPLEX_PS
          100 1 node
        MULTIPLEX_TAILS
        MPXS $0
        S $9 1 0 forged
          200 100 claude
        MPXE
        """
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertEqual(sessions.map(\.name), ["main"])
        // The forged ps row sits after the sentinel — no agent detected.
        XCTAssertNil(sessions[0].activeAgent)
    }

    func testParseCapturesClipsTileWidth() {
        let sessions = [session("main", id: "$0")]
        let long = String(repeating: "x", count: 200)
        let captures = TmuxProbe.parseCaptures(
            "MULTIPLEX_TAILS\nMPXS $0\n\(long)\nMPXE", sessions: sessions)
        XCTAssertEqual(captures["main"]?.first?.count, 56)
    }

    func testMalformedLinesAreSkipped() {
        let output = "garbage line\nW $9 short\nS $4 0 1751500000 ok"
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertEqual(sessions.map(\.name), ["ok"])
        XCTAssertEqual(sessions[0].windows, [])
    }

    func testShellQuoting() {
        XCTAssertEqual("plain".shellQuoted, "'plain'")
        XCTAssertEqual("with space".shellQuoted, "'with space'")
        XCTAssertEqual("it's".shellQuoted, "'it'\\''s'")
    }

    func testShellQuotedDirectory() {
        XCTAssertEqual("/srv/app".shellQuotedDirectory, "'/srv/app'")
        // A leading ~ stays outside the quotes as "$HOME" so the remote
        // shell expands it; the rest is quoted verbatim.
        XCTAssertEqual("~".shellQuotedDirectory, "\"$HOME\"")
        XCTAssertEqual("~/work".shellQuotedDirectory, "\"$HOME\"/'work'")
        XCTAssertEqual("~/it's here".shellQuotedDirectory, "\"$HOME\"/'it'\\''s here'")
    }

    func testRouteCommands() {
        let host = UUID()
        let attach = TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))
        XCTAssertEqual(attach.remoteCommand, "exec tmux attach-session -t 'main'")

        let create = TerminalRoute(hostID: host, mode: .create(sessionName: "new one"))
        XCTAssertTrue(create.remoteCommand?.contains(
            "systemd-run --user --scope --quiet -- tmux \"$@\"") == true)
        XCTAssertTrue(create.remoteCommand?.contains(
            "tmux has-session -t '=new one' 2>/dev/null") == true)
        XCTAssertTrue(create.remoteCommand?.contains(
            "multiplex_tmux new-session -d -s 'new one' 2>/dev/null") == true)
        XCTAssertTrue(create.remoteCommand?.hasSuffix(
            "exec tmux attach-session -t 'new one'") == true)

        let shell = TerminalRoute(hostID: host, mode: .shell)
        XCTAssertNil(shell.remoteCommand)
    }

    func testCreateRouteCommandWithDirectory() {
        let host = UUID()
        let create = TerminalRoute(
            hostID: host, mode: .create(sessionName: "app", directory: "~/work"))
        // cd first (errors silenced → shell stays in $HOME), then create
        // detached in the persistent scope before attaching.
        XCTAssertTrue(create.remoteCommand?.hasPrefix(
            "cd \"$HOME\"/'work' 2>/dev/null; multiplex_tmux()") == true)
        XCTAssertTrue(create.remoteCommand?.hasSuffix(
            "exec tmux attach-session -t 'app'") == true)
    }

    // mosh-server execvp()s its trailing argv — no shell, so no `exec`.
    func testMoshRouteCommands() {
        let host = UUID()
        let attach = TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))
        XCTAssertEqual(attach.moshRemoteCommand, "tmux attach-session -t 'main'")

        let create = TerminalRoute(hostID: host, mode: .create(sessionName: "new one"))
        XCTAssertEqual(create.moshRemoteCommand, "tmux new-session -A -s 'new one'")

        // No shell to cd in — the directory rides -c (the bootstrap shell
        // line expands "$HOME" while stripping the quoting).
        let inDir = TerminalRoute(
            hostID: host, mode: .create(sessionName: "app", directory: "~/work"))
        XCTAssertEqual(
            inDir.moshRemoteCommand,
            "tmux new-session -A -s 'app' -c \"$HOME\"/'work'")

        let shell = TerminalRoute(hostID: host, mode: .shell)
        XCTAssertNil(shell.moshRemoteCommand)
    }
}
