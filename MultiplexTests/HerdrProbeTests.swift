import XCTest
@testable import Multiplex

/// Anchors `Bundle(for:)` fixture loading, the BindProtocolTests pattern.
private final class HerdrFixtureAnchor {}

/// Pins the herdr-mode probe to output captured from a real herdr 0.7.5
/// install (protocol 17; snapshot fixture captured 2026-08-01, session
/// list / lifecycle verbs verified live 2026-08-02) — the snapshot
/// fixture is the verbatim `herdr api snapshot` envelope for two
/// workspaces, three tabs, and four panes (one split tab, one background
/// tab), with agent states faked through `pane report-agent` exactly the
/// way the dev harness does. When herdr changes its wire, this file is
/// where the new truth lands.
///
/// The mapping under test: one deck tile per herdr SESSION (a whole
/// server), workspaces as that tile's windows. Pane ids collide across
/// sessions by design (`w1:p1` exists in every fresh session), which is
/// why everything keys by session first.
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
    /// and still names the client version, the probe's version gate.
    private let statusDown = #"{"client":{"version":"0.7.5","channel":"stable","#
        + #""protocol":17,"session":null},"server":{"status":"not_running","#
        + #""running":false,"version":null,"protocol":null,"capabilities":null,"#
        + #""compatible":null,"session":null,"restart_needed":false},"#
        + #""update":{"restart_needed":false}}"#

    /// Captured `herdr session list --json` shape (2026-08-02): a client
    /// verb, plain JSON, extra fields prove tolerant decoding. `default`
    /// and `work` run; `parked` is stopped.
    private let sessionList = #"{"sessions":["#
        + #"{"default":true,"name":"default","running":true,"#
        + #""session_dir":"/home/dev/.config/herdr","#
        + #""socket_path":"/home/dev/.config/herdr/herdr.sock"},"#
        + #"{"default":false,"name":"work","running":true,"#
        + #""session_dir":"/home/dev/.config/herdr/sessions/work","#
        + #""socket_path":"/home/dev/.config/herdr/sessions/work/herdr.sock"},"#
        + #"{"default":false,"name":"parked","running":false,"#
        + #""session_dir":"/home/dev/.config/herdr/sessions/parked","#
        + #""socket_path":"/home/dev/.config/herdr/sessions/parked/herdr.sock"}"#
        + #"]}"#

    /// A second running session's snapshot (shape-true, hand-reduced):
    /// one workspace, one pane — whose ids deliberately COLLIDE with the
    /// default session's (`w1:p1` exists in both, as it does on any real
    /// host).
    private let workSnapshot = #"{"id":"cli:api:snapshot","result":{"snapshot":{"#
        + #""version":"0.7.5","protocol":17,"agents":[],"#
        + #""focused_workspace_id":"w1","focused_tab_id":"w1:t1","#
        + #""focused_pane_id":"w1:p1","#
        + #""workspaces":[{"workspace_id":"w1","number":1,"label":"api","#
        + #""active_tab_id":"w1:t1"}],"#
        + #""tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1"}],"#
        + #""panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","#
        + #""agent":"codex","agent_status":"blocked"}],"#
        + #""layouts":[{"tab_id":"w1:t1","focused_pane_id":"w1:p1"}]}}}"#

    private func transcript(
        status: String?,
        list: String?,
        snapshots: [(name: String, json: String)] = [],
        tails: String = ""
    ) -> String {
        var output = "MULTIPLEX_HERDR_STATUS\n"
        if let status { output += status + "\n" }
        output += "MULTIPLEX_HERDR_SESSIONS\n"
        if let list { output += list + "\n" }
        for snapshot in snapshots {
            output += "MULTIPLEX_HERDR_SNAP \(snapshot.name)\n" + snapshot.json + "\n"
        }
        output += "MULTIPLEX_TAILS\n" + tails + "MPXE"
        return output
    }

    private func standardTranscript(tails: String = "") throws -> String {
        transcript(
            status: statusUp,
            list: sessionList,
            snapshots: [
                ("default", try fixtureSnapshot()),
                ("work", workSnapshot),
            ],
            tails: tails
        )
    }

    // MARK: Session → tile mapping

    func testSessionsBecomeTilesInListOrder() throws {
        let parsed = HerdrProbe.parseProbe(try standardTranscript())

        guard case .sessions(let sessions) = parsed.state else {
            return XCTFail("expected sessions, got \(parsed.state)")
        }
        XCTAssertEqual(sessions.map(\.name), ["default", "work", "parked"])
        XCTAssertEqual(sessions.map(\.tmuxID), ["default", "work", "parked"],
                       "session names are herdr's own unique identity")
        XCTAssertEqual(parsed.serverVersion, "0.7.5")

        // No API surface reports attached clients, so herdr sessions never
        // claim the lamp.
        XCTAssertEqual(sessions.map(\.clientCount), [0, 0, 0])
        XCTAssertTrue(sessions.allSatisfy { !$0.isAttached })

        // created is synthesized from the list position so the widget and
        // external actions keep a deterministic "most recent" ordering.
        XCTAssertLessThan(sessions[0].created, sessions[1].created)
        XCTAssertLessThan(sessions[1].created, sessions[2].created)
    }

    func testWorkspacesBecomeWindows() throws {
        let parsed = HerdrProbe.parseProbe(try standardTranscript())
        guard case .sessions(let sessions) = parsed.state else {
            return XCTFail("expected sessions, got \(parsed.state)")
        }

        let home = sessions[0]
        XCTAssertEqual(home.windows.map(\.index), [1, 2])
        XCTAssertEqual(home.windows.map(\.name), ["~", "demo"],
                       "workspace labels are the spine lines — duplicates allowed")
        XCTAssertEqual(home.windows.map(\.isActive), [true, false],
                       "the focused workspace is the active window")
        XCTAssertEqual(home.activeAgent, .claudeCode)
        XCTAssertEqual(home.windows[0].panes?.map(\.tmuxID), ["w1:p1"],
                       "a window carries its workspace's ACTIVE tab's panes")
        XCTAssertEqual(
            home.windows[0].paneTitle, "jhen@Jhen-MBPr14-429:~",
            "the pane title mirrors herdr's stripped OSC title"
        )

        let split = home.windows[1]
        XCTAssertEqual(split.paneCount, 2)
        XCTAssertEqual(split.activePane?.tmuxID, "w2:p1",
                       "the layout's focused pane is the keystroke target")
        XCTAssertEqual(split.detectedAgents, [.codex, .codex])
        XCTAssertNil(
            split.displayPaneTitle(serverHost: ""),
            "split windows never advertise one pane's title as the window's"
        )

        let work = sessions[1]
        XCTAssertEqual(work.windows.map(\.name), ["api"])
        XCTAssertEqual(work.activeAgent, .codex)
    }

    func testStoppedSessionIsASpinelessTile() throws {
        let parsed = HerdrProbe.parseProbe(try standardTranscript())
        guard case .sessions(let sessions) = parsed.state else {
            return XCTFail("expected sessions, got \(parsed.state)")
        }
        let parked = sessions[2]
        XCTAssertTrue(parked.windows.isEmpty,
                      "no snapshot — attach restarts it, so the tile still presses")
        XCTAssertNil(parked.activeWindow)
    }

    func testStoppedOnlyHostStillShowsTiles() throws {
        // Every session stopped: no server answers, but the tiles remain —
        // attach restarts them. server.running is deliberately not the
        // classifier.
        let stoppedList = sessionList
            .replacingOccurrences(of: #""running":true"#, with: #""running":false"#)
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusDown, list: stoppedList)
        )
        guard case .sessions(let sessions) = parsed.state else {
            return XCTFail("expected sessions, got \(parsed.state)")
        }
        XCTAssertEqual(sessions.map(\.name), ["default", "work", "parked"])
        XCTAssertTrue(sessions.allSatisfy(\.windows.isEmpty))
        XCTAssertTrue(parsed.tailTargets.isEmpty)
        XCTAssertTrue(parsed.sessionNames.isEmpty)
    }

    // MARK: Statuses, targets, and the next tick's bake

    func testPaneStatusesKeyBySessionFirst() throws {
        let parsed = HerdrProbe.parseProbe(try standardTranscript())

        XCTAssertEqual(parsed.paneStatuses["default"]?["w1:p1"], .working)
        XCTAssertEqual(parsed.paneStatuses["default"]?["w1:p2"], .done,
                       "background-tab panes carry statuses too")
        XCTAssertEqual(parsed.paneStatuses["default"]?["w2:p1"], .blocked)
        XCTAssertEqual(parsed.paneStatuses["default"]?["w2:p2"], .idle)
        // The SAME pane id in another session is another pane.
        XCTAssertEqual(parsed.paneStatuses["work"]?["w1:p1"], .blocked)
        XCTAssertNil(parsed.paneStatuses["parked"])
    }

    func testNextTickBakesRunningSessionsAndTheirFronts() throws {
        let parsed = HerdrProbe.parseProbe(try standardTranscript())

        XCTAssertEqual(parsed.sessionNames, ["default", "work"],
                       "stopped sessions get no snapshot next tick")
        XCTAssertEqual(parsed.tailTargets, [
            HerdrProbe.TailTarget(sessionName: "default", paneID: "w1:p1"),
            HerdrProbe.TailTarget(sessionName: "work", paneID: "w1:p1"),
        ], "one miniature read per running session — its focused pane")
    }

    func testForeignAgentKeepsStatusWithoutClaimingAKind() throws {
        // A kind Multiplex has no helper set for (herdr supports many
        // more) keeps its lifecycle status but maps to no AgentKind.
        let snapshot = try fixtureSnapshot()
            .replacingOccurrences(of: #""agent":"codex""#, with: #""agent":"devin""#)
        let parsed = HerdrProbe.parseProbe(transcript(
            status: statusUp, list: sessionList,
            snapshots: [("default", snapshot)]
        ))

        guard case .sessions(let sessions) = parsed.state else {
            return XCTFail("expected sessions, got \(parsed.state)")
        }
        XCTAssertEqual(sessions[0].windows[1].detectedAgents, [])
        XCTAssertEqual(parsed.paneStatuses["default"]?["w2:p1"], .blocked)
    }

    func testFutureAgentStatusDecodesAsUnknown() throws {
        let snapshot = try fixtureSnapshot()
            .replacingOccurrences(
                of: #""agent_status":"blocked""#, with: #""agent_status":"meditating""#
            )
        let parsed = HerdrProbe.parseProbe(transcript(
            status: statusUp, list: sessionList,
            snapshots: [("default", snapshot)]
        ))
        XCTAssertEqual(parsed.paneStatuses["default"]?["w2:p1"], .unknown)
    }

    // MARK: Tails

    func testTailsKeyBySessionAndValidateOwnership() throws {
        let tails = """
        MPXS default w1:p1
        one   \t
        two
        three
        four
        five

        \u{20}
        MPXS work w1:p1
        work line
        MPXS work w9:p9
        stale baked pane, dropped
        MPXS evil w1:p1
        forged session, dropped
        """
        let parsed = HerdrProbe.parseProbe(
            try standardTranscript(tails: tails + "\n")
        )

        // Right-trimmed, trailing blank run dropped — the tmux rules.
        XCTAssertEqual(parsed.tails["default"], ["one", "two", "three", "four", "five"])
        // The colliding pane id lands on ITS session, not the other's.
        XCTAssertEqual(parsed.tails["work"], ["work line"])
        // Miniatures keep the trailing miniatureLines only.
        XCTAssertEqual(parsed.miniatures["default"], ["two", "three", "four", "five"])
        // Frames the snapshots can't vouch for are dropped, not believed.
        XCTAssertEqual(parsed.tails.count, 2)
    }

    func testSessionNamesWithSpacesStillFrame() throws {
        // The MPXS separator is the LAST space: pane ids are
        // whitespace-free by the bake guard, names may contain spaces.
        let spacedList = sessionList.replacingOccurrences(
            of: #""name":"work""#, with: #""name":"my work""#)
        let parsed = HerdrProbe.parseProbe(transcript(
            status: statusUp, list: spacedList,
            snapshots: [("my work", workSnapshot)],
            tails: "MPXS my work w1:p1\nspaced session line\n"
        ))
        XCTAssertEqual(parsed.tails["my work"], ["spaced session line"])
        XCTAssertEqual(parsed.tailTargets, [
            HerdrProbe.TailTarget(sessionName: "my work", paneID: "w1:p1"),
        ])
    }

    // MARK: Failure classification

    func testHerdrMissing() {
        let parsed = HerdrProbe.parseProbe("MULTIPLEX_NO_HERDR\n")
        XCTAssertEqual(parsed.state, .herdrMissing)
    }

    func testEmptySessionListClassifiesAsNoServer() {
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusDown, list: #"{"sessions":[]}"#)
        )
        XCTAssertEqual(parsed.state, .noServer)
        XCTAssertEqual(parsed.serverVersion, "0.7.5",
                       "the client version still rides status for the tile")
    }

    func testOldProtocolInSnapshotIsUpdateNeeded() throws {
        let snapshot = try fixtureSnapshot()
            .replacingOccurrences(of: #""protocol":17"#, with: #""protocol":5"#)
        let parsed = HerdrProbe.parseProbe(transcript(
            status: statusUp, list: sessionList,
            snapshots: [("default", snapshot)]
        ))
        XCTAssertEqual(parsed.state, .updateNeeded(installedVersion: "0.7.5"))
    }

    func testOldClientProtocolIsUpdateNeeded() {
        let status = statusDown
            .replacingOccurrences(of: #""protocol":17"#, with: #""protocol":3"#)
            .replacingOccurrences(of: #""version":"0.7.5""#, with: #""version":"0.4.0""#)
        let parsed = HerdrProbe.parseProbe(
            transcript(status: status, list: nil)
        )
        XCTAssertEqual(parsed.state, .updateNeeded(installedVersion: "0.4.0"))
    }

    func testStatusWithoutSessionListFails() {
        let parsed = HerdrProbe.parseProbe(
            transcript(status: statusUp, list: nil)
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

    // MARK: Probe command

    func testProbeCommandShape() {
        let command = HerdrProbe.probeCommand(
            sessionNames: ["default", "work"],
            tailTargets: [
                HerdrProbe.TailTarget(sessionName: "default", paneID: "w1:p1"),
                HerdrProbe.TailTarget(sessionName: "work", paneID: "w1:p1"),
            ]
        )

        XCTAssertTrue(command.hasPrefix(HerdrProbe.pathPrefix))
        XCTAssertTrue(command.contains(
            "command -v herdr >/dev/null 2>&1 || { echo MULTIPLEX_NO_HERDR; exit 0; }"))
        XCTAssertTrue(command.contains("herdr status --json 2>/dev/null || true"))
        XCTAssertTrue(command.contains("herdr session list --json 2>/dev/null || true"))
        XCTAssertTrue(command.contains("echo 'MULTIPLEX_HERDR_SNAP work'"))
        XCTAssertTrue(command.contains(
            "herdr --session 'work' api snapshot 2>/dev/null || true"))
        XCTAssertTrue(command.contains("echo 'MPXS work w1:p1'"))
        XCTAssertTrue(command.contains(
            "herdr --session 'work' pane read 'w1:p1' --source visible 2>/dev/null || true"))
        XCTAssertTrue(command.hasSuffix("echo MPXE"))
    }

    func testProbeCommandAlwaysTriesDefault() {
        // A cold first tick has no baked names yet — the default session
        // still gets its snapshot so the wall paints a spine on tick one.
        let command = HerdrProbe.probeCommand(sessionNames: [], tailTargets: [])
        XCTAssertTrue(command.contains("echo 'MULTIPLEX_HERDR_SNAP default'"))
        XCTAssertTrue(command.contains("echo MULTIPLEX_TAILS; echo MPXE"))
        XCTAssertFalse(command.contains("pane read"))
        // And never twice when it's already baked.
        let baked = HerdrProbe.probeCommand(sessionNames: ["default"], tailTargets: [])
        XCTAssertEqual(
            baked.components(separatedBy: "MULTIPLEX_HERDR_SNAP default").count, 2)
    }

    func testProbeCommandRefusesUnbakeableNames() {
        let command = HerdrProbe.probeCommand(
            sessionNames: ["ok", "-flag", "new\nline"],
            tailTargets: [
                HerdrProbe.TailTarget(sessionName: "ok", paneID: "w1 p1"),
                HerdrProbe.TailTarget(sessionName: "-flag", paneID: "w1:p1"),
            ]
        )
        XCTAssertTrue(command.contains("MULTIPLEX_HERDR_SNAP ok"))
        XCTAssertFalse(command.contains("-flag"))
        XCTAssertFalse(command.contains("new\nline"))
        XCTAssertFalse(command.contains("MPXS"),
                       "a whitespace pane id would break the last-space framing")
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

    func testSessionAgentStateFoldsEveryPane() {
        typealias Status = HerdrProbe.AgentStatus
        // Any blocked pane needs you — background tabs included.
        XCTAssertEqual(
            HerdrProbe.sessionAgentState([Status.working, .idle, .blocked]),
            .needsYou(.permission))
        XCTAssertEqual(
            HerdrProbe.sessionAgentState([Status.idle, .working]), .busy)
        XCTAssertEqual(
            HerdrProbe.sessionAgentState([Status.idle, .done]), .idle)
        XCTAssertEqual(
            HerdrProbe.sessionAgentState([Status.unknown, .idle]), .idle)
        XCTAssertNil(HerdrProbe.sessionAgentState([Status.unknown, .unknown]),
                     "a session of nothing but unknown makes no claim")
        XCTAssertNil(HerdrProbe.sessionAgentState([Status]()))
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

    // MARK: Session actions

    func testAttachCommandTargetsTheSession() {
        let command = HerdrProbe.attachCommand(sessionName: "work")
        XCTAssertTrue(command.hasSuffix("exec herdr session attach 'work'"))
        XCTAssertFalse(command.contains("workspace focus"),
                       "the tile is the whole session — nothing to pre-focus")
        // The blind form (debug auto-attach before any probe) lands on
        // the default session.
        XCTAssertTrue(HerdrProbe.attachCommand(sessionName: "")
            .hasSuffix("exec herdr session attach 'default'"))
    }

    func testCloseSessionCommandStopsThenDeletes() {
        let command = HerdrProbe.closeSessionCommand(sessionName: "work")
        let stop = command.range(of: "herdr session stop 'work' --json >/dev/null 2>&1")
        let delete = command.range(of: "herdr session delete 'work' --json >/dev/null 2>&1")
        XCTAssertNotNil(stop)
        XCTAssertNotNil(delete)
        if let stop, let delete {
            XCTAssertLessThan(stop.lowerBound, delete.lowerBound,
                              "delete requires stopped — order is the contract")
        }
        XCTAssertTrue(command.hasSuffix("true"),
                      "herdr refuses deleting the default session; the exec must not throw")
    }

    func testSpawnSessionCommandCreatesHeadlesslyThenVerifies() {
        let command = HerdrProbe.spawnSessionCommand(sessionName: "api")
        let attach = command.range(
            of: "herdr session attach 'api' >/dev/null 2>&1 </dev/null")
        let verify = command.range(of: "herdr --session 'api' api snapshot")
        XCTAssertNotNil(attach)
        XCTAssertNotNil(verify)
        if let attach, let verify {
            XCTAssertLessThan(attach.lowerBound, verify.lowerBound,
                              "spawn first, then wait for the socket to answer")
        }
        XCTAssertTrue(command.contains("sleep 1"),
                      "the verify loop polls — the server daemonizes asynchronously")
    }

    func testParseFocusedPaneReadsALoneSnapshot() throws {
        let output = "login noise\n" + workSnapshot + "\n"
        XCTAssertEqual(HerdrProbe.parseFocusedPane(output), "w1:p1")
        XCTAssertNil(HerdrProbe.parseFocusedPane("Error: no server\n"))
    }

    func testParseSessionNamesReadsTheListEnvelope() {
        XCTAssertEqual(
            HerdrProbe.parseSessionNames("noise\n" + sessionList + "\n"),
            ["default", "work", "parked"]
        )
        XCTAssertEqual(HerdrProbe.parseSessionNames("garbage"), [])
    }

    func testTypeCommandScopesToTheSessionAndTypesLinesThenEnter() {
        let command = HerdrProbe.typeCommand(
            sessionName: "api", paneID: "w1:p1",
            lines: ["source .env", "claude 'do it'"])
        XCTAssertNotNil(command)
        XCTAssertTrue(command?.contains(
            "herdr --session 'api' pane send-text 'w1:p1' 'source .env' 2>/dev/null || true")
            == true)
        XCTAssertTrue(command?.contains(
            "herdr --session 'api' pane send-text 'w1:p1' "
                + "claude 'do it'".shellQuoted) == true)
        XCTAssertTrue(command?.contains(
            "herdr --session 'api' pane send-keys 'w1:p1' Enter") == true)
        XCTAssertNil(HerdrProbe.typeCommand(
            sessionName: "api", paneID: "w1:p1", lines: []))
        XCTAssertNil(HerdrProbe.typeCommand(
            sessionName: "api", paneID: "w1:p1", lines: [""]))
    }

    // MARK: Session names

    func testSessionNameArgumentReducesToDirectorySafety() {
        XCTAssertEqual(HerdrProbe.sessionNameArgument("api"), "api")
        XCTAssertEqual(HerdrProbe.sessionNameArgument("my work"), "my-work")
        XCTAssertEqual(HerdrProbe.sessionNameArgument("a/b:c"), "a-b-c")
        XCTAssertEqual(HerdrProbe.sessionNameArgument("v1.3-fix_2"), "v1.3-fix_2",
                       "dots, dashes, underscores survive")
        XCTAssertEqual(HerdrProbe.sessionNameArgument("--flag"), "flag")
        XCTAssertEqual(HerdrProbe.sessionNameArgument(".hidden"), "hidden")
        XCTAssertEqual(HerdrProbe.sessionNameArgument("tail-"), "tail")
        XCTAssertEqual(HerdrProbe.sessionNameArgument("héllo wörld"), "h-llo-w-rld")
        XCTAssertEqual(HerdrProbe.sessionNameArgument(""), "session")
        XCTAssertEqual(HerdrProbe.sessionNameArgument("🚀🚀"), "session")
        XCTAssertEqual(
            HerdrProbe.sessionNameArgument(String(repeating: "a", count: 80)).count, 64)
    }

    func testUniqueSessionNameSuffixesWithinHerdrRules() {
        XCTAssertEqual(
            HerdrProbe.uniqueSessionName(base: "api", existing: ["default"]), "api")
        XCTAssertEqual(
            HerdrProbe.uniqueSessionName(base: "api", existing: ["api"]), "api-2")
        XCTAssertEqual(
            HerdrProbe.uniqueSessionName(base: "api", existing: ["api", "api-2"]),
            "api-3")
        XCTAssertEqual(
            HerdrProbe.uniqueSessionName(base: "v1.3 fix", existing: ["v1.3-fix"]),
            "v1.3-fix-2",
            "sanitized first, then uniqued — dots survive where tmux's rules wouldn't")
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

/// The `.herdrAttach` route: the PTY command, the mosh argv, and the
/// identity surfaces the session name answers for.
final class HerdrRouteTests: XCTestCase {
    private let route = TerminalRoute(
        hostID: UUID(),
        mode: .herdrAttach(sessionName: "work")
    )

    func testRemoteCommandAttachesTheHerdrClient() throws {
        let command = try XCTUnwrap(route.remoteCommand)
        XCTAssertTrue(command.hasSuffix("exec herdr session attach 'work'"))
        XCTAssertFalse(command.contains("workspace focus"))
    }

    func testMoshRemoteCommandWrapsTheShellLineInAShell() throws {
        let command = try XCTUnwrap(route.moshRemoteCommand)
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        XCTAssertTrue(command.contains("herdr session attach"))
    }

    func testIdentitySurfacesAnswerTheSessionName() {
        XCTAssertEqual(route.displayName, "work")
        XCTAssertEqual(route.sessionName, "work")
        XCTAssertFalse(route.usesTmux)
        XCTAssertFalse(route.isAuxiliaryPane)
    }

    func testAttachFactoryPicksTheBackend() {
        var host = Host(name: "box", hostname: "10.0.0.1", username: "dev")
        let session = TmuxSession(
            name: "work", windows: [], created: .distantPast, tmuxID: "work")

        XCTAssertEqual(
            TerminalRoute.Mode.attach(host: host, session: session),
            .attach(sessionName: "work")
        )
        host.sessionBackend = .herdr
        XCTAssertEqual(
            TerminalRoute.Mode.attach(host: host, session: session),
            .herdrAttach(sessionName: "work")
        )
    }

    func testTmuxRoutesKeepTmuxChrome() {
        let tmuxRoute = TerminalRoute(
            hostID: UUID(), mode: .attach(sessionName: "main"))
        XCTAssertTrue(tmuxRoute.usesTmux)
        let shellRoute = TerminalRoute(hostID: UUID(), mode: .shell)
        XCTAssertFalse(shellRoute.usesTmux)
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
