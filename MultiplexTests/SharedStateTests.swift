import XCTest
@testable import Multiplex

/// Locks the widget-facing shared surface to the app's models: the two URL
/// builders, Shortcut working-directory/setup-script choices, agent raw
/// values/labels, and the snapshot codec — the
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
                        askForPrompt: ask, directory: nil,
                        setupScript: .remembered, model: nil)
                )
            }
        }
    }

    func testWidgetAgentLinkCarriesConfiguredModel() {
        let id = UUID()
        XCTAssertEqual(
            ExternalActionURL.action(from: WidgetLink.agentURL(
                hostID: id, agentRaw: "codex", askForPrompt: false,
                model: "gpt-5-codex")),
            .openAgent(
                host: .id(id), agent: .codex, prompt: nil,
                askForPrompt: false, directory: nil,
                setupScript: .remembered, model: "gpt-5-codex")
        )
        // The widget passes its configuration text through unvalidated; the
        // app-side parser owns the grammar, so junk reads as agent default.
        XCTAssertEqual(
            ExternalActionURL.action(from: WidgetLink.agentURL(
                hostID: id, agentRaw: "codex", askForPrompt: false,
                model: "two words")),
            .openAgent(
                host: .id(id), agent: .codex, prompt: nil,
                askForPrompt: false, directory: nil,
                setupScript: .remembered, model: nil)
        )
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

    // MARK: Shortcut setup scripts

    func testSetupScriptOptionsKeepHostOrderAndStableIDs() {
        let first = ShortcutSessionScript(id: UUID(), displayName: "venv")
        let second = ShortcutSessionScript(id: UUID(), displayName: "  nvm  ")

        XCTAssertEqual(
            ShortcutSetupScriptOptions.choices(configured: [first, second, first]),
            [
                .init(value: "default", title: "New Session Default"),
                .init(value: "none", title: "None"),
                .init(value: first.id.uuidString, title: "venv"),
                .init(value: second.id.uuidString, title: "nvm"),
            ]
        )
    }

    func testSetupScriptOptionTokensAreValidated() {
        let id = UUID()
        XCTAssertEqual(
            ShortcutSetupScriptOptions.selection(for: nil),
            .remembered
        )
        XCTAssertEqual(
            ShortcutSetupScriptOptions.selection(for: "default"),
            .remembered
        )
        XCTAssertEqual(
            ShortcutSetupScriptOptions.selection(for: "none"),
            .none
        )
        XCTAssertEqual(
            ShortcutSetupScriptOptions.selection(for: id.uuidString),
            .id(id)
        )
        // Shortcut variables remain accepted, but arbitrary shell text can
        // never become a setup script body.
        XCTAssertEqual(
            ShortcutSetupScriptOptions.selection(for: "echo unsafe"),
            .none
        )
    }

    // MARK: Launch-model choices

    func testAgentModelChoicesTrimAndDedupeInOrder() {
        XCTAssertEqual(
            AgentModelChoices.values(configured: [
                "  gpt-5-codex  ",
                "gpt-5-codex",
                "",
                "anthropic/claude-opus-4:high",
                "   ",
            ]),
            ["gpt-5-codex", "anthropic/claude-opus-4:high"]
        )
        XCTAssertEqual(AgentModelChoices.values(configured: []), [])
    }

    func testAgentModelChoicesAreNeverEmptyAndLeadWithAgentDefault() {
        // A zero-item options query flash-dismisses the widget config
        // picker, so Agent Default always leads.
        XCTAssertEqual(
            AgentModelChoices.choices(configured: []),
            [.init(value: "", title: "Agent Default")]
        )
        XCTAssertEqual(
            AgentModelChoices.choices(configured: ["gpt-5-codex"]),
            [
                .init(value: "", title: "Agent Default"),
                .init(value: "gpt-5-codex", title: "gpt-5-codex"),
            ]
        )
        // The sentinel must read as "no model" where the value is consumed:
        // the launch grammar rejects it and the widget link omits it.
        XCTAssertNil(AgentKind.normalizedLaunchModel(AgentModelChoices.agentDefaultValue))
        XCTAssertEqual(
            ExternalActionURL.action(from: WidgetLink.agentURL(
                hostID: UUID(), agentRaw: "codex", askForPrompt: false,
                model: AgentModelChoices.agentDefaultValue))
                .flatMap { action -> String?? in
                    guard case .openAgent(_, _, _, _, _, _, let model) = action
                    else { return nil }
                    return .some(model)
                },
            .some(nil)
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
                    windowPaneTitles: ["✳ Claude Code", "pnpm dev", ""],
                    activeWindowIndex: 1,
                    miniatureLines: ["$ pnpm build", "✓ 214 modules · 3.2s"],
                    createdAt: Date(timeIntervalSince1970: 100)
                )],
                probedAt: Date(timeIntervalSince1970: 200),
                agentModels: ["codex": ["gpt-5-codex"], "claudeCode": ["opus"]]
            )],
            generatedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertTrue(SharedStateStore.save(state, directory: directory))
        XCTAssertEqual(SharedStateStore.load(directory: directory), state)
    }

    func testStateWrittenBeforePaneTitlesStillDecodes() throws {
        // A widget cannot ask the app to republish, so a file left by an older
        // build has to keep rendering — the field defaults must be honoured on
        // decode, not just by the memberwise initializer.
        let json = """
        {
          "hosts": [{
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "devbox",
            "address": "jhen@10.0.1.7",
            "sessions": [{
              "name": "main",
              "windowNames": ["editor", "server"],
              "activeWindowIndex": 1,
              "miniatureLines": ["$ pnpm build"],
              "createdAt": -978307200
            }]
          }],
          "generatedAt": -978307200
        }
        """
        let state = try JSONDecoder().decode(WidgetFleetState.self, from: Data(json.utf8))
        let session = try XCTUnwrap(state.hosts.first?.sessions.first)
        XCTAssertEqual(session.windowNames, ["editor", "server"])
        XCTAssertEqual(session.windowPaneTitles, [])
        XCTAssertNil(session.activePaneTitle)
        // Launch-model lists arrived later still; absent decodes as none.
        XCTAssertNil(state.hosts.first?.agentModels)
    }

    func testLoadFailsSoftOnMissingFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-state-missing-\(UUID().uuidString)")
        XCTAssertNil(SharedStateStore.load(directory: directory))
    }
}
