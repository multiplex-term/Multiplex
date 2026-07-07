import XCTest
@testable import Multiplex

final class TmuxProbeTests: XCTestCase {
    private let us = String(TmuxProbe.fieldSeparator)

    func testParsesSessionsAndWindows() {
        let output = [
            ["S", "main", "1", "1751500000"].joined(separator: us),
            ["S", "scratch", "0", "1751600000"].joined(separator: us),
            ["W", "main", "0", "editor", "0", "0", "0"].joined(separator: us),
            ["W", "main", "1", "server", "1", "0", "1"].joined(separator: us),
            ["W", "scratch", "0", "zsh", "1", "0", "0"].joined(separator: us),
        ].joined(separator: "\n")

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

    func testSessionNameWithSpacesAndUnicode() {
        let output = ["S", "my project ✨", "0", "0"].joined(separator: us)
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertEqual(sessions[0].name, "my project ✨")
        XCTAssertEqual(sessions[0].windows, [])
    }

    func testMalformedLinesAreSkipped() {
        let good = ["S", "ok", "0", "1751500000"].joined(separator: us)
        let output = "garbage line\nW\(us)too\(us)short\n\(good)"
        guard case .sessions(let sessions) = TmuxProbe.parse(output) else {
            return XCTFail("expected .sessions")
        }
        XCTAssertEqual(sessions.map(\.name), ["ok"])
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
