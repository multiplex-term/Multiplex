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

    /// Hand-reduced `herdr pane current` envelope. The real 0.7.5 response
    /// carries the same pane fields as a snapshot plus a `pane_current` type.
    private func currentPane(
        paneID: String, tabID: String, agent: String?
    ) -> String {
        let agentField = agent.map { #""agent":"\#($0)","# } ?? ""
        return #"{"id":"cli:pane:current","result":{"pane":{"#
            + agentField
            + #""agent_status":"idle","focused":true,"pane_id":"\#(paneID)","#
            + #""tab_id":"\#(tabID)"},"type":"pane_current"}}"#
    }

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

    func testPaneScreenRectsComeFromTheFocusedLayout() throws {
        let snapshot = try fixtureSnapshot()
        // Fixture: focused tab w1:t1 holds one pane, rect x26 y1 54×23 with
        // viewport_rows 23 == rect height → no border inset.
        XCTAssertEqual(
            HerdrProbe.parsePaneScreenRects(snapshot),
            [PaneScreenRectEntry(
                id: "w1:p1",
                rect: PaneScreenRect(columns: 26...79, rows: 1...23),
                isFocused: true
            )]
        )
        XCTAssertEqual(HerdrProbe.parsePaneScreenRects("not an envelope"), [])
        XCTAssertEqual(HerdrProbe.parsePaneScreenRects(""), [])
    }

    func testPaneScreenRectsInsetDrawnBordersPerPane() {
        // viewport_rows 21 inside a 23-row rect → one border row each side,
        // trimmed symmetrically on both axes; the unfocused sibling keeps
        // its own geometry and flag.
        let snapshot = #"{"id":"cli:api:snapshot","result":{"snapshot":{"#
            + #""version":"0.7.5","protocol":17,"focused_workspace_id":"w1","#
            + #""focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","#
            + #""workspaces":[{"workspace_id":"w1","number":1,"label":"one","#
            + #""active_tab_id":"w1:t1"}],"#
            + #""panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","#
            + #""agent_status":"unknown","scroll":{"viewport_rows":21}},"#
            + #"{"pane_id":"w1:p2","tab_id":"w1:t1","#
            + #""agent_status":"unknown","scroll":{"viewport_rows":21}}],"#
            + #""layouts":[{"tab_id":"w1:t1","focused_pane_id":"w1:p1","#
            + #""panes":[{"pane_id":"w1:p1","focused":true,"#
            + #""rect":{"x":10,"y":2,"width":40,"height":23}},"#
            + #"{"pane_id":"w1:p2","focused":false,"#
            + #""rect":{"x":50,"y":2,"width":40,"height":23}}]}]}}}"#
        XCTAssertEqual(HerdrProbe.parsePaneScreenRects(snapshot), [
            PaneScreenRectEntry(
                id: "w1:p1",
                rect: PaneScreenRect(columns: 11...48, rows: 3...23),
                isFocused: true
            ),
            PaneScreenRectEntry(
                id: "w1:p2",
                rect: PaneScreenRect(columns: 51...88, rows: 3...23),
                isFocused: false
            ),
        ])
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

    func testTailParserSplitsAtTheLastSpaceDefensively() throws {
        // 0.7.5 restricts names to ASCII token characters, but keep the tail
        // parser forward-tolerant: the pane id is the last whitespace-free
        // field, so a future list grammar growing spaces stays unambiguous.
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

    func testLoginNoiseDoesNotHideTheClientProtocol() {
        let old = statusDown
            .replacingOccurrences(of: #""protocol":17"#, with: #""protocol":3"#)
            .replacingOccurrences(of: #""version":"0.7.5""#, with: #""version":"0.4.0""#)
        let parsed = HerdrProbe.parseProbe(transcript(
            status: "welcome from zsh\n" + old,
            list: nil
        ))
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
        XCTAssertTrue(command.contains("printf '%s\\n' 'MULTIPLEX_HERDR_SNAP work'"))
        XCTAssertTrue(command.contains(
            "herdr --session 'work' api snapshot 2>/dev/null || true"))
        XCTAssertTrue(command.contains("printf '%s\\n' 'MPXS work w1:p1'"))
        XCTAssertTrue(command.contains(
            "herdr --session 'work' pane read 'w1:p1' --source visible 2>/dev/null || true"))
        XCTAssertTrue(command.hasSuffix("echo MPXE"))
    }

    func testProbeCommandTriesDefaultOnlyOnAColdTick() {
        // A cold first tick has no baked names yet — the primary session
        // gets a snapshot so the wall paints a spine on tick one.
        let command = HerdrProbe.probeCommand(sessionNames: nil, tailTargets: [])
        XCTAssertTrue(command.contains("MULTIPLEX_HERDR_SNAP default"))
        XCTAssertTrue(command.contains("echo MULTIPLEX_TAILS; echo MPXE"))
        XCTAssertFalse(command.contains("pane read"))
        // Once a list has been parsed, [] is real knowledge — every session
        // may be stopped. It must not be mistaken for the cold sentinel or a
        // failed default snapshot is paid every tick forever.
        let stopped = HerdrProbe.probeCommand(sessionNames: [], tailTargets: [])
        XCTAssertFalse(stopped.contains("MULTIPLEX_HERDR_SNAP default"))
        let baked = HerdrProbe.probeCommand(sessionNames: ["work"], tailTargets: [])
        XCTAssertFalse(baked.contains("MULTIPLEX_HERDR_SNAP default"))
        // And never twice when it IS baked.
        let rebaked = HerdrProbe.probeCommand(sessionNames: ["default"], tailTargets: [])
        XCTAssertEqual(
            rebaked.components(separatedBy: "MULTIPLEX_HERDR_SNAP default").count, 2)
    }

    func testProbeCommandEnforcesTheHerdrNameAndFrameGrammar() {
        let tooLong = String(repeating: "a", count: 65)
        let command = HerdrProbe.probeCommand(
            sessionNames: ["ok", "-flag", ".", "my work", tooLong],
            tailTargets: [
                HerdrProbe.TailTarget(sessionName: "ok", paneID: "w1 p1"),
                HerdrProbe.TailTarget(sessionName: "-flag", paneID: "w1:p1"),
            ]
        )
        XCTAssertTrue(command.contains("MULTIPLEX_HERDR_SNAP ok"))
        XCTAssertTrue(command.contains("MULTIPLEX_HERDR_SNAP -flag"),
                      "0.7.5 accepts leading-dash names as option values")
        XCTAssertFalse(HerdrProbe.bakeableSessionName("."))
        XCTAssertFalse(command.contains("my work"))
        XCTAssertFalse(command.contains(tooLong))
        XCTAssertTrue(command.contains("MPXS -flag w1:p1"))
        XCTAssertFalse(command.contains("MPXS ok w1 p1"),
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

    func testFrontPaneAlertAttributionNeedsItsOwnVerdictOrTransition() {
        XCTAssertTrue(HerdrProbe.paneProducedSessionState(
            .busy, current: .working, previous: .idle))
        XCTAssertTrue(HerdrProbe.paneProducedSessionState(
            .needsYou(.permission), current: .blocked, previous: .working))
        XCTAssertTrue(HerdrProbe.paneProducedSessionState(
            .idle, current: .done, previous: .working))
        XCTAssertTrue(HerdrProbe.paneProducedSessionState(
            .idle, current: .idle, previous: .working),
            "a focused agent settles as idle rather than retaining done")
        XCTAssertFalse(HerdrProbe.paneProducedSessionState(
            .idle, current: .idle, previous: .idle),
            "do not borrow an idle front agent when a background pane finished")
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
        let command = HerdrSessionLaunch.attachCommand(sessionName: "work")
        XCTAssertTrue(command.hasSuffix("exec herdr session attach 'work'"))
        XCTAssertFalse(command.contains("workspace focus"),
                       "the tile is the whole session — nothing to pre-focus")
        // The blind form (debug auto-attach before any probe) lands on
        // the default session.
        XCTAssertTrue(HerdrSessionLaunch.attachCommand(sessionName: "")
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

    func testCloseSessionFallsBackToTheRouteNameBeforeAProbe() {
        let restored = TmuxSession(
            name: "restored", windows: [], created: .distantPast)
        let command = HerdrProbe.closeSessionCommand(for: restored)
        XCTAssertTrue(command.contains("herdr session stop 'restored'"))
        XCTAssertTrue(command.contains("herdr session delete 'restored'"))
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
        XCTAssertFalse(command.contains("cd \"$d\""),
                       "no directory rider, no cd — the login $HOME is the server default")
    }

    func testSpawnSessionCommandRootsTheWorldInTheAskedDirectory() {
        let command = HerdrProbe.spawnSessionCommand(
            sessionName: "api", directory: "/w/repo")
        let cd = command.range(
            of: "d='/w/repo'; [ -d \"$d\" ] || d=\"$HOME\"; cd \"$d\" 2>/dev/null;")
        let attach = command.range(of: "herdr session attach 'api'")
        XCTAssertNotNil(cd)
        XCTAssertNotNil(attach)
        if let cd, let attach {
            XCTAssertLessThan(cd.lowerBound, attach.lowerBound,
                              "the session server inherits the spawn's cwd — cd first")
        }
        XCTAssertTrue(
            HerdrProbe.spawnSessionCommand(sessionName: "api", directory: "~")
                .contains("d=\"$HOME\"; "),
            "the New Session sheet's explicit Home choice arrives as ~")
    }

    func testParseFocusedPaneReadsALoneSnapshot() throws {
        let output = "login noise\n" + workSnapshot + "\n"
        XCTAssertEqual(HerdrProbe.parseFocusedPane(output), "w1:p1")
        XCTAssertNil(HerdrProbe.parseFocusedPane("Error: no server\n"))
    }

    func testFastAgentDetectionFollowsTheSessionFocusedTab() throws {
        let command = HerdrProbe.activePaneCommand(sessionName: "mpx-demo")
        XCTAssertTrue(command.contains(
            "herdr --session 'mpx-demo' pane current 2>/dev/null || true"))
        XCTAssertFalse(command.contains("api snapshot"),
                       "the one-second path must not fetch the whole session")

        let claude = try XCTUnwrap(HerdrProbe.parseActiveAgent(
            "login noise\n" + currentPane(
                paneID: "w1:p1", tabID: "w1:t1", agent: "claude")))
        XCTAssertEqual(claude.fingerprint.tmuxID, "w1:p1")
        XCTAssertEqual(claude.fingerprint.command, "claude")
        XCTAssertEqual(claude.agent, .claudeCode)
        XCTAssertTrue(claude.isDefinitive)

        let pi = try XCTUnwrap(HerdrProbe.parseActiveAgent(currentPane(
            paneID: "w1:p2", tabID: "w1:t2", agent: "pi")))
        XCTAssertEqual(pi.fingerprint.tmuxID, "w1:p2")
        XCTAssertEqual(pi.fingerprint.command, "pi")
        XCTAssertEqual(pi.agent, .pi)
        XCTAssertTrue(pi.isDefinitive)
    }

    func testFastAgentDetectionDefinitivelyClearsUnsupportedOrMissingAgents() throws {
        let unsupported = try XCTUnwrap(HerdrProbe.parseActiveAgent(currentPane(
            paneID: "w2:p1", tabID: "w2:t1", agent: "opencode")))
        XCTAssertEqual(unsupported.fingerprint.command, "opencode")
        XCTAssertNil(unsupported.agent)
        XCTAssertTrue(unsupported.isDefinitive,
                      "herdr named the pane's agent; no process fallback is pending")

        let shell = try XCTUnwrap(HerdrProbe.parseActiveAgent(currentPane(
            paneID: "w3:p1", tabID: "w3:t1", agent: nil)))
        XCTAssertEqual(shell.fingerprint.command, "")
        XCTAssertNil(shell.agent)
        XCTAssertTrue(shell.isDefinitive)

        XCTAssertNil(HerdrProbe.parseActiveAgent("Error: no server\n"))
        XCTAssertNil(HerdrProbe.parseActiveAgent(workSnapshot),
                     "a full snapshot is not the focused fast-path envelope")
    }

    // MARK: File drops

    /// A one-pane snapshot with the given pane fields spliced in — the
    /// hand-reduced shape `workSnapshot` uses, varied per cwd case.
    private func dropSnapshot(
        _ paneFields: String, focusedPane: String? = "w1:p1"
    ) -> String {
        let focus = focusedPane.map { #""focused_pane_id":"\#($0)","# } ?? ""
        return #"{"id":"cli:api:snapshot","result":{"snapshot":{"#
            + #""version":"0.7.5","protocol":17,"agents":[],"#
            + focus
            + #""focused_workspace_id":"w1","focused_tab_id":"w1:t1","#
            + #""workspaces":[{"workspace_id":"w1","number":1,"label":"api","#
            + #""active_tab_id":"w1:t1"}],"#
            + #""tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1"}],"#
            + #""panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","#
            + paneFields
            + #","agent_status":"idle"}],"#
            + #""layouts":[{"tab_id":"w1:t1","focused_pane_id":"w1:p1"}]}}}"#
    }

    func testParseFocusedPaneWorkingDirectoryPrefersTheForegroundProcess() throws {
        // The fixture's focused pane (w1:p1) reports both cwd fields.
        XCTAssertEqual(
            HerdrProbe.parseFocusedPaneWorkingDirectory(try fixtureSnapshot()),
            "/Users/jhen"
        )
        // foreground_cwd is `pane_current_path`'s analog — while an agent
        // runs, the agent's own directory beats the pane's shell cwd.
        XCTAssertEqual(
            HerdrProbe.parseFocusedPaneWorkingDirectory(dropSnapshot(
                #""cwd":"/home/dev","foreground_cwd":"/home/dev/repo""#)),
            "/home/dev/repo"
        )
        // A snapshot without the cwd fields (workSnapshot's pre-cwd shape)
        // answers nothing — the $HOME fallback, never a guess.
        XCTAssertNil(HerdrProbe.parseFocusedPaneWorkingDirectory(workSnapshot))
        XCTAssertNil(HerdrProbe.parseFocusedPaneWorkingDirectory("Error: no server\n"))
    }

    func testParseFocusedPaneWorkingDirectoryNeverGuessesWithoutFocus() {
        // Typed paths land in the focused pane; a session that names no
        // focus (or names a pane the snapshot doesn't carry) gets $HOME —
        // `frontPaneID`'s miniature fallback deliberately does not apply.
        XCTAssertNil(HerdrProbe.parseFocusedPaneWorkingDirectory(
            dropSnapshot(#""cwd":"/home/dev""#, focusedPane: nil)))
        XCTAssertNil(HerdrProbe.parseFocusedPaneWorkingDirectory(
            dropSnapshot(#""cwd":"/home/dev""#, focusedPane: "w9:p9")))
    }

    func testParseFocusedPaneWorkingDirectoryOnlyAnswersSpliceablePaths() {
        // The value is respliced into the git-corral exec and aimed at by
        // SFTP: a relative or control-carrying candidate falls through to
        // the next field, then to nil.
        XCTAssertEqual(
            HerdrProbe.parseFocusedPaneWorkingDirectory(dropSnapshot(
                #""cwd":"/home/dev","foreground_cwd":"repo""#)),
            "/home/dev"
        )
        XCTAssertNil(HerdrProbe.parseFocusedPaneWorkingDirectory(
            dropSnapshot(#""cwd":"~/repo""#)))
        XCTAssertNil(HerdrProbe.parseFocusedPaneWorkingDirectory(
            dropSnapshot(#""cwd":"/home/dev\nfake""#)))
    }

    func testParseSessionNamesReadsTheListEnvelope() {
        XCTAssertEqual(
            HerdrProbe.parseSessionNames("noise\n" + sessionList + "\n"),
            ["default", "work", "parked"]
        )
        XCTAssertNil(HerdrProbe.parseSessionNames("garbage"),
                     "unreadable is not the same as a valid empty list")
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

    // MARK: In-session placement (external agent launches)

    func testCreateTabAndWorkspaceCommandsShareOneFocusedShape() {
        XCTAssertEqual(
            HerdrProbe.createTabCommand(
                sessionName: "api", label: "claude", directory: nil),
            HerdrProbe.pathPrefix
                + "herdr --session 'api' tab create --label 'claude'"
                + " --focus 2>/dev/null || true"
        )
        // `--focus` is explicit — 0.7.5 creates unfocused by default, and
        // the attach that follows must front the fresh pane. `--cwd` rides
        // the shell's own $HOME expansion; herdr fails a missing directory
        // soft to $HOME itself, so there is no [ -d ] guard to test.
        XCTAssertEqual(
            HerdrProbe.createWorkspaceCommand(
                sessionName: "api", label: "codex", directory: "~/work dir"),
            HerdrProbe.pathPrefix
                + "herdr --session 'api' workspace create --label 'codex'"
                + " --cwd \"$HOME\"/'work dir' --focus 2>/dev/null || true"
        )
        // The terminal window's own + TAB press passes neither rider: a
        // press means "another one here", so herdr numbers the tab and
        // starts it in the focused pane's directory (the tmux mint's
        // inDirectoryOf, without an exec to ask for it).
        XCTAssertEqual(
            HerdrProbe.createTabCommand(
                sessionName: "api", label: nil, directory: nil),
            HerdrProbe.pathPrefix
                + "herdr --session 'api' tab create --focus 2>/dev/null || true"
        )
    }

    func testParseCreatedPaneReadsBothCreateEnvelopes() {
        // Captured verbatim from herdr 0.7.5 (2026-08-02), trimmed only of
        // sibling pane fields the decoder ignores.
        let tab = """
        {"id":"cli:tab:create","result":{"root_pane":{"agent_status":"unknown",\
        "cwd":"/private/tmp","focused":true,"pane_id":"w1:p3","revision":0,\
        "tab_id":"w1:t3","workspace_id":"w1"},"tab":{"focused":true,\
        "label":"probe-b","number":3,"tab_id":"w1:t3","workspace_id":"w1"},\
        "type":"tab_created"}}
        """
        let workspace = """
        {"id":"cli:workspace:create","result":{"root_pane":{"agent_status":"unknown",\
        "cwd":"/private/tmp","focused":true,"pane_id":"w2:p1","revision":0,\
        "tab_id":"w2:t1","workspace_id":"w2"},"tab":{"focused":true,"label":"1",\
        "number":1,"tab_id":"w2:t1","workspace_id":"w2"},"type":"workspace_created",\
        "workspace":{"active_tab_id":"w2:t1","focused":true,"label":"probe-ws",\
        "number":2,"workspace_id":"w2"}}}
        """
        XCTAssertEqual(
            HerdrProbe.parseCreatedPane("login noise\n" + tab + "\n"), "w1:p3")
        XCTAssertEqual(HerdrProbe.parseCreatedPane(workspace), "w2:p1")
        // A stopped session's create answers a Rust error line, not an
        // envelope — the launch must fail visibly, never type blind.
        XCTAssertNil(HerdrProbe.parseCreatedPane(
            "Error: Os { code: 2, kind: NotFound, message: \"No such file or directory\" }\n"))
        XCTAssertNil(HerdrProbe.parseCreatedPane(""))
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
        let exposedTrailingDot = String(repeating: "a", count: 63) + ".z"
        XCTAssertFalse(HerdrProbe.sessionNameArgument(exposedTrailingDot).hasSuffix("."),
                       "truncation must re-apply the trailing dot/dash rule")
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
        let long = String(repeating: "a", count: 64)
        let suffixed = HerdrProbe.uniqueSessionName(base: long, existing: [long])
        XCTAssertEqual(suffixed.count, 64)
        XCTAssertTrue(suffixed.hasSuffix("-2"),
                      "the uniqueness suffix must stay inside herdr's 64-byte limit")
    }

    // MARK: Shortcut panel (HRDR)

    /// Captured `herdr workspace list` envelope shape (0.7.5, 2026-08-02);
    /// extra fields prove tolerant decoding.
    private let workspaceList = #"{"id":"cli:workspace:list","result":{"#
        + #""type":"workspace_list","workspaces":["#
        + #"{"active_tab_id":"w2:t1","agent_status":"unknown","focused":false,"#
        + #""label":"demo","number":2,"pane_count":1,"tab_count":1,"#
        + #""workspace_id":"w2"},"#
        + #"{"active_tab_id":"w1:t1","agent_status":"working","focused":true,"#
        + #""label":"api","number":1,"pane_count":2,"tab_count":2,"#
        + #""workspace_id":"w1"}"#
        + #"]}}"#

    func testWorkspaceListCommandScopesToTheSession() {
        XCTAssertEqual(
            HerdrProbe.workspaceListCommand(sessionName: "work"),
            HerdrProbe.pathPrefix
                + "herdr --session 'work' workspace list 2>/dev/null || true"
        )
    }

    func testParseWorkspaceChoicesOrdersByNumberAndMarksTheFocusedRow() {
        let choices = HerdrProbe.parseWorkspaceChoices("noise\n" + workspaceList + "\n")
        XCTAssertEqual(choices, [
            TmuxWindowChoice(tmuxID: "w1", index: 1, isActive: true, name: "api"),
            TmuxWindowChoice(tmuxID: "w2", index: 2, isActive: false, name: "demo"),
        ])
        XCTAssertNil(HerdrProbe.parseWorkspaceChoices("Error: no server\n"),
                     "unreadable is not the same as a valid empty list")
    }

    func testFocusWorkspaceCommandVetsTheResponseDerivedID() {
        XCTAssertEqual(
            HerdrProbe.focusWorkspaceCommand(sessionName: "work", workspaceID: "w2"),
            HerdrProbe.pathPrefix
                + "herdr --session 'work' workspace focus 'w2' 2>/dev/null || true"
        )
        XCTAssertNil(HerdrProbe.focusWorkspaceCommand(
            sessionName: "work", workspaceID: "w2 evil"),
            "an id with whitespace must never be spliced into a shell line")
        XCTAssertNil(HerdrProbe.focusWorkspaceCommand(sessionName: "work", workspaceID: ""))
    }

    func testParseFocusedCloseTargetReadsExactlyWhatTheServerNamesFocused() {
        let output = "login noise\n" + workSnapshot + "\n"
        XCTAssertEqual(
            HerdrProbe.parseFocusedCloseTarget(output, scope: .pane), "w1:p1")
        XCTAssertEqual(
            HerdrProbe.parseFocusedCloseTarget(output, scope: .tab), "w1:t1")
        XCTAssertEqual(
            HerdrProbe.parseFocusedCloseTarget(output, scope: .workspace), "w1")
        XCTAssertNil(HerdrProbe.parseFocusedCloseTarget("garbage", scope: .pane),
                     "a close must never guess its target")
    }

    func testParseFocusedCloseTargetFallsBackToTheFocusedWorkspacesActiveTab() {
        // Same snapshot minus focused_tab_id: the focused workspace's
        // active tab IS the focused tab, stated the other way.
        let trimmed = workSnapshot.replacingOccurrences(
            of: #""focused_tab_id":"w1:t1","#, with: "")
        XCTAssertEqual(
            HerdrProbe.parseFocusedCloseTarget(trimmed, scope: .tab), "w1:t1")
    }

    func testCloseShortcutCommandSpeaksEachScopeAndVetsTheID() {
        XCTAssertEqual(
            HerdrProbe.closeShortcutCommand(
                sessionName: "work", scope: .pane, targetID: "w1:p2"),
            HerdrProbe.pathPrefix
                + "herdr --session 'work' pane close 'w1:p2' 2>/dev/null || true"
        )
        XCTAssertEqual(
            HerdrProbe.closeShortcutCommand(
                sessionName: "work", scope: .tab, targetID: "w1:t2"),
            HerdrProbe.pathPrefix
                + "herdr --session 'work' tab close 'w1:t2' 2>/dev/null || true"
        )
        XCTAssertEqual(
            HerdrProbe.closeShortcutCommand(
                sessionName: "work", scope: .workspace, targetID: "w2"),
            HerdrProbe.pathPrefix
                + "herdr --session 'work' workspace close 'w2' 2>/dev/null || true"
        )
        XCTAssertNil(HerdrProbe.closeShortcutCommand(
            sessionName: "work", scope: .pane, targetID: "bad id"))
    }
}

/// The tmux probe's herdr-presence line — the dead-tile switch hint's
/// input. Presence rides every tick; only dead tiles read it.
final class TmuxProbeHerdrPresenceTests: XCTestCase {
    func testProbeCommandChecksHerdrBeforeTheTmuxGuard() {
        let command = TmuxProbe.probeCommand
        let herdrCheck = command.range(of: "command -v herdr")
        let tmuxGuard = command.range(of: "command -v tmux")
        XCTAssertNotNil(herdrCheck)
        XCTAssertNotNil(tmuxGuard)
        if let herdrCheck, let tmuxGuard {
            XCTAssertLessThan(herdrCheck.lowerBound, tmuxGuard.lowerBound,
                              "the tmux guard exits; herdr must be checked first")
        }
        XCTAssertTrue(command.contains("$HOME/.cargo/bin/herdr"),
                      "the hint must see the same Cargo install the herdr probe can run")
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
        XCTAssertEqual(route.sessionBackend, .herdr)
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
        // The name-based overload serves callers holding only a name
        // (auto-attach entries, widget targets) — no fabricated session.
        XCTAssertEqual(
            TerminalRoute.Mode.attach(host: host, sessionName: "work"),
            .herdrAttach(sessionName: "work")
        )
    }

    func testTmuxRoutesKeepTmuxChrome() {
        let tmuxRoute = TerminalRoute(
            hostID: UUID(), mode: .attach(sessionName: "main"))
        XCTAssertTrue(tmuxRoute.usesTmux)
        XCTAssertEqual(tmuxRoute.sessionBackend, .tmux)
        let shellRoute = TerminalRoute(hostID: UUID(), mode: .shell)
        XCTAssertFalse(shellRoute.usesTmux)
    }

    func testPlusTabLeadsWithASessionAndOnlyHerdrOffersTheWorkspaceTabRow() {
        XCTAssertEqual(route.extraNewTabTarget, .herdrWorkspaceTab)
        XCTAssertNil(
            TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
                .extraNewTabTarget,
            "tmux windows belong to the prefix key and the shortcut panel"
        )
        XCTAssertNil(TerminalRoute(hostID: UUID(), mode: .shell).extraNewTabTarget)
        XCTAssertNil(
            TerminalRoute(hostID: UUID(), mode: .fileViewer(path: "~"))
                .extraNewTabTarget,
            "an auxiliary pane names no session — the press keeps minting one"
        )
        XCTAssertEqual(
            TerminalRoute.NewTabTarget.herdrWorkspaceTab.menuTitle,
            "New Tab in Workspace"
        )
        XCTAssertEqual(TerminalRoute.NewTabTarget.session.menuTitle, "New Session")
        XCTAssertEqual(
            TerminalRoute.NewTabTarget.herdrWorkspaceTab.failureTitle,
            "Couldn't Create Tab"
        )
        XCTAssertEqual(
            TerminalRoute.NewTabTarget.controlAccessibilityLabel(
                offering: .herdrWorkspaceTab),
            "New tab: another session, a tab in this herdr workspace, or the file viewer"
        )
        XCTAssertEqual(
            TerminalRoute.NewTabTarget.controlAccessibilityLabel(offering: nil),
            "New tab: another session or the file viewer"
        )
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
