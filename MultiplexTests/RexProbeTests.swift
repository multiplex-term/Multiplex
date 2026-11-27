import UIKit
import XCTest
@testable import Multiplex

/// Anchors `Bundle(for:)` fixture loading, the BindProtocolTests pattern.
private final class RexFixtureAnchor {}

/// Rex on the deck: the probe, the record rules, and the tile. (Attaching a
/// Rex terminal is `RexWireTests`.) The probe fixture is the verbatim output of
/// the shipped probe command against a throwaway Rex 0.1.0-preview.19 server
/// (API revision 14, captured 2026-11-16; a second capture off preview.25
/// has its own test) holding three sessions:
/// - `work` — window `editor` (a titled block beside an untitled split) and
///   an unnamed window whose block reports `blocked` / `permission` for
///   `claude-code`; the session fronts `editor`.
/// - an unnamed session Rex labelled `floral-river`, fronting a block with
///   400 multibyte lines of scrollback (so its tail is a clipped read).
/// - a SECOND `work`, whose block reports `working` for `cargo`.
@MainActor
final class RexProbeTests: XCTestCase {
    private func fixture(_ name: String = "rex-probe-preview19") throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: RexFixtureAnchor.self).url(forResource: name, withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sessions(_ probe: RexProbe.ParsedProbe) throws -> [TmuxSession] {
        guard case .sessions(let sessions) = probe.state else {
            XCTFail("expected sessions, got \(probe.state)")
            return []
        }
        return sessions
    }

    private func response(json: String, exit: Int = 0) -> String {
        "MULTIPLEX_REX_PROBE\n\(json)\nMULTIPLEX_REX_EXIT \(exit)\n"
    }

    // MARK: The command

    func testTheProbeNeverStartsAServerAndReportsItsExitStatus() {
        let command = RexProbe.probeCommand()
        // The CLI autostarts a server by default; a probe that did would
        // leave one running on every host that merely has the binary.
        XCTAssertTrue(command.contains("REX_AUTOSTART=0 rex do -e '"))
        XCTAssertTrue(command.contains(
            "command -v rex >/dev/null 2>&1 || { echo MULTIPLEX_NO_REX; exit 0; }"))
        XCTAssertTrue(command.hasSuffix("echo \"MULTIPLEX_REX_EXIT $?\""))
        // One connection that attaches without JOINING any session.
        XCTAssertTrue(command.contains("session.attach_all"))
        XCTAssertFalse(command.contains("\"session.attach\""))
        // The script is one single-quoted argument: a quote inside it would
        // end the argument early.
        let script = command.components(separatedBy: "do -e '")[1]
            .components(separatedBy: "' --json")[0]
        XCTAssertFalse(script.contains("'"))
    }

    func testTheProbeLooksForRexWhereAMacKeepsIt() {
        let command = RexProbe.probeCommand()
        XCTAssertTrue(command.contains(
            "$HOME/Library/Application Support/com.superlogical.rex/RexServer"
                + "/Versions/Current/Rex Server.app/Contents/MacOS"))
        XCTAssertTrue(command.contains(
            "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS"))
    }

    func testRidersLeadTheProbeAndASecondaryCarriesNone() {
        XCTAssertTrue(RexProbe.probeCommand().hasPrefix("PATH="))
        let riding = RexProbe.probeCommand(discovering: [.tmux, .rex])
        XCTAssertTrue(riding.hasPrefix("echo MULTIPLEX_DISCOVER tmux; "))
        // A probe never discovers itself.
        XCTAssertFalse(riding.contains("MULTIPLEX_DISCOVER rex"))
    }

    // MARK: The fixture

    func testSessionsMapOntoTilesWithUniqueNames() throws {
        let probe = RexProbe.parseProbe(try fixture())
        let sessions = try sessions(probe)
        // Two sessions share the label `work`; BOTH are spelled with the
        // tail of their id, and the unique one keeps its label.
        XCTAssertEqual(
            sessions.map(\.name),
            ["work …8d7863", "floral-river", "work …04272d"])
        XCTAssertEqual(Set(sessions.map(\.id)).count, 3)
        XCTAssertTrue(sessions.allSatisfy { $0.backend == .rex })
        // The id is the only unambiguous target.
        XCTAssertEqual(
            sessions[0].tmuxID, "session:01a1e1e3-47e5-7497-bde1-74a5768d7863")
        // Rex states no creation time; the list position stands in.
        XCTAssertTrue(sessions.allSatisfy { HerdrProbe.isSyntheticCreated($0.created) })
        XCTAssertLessThan(sessions[0].created, sessions[2].created)
    }

    func testWindowsAndBlocksBecomeTheSpine() throws {
        let work = try XCTUnwrap(
            try sessions(RexProbe.parseProbe(try fixture())).first)
        XCTAssertEqual(work.windows.map(\.index), [1, 2])
        // A label someone chose is kept; Rex's generated `Window <id>` gives
        // way to the focused block's label.
        XCTAssertEqual(work.windows.map(\.name), ["editor", "agent"])
        XCTAssertEqual(work.windows.map(\.isActive), [true, false])

        let editor = work.windows[0]
        XCTAssertEqual(editor.paneCount, 2)
        // The REX key's list is terminals, not windows: one split window
        // alone is already somewhere else to go, where a tmux session with
        // the same shape has only itself.
        var split = work
        split.windows = [editor]
        XCTAssertTrue(split.hasSwitchChoices)
        split.backend = .tmux
        XCTAssertFalse(split.hasSwitchChoices)
        XCTAssertEqual(editor.panes?.map(\.isActive), [true, false])
        XCTAssertEqual(editor.paneTitle, "vim README.md")
        XCTAssertEqual(editor.panes?.first?.command, "sleep")
        XCTAssertEqual(
            editor.panes?.first?.tmuxID,
            "block:01a1e1e3-47e6-7042-8802-7dd67693eaba")

        // The agent is in a window the session is not fronting — still seen.
        XCTAssertEqual(work.windows[1].activeAgent, .claudeCode)
        XCTAssertEqual(work.detectedAgents, [.claudeCode])
        XCTAssertNil(work.activeAgent)
    }

    /// The same probe command against Rex 0.1.0-preview.25 (API revision
    /// 24, captured 2026-11-27): `work` — window `editor` split in two, and
    /// an unnamed window whose block reports `blocked` / `permission` for
    /// `claude-code` — and an unnamed session with 400 multibyte lines.
    func testTheNewestServersProbeReadsTheSameWay() throws {
        let probe = RexProbe.parseProbe(try fixture("rex-probe-preview25"))
        let sessions = try sessions(probe)
        XCTAssertEqual(sessions.map(\.name), ["work", "drifting-bluff"])
        XCTAssertEqual(
            sessions[0].tmuxID, "session:01a21b89-5982-70bb-aa31-e0ead58431fe")

        let work = sessions[0]
        // The second window's generated `Window 3a065c6a` gives way to its
        // focused block's label.
        XCTAssertEqual(work.windows.map(\.name), ["editor", "shell"])
        XCTAssertEqual(work.windows.map(\.isActive), [true, false])
        XCTAssertEqual(work.windows.map(\.paneCount), [2, 1])
        XCTAssertEqual(work.windows[0].paneTitle, "vim README.md")
        XCTAssertEqual(work.windows[0].panes?.map(\.command), ["sleep", "sleep"])
        XCTAssertEqual(work.windows[1].activeAgent, .claudeCode)

        XCTAssertEqual(
            probe.signals["work"]?.reported,
            [RexProbe.ProgramStatus(state: .blocked, kind: .permission)])
        XCTAssertEqual(probe.tails["work"], ["editing README"])
        let tail = try XCTUnwrap(probe.tails["drifting-bluff"])
        XCTAssertTrue(tail.allSatisfy { $0.hasPrefix("行 ") })
        XCTAssertEqual(tail.last, "行 400 日本語の出力")
        XCTAssertEqual(tail.count, 30)
    }

    func testAnUnnamedWindowWithAnUnnamedBlockFallsBackToItsPosition() throws {
        let probe = RexProbe.parseProbe(response(json: """
            {"ok":true,"sessions":[
              {"id":"session:0000-dddddd","label":"bare","windows":[
                {"id":"window:0000-11112222","label":"Window 11112222",
                 "blocks":[{"id":"block:1","label":""}]},
                {"id":"window:0000-33334444","label":"Window kept by hand",
                 "blocks":[{"id":"block:2","label":"shell"}]}
              ]}
            ]}
            """))
        let session = try XCTUnwrap(try sessions(probe).first)
        // Only the exact generated shape is replaced.
        XCTAssertEqual(session.windows.map(\.name), ["window 1", "Window kept by hand"])
    }

    func testTheFrontedBlocksScreenFeedsTheMiniature() throws {
        let probe = RexProbe.parseProbe(try fixture())
        XCTAssertEqual(probe.tails["work …8d7863"], ["editing README"])
        XCTAssertEqual(probe.tails["work …04272d"], ["Compiling..."])
        XCTAssertEqual(probe.miniatures["work …8d7863"], ["editing README"])
    }

    func testAClippedTailDropsItsPartialFirstLine() throws {
        let probe = RexProbe.parseProbe(try fixture())
        let tail = try XCTUnwrap(probe.tails["floral-river"])
        // The read started mid-screen, so the fixture's first line is the
        // back half of one (`258 測試…`, its leading `行 ` cut off).
        XCTAssertTrue(tail.allSatisfy { $0.hasPrefix("行 ") })
        XCTAssertEqual(tail.last, "行 400 測試多位元組輸出內容 ✳")
        XCTAssertEqual(tail.count, 30)
        XCTAssertEqual(
            probe.miniatures["floral-river"]?.count, TmuxProbe.miniatureLines)
    }

    func testReportedStatusesFoldAcrossEveryBlockOfASession() throws {
        let probe = RexProbe.parseProbe(try fixture())
        let blocked = try XCTUnwrap(probe.signals["work …8d7863"])
        XCTAssertEqual(
            blocked.reported,
            [RexProbe.ProgramStatus(state: .blocked, kind: .permission)])
        XCTAssertEqual(
            RexProbe.sessionAgentState(blocked.reported), .needsYou(.permission))
        // The blocked program is NOT in the fronted block, so an alert may
        // not borrow that block's agent or screen.
        XCTAssertTrue(blocked.front.isEmpty)
        XCTAssertFalse(RexProbe.frontProducedSessionState(
            .needsYou(.permission), front: blocked.front))

        let working = try XCTUnwrap(probe.signals["work …04272d"])
        XCTAssertEqual(RexProbe.sessionAgentState(working.reported), .busy)
        XCTAssertTrue(RexProbe.frontProducedSessionState(.busy, front: working.front))

        // Nothing reported means no claim — the tile falls back to its title.
        let silent = try XCTUnwrap(probe.signals["floral-river"])
        XCTAssertNil(RexProbe.sessionAgentState(silent.reported))
    }

    // MARK: Attention fold

    func testTheStatusFoldRanksBlockedOverWorkingOverSettled() {
        func status(
            _ state: RexProbe.ProgramState, _ kind: AttentionKind? = nil
        ) -> RexProbe.ProgramStatus {
            RexProbe.ProgramStatus(state: state, kind: kind)
        }
        XCTAssertEqual(
            RexProbe.sessionAgentState([status(.working), status(.blocked, .question)]),
            .needsYou(.question))
        // A blocked program that names no kind is the generic prompt.
        XCTAssertEqual(
            RexProbe.sessionAgentState([status(.blocked)]), .needsYou(.permission))
        XCTAssertEqual(
            RexProbe.sessionAgentState([status(.done), status(.working)]), .busy)
        // `done` and `error` settle to idle: that busy → idle edge is the
        // turn-ended alert.
        XCTAssertEqual(RexProbe.sessionAgentState([status(.done)]), .idle)
        XCTAssertEqual(RexProbe.sessionAgentState([status(.error)]), .idle)
        XCTAssertNil(RexProbe.sessionAgentState([status(.unknown)]))
        XCTAssertNil(RexProbe.sessionAgentState([]))
    }

    // MARK: States

    func testAHostWithoutRexReportsItMissing() {
        XCTAssertEqual(RexProbe.parseProbe("MULTIPLEX_NO_REX\n").state, .rexMissing)
        // Login-shell noise ahead of the marker is tolerated.
        XCTAssertEqual(
            RexProbe.parseProbe("Welcome to devbox\nMULTIPLEX_NO_REX\n").state,
            .rexMissing)
        XCTAssertEqual(RexProbe.State.rexMissing.tmuxState, .tmuxMissing)
    }

    func testNoRunningServerIsNoServerNotAFailure() {
        // Exit 4 is the CLI's "server could not be reached"; with autostart
        // off that is simply nothing running.
        let probe = RexProbe.parseProbe("MULTIPLEX_REX_PROBE\nMULTIPLEX_REX_EXIT 4\n")
        XCTAssertEqual(probe.state, .noServer)
        XCTAssertEqual(probe.state.tmuxState, .noServer)
    }

    func testAnyOtherExitStatusIsAFailureThatNamesIt() {
        let probe = RexProbe.parseProbe("MULTIPLEX_REX_PROBE\nMULTIPLEX_REX_EXIT 2\n")
        guard case .failed(let message) = probe.state else {
            return XCTFail("expected a failure, got \(probe.state)")
        }
        XCTAssertTrue(message.contains("2"))
    }

    func testAServerWithNoSessionsRendersNothing() {
        // An empty Lua table encodes as `{}`, never `[]`.
        let probe = RexProbe.parseProbe(response(json: #"{"ok":true,"sessions":{}}"#))
        XCTAssertEqual(probe.state, .noServer)
    }

    func testAScriptThatNeverReachedTheSessionListIsUnreadable() {
        // `ok` is only set once `session.list` answered.
        let probe = RexProbe.parseProbe(response(json: #"{"sessions":{}}"#))
        guard case .failed = probe.state else {
            return XCTFail("expected a failure, got \(probe.state)")
        }
        guard case .failed = RexProbe.parseProbe("garbage").state else {
            return XCTFail("garbage must not parse")
        }
        // A response cut off before its exit line reports nothing.
        guard case .failed = RexProbe.parseProbe(
            "MULTIPLEX_REX_PROBE\n{\"ok\":true,").state
        else { return XCTFail("a truncated response must not parse") }
    }

    func testASessionWhoseViewFailedIsStillATile() throws {
        // The view call can lose a race with a closing session; the session
        // is listed with no spine rather than dropped.
        let probe = RexProbe.parseProbe(response(json: """
            {"ok":true,"sessions":[
              {"id":"session:0000-aaaaaa","label":"solo","windows":{}}
            ]}
            """))
        let session = try XCTUnwrap(try sessions(probe).first)
        XCTAssertEqual(session.name, "solo")
        XCTAssertTrue(session.windows.isEmpty)
        XCTAssertNil(probe.tails["solo"])
    }

    func testAScreenCannotForgeTheExitLine() throws {
        // Screen text arrives JSON-escaped inside a quoted, indented value,
        // so it can never start a line with the marker.
        let probe = RexProbe.parseProbe(response(json: """
            {"ok":true,"sessions":[
              {"id":"session:0000-bbbbbb","label":"sly",
               "tail":"hello\\nMULTIPLEX_REX_EXIT 4\\nMULTIPLEX_NO_REX","windows":{}}
            ]}
            """))
        XCTAssertEqual(try sessions(probe).map(\.name), ["sly"])
        XCTAssertEqual(
            probe.tails["sly"],
            ["hello", "MULTIPLEX_REX_EXIT 4", "MULTIPLEX_NO_REX"])
    }

    func testAttachedAppClientsLightTheLiveLamp() throws {
        let probe = RexProbe.parseProbe(response(json: """
            {"ok":true,"sessions":[
              {"id":"session:0000-cccccc","label":"shown","clients":2,"windows":{}}
            ]}
            """))
        let session = try XCTUnwrap(try sessions(probe).first)
        XCTAssertEqual(session.clientCount, 2)
        XCTAssertTrue(Host.SessionBackend.rex.isSessionLive(
            clientCount: session.clientCount, hasOpenTab: false))
        // This app attaches as kind `other`, so its own tab is not in that
        // count and lights the lamp by itself.
        XCTAssertTrue(Host.SessionBackend.rex.isSessionLive(clientCount: 0, hasOpenTab: true))
        XCTAssertFalse(Host.SessionBackend.rex.isSessionLive(clientCount: 0, hasOpenTab: false))
    }

    // MARK: Names

    func testSharedAndEmptyLabelsAreSpelledWithTheIDTail() {
        XCTAssertEqual(
            RexProbe.sessionNames(for: [
                (id: "session:1111-aaaaaa", label: "work"),
                (id: "session:2222-bbbbbb", label: "notes"),
                // Rex matches labels case-insensitively, so these collide.
                (id: "session:3333-cccccc", label: "Work"),
                (id: "session:4444-dddddd", label: "  "),
            ]),
            ["work …aaaaaa", "notes", "Work …cccccc", "…dddddd"])
    }

    func testControlCharactersNeverReachATileName() {
        XCTAssertEqual(
            RexProbe.sessionNames(for: [(id: "session:1-abcdef", label: "a\u{1B}[31mb\n")]),
            ["a[31mb"])
    }

    // MARK: Actions

    func testKillAimsAtTheIDAndRefusesAnythingElse() throws {
        var session = TmuxSession(
            name: "work …8d7863", windows: [], created: .distantPast,
            tmuxID: "session:01a1e1e3-47e5-7497-bde1-74a5768d7863", backend: .rex)
        let command = try XCTUnwrap(RexProbe.killCommand(for: session))
        XCTAssertTrue(command.contains(
            "REX_AUTOSTART=0 rex kill 'session:01a1e1e3-47e5-7497-bde1-74a5768d7863'"))
        XCTAssertTrue(command.hasSuffix("; true"))

        // A label is not a target: two sessions can share it.
        session.tmuxID = ""
        XCTAssertNil(RexProbe.killCommand(for: session))
        session.tmuxID = "session:x; rm -rf ~"
        XCTAssertNil(RexProbe.killCommand(for: session))
        XCTAssertFalse(RexWire.bakeableSessionID("work"))
        XCTAssertFalse(RexWire.bakeableSessionID("session:"))
    }

    // MARK: Discovery

    func testTheRiderCountsSessionsWithoutStartingAServer() {
        let rider = BackendDiscovery.riderCommand(for: .rex)
        XCTAssertTrue(rider.contains("REX_AUTOSTART=0 rex ls -q 2>/dev/null || true"))
        XCTAssertTrue(rider.contains("command -v rex >/dev/null 2>&1 && "))

        let reading = BackendDiscovery.read("""
            MULTIPLEX_DISCOVER rex
            MPXD_PRESENT
            session:01a1e1e3-47e5-7497-bde1-74a5768d7863
            session:01a1e1e3-4870-742a-9d13-2b5e9df0ada5
            a stray warning line
            MULTIPLEX_DISCOVER_END
            S $0 0 1 main
            """)
        let result = try? XCTUnwrap(reading.results[.rex])
        XCTAssertEqual(result?.isInstalled, true)
        XCTAssertEqual(result?.sessionCount, 2)
        XCTAssertEqual(result?.offersSessions, true)
        XCTAssertEqual(reading.remainder, "S $0 0 1 main")
        XCTAssertEqual(
            FleetBackendOffer(backend: .rex, sessionCount: 2).chipCaption, "+ REX · 2")
    }

    func testEveryPrimaryProbeAsksAfterRex() {
        XCTAssertTrue(TmuxProbe.probeCommand(discovering: [.herdr, .rex])
            .contains("MULTIPLEX_DISCOVER rex"))
        XCTAssertTrue(HerdrProbe.probeCommand(
            sessionNames: nil, tailTargets: [], discovering: [.tmux, .rex]
        ).contains("MULTIPLEX_DISCOVER rex"))
    }

    // MARK: The record — attachable, never the primary

    func testRexIsNeverTheHostsPrimary() {
        var host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        host.sessionBackend = .rex
        // The write keeps the old primary and shows Rex beside it.
        XCTAssertEqual(host.sessionBackend, .tmux)
        XCTAssertEqual(host.secondaryBackends, [.rex])
        XCTAssertEqual(host.monitoredBackends, [.tmux, .rex])
        XCTAssertTrue(host.showsBackendIdentity)

        XCTAssertFalse(Host.SessionBackend.rex.canBeDefault)
        XCTAssertEqual(Host.SessionBackend.defaultCases, [.tmux, .herdr])
    }

    func testARecordNamingRexAsPrimaryDecodesWithTmuxLeading() throws {
        let json = """
            {"name":"devbox","hostname":"127.0.0.1","username":"dev",
             "sessionBackend":"rex","secondaryBackends":["herdr"]}
            """
        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        XCTAssertEqual(host.sessionBackend, .tmux)
        XCTAssertEqual(host.secondaryBackends, [.herdr, .rex])
    }

    func testTheBackendSelectionNeverLeavesAHostWithNothingToRunOn() {
        var selection = Host.BackendSelection(preferred: .tmux, also: [.rex])
        XCTAssertEqual(selection.defaultChoices, [.tmux])
        XCTAssertTrue(selection.isMixed)

        // Unchecking the only backend that can host a terminal is refused.
        selection.setEnabled([.rex])
        XCTAssertEqual(selection.enabled, [.tmux, .rex])
        // Rex cannot be chosen as the default.
        selection.setPreferred(.rex)
        XCTAssertEqual(selection.preferred, .tmux)

        // Unchecking the default promotes one that can run sessions.
        selection.setEnabled([.herdr, .rex])
        XCTAssertEqual(selection.preferred, .herdr)
        XCTAssertEqual(selection.secondaries, [.rex])

        // A selection handed Rex as its default leads with a real one.
        let demoted = Host.BackendSelection(preferred: .rex, also: [.herdr])
        XCTAssertEqual(demoted.preferred, .herdr)
        XCTAssertEqual(demoted.enabled, [.herdr, .rex])
    }

    func testASetOfBackendsEncodesSorted() throws {
        var host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        host.secondaryBackends = [.rex, .herdr]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let first = try encoder.encode(host)
        // `Set` iterates in a per-process order; the record must not.
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(object["secondaryBackends"] as? [String], ["herdr", "rex"])
        let decoded = try JSONDecoder().decode(Host.self, from: first)
        XCTAssertEqual(decoded.secondaryBackends, [.herdr, .rex])
        XCTAssertEqual(try encoder.encode(decoded), first)
    }

    // MARK: Attaching goes by id

    func testARexSessionAttachesByItsIDNeverItsLabel() throws {
        let id = "session:01a1e1e3-47e5-7497-bde1-74a5768d7863"
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let session = TmuxSession(
            name: "work …8d7863", windows: [], created: .distantPast,
            tmuxID: id, backend: .rex)
        let mode = try XCTUnwrap(TerminalRoute.Mode.attach(host: host, session: session))
        XCTAssertEqual(mode, .rexAttach(sessionName: "work …8d7863", sessionID: id))

        let route = TerminalRoute(hostID: host.id, mode: mode)
        XCTAssertNil(route.rexTarget?.blockID)
        XCTAssertEqual(route.sessionBackend, .rex)
        XCTAssertEqual(route.sessionKey, session.id)
        XCTAssertEqual(route.rexTarget?.sessionID, id)
        XCTAssertEqual(route.displayName, "work …8d7863")
        // No client runs in a PTY, so there is nothing to hand a shell —
        // over SSH or over mosh.
        XCTAssertNil(route.remoteCommand)
        XCTAssertNil(route.moshRemoteCommand)
        XCTAssertFalse(route.usesTmux)
        // Its rail key opens the REX panel — never a TMUX one.
        XCTAssertEqual(route.sessionBackend, .rex)
        XCTAssertEqual(Host.SessionBackend.rex.shortcutKeyCaption, "REX")
        XCTAssertEqual(Host.SessionBackend.tmux.shortcutKeyCaption, "TMUX")
        XCTAssertEqual(Host.SessionBackend.herdr.shortcutKeyCaption, "HRDR")
        // The panel lists no bindings (Rex has no prefix-key client): its
        // rows act on the tab's own panes, and the list below them reaches
        // the session's other terminals.
        let panel = ShortcutPanelContent.content(for: route.sessionBackend)
        XCTAssertEqual(panel, .rex)
        XCTAssertEqual(
            panel?.sections.flatMap(\.items).map(\.payload),
            [
                .pane(.splitRight), .pane(.splitDown), .pane(.zoomPane), .pane(.closePane),
                .pane(.newWindow),
            ])
        // Closing ends a program: asked twice, like every backend's close.
        XCTAssertEqual(
            panel?.sections.flatMap(\.items).map(\.requiresDoubleActivation),
            [false, false, false, true, false])
        // Rex's own app calls a window a tab, and so does its row.
        XCTAssertEqual(panel?.sections.map(\.title), ["Panes", "Tabs"])
        XCTAssertEqual(panel?.sections.last?.items.map(\.title), ["New Tab"])
        XCTAssertEqual(panel?.sections.last?.items.map(\.command), ["session.new_window"])
        XCTAssertEqual(panel?.switchSectionTitle, "Switch Terminal")

        // A label is not a target: two sessions can share one.
        XCTAssertNil(TerminalRoute.Mode.attach(backend: .rex, sessionName: "work"))
        XCTAssertNil(TerminalRoute.Mode.attach(
            backend: .rex, sessionName: "work", sessionID: "work; rm -rf ~"))
        XCTAssertEqual(
            TerminalRoute.Mode.attach(backend: .tmux, sessionName: "work"),
            .attach(sessionName: "work"))
        // Rex has no terminal client, so no line opens it in a host shell.
        XCTAssertNil(SessionHandoff.command(session: session))
    }

    func testARexRouteSurvivesARelaunch() throws {
        for block in [nil, RexBlockRef(id: "block:b", label: "editor")] {
            let route = TerminalRoute(
                hostID: UUID(),
                mode: .rexAttach(
                    sessionName: "api", sessionID: "session:0000-aaaaaa", block: block))
            let decoded = try JSONDecoder().decode(
                TerminalRoute.self, from: JSONEncoder().encode(route))
            XCTAssertEqual(decoded, route)
        }
        // A route saved before a tab could name a terminal has no `block`.
        let legacy = try JSONDecoder().decode(
            TerminalRoute.Mode.self,
            from: Data(#"{"rexAttach":{"sessionName":"api","sessionID":"session:0000-aaaaaa"}}"#.utf8))
        XCTAssertEqual(
            legacy, .rexAttach(sessionName: "api", sessionID: "session:0000-aaaaaa"))
    }

    func testATabsAgentIsItsOwnTerminalsNotTheOneTheSessionFronts() throws {
        let session = try XCTUnwrap(
            try sessions(RexProbe.parseProbe(try fixture())).first)
        // The session is fronting its editor window, where no agent runs;
        // the agent is in another window.
        XCTAssertNil(session.activeAgent)
        let agentPane = try XCTUnwrap(session.windows[1].panes?.first)
        // A tab on the agent's terminal speaks for the agent, whatever the
        // Rex app is showing (seen live: fronting another window took the
        // strip off a tab that was still on Claude Code).
        XCTAssertEqual(session.agent(inPane: agentPane.tmuxID), .claudeCode)
        // A tab on a plain terminal of the same session speaks for none.
        let logsPane = try XCTUnwrap(session.windows[0].panes?.last)
        XCTAssertNil(session.agent(inPane: logsPane.tmuxID))
        // A tab that names no terminal shows the whole session and follows
        // its focus — tmux and herdr.
        XCTAssertEqual(session.agent(inPane: nil), session.activeAgent)
        // A terminal the record does not list has nothing to report.
        XCTAssertNil(session.agent(inPane: "block:gone"))
    }

    func testOpenTerminalNamesEachTerminalAndTargetsItsBlock() throws {
        let session = try XCTUnwrap(
            try sessions(RexProbe.parseProbe(try fixture())).first)
        let rows = session.windows.flatMap { window in
            (window.panes ?? []).map { RexProbe.terminalMenuTitle(window: window, pane: $0) }
        }
        // The title a program set, else the command in front.
        XCTAssertEqual(rows, ["editor — vim README.md", "editor — sleep", "agent — ✳ Claude Code"])

        let window = session.windows[0]
        let pane = try XCTUnwrap(window.panes?.last)
        let mode = try XCTUnwrap(
            TerminalRoute.Mode.attach(session: session, window: window, pane: pane))
        let route = TerminalRoute(hostID: UUID(), mode: mode)
        XCTAssertEqual(route.rexTarget?.sessionID, session.tmuxID)
        XCTAssertEqual(route.rexTarget?.blockID, "block:01a1e1e3-4810-7831-92b7-22087aff9bc8")
        // Same session identity as the tile — the deck still finds the tab —
        // but a label that says which terminal this one is.
        XCTAssertEqual(route.sessionKey, session.id)
        XCTAssertEqual(route.displayName, "work …8d7863 · editor")
        // A tile press names no terminal: the fronted one, chosen at attach.
        let fronted = TerminalRoute(
            hostID: UUID(),
            mode: try XCTUnwrap(TerminalRoute.Mode.attach(
                host: Host(name: "a", hostname: "b", username: "c"), session: session)))
        XCTAssertNil(fronted.rexTarget?.blockID)
    }

    func testOnlyAMultiTerminalRexTileOffersOpenTerminal() throws {
        let fixtureSessions = try sessions(RexProbe.parseProbe(try fixture()))
        func menuTitles(_ session: TmuxSession) -> [String] {
            let tile = FleetSessionTileView()
            tile.configure(FleetSessionTileConfiguration(
                hostID: UUID(), session: session, lines: [], attention: nil,
                usesTmuxAttentionFallback: false, hasOpenTab: false,
                sessionBackend: session.backend, showsBackendIdentity: true,
                compact: false, selected: false,
                duplicateAttachTitle: "Attach in New Window",
                openTabAccessibilityText: "Open",
                attach: {}, attachNewWindow: {}, newHerdrTab: {},
                copyHandoffCommand: {}, delete: {}, droppedSession: { _ in }
            ))
            return tile.menuProvider?()?.children.map(\.title) ?? []
        }
        // Three terminals across two windows.
        XCTAssertEqual(
            menuTitles(fixtureSessions[0]),
            ["Attach in New Window", "Open Terminal", "Delete Session…"])
        // One terminal: a press already opens it.
        XCTAssertEqual(
            menuTitles(fixtureSessions[2]), ["Attach in New Window", "Delete Session…"])
    }

    func testABannerForARexSessionCanAttachIt() {
        XCTAssertTrue(AttentionTapTarget(
            hostID: UUID(), sessionName: "work", backend: .rex
        ).sessionIsAttachable)
    }

    func testWidgetsListRexSessionsAndOfferRexToRunOn() {
        var host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        host.secondaryBackends = [.rex]
        let tmux = TmuxSession(name: "main", windows: [], created: .distantPast)
        let rex = TmuxSession(
            name: "work", windows: [], created: .distantPast, backend: .rex)
        let state = WidgetStateBuilder.hostState(
            host: host, sessions: [tmux, rex], miniatures: [:], probedAt: nil)
        // A row is a session to open; both backends' are.
        XCTAssertEqual(state.sessions.map(\.name), ["main", "work"])
        XCTAssertEqual(state.sessions.map(\.backendRaw), ["tmux", "rex"])
        // A pick list is where a NEW session runs: the default first, then
        // Rex, which can run one without ever being the default.
        XCTAssertEqual(state.backendsRaw, ["tmux", "rex"])
    }

    // MARK: New session

    /// A reply as preview.19 prints it (2026-11-16): pretty-printed, keys
    /// sorted, the CLI's exit status on the command's own last line.
    private func mintReply(_ body: String, exit: Int = 0) -> String {
        "MULTIPLEX_REX_MINT\n\(body)\nMULTIPLEX_REX_EXIT \(exit)\n"
    }

    func testAMintReportsTheSessionTheServerActuallyMade() {
        let reply = mintReply("""
            {
              "id": "session:01a1e24f-9765-74c6-9227-dda638130537",
              "label": "api-2",
              "ok": true
            }
            """)
        XCTAssertEqual(
            RexProbe.parseMint(reply),
            .created(name: "api-2", id: "session:01a1e24f-9765-74c6-9227-dda638130537"))
        // Login-shell noise ahead of the marker changes nothing.
        XCTAssertEqual(
            RexProbe.parseMint("Last login: Mon Nov 16\n" + reply),
            .created(name: "api-2", id: "session:01a1e24f-9765-74c6-9227-dda638130537"))
    }

    func testAMintWithNoServerSaysSoInsteadOfLookingLikeABrokenLink() {
        // Autostart is off, so the CLI exits 4 and prints nothing on stdout.
        XCTAssertEqual(RexProbe.parseMint(mintReply("", exit: 4)), .noServer)
        XCTAssertEqual(RexProbe.parseMint("MULTIPLEX_NO_REX\n"), .rexMissing)
        // Any other status, a script that gave up, an id nothing could be
        // attached by, and an answer cut short are all just "not created".
        XCTAssertEqual(RexProbe.parseMint(mintReply("", exit: 1)), .failed)
        XCTAssertEqual(RexProbe.parseMint(mintReply("{\n  \"ok\": false\n}")), .failed)
        XCTAssertEqual(
            RexProbe.parseMint(mintReply("{\"ok\": true, \"id\": \"work; rm -rf\", \"label\": \"x\"}")),
            .failed)
        XCTAssertEqual(RexProbe.parseMint("MULTIPLEX_REX_MINT\n{\n  \"ok\": true"), .failed)
        XCTAssertEqual(RexProbe.parseMint(""), .failed)
    }

    func testAMintedSessionIsNamedAsTheNextProbeWillNameIt() {
        // A label comes back through the same reading a probed one gets,
        // and a session the server left unlabeled is spelled by its id tail
        // — `sessionNames`' own spelling, so the tab and the tile agree.
        let unlabeled = mintReply("""
            {"id": "session:01a1e24f-a3e4-74ca-90c0-8cfddb282ebc", "label": "", "ok": true}
            """)
        XCTAssertEqual(
            RexProbe.parseMint(unlabeled),
            .created(name: "…282ebc", id: "session:01a1e24f-a3e4-74ca-90c0-8cfddb282ebc"))
        XCTAssertEqual(
            RexProbe.sessionNames(for: [
                (id: "session:01a1e24f-a3e4-74ca-90c0-8cfddb282ebc", label: ""),
            ]),
            ["…282ebc"])
    }

    func testTheMintCarriesWhatTheUserTypedAsDataNeverAsScript() throws {
        let label = "it's \"mine\"; os.exit() ]] --"
        let command = RexProbe.mintCommand(
            label: label, inDirectoryOf: nil, startingIn: nil,
            typing: ["source ~/.venv/bin/activate", "claude 'fix it'"])
        // Never started by Multiplex, never a failed exec.
        XCTAssertTrue(command.contains("REX_AUTOSTART=0 rex do -e "))
        XCTAssertTrue(command.contains("command -v rex >/dev/null 2>&1 || { echo MULTIPLEX_NO_REX; exit 0; }"))
        XCTAssertTrue(command.hasSuffix("echo \"MULTIPLEX_REX_EXIT $?\""))

        // The arguments are one shell word holding one JSON object.
        let arguments = try XCTUnwrap(jsonArguments(of: command))
        XCTAssertEqual(arguments["label"], label)
        // Each line is followed by Enter, in order: setup, then launch.
        XCTAssertEqual(
            arguments["input"], "source ~/.venv/bin/activate\rclaude 'fix it'\r")
        XCTAssertNil(arguments["source"])
        // The script itself is constant: nothing typed reaches it.
        let other = RexProbe.mintCommand(
            label: "plain", inDirectoryOf: nil, startingIn: nil, typing: [])
        XCTAssertEqual(script(of: command), script(of: other))
        XCTAssertNil(try XCTUnwrap(jsonArguments(of: other))["input"])
    }

    func testTheMintStartsWhereTheSourceSessionIsElseInTheNamedDirectory() throws {
        let source = "session:01a1e24a-4b6a-7557-8707-32a02f197112"
        // A source wins, and the explicit directory is then not consulted.
        let sibling = RexProbe.mintCommand(
            label: "api", inDirectoryOf: source, startingIn: "~/elsewhere", typing: [])
        XCTAssertEqual(try XCTUnwrap(jsonArguments(of: sibling))["source"], source)
        XCTAssertFalse(sibling.contains("MULTIPLEX_REX_CWD="))
        XCTAssertFalse(sibling.contains("elsewhere"))

        // Without one, the SHELL resolves the directory — the server takes
        // `cwd` literally, tilde included — and hands over an absolute path,
        // or nothing when it is not there.
        let placed = RexProbe.mintCommand(
            label: "api", inDirectoryOf: nil, startingIn: "~/work space", typing: [])
        XCTAssertTrue(placed.contains(
            "d=\"$HOME\"/'work space'; d=$(CDPATH= cd -- \"$d\" 2>/dev/null && pwd); "))
        XCTAssertTrue(placed.contains("MULTIPLEX_REX_CWD=\"$d\" REX_AUTOSTART=0 rex do -e "))
        XCTAssertNil(try XCTUnwrap(jsonArguments(of: placed))["source"])

        // Neither: nothing is resolved and nothing is exported.
        let home = RexProbe.mintCommand(
            label: "api", inDirectoryOf: nil, startingIn: nil, typing: [])
        XCTAssertFalse(home.contains("MULTIPLEX_REX_CWD="))
    }

    func testANewLabelIsReadableUniqueAndNeverEmpty() {
        XCTAssertEqual(RexProbe.sessionLabel(base: "  my work\u{07} "), "my work")
        // An empty label would make the server invent one nobody predicted.
        XCTAssertEqual(RexProbe.sessionLabel(base: " \n "), "session")
        XCTAssertEqual(RexProbe.sessionLabel(base: String(repeating: "x", count: 300)).count, 120)

        XCTAssertEqual(RexProbe.uniqueSessionLabel(base: "api", existing: ["main"]), "api")
        // Without case, as the wall counts labels.
        XCTAssertEqual(RexProbe.uniqueSessionLabel(base: "api", existing: ["API"]), "api-2")
        XCTAssertEqual(
            RexProbe.uniqueSessionLabel(base: "api", existing: ["api", "api-2"]), "api-3")
    }

    func testTheNewSessionSheetOffersRexWithoutMakingItTheDefault() throws {
        var host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        host.secondaryBackends = [.rex]
        // No remembered agent: the suggestion is the backend's own default.
        let suite = "app.multiplexterm.multiplex.tests.rex-mint.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        var form = NewSessionFormState(
            host: host, existingNames: [.tmux: ["main"], .rex: ["session"]],
            preferences: NewSessionPreferences(defaults: defaults))
        XCTAssertEqual(form.backendChoices, [.tmux, .rex])
        // The sheet opens on the host's default.
        XCTAssertEqual(form.backend, .tmux)
        XCTAssertEqual(form.name, "main-2")

        form.selectBackend(.rex)
        XCTAssertEqual(form.backend, .rex)
        // An untouched suggestion follows the backend, by ITS namer and
        // against ITS sessions.
        XCTAssertEqual(form.name, "session-2")
        // A tab inside an existing session stays herdr's shape.
        XCTAssertTrue(form.tabTargetChoices.isEmpty)
    }

    /// The `--args` word of a mint command, decoded.
    private func jsonArguments(of command: String) -> [String: String]? {
        guard let start = command.range(of: " --args '"),
              let end = command.range(of: "' --json 2>/dev/null; ", options: .backwards)
        else { return nil }
        let quoted = String(command[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "'\\''", with: "'")
        return try? JSONDecoder().decode([String: String].self, from: Data(quoted.utf8))
    }

    /// The `-e` word of a mint command.
    private func script(of command: String) -> String? {
        guard let start = command.range(of: " do -e '"),
              let end = command.range(of: "' --args '")
        else { return nil }
        return String(command[start.upperBound..<end.lowerBound])
    }

    // MARK: The tile

    private func tile(
        backend: Host.SessionBackend, mixed: Bool = true
    ) -> FleetSessionTileView {
        let session = TmuxSession(
            name: "work", windows: [], created: .distantPast, backend: backend)
        let tile = FleetSessionTileView()
        tile.configure(FleetSessionTileConfiguration(
            hostID: UUID(),
            session: session,
            lines: [],
            attention: nil,
            usesTmuxAttentionFallback: false,
            hasOpenTab: false,
            sessionBackend: backend,
            showsBackendIdentity: mixed,
            compact: false,
            selected: false,
            duplicateAttachTitle: "Attach in New Window",
            openTabAccessibilityText: "Open",
            attach: {}, attachNewWindow: {}, newHerdrTab: {},
            copyHandoffCommand: {}, delete: {}, droppedSession: { _ in }
        ))
        return tile
    }

    func testARexTileAttachesLikeAnyOtherAndOffersNoHandoffLine() throws {
        let rex = tile(backend: .rex)
        let label = try XCTUnwrap(rex.accessibilityLabel)
        XCTAssertTrue(label.contains("on rex"))
        XCTAssertTrue(label.hasSuffix("Attach"))
        // There is no command that opens a Rex session in a host shell, so
        // the handoff row is the one a Rex tile does not carry.
        XCTAssertEqual(
            rex.menuProvider?()?.children.map(\.title),
            ["Attach in New Window", "Delete Session…"])

        let tmux = tile(backend: .tmux)
        XCTAssertEqual(
            tmux.menuProvider?()?.children.map(\.title),
            ["Attach in New Window", "Copy Command for Handoff", "Delete Session…"])
    }

    /// The wash must change HUE, not hierarchy, and must not be mistaken for
    /// herdr's: blue over green over red, where mauve runs blue, red, green.
    func testTheRexWashMatchesBezelsLightnessAndIsNotMauve() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let bezel = TallyPalette.bezel.resolvedColor(with: traits)
            let rex = TallyPalette.rexBezel.resolvedColor(with: traits)
            XCTAssertNotEqual(rex, bezel, "\(style)")
            XCTAssertNotEqual(
                rex, TallyPalette.herdrBezel.resolvedColor(with: traits), "\(style)")
            XCTAssertEqual(
                luminance(of: rex), luminance(of: bezel), accuracy: 3 / 255,
                "the rex wash must read as a different tint, not a brighter tile")
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            rex.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            XCTAssertGreaterThan(blue, green, "\(style)")
            XCTAssertGreaterThan(green, red, "\(style)")
        }
        XCTAssertEqual(
            UIKitChassis.tileBezel(backend: .rex, tinted: false), UIKitChassis.bezel)
        XCTAssertEqual(
            UIKitChassis.tileBezel(backend: .tmux, tinted: true), UIKitChassis.bezel)
    }

    private func luminance(of color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
