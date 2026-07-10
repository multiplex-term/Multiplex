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

    func testRouteCommands() {
        let host = UUID()
        let attach = TerminalRoute(hostID: host, mode: .attach(sessionName: "main"))
        XCTAssertEqual(attach.remoteCommand, "exec tmux attach-session -t 'main'")

        let create = TerminalRoute(hostID: host, mode: .create(sessionName: "new one"))
        XCTAssertEqual(create.remoteCommand, "exec tmux new-session -A -s 'new one'")

        let shell = TerminalRoute(hostID: host, mode: .shell)
        XCTAssertNil(shell.remoteCommand)
    }
}
