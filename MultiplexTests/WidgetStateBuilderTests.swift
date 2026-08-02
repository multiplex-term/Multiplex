import XCTest
@testable import Multiplex

final class WidgetStateBuilderTests: XCTestCase {
    private func session(
        name: String,
        created: TimeInterval = 0,
        serverHost: String = "",
        windows: [TmuxWindow]
    ) -> TmuxSession {
        TmuxSession(
            name: name,
            windows: windows,
            created: Date(timeIntervalSince1970: created),
            serverHost: serverHost
        )
    }

    private func window(
        _ index: Int, name: String, active: Bool = false, agent: AgentKind? = nil,
        paneTitle: String = ""
    ) -> TmuxWindow {
        TmuxWindow(
            index: index, name: name, isActive: active,
            hasBell: false, hasActivity: false, agent: agent, paneTitle: paneTitle
        )
    }

    func testHostStateProjectsSessionsWindowsAndMiniatures() {
        var host = Host(name: "devbox", hostname: "10.0.1.7", username: "jhen")
        host.agentLaunchModels = ["codex": ["gpt-5-codex"]]
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
        // Configured launch models feed the widget's Model setting picker;
        // a host with none stays nil so legacy-file shape and no-config
        // shape read the same.
        XCTAssertEqual(state.agentModels, ["codex": ["gpt-5-codex"]])
        XCTAssertNil(WidgetStateBuilder.hostState(
            host: Host(name: "b", hostname: "h", username: "u"),
            sessions: [], miniatures: [:], probedAt: nil
        ).agentModels)
        // The backend rides the projection so the widget configuration's
        // placement picker can speak the host's vocabulary.
        XCTAssertEqual(state.backendRaw, "tmux")
        var herdrHost = Host(name: "c", hostname: "h", username: "u")
        herdrHost.sessionBackend = .herdr
        XCTAssertEqual(WidgetStateBuilder.hostState(
            host: herdrHost, sessions: [], miniatures: [:], probedAt: nil
        ).backendRaw, "herdr")
        // Configured working dirs feed the widget's directory picker; a
        // host with none stays nil so legacy-file shape and no-config
        // shape read the same (paths only — script names never ride).
        XCTAssertNil(state.workingDirs)
        var dirHost = Host(name: "d", hostname: "h", username: "u")
        dirHost.workingDirs = ["~/srv", "/tmp"]
        XCTAssertEqual(WidgetStateBuilder.hostState(
            host: dirHost, sessions: [], miniatures: [:], probedAt: nil
        ).workingDirs, ["~/srv", "/tmp"])
        XCTAssertEqual(state.sessions.count, 1)
        let main = state.sessions[0]
        XCTAssertEqual(main.name, "main")
        XCTAssertEqual(main.agentRaw, "claudeCode")
        XCTAssertEqual(main.windowNames, ["editor", "server", "logs"])
        XCTAssertEqual(main.activeWindowIndex, 1)
        XCTAssertEqual(main.miniatureLines, ["$ pnpm build", "✓ done"])
        XCTAssertEqual(main.createdAt, Date(timeIntervalSince1970: 100))
    }

    func testPaneTitlesAreFilteredBeforeTheyReachTheWidget() {
        let sessions = [session(
            name: "main",
            serverHost: "Jhen-MBPr14.local",
            windows: [
                window(0, name: "cc", paneTitle: "✳ Claude Code"),
                // tmux's seed and a redundant repeat both project as "" so
                // the widget process never has to know the rule.
                window(1, name: "server", active: true, paneTitle: "Jhen-MBPr14.local"),
                window(2, name: "logs", paneTitle: "logs"),
            ]
        )]
        let state = WidgetStateBuilder.hostState(
            host: Host(name: "devbox", hostname: "10.0.1.7", username: "jhen"),
            sessions: sessions,
            miniatures: [:],
            probedAt: nil
        )
        let main = state.sessions[0]
        XCTAssertEqual(main.windowPaneTitles, ["✳ Claude Code", "", ""])
        // Parallel to windowNames, so activeWindowIndex indexes both.
        XCTAssertEqual(main.windowPaneTitles.count, main.windowNames.count)
        XCTAssertNil(main.activePaneTitle)
    }

    func testActivePaneTitleReadsTheActiveWindowAndSurvivesLegacyFiles() {
        let titled = WidgetSessionState(
            name: "main",
            windowNames: ["cc", "server"],
            windowPaneTitles: ["✳ Claude Code", "pnpm dev"],
            activeWindowIndex: 1
        )
        XCTAssertEqual(titled.activePaneTitle, "pnpm dev")

        // A file written before pane titles existed carries none at all.
        let legacy = WidgetSessionState(
            name: "main", windowNames: ["cc", "server"], activeWindowIndex: 1)
        XCTAssertNil(legacy.activePaneTitle)
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
