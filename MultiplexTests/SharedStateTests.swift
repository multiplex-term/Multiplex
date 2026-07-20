import XCTest
@testable import Multiplex

/// Locks the widget-facing shared surface to the app's models: the two URL
/// builders, Shortcut working-directory choices, agent raw values/labels,
/// and the snapshot codec — the
/// widget target compiles none of the app model chain, so these tests are
/// the only thing keeping the two sides in step.
final class SharedStateTests: XCTestCase {
    // MARK: WidgetLink ↔ ExternalActionURL

    func testWidgetShellLinkParsesToOpenShell() {
        let id = UUID()
        XCTAssertEqual(
            ExternalActionURL.action(from: WidgetLink.shellURL(hostID: id)),
            .openShell(host: .id(id), sessionName: nil)
        )
        XCTAssertEqual(
            ExternalActionURL.action(
                from: WidgetLink.shellURL(hostID: id, sessionName: "agent runs")),
            .openShell(host: .id(id), sessionName: "agent runs")
        )
    }

    func testMostRecentSessionMirrorsExternalActionPlan() {
        let sessions = [
            ("old", 100.0), ("newest", 400.0), ("tie-b", 400.0), ("mid", 250.0),
        ]
        let tmux = sessions.map {
            TmuxSession(name: $0.0, windows: [], created: Date(timeIntervalSince1970: $0.1))
        }
        let widget = WidgetHostState(
            id: UUID(), name: "devbox", address: "a@b",
            sessions: sessions.map {
                WidgetSessionState(name: $0.0, createdAt: Date(timeIntervalSince1970: $0.1))
            }
        )
        XCTAssertEqual(
            widget.mostRecentSession?.name,
            ExternalActionPlan.mostRecentSessionName(in: tmux)
        )
    }

    func testWidgetAgentLinkParsesToOpenAgentForEveryAgent() {
        let id = UUID()
        for agent in AgentKind.allCases {
            for ask in [false, true] {
                XCTAssertEqual(
                    ExternalActionURL.action(from: WidgetLink.agentURL(
                        hostID: id, agentRaw: agent.rawValue, askForPrompt: ask)),
                    .openAgent(
                        host: .id(id), agent: agent, prompt: nil,
                        askForPrompt: ask, directory: nil)
                )
            }
        }
    }

    // MARK: Shortcut working directories

    func testWorkingDirectoryOptionsKeepHostOrderAndAddHomeOnce() {
        XCTAssertEqual(
            ShortcutWorkingDirectoryOptions.values(configured: [
                "  ~/workspace/Multiplex  ",
                "/srv/build dir",
                "~/workspace/Multiplex",
                "~",
                "   ",
            ]),
            ["~/workspace/Multiplex", "/srv/build dir", "~"]
        )
        XCTAssertEqual(
            ShortcutWorkingDirectoryOptions.values(configured: []),
            ["~"]
        )
    }

    // MARK: AgentChoice ↔ AgentKind

    func testAgentChoiceMirrorsAgentKindOneToOne() {
        XCTAssertEqual(
            Set(AgentChoice.allCases.map(\.rawValue)),
            Set(AgentKind.allCases.map(\.rawValue))
        )
        for choice in AgentChoice.allCases {
            XCTAssertNotNil(AgentKind(rawValue: choice.rawValue))
        }
    }

    func testAgentTelemetryLabelsMatchAgentKind() {
        for agent in AgentKind.allCases {
            XCTAssertEqual(
                SharedStateStore.agentTelemetryLabel(forRaw: agent.rawValue),
                agent.telemetryLabel
            )
        }
        XCTAssertNil(SharedStateStore.agentTelemetryLabel(forRaw: "not-an-agent"))
    }

    // MARK: Snapshot codec

    func testFleetStateRoundTripsThroughDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-state-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = WidgetFleetState(
            hosts: [WidgetHostState(
                id: UUID(),
                name: "devbox",
                address: "jhen@10.0.1.7",
                sessions: [WidgetSessionState(
                    name: "main",
                    agentRaw: "claudeCode",
                    windowNames: ["editor", "server", "logs"],
                    activeWindowIndex: 1,
                    miniatureLines: ["$ pnpm build", "✓ 214 modules · 3.2s"],
                    createdAt: Date(timeIntervalSince1970: 100)
                )],
                probedAt: Date(timeIntervalSince1970: 200)
            )],
            generatedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertTrue(SharedStateStore.save(state, directory: directory))
        XCTAssertEqual(SharedStateStore.load(directory: directory), state)
    }

    func testLoadFailsSoftOnMissingFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-state-missing-\(UUID().uuidString)")
        XCTAssertNil(SharedStateStore.load(directory: directory))
    }
}
