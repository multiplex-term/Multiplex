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
