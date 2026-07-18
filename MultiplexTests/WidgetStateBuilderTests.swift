import XCTest
@testable import Multiplex

final class WidgetStateBuilderTests: XCTestCase {
    private func session(
        name: String,
        created: TimeInterval = 0,
        windows: [TmuxWindow]
    ) -> TmuxSession {
        TmuxSession(name: name, windows: windows, created: Date(timeIntervalSince1970: created))
    }

    private func window(
        _ index: Int, name: String, active: Bool = false, agent: AgentKind? = nil
    ) -> TmuxWindow {
        TmuxWindow(
            index: index, name: name, isActive: active,
            hasBell: false, hasActivity: false, agent: agent
        )
    }

    func testHostStateProjectsSessionsWindowsAndMiniatures() {
        let host = Host(name: "devbox", hostname: "10.0.1.7", username: "jhen")
        let sessions = [session(
            name: "main",
            created: 100,
            windows: [
                window(0, name: "editor"),
                window(1, name: "server", active: true, agent: .claudeCode),
                window(2, name: "logs"),
            ]
        )]
        let probed = Date(timeIntervalSince1970: 500)
        let state = WidgetStateBuilder.hostState(
            host: host,
            sessions: sessions,
            miniatures: ["main": ["$ pnpm build", "✓ done"]],
            probedAt: probed
        )

        XCTAssertEqual(state.id, host.id)
        XCTAssertEqual(state.name, "devbox")
        XCTAssertEqual(state.address, "jhen@10.0.1.7")
        XCTAssertEqual(state.probedAt, probed)
        XCTAssertEqual(state.sessions.count, 1)
        let main = state.sessions[0]
        XCTAssertEqual(main.name, "main")
        XCTAssertEqual(main.agentRaw, "claudeCode")
        XCTAssertEqual(main.windowNames, ["editor", "server", "logs"])
        XCTAssertEqual(main.activeWindowIndex, 1)
        XCTAssertEqual(main.miniatureLines, ["$ pnpm build", "✓ done"])
        XCTAssertEqual(main.createdAt, Date(timeIntervalSince1970: 100))
    }

    func testMiniatureLinesKeepOnlyTheTail() {
        let lines = (1...10).map { "line \($0)" }
        let state = WidgetStateBuilder.sessionState(
            session(name: "s", windows: []), miniatureLines: lines)
        XCTAssertEqual(state.miniatureLines.count, WidgetStateBuilder.miniatureLineLimit)
        XCTAssertEqual(state.miniatureLines.last, "line 10")
        XCTAssertEqual(state.miniatureLines.first, "line 5")
    }

    func testSessionAgentPrefersActivePaneThenAnyDetected() {
        let activeAgent = session(name: "a", windows: [
            window(0, name: "w", active: true, agent: .codex),
            window(1, name: "x", agent: .pi),
        ])
        XCTAssertEqual(WidgetStateBuilder.sessionAgent(activeAgent), .codex)

        let backgroundAgent = session(name: "b", windows: [
            window(0, name: "w", active: true),
            window(1, name: "x", agent: .pi),
        ])
        XCTAssertEqual(WidgetStateBuilder.sessionAgent(backgroundAgent), .pi)

        XCTAssertNil(WidgetStateBuilder.sessionAgent(session(name: "c", windows: [
            window(0, name: "w", active: true)
        ])))
    }

    func testContentFingerprintIgnoresProbeDatesButNotContent() {
        let host = Host(name: "devbox", hostname: "10.0.1.7", username: "jhen")
        func fleet(probed: TimeInterval, sessionName: String) -> WidgetFleetState {
            WidgetFleetState(
                hosts: [WidgetStateBuilder.hostState(
                    host: host,
                    sessions: [session(name: sessionName, windows: [])],
                    miniatures: [:],
                    probedAt: Date(timeIntervalSince1970: probed)
                )],
                generatedAt: Date(timeIntervalSince1970: probed)
            )
        }
        XCTAssertEqual(
            WidgetStateBuilder.contentFingerprint(of: fleet(probed: 1, sessionName: "main")),
            WidgetStateBuilder.contentFingerprint(of: fleet(probed: 2, sessionName: "main"))
        )
        XCTAssertNotEqual(
            WidgetStateBuilder.contentFingerprint(of: fleet(probed: 1, sessionName: "main")),
            WidgetStateBuilder.contentFingerprint(of: fleet(probed: 1, sessionName: "other"))
        )
    }
}
