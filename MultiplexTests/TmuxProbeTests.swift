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
        P $0 0 1 4242 claude ✳ Claude Code
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
        P $0 0 1 77 cat ✳ Claude Code
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
        P $0 0 1 100 node
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

    func testAgentOnlyFromActiveWindowAndPane() {
        let output = """
        S $0 1 0 main
        W $0 0 0 0 0 editor
        W $0 1 1 0 0 agent
        P $0 0 1 10 claude
        P $0 1 0 20 claude
        P $0 1 1 30 zsh
        """
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        // Window 0 (inactive window, active pane) still records its agent…
        XCTAssertEqual(sessions[0].windows[0].agent, .claudeCode)
        // …the inactive pane of window 1 is ignored, so window 1 has none…
        XCTAssertNil(sessions[0].windows[1].agent)
        // …and the session's activeAgent follows the ACTIVE window's pane —
        // the one attach keystrokes reach.
        XCTAssertNil(sessions[0].activeAgent)
    }

    func testMalformedAgentLinesNeverHurtSessions() {
        let output = """
        S $0 1 0 main
        W $0 0 1 0 0 editor
        P $0 short
        P $9 0 1 11 claude
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
        XCTAssertTrue(command.contains("#{pane_current_command} #{pane_title}"))
        XCTAssertTrue(command.contains("echo MULTIPLEX_PS"))
        XCTAssertTrue(command.contains("ps -eo pid=,ppid=,args="))
        XCTAssertTrue(command.contains("cut -c1-120"))
        // The original sentinel + fail-soft contract survives.
        XCTAssertTrue(command.contains("MULTIPLEX_NO_TMUX"))
        XCTAssertTrue(command.hasSuffix("|| true"))
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

    func testCaptureCommandTargetsSessionIDsWithMarkers() {
        let command = TmuxProbe.captureCommand(for: [
            session("main", id: "$0"),
            session("my project ✨", id: "$7"),
        ])
        XCTAssertTrue(command.contains("echo 'MPXS 0'; tmux capture-pane -p -t '$0'"))
        XCTAssertTrue(command.contains("echo 'MPXS 1'; tmux capture-pane -p -t '$7'"))
        XCTAssertTrue(command.hasSuffix("echo 'MPXE'"))
        // Names never appear in targets or markers — ids are unambiguous.
        XCTAssertFalse(command.contains("my project"))
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
        MPXS 0
        one
        two
        three
        four
        five

        \u{20}\u{20}
        MPXS 1
        % vim notes.md
        MPXE
        """
        let captures = TmuxProbe.parseCaptures(output, sessions: sessions)
        // Blank pane rows below the cursor are dropped; last 4 lines kept.
        XCTAssertEqual(captures["main"], ["two", "three", "four", "five"])
        XCTAssertEqual(captures["scratch"], ["% vim notes.md"])
    }

    func testParseCapturesToleratesTruncationAndBogusIndexes() {
        let sessions = [session("main", id: "$0")]
        let output = """
        MPXS 9
        not a real session
        MPXS 0
        tail line
        """
        // No trailing MPXE, and index 9 is out of range — both tolerated.
        let captures = TmuxProbe.parseCaptures(output, sessions: sessions)
        XCTAssertEqual(captures, ["main": ["tail line"]])
    }

    func testParseCapturesClipsTileWidth() {
        let sessions = [session("main", id: "$0")]
        let long = String(repeating: "x", count: 200)
        let captures = TmuxProbe.parseCaptures("MPXS 0\n\(long)\nMPXE", sessions: sessions)
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
