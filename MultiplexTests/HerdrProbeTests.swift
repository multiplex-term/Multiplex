import XCTest
@testable import Multiplex

/// Anchors `Bundle(for:)` fixture loading, the BindProtocolTests pattern.
private final class HerdrFixtureAnchor {}

/// Pins the herdr-mode probe to output captured from a real herdr 0.7.5
/// server (protocol 17) on 2026-08-01 — the snapshot fixture is the
/// verbatim `herdr api snapshot` envelope for two workspaces, three tabs,
/// and four panes (one split tab), with agent states faked through
/// `pane report-agent` exactly the way the dev harness will. When herdr
/// changes its wire, this file is where the new truth lands.
final class HerdrProbeTests: XCTestCase {
    // MARK: Fixtures

    private func fixtureSnapshot() throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: HerdrFixtureAnchor.self)
                .url(forResource: "herdr-snapshot-v0-7-5", withExtension: "json"),
            "herdr-snapshot-v0-7-5.json must ship as a test resource"
        )
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Captured `herdr status --json` with the server up (binary/socket
    /// paths abridged; the untouched extra fields still prove tolerant
    /// decoding).
    private let statusUp = #"{"client":{"version":"0.7.5","channel":"stable","#
        + #""protocol":17,"session":null},"server":{"status":"running","#
        + #""running":true,"version":"0.7.5","protocol":17,"#
        + #""capabilities":{"live_handoff":true,"detached_server_daemon":false},"#
        + #""compatible":true,"session":null,"restart_needed":false},"#
        + #""update":{"restart_needed":false}}"#

    /// Captured `herdr status --json` with no server running — it exits 0
    /// and still names the client version, which is the whole reason the
    /// probe carries a status section.
    private let statusDown = #"{"client":{"version":"0.7.5","channel":"stable","#
        + #""protocol":17,"session":null},"server":{"status":"not_running","#
        + #""running":false,"version":null,"protocol":null,"capabilities":null,"#
        + #""compatible":null,"session":null,"restart_needed":false},"#
        + #""update":{"restart_needed":false}}"#

    private func transcript(
        status: String?, snapshot: String?, tails: String = ""
    ) -> String {
        var output = "MULTIPLEX_HERDR_STATUS\n"
        if let status { output += status + "\n" }
        output += "MULTIPLEX_HERDR_SNAPSHOT\n"
        if let snapshot { output += snapshot + "\n" }
        output += "MULTIPLEX_TAILS\n" + tails + "MPXE"
        return output
    }

    // MARK: Snapshot → session mapping

    func testFixtureSnapshotMapsWorkspacesToSessions() throws {
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusUp, snapshot: try fixtureSnapshot())
        )

        guard case .sessions(let sessions) = parsed.state else {
            return XCTFail("expected sessions, got \(parsed.state)")
        }
        XCTAssertEqual(sessions.map(\.name), ["~", "demo"])
        XCTAssertEqual(sessions.map(\.tmuxID), ["w1", "w2"])
        XCTAssertEqual(parsed.serverVersion, "0.7.5")

        // No API surface reports attached clients, so herdr sessions never
        // claim the lamp.
        XCTAssertEqual(sessions.map(\.clientCount), [0, 0])
        XCTAssertTrue(sessions.allSatisfy { !$0.isAttached })

        // created is synthesized from the workspace ordinal so the widget
        // and external actions keep a truthful "most recent" ordering.
        XCTAssertLessThan(sessions[0].created, sessions[1].created)

        let home = sessions[0]
        XCTAssertEqual(home.windows.map(\.index), [1, 2])
        XCTAssertEqual(home.windows.map(\.name), ["1", "2"])
        XCTAssertEqual(home.windows.map(\.isActive), [true, false])
        XCTAssertEqual(home.activeAgent, .claudeCode)
        XCTAssertEqual(home.windows[1].activeAgent, .pi)
        XCTAssertEqual(home.windows[0].panes?.first?.tmuxID, "w1:p1")
        XCTAssertEqual(
            home.windows[0].paneTitle, "jhen@Jhen-MBPr14-429:~",
            "the pane title mirrors herdr's stripped OSC title"
        )

        let demo = sessions[1]
        XCTAssertEqual(demo.windows.count, 1)
        let split = try XCTUnwrap(demo.windows.first)
        XCTAssertEqual(split.paneCount, 2)
        XCTAssertEqual(split.activePane?.tmuxID, "w2:p1",
                       "the layout's focused pane is the keystroke target")
        XCTAssertEqual(split.detectedAgents, [.codex, .codex])
        XCTAssertNil(
            split.displayPaneTitle(serverHost: ""),
            "split windows never advertise one pane's title as the window's"
        )
    }

    func testPaneStatusesAndNextTailSet() throws {
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusUp, snapshot: try fixtureSnapshot())
        )

        XCTAssertEqual(parsed.paneStatuses["w1:p1"], .working)
        XCTAssertEqual(parsed.paneStatuses["w1:p2"], .done)
        XCTAssertEqual(parsed.paneStatuses["w2:p1"], .blocked)
        XCTAssertEqual(parsed.paneStatuses["w2:p2"], .idle)

        // Each workspace fronts its active tab's focused pane — the read
        // set the next probe command bakes in.
        XCTAssertEqual(parsed.tailPaneIDs, ["w1:p1", "w2:p1"])
    }

    func testForeignAgentKeepsStatusWithoutClaimingAKind() throws {
        // A kind Multiplex has no helper set for (herdr supports many
        // more) keeps its lifecycle status but maps to no AgentKind.
        let snapshot = try fixtureSnapshot()
            .replacingOccurrences(of: #""agent":"codex""#, with: #""agent":"devin""#)
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusUp, snapshot: snapshot)
        )

        guard case .sessions(let sessions) = parsed.state else {
            return XCTFail("expected sessions, got \(parsed.state)")
        }
        XCTAssertEqual(sessions[1].detectedAgents, [])
        XCTAssertEqual(parsed.paneStatuses["w2:p1"], .blocked)
    }

    func testFutureAgentStatusDecodesAsUnknown() throws {
        let snapshot = try fixtureSnapshot()
            .replacingOccurrences(
                of: #""agent_status":"blocked""#, with: #""agent_status":"meditating""#
            )
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusUp, snapshot: snapshot)
        )
        XCTAssertEqual(parsed.paneStatuses["w2:p1"], .unknown)
    }

    // MARK: Tails

    func testTailsKeyByWorkspaceNameAndClipLikeTmux() throws {
        let tails = """
        MPXS w1:p1
        one   \t
        two
        three
        four
        five

        \u{20}
        MPXS w2:p1
        demo line
        MPXS w9:p9
        orphan content
        """
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusUp, snapshot: try fixtureSnapshot(),
                       tails: tails + "\n")
        )

        // Right-trimmed, trailing blank run dropped — the tmux rules.
        XCTAssertEqual(parsed.tails["~"], ["one", "two", "three", "four", "five"])
        XCTAssertEqual(parsed.tails["demo"], ["demo line"])
        // Miniatures keep the trailing miniatureLines only.
        XCTAssertEqual(parsed.miniatures["~"], ["two", "three", "four", "five"])
        // A baked pane id that vanished this tick resolves to no owner.
        XCTAssertEqual(parsed.tails.count, 2)
    }

    // MARK: Failure classification

    func testHerdrMissing() {
        let parsed = HerdrProbe.parseProbe("MULTIPLEX_NO_HERDR\n")
        XCTAssertEqual(parsed.state, .herdrMissing)
    }

    func testServerDownClassifiesAsNoServer() {
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusDown, snapshot: nil)
        )
        XCTAssertEqual(parsed.state, .noServer)
        XCTAssertEqual(parsed.serverVersion, "0.7.5",
                       "the client version still rides status for the tile")
    }

    func testOldProtocolInSnapshotIsUpdateNeeded() throws {
        let snapshot = try fixtureSnapshot()
            .replacingOccurrences(of: #""protocol":17"#, with: #""protocol":5"#)
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusUp, snapshot: snapshot)
        )
        XCTAssertEqual(parsed.state, .updateNeeded(installedVersion: "0.7.5"))
    }

    func testOldClientProtocolWithoutSnapshotIsUpdateNeeded() {
        let status = statusDown
            .replacingOccurrences(of: #""protocol":17"#, with: #""protocol":3"#)
            .replacingOccurrences(of: #""version":"0.7.5""#, with: #""version":"0.4.0""#)
        let parsed = HerdrProbe.parseProbe(
            transcript(status: status, snapshot: nil)
        )
        XCTAssertEqual(parsed.state, .updateNeeded(installedVersion: "0.4.0"))
    }

    func testRunningServerWithoutSnapshotFails() {
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusUp, snapshot: nil)
        )
        guard case .failed = parsed.state else {
            return XCTFail("expected failed, got \(parsed.state)")
        }
    }

    func testGarbageOutputFails() {
        let parsed = HerdrProbe.parseProbe("zsh: command not found: something\n")
        guard case .failed = parsed.state else {
            return XCTFail("expected failed, got \(parsed.state)")
        }
    }

    // MARK: Workspace name uniqueness

    func testDuplicateWorkspaceLabelsDisambiguate() {
        // TmuxSession.id is the name; herdr does not enforce unique labels.
        let workspaces = [
            HerdrProbe.Workspace(
                workspaceID: "w1", number: 1, label: "~", activeTabID: "w1:t1"),
            HerdrProbe.Workspace(
                workspaceID: "w2", number: 2, label: "~", activeTabID: "w2:t1"),
            HerdrProbe.Workspace(
                workspaceID: "w3", number: 3, label: "api", activeTabID: "w3:t1"),
            HerdrProbe.Workspace(
                workspaceID: "w4", number: 4, label: "", activeTabID: "w4:t1")
        ]
        let names = HerdrProbe.uniqueWorkspaceNames(workspaces)
        XCTAssertEqual(names["w1"], "~ ·1")
        XCTAssertEqual(names["w2"], "~ ·2")
        XCTAssertEqual(names["w3"], "api")
        XCTAssertEqual(names["w4"], "workspace 4",
                       "an empty label falls back to the ordinal")
        XCTAssertEqual(Set(names.values).count, 4)
    }

    // MARK: Probe command

    func testProbeCommandShape() {
        let command = HerdrProbe.probeCommand(tailPaneIDs: ["w1:p1", "w2:p1"])

        XCTAssertTrue(command.hasPrefix(HerdrProbe.pathPrefix))
        XCTAssertTrue(command.contains(
            "command -v herdr >/dev/null 2>&1 || { echo MULTIPLEX_NO_HERDR; exit 0; }"))
        XCTAssertTrue(command.contains("herdr status --json 2>/dev/null || true"))
        XCTAssertTrue(command.contains("herdr api snapshot 2>/dev/null || true"))
        XCTAssertTrue(command.contains(
            "herdr pane read 'w1:p1' --source visible 2>/dev/null || true"))
        XCTAssertTrue(command.contains("echo 'MPXS w2:p1'"))
        XCTAssertTrue(command.hasSuffix("echo MPXE"))
    }

    func testProbeCommandWithNoTailsStillFrames() {
        let command = HerdrProbe.probeCommand(tailPaneIDs: [])
        XCTAssertTrue(command.contains("echo MULTIPLEX_TAILS; echo MPXE"))
        XCTAssertFalse(command.contains("pane read"))
    }

    // MARK: herdr agent ids

    func testHerdrAgentKindMapping() {
        XCTAssertEqual(AgentKind(herdrAgent: "claude"), .claudeCode)
        XCTAssertEqual(AgentKind(herdrAgent: "codex"), .codex)
        XCTAssertEqual(AgentKind(herdrAgent: "pi"), .pi)
        XCTAssertNil(AgentKind(herdrAgent: "opencode"))
    }

    // MARK: Attention mapping

    func testPaneAgentStateMapping() {
        XCTAssertEqual(HerdrProbe.paneAgentState(.working), .busy)
        XCTAssertEqual(HerdrProbe.paneAgentState(.blocked), .needsYou(.permission))
        // done → idle hands the tracker the busy → idle edge that raises
        // the turn-ended alert exactly once.
        XCTAssertEqual(HerdrProbe.paneAgentState(.done), .idle)
        XCTAssertEqual(HerdrProbe.paneAgentState(.idle), .idle)
        XCTAssertNil(HerdrProbe.paneAgentState(.unknown))
        XCTAssertNil(HerdrProbe.paneAgentState(nil))
    }

    func testStateFoldsOntoTmuxState() {
        XCTAssertEqual(HerdrProbe.State.herdrMissing.tmuxState, .tmuxMissing)
        XCTAssertEqual(HerdrProbe.State.noServer.tmuxState, .noServer)
        guard case .failed(let message) = HerdrProbe.State
            .updateNeeded(installedVersion: "0.4.0").tmuxState else {
            return XCTFail("updateNeeded should ride the failed lane")
        }
        XCTAssertTrue(message.contains("0.4.0"))
    }

    // MARK: Working directories

    func testPaneCWDsRideTheParse() throws {
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusUp, snapshot: try fixtureSnapshot())
        )
        XCTAssertEqual(parsed.paneCWDs["w1:p1"], "/Users/jhen")
        XCTAssertEqual(parsed.paneCWDs["w2:p1"], "/private/tmp")
    }

    // MARK: Workspace actions

    func testNewWorkspaceCommandShape() {
        let command = HerdrProbe.newWorkspaceCommand(label: "web-2", cwd: "~/api")
        XCTAssertTrue(command.contains(
            #"herdr workspace create --cwd "$HOME"/'api' --label 'web-2' 2>/dev/null || true"#))
        let bare = HerdrProbe.newWorkspaceCommand(label: "web", cwd: nil)
        XCTAssertFalse(bare.contains("--cwd"))
    }

    func testParseNewWorkspaceReadsTheCreateEnvelope() {
        // The captured create envelope's shape (2026-08-01, herdr 0.7.5),
        // abridged around the fields the parser reads.
        let output = "ignored login noise\n"
            + #"{"id":"cli:workspace:create","result":{"root_pane":"#
            + #"{"agent_status":"unknown","cwd":"/private/tmp","focused":false,"#
            + #""pane_id":"w2:p1","revision":0,"tab_id":"w2:t1","workspace_id":"w2"},"#
            + #""tab":{"label":"1","number":1,"tab_id":"w2:t1","workspace_id":"w2"},"#
            + #""type":"workspace_created","workspace":{"active_tab_id":"w2:t1","#
            + #""agent_status":"unknown","focused":false,"label":"demo","number":2,"#
            + #""pane_count":1,"tab_count":1,"workspace_id":"w2"}}}"#
        let created = HerdrProbe.parseNewWorkspace(output)
        XCTAssertEqual(created, HerdrProbe.NewWorkspace(
            workspaceID: "w2", label: "demo", rootPaneID: "w2:p1"))
        XCTAssertNil(HerdrProbe.parseNewWorkspace("Error: no server\n"))
    }

    func testTypeCommandTypesLinesThenEnter() {
        let command = HerdrProbe.typeCommand(
            paneID: "w2:p1", lines: ["source .env", "claude 'do it'"])
        XCTAssertNotNil(command)
        XCTAssertTrue(command?.contains(
            "herdr pane send-text 'w2:p1' 'source .env' 2>/dev/null || true") == true)
        XCTAssertTrue(command?.contains(
            "herdr pane send-text 'w2:p1' " + "claude 'do it'".shellQuoted) == true)
        XCTAssertTrue(command?.contains(
            "herdr pane send-keys 'w2:p1' Enter") == true)
        XCTAssertNil(HerdrProbe.typeCommand(paneID: "w2:p1", lines: []))
        XCTAssertNil(HerdrProbe.typeCommand(paneID: "w2:p1", lines: [""]))
    }

    func testCloseWorkspaceCommandShape() {
        XCTAssertTrue(HerdrProbe.closeWorkspaceCommand(workspaceID: "w4")
            .contains("herdr workspace close 'w4' 2>/dev/null || true"))
    }

    func testAttachCommandFocusesThenExecs() {
        let command = HerdrProbe.attachCommand(workspaceID: "w3")
        XCTAssertTrue(command.contains("herdr workspace focus 'w3' >/dev/null 2>&1; "))
        XCTAssertTrue(command.hasSuffix("exec herdr session attach default"))
        // The blind form (debug auto-attach before any probe) skips focus.
        XCTAssertFalse(HerdrProbe.attachCommand(workspaceID: "").contains("focus"))
    }
}

/// The tmux probe's herdr-presence line — the dead-tile switch hint's
/// input. Presence rides every tick; only dead tiles read it.
final class TmuxProbeHerdrPresenceTests: XCTestCase {
    func testProbeCommandChecksHerdrBeforeTheTmuxGuard() {
        let command = TmuxProbe.probeCommand
        let herdrCheck = command.range(
            of: "command -v herdr >/dev/null 2>&1 && echo MULTIPLEX_HERDR_PRESENT")
        let tmuxGuard = command.range(of: "command -v tmux")
        XCTAssertNotNil(herdrCheck)
        XCTAssertNotNil(tmuxGuard)
        if let herdrCheck, let tmuxGuard {
            XCTAssertLessThan(herdrCheck.lowerBound, tmuxGuard.lowerBound,
                              "the tmux guard exits; herdr must be checked first")
        }
    }

    func testParseProbeReadsThePresenceMarker() {
        let missingWithHerdr = TmuxProbe.parseProbe(
            "MULTIPLEX_HERDR_PRESENT\nMULTIPLEX_NO_TMUX\n")
        XCTAssertEqual(missingWithHerdr.state, .tmuxMissing)
        XCTAssertTrue(missingWithHerdr.herdrPresent)

        let missingAlone = TmuxProbe.parseProbe("MULTIPLEX_NO_TMUX\n")
        XCTAssertFalse(missingAlone.herdrPresent)
    }
}

/// The Agent Gallery's pure derivations: rail rows from the probe's
/// records, selection continuity, prompt hygiene, and the composer's
/// delivery verdicts.
final class AgentGalleryTests: XCTestCase {
    private func pane(
        _ id: String, agent: AgentKind?, kind: String, active: Bool = true
    ) -> TmuxPane {
        TmuxPane(
            index: 0, isActive: active, tmuxID: id, pid: 0, tty: "",
            command: kind, title: "", agent: agent
        )
    }

    func testRailRowsComeFromAgentPanesOnly() {
        let sessions = [
            TmuxSession(
                name: "web",
                windows: [TmuxWindow(
                    index: 1, name: "1", isActive: true, hasBell: false,
                    hasActivity: false,
                    panes: [
                        pane("w1:p1", agent: .claudeCode, kind: "claude"),
                        TmuxPane(
                            index: 1, isActive: false, tmuxID: "w1:p2", pid: 0,
                            tty: "", command: "", title: "", agent: nil),
                    ]
                )],
                created: .distantPast, tmuxID: "w1"
            ),
            TmuxSession(
                name: "api",
                windows: [TmuxWindow(
                    index: 1, name: "1", isActive: true, hasBell: false,
                    hasActivity: false,
                    panes: [pane("w2:p1", agent: nil, kind: "devin")]
                )],
                created: .distantPast, tmuxID: "w2"
            ),
        ]
        let rows = AgentGallery.agents(
            sessions: sessions,
            statuses: ["w1:p1": .working, "w2:p1": .blocked]
        )
        XCTAssertEqual(rows.map(\.paneID), ["w1:p1", "w2:p1"])
        XCTAssertEqual(rows[0].displayName, AgentKind.claudeCode.telemetryLabel)
        XCTAssertEqual(rows[0].statusWord, "WORKING")
        // A foreign kind keeps its honest status and herdr name.
        XCTAssertNil(rows[1].agent)
        XCTAssertEqual(rows[1].displayName, "DEVIN")
        XCTAssertTrue(rows[1].needsYou)
        XCTAssertEqual(rows[1].workspaceName, "api")
    }

    func testSelectionPrefersBlockedThenWorking() {
        let agents = [
            GalleryAgent(paneID: "a", agent: .pi, herdrKind: "pi",
                         workspaceName: "x", workspaceID: "w1", status: .idle),
            GalleryAgent(paneID: "b", agent: .codex, herdrKind: "codex",
                         workspaceName: "y", workspaceID: "w2", status: .working),
            GalleryAgent(paneID: "c", agent: .claudeCode, herdrKind: "claude",
                         workspaceName: "z", workspaceID: "w3", status: .blocked),
        ]
        XCTAssertEqual(AgentGallery.resolvedSelection(previous: nil, agents: agents), "c")
        XCTAssertEqual(AgentGallery.resolvedSelection(previous: "a", agents: agents), "a")
        XCTAssertEqual(
            AgentGallery.resolvedSelection(previous: "gone", agents: agents), "c")
        XCTAssertNil(AgentGallery.resolvedSelection(previous: "a", agents: []))
    }

    func testPromptSanitizerStripsControlsKeepsNewlines() {
        // Control BYTES go (Ctrl-B especially — the tmux prefix), CR-LF
        // normalizes, interior newlines stay for bracketed paste. Printable
        // remainders of an escape sequence are the policy's documented
        // behavior, same as the custom-command editor.
        XCTAssertEqual(
            AgentGalleryController.sanitizedPrompt("  fix\u{02} the\r\nbuild\u{1B} "),
            "fix the\nbuild"
        )
        XCTAssertEqual(AgentGalleryController.sanitizedPrompt(" \n "), "")
    }

    func testVisibleLinesTrimLikeTheMiniatures() {
        XCTAssertEqual(
            AgentGalleryController.visibleLines("one  \ntwo\n\n   \n"),
            ["one", "two"]
        )
    }

    func testPromptVerdicts() {
        XCTAssertEqual(HerdrProbe.promptVerdict(""), .delivered)
        XCTAssertEqual(
            HerdrProbe.promptVerdict("agent_prompt_stalled\n"), .stalled)
        XCTAssertEqual(
            HerdrProbe.promptVerdict(
                #"{"error":{"code":"agent_not_found","message":"agent target x not found"},"id":"cli:agent:prompt"}"#),
            .failed("agent target x not found")
        )
        XCTAssertEqual(
            HerdrProbe.promptVerdict("Error: Os { code: 2 }"),
            .failed("Error: Os { code: 2 }")
        )
    }

    func testScreenAndPromptCommandShapes() {
        XCTAssertTrue(HerdrProbe.screenReadCommand(paneID: "w1:p1")
            .contains("herdr pane read 'w1:p1' --source visible 2>/dev/null || true"))
        let prompt = HerdrProbe.promptCommand(paneID: "w1:p1", text: "fix it")
        XCTAssertTrue(prompt.contains("herdr agent prompt 'w1:p1' 'fix it' 2>&1 || true"))
    }
}

/// The `.herdrAttach` route: the PTY command, the mosh argv, and the
/// identity surfaces the workspace label answers for.
final class HerdrRouteTests: XCTestCase {
    private let route = TerminalRoute(
        hostID: UUID(),
        mode: .herdrAttach(workspaceID: "w3", label: "web")
    )

    func testRemoteCommandAttachesTheHerdrClient() throws {
        let command = try XCTUnwrap(route.remoteCommand)
        XCTAssertTrue(command.contains("herdr workspace focus 'w3'"))
        XCTAssertTrue(command.hasSuffix("exec herdr session attach default"))
    }

    func testMoshRemoteCommandWrapsTheTwoCommandsInAShell() throws {
        let command = try XCTUnwrap(route.moshRemoteCommand)
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        XCTAssertTrue(command.contains("herdr session attach default"))
    }

    func testIdentitySurfacesAnswerTheLabel() {
        XCTAssertEqual(route.displayName, "web")
        XCTAssertEqual(route.sessionName, "web")
        XCTAssertFalse(route.usesTmux)
        XCTAssertFalse(route.isAuxiliaryPane)
    }

    func testAttachFactoryPicksTheBackend() {
        var host = Host(name: "box", hostname: "10.0.0.1", username: "dev")
        let session = TmuxSession(
            name: "web", windows: [], created: .distantPast, tmuxID: "w3")

        XCTAssertEqual(
            TerminalRoute.Mode.attach(host: host, session: session),
            .attach(sessionName: "web")
        )
        host.sessionBackend = .herdr
        XCTAssertEqual(
            TerminalRoute.Mode.attach(host: host, session: session),
            .herdrAttach(workspaceID: "w3", label: "web")
        )
    }

    func testTmuxRoutesKeepTmuxChrome() {
        let tmuxRoute = TerminalRoute(
            hostID: UUID(), mode: .attach(sessionName: "main"))
        XCTAssertTrue(tmuxRoute.usesTmux)
        let shellRoute = TerminalRoute(hostID: UUID(), mode: .shell)
        XCTAssertFalse(shellRoute.usesTmux)
    }

    func testAgentDoorAttachIsScopedAndNeverDedupesAsTheWorkspace() throws {
        // Decision #4's hybrid: agent doors take `herdr agent attach` —
        // chrome-free, one agent's terminal — never the full client.
        let door = TerminalRoute(
            hostID: UUID(),
            mode: .herdrAgentAttach(target: "w2:p1", label: "codex · api")
        )
        let command = try XCTUnwrap(door.remoteCommand)
        XCTAssertTrue(command.hasSuffix("exec herdr agent attach 'w2:p1'"))
        XCTAssertFalse(command.contains("session attach"))
        XCTAssertEqual(door.moshRemoteCommand, "herdr agent attach 'w2:p1'")
        XCTAssertEqual(door.displayName, "codex · api")
        // Not the workspace's client: tile-press focus dedupe matches on
        // sessionName, and this tab must never be raised in its place.
        XCTAssertNil(door.sessionName)
        XCTAssertFalse(door.usesTmux)
        XCTAssertFalse(door.isAuxiliaryPane)
    }
}

/// The backend field itself: legacy records decode to tmux, unknown
/// future values fail soft to tmux instead of dropping the host, and a
/// backend flip restarts the probe connection.
final class HostSessionBackendTests: XCTestCase {
    private func decodeHost(_ json: String) throws -> Host {
        try JSONDecoder().decode(Host.self, from: Data(json.utf8))
    }

    func testLegacyRecordDecodesToTmux() throws {
        let host = try decodeHost(
            #"{"name":"box","hostname":"10.0.0.1","username":"dev"}"#
        )
        XCTAssertEqual(host.sessionBackend, .tmux)
    }

    func testHerdrValueRoundTrips() throws {
        var host = Host(name: "box", hostname: "10.0.0.1", username: "dev")
        host.sessionBackend = .herdr
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded.sessionBackend, .herdr)
    }

    func testUnknownBackendFailsSoftToTmux() throws {
        let host = try decodeHost(
            #"{"name":"box","hostname":"10.0.0.1","username":"dev","sessionBackend":"zellij"}"#
        )
        XCTAssertEqual(host.sessionBackend, .tmux)
    }

    func testBackendFlipChangesConnectionModelConfiguration() {
        var tmuxHost = Host(name: "box", hostname: "10.0.0.1", username: "dev")
        var herdrHost = tmuxHost
        herdrHost.sessionBackend = .herdr

        XCTAssertFalse(
            tmuxHost.hasSameConnectionModelConfiguration(as: herdrHost),
            "a backend flip must tear down and rebuild the probe"
        )

        // Content-field edits still keep the probe link.
        tmuxHost.sessionScripts = [SessionScript(name: "setup", body: "true")]
        var edited = tmuxHost
        edited.updatedAt = Date()
        XCTAssertTrue(tmuxHost.hasSameConnectionModelConfiguration(as: edited))
    }
}
