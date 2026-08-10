import XCTest
@testable import Multiplex

final class ExternalActionTests: XCTestCase {
    // MARK: URL round-trips

    func testShellURLRoundTripsHostID() {
        let id = UUID()
        let action = ExternalAction.openShell(host: .id(id), sessionName: nil)
        let url = ExternalActionURL.url(for: action)
        XCTAssertEqual(url.scheme, "multiplex")
        XCTAssertEqual(ExternalActionURL.action(from: url), action)
    }

    func testShellURLRoundTripsNamedSession() {
        let action = ExternalAction.openShell(
            host: .id(UUID()), sessionName: "deploy tools & más")
        XCTAssertEqual(
            ExternalActionURL.action(from: ExternalActionURL.url(for: action)),
            action
        )
    }

    func testAgentURLRoundTripsPromptAndAsk() {
        let action = ExternalAction.openAgent(
            host: .id(UUID()),
            agent: .codex,
            prompt: "fix the build\nthen run tests & say \"done\" 100%",
            askForPrompt: true,
            directory: nil,
            setupScript: .remembered,
            model: nil,
            target: .newSession
        )
        let url = ExternalActionURL.url(for: action)
        XCTAssertEqual(ExternalActionURL.action(from: url), action)
    }

    func testFileURLRoundTripsPathAndLine() {
        for line: Int? in [nil, 42] {
            let action = ExternalAction.openFile(
                host: .id(UUID()),
                path: "/srv/build dir/Sources/App:Release.swift",
                line: line
            )
            XCTAssertEqual(
                ExternalActionURL.action(from: ExternalActionURL.url(for: action)),
                action
            )
        }
    }

    func testFileURLRequiresAUsablePathAndPositiveLine() {
        for query in [
            "multiplex://open?host=devbox&action=file",
            "multiplex://open?host=devbox&action=file&path=",
            "multiplex://open?host=devbox&action=file&path=README.md&line=0",
            "multiplex://open?host=devbox&action=file&path=README.md&line=nope",
        ] {
            XCTAssertNil(ExternalActionURL.action(from: URL(string: query)!))
        }
    }

    func testAgentURLWithoutPromptRoundTrips() {
        let action = ExternalAction.openAgent(
            host: .id(UUID()), agent: .pi, prompt: nil,
            askForPrompt: false, directory: nil,
            setupScript: .remembered, model: nil, target: .newSession)
        XCTAssertEqual(
            ExternalActionURL.action(from: ExternalActionURL.url(for: action)),
            action
        )
    }

    func testAgentURLRoundTripsDirectoryIncludingHomeSentinel() {
        for directory in ["~/workspace/Multiplex", "~", "/srv/build dir"] {
            let action = ExternalAction.openAgent(
                host: .id(UUID()), agent: .claudeCode, prompt: "go",
                askForPrompt: true, directory: directory,
                setupScript: .remembered, model: nil, target: .newSession)
            XCTAssertEqual(
                ExternalActionURL.action(from: ExternalActionURL.url(for: action)),
                action
            )
        }
    }

    func testAgentURLRoundTripsEverySetupScriptSelection() {
        let scriptID = UUID()
        for selection: ExternalSetupScriptSelection in [
            .remembered, .none, .id(scriptID),
        ] {
            let action = ExternalAction.openAgent(
                host: .id(UUID()), agent: .codex, prompt: nil,
                askForPrompt: false, directory: nil,
                setupScript: selection, model: nil, target: .newSession
            )
            XCTAssertEqual(
                ExternalActionURL.action(from: ExternalActionURL.url(for: action)),
                action
            )
        }
    }

    func testAgentURLRoundTripsModel() {
        for model in ["opus", "sonnet[1m]", "google/gemini-2.5-pro:minimal"] {
            let action = ExternalAction.openAgent(
                host: .id(UUID()), agent: .claudeCode, prompt: "go",
                askForPrompt: false, directory: nil,
                setupScript: .remembered, model: model, target: .newSession)
            XCTAssertEqual(
                ExternalActionURL.action(from: ExternalActionURL.url(for: action)),
                action
            )
        }
    }

    func testMalformedModelParsesAsAgentDefaultNotAsFailure() {
        // Unlike a bad script token (strict — a wrong script runs arbitrary
        // text), a model the launch grammar rejects reads as omitted: the
        // action still runs, on the agent's own default.
        let url = URL(string:
            "multiplex://open?host=devbox&action=agent&agent=claude&model=--help")!
        XCTAssertEqual(
            ExternalActionURL.action(from: url),
            .openAgent(
                host: .named("devbox"), agent: .claudeCode, prompt: nil,
                askForPrompt: false, directory: nil,
                setupScript: .remembered, model: nil, target: .newSession)
        )
    }

    // MARK: Session target

    func testAgentURLRoundTripsSessionTargetForBothPlacements() {
        for placement: ExternalSessionPlacement in [.tab, .workspace] {
            let action = ExternalAction.openAgent(
                host: .id(UUID()), agent: .claudeCode, prompt: "go",
                askForPrompt: false, directory: "~/work dir",
                setupScript: .remembered, model: "opus",
                target: .existingSession(name: "deploy tools", placement: placement))
            XCTAssertEqual(
                ExternalActionURL.action(from: ExternalActionURL.url(for: action)),
                action
            )
        }
    }

    func testAgentSessionPlacementTokensWindowAliasAndFailSoftDefault() {
        // "window" is the tmux-natural spelling of the workspace branch
        // (the adapter maps herdr workspace → window)...
        let window = URL(string:
            "multiplex://open?host=devbox&action=agent&agent=claude&session=main&in=window")!
        guard case .openAgent(_, _, _, _, _, _, _, let aliased, _)? =
            ExternalActionURL.action(from: window)
        else { return XCTFail("expected openAgent") }
        XCTAssertEqual(aliased, .existingSession(name: "main", placement: .workspace))

        // ...while junk fails soft to the tab default, like `model`: the
        // performer validates the name against the live list anyway.
        let junk = URL(string:
            "multiplex://open?host=devbox&action=agent&agent=claude&session=main&in=explode")!
        guard case .openAgent(_, _, _, _, _, _, _, let defaulted, _)? =
            ExternalActionURL.action(from: junk)
        else { return XCTFail("expected openAgent") }
        XCTAssertEqual(defaulted, .existingSession(name: "main", placement: .tab))
    }

    func testAgentWithoutSessionParsesAsNewSessionAndEmptySessionToo() {
        for query in [
            "multiplex://open?host=devbox&action=agent&agent=claude",
            "multiplex://open?host=devbox&action=agent&agent=claude&session=",
            // A placement without a session names nowhere to place into.
            "multiplex://open?host=devbox&action=agent&agent=claude&in=workspace",
        ] {
            guard case .openAgent(_, _, _, _, _, _, _, let target, _)? =
                ExternalActionURL.action(from: URL(string: query)!)
            else { return XCTFail("expected openAgent for \(query)") }
            XCTAssertEqual(target, .newSession, query)
        }
    }

    // MARK: Parsing

    func testParsesHostNameWhenTokenIsNotAUUID() {
        let url = URL(string: "multiplex://open?host=devbox&action=shell")!
        XCTAssertEqual(
            ExternalActionURL.action(from: url),
            .openShell(host: .named("devbox"), sessionName: nil)
        )
    }

    func testActionDefaultsToShell() {
        let url = URL(string: "multiplex://open?host=devbox")!
        XCTAssertEqual(
            ExternalActionURL.action(from: url),
            .openShell(host: .named("devbox"), sessionName: nil)
        )
    }

    func testAgentAcceptsLaunchCommandAlias() {
        let url = URL(string: "multiplex://open?host=devbox&action=agent&agent=claude")!
        XCTAssertEqual(
            ExternalActionURL.action(from: url),
            .openAgent(
                host: .named("devbox"), agent: .claudeCode, prompt: nil,
                askForPrompt: false, directory: nil,
                setupScript: .remembered, model: nil, target: .newSession)
        )
    }

    func testAgentDefaultsToClaudeCode() {
        let url = URL(string: "multiplex://open?host=devbox&action=agent")!
        guard case .openAgent(_, let agent, _, _, _, _, _, _, _)? = ExternalActionURL.action(from: url) else {
            return XCTFail("expected openAgent")
        }
        XCTAssertEqual(agent, .claudeCode)
    }

    func testRejectsForeignSchemeMissingHostAndUnknownAction() {
        XCTAssertNil(ExternalActionURL.action(
            from: URL(string: "https://open?host=devbox")!))
        XCTAssertNil(ExternalActionURL.action(
            from: URL(string: "multiplex://open?action=shell")!))
        XCTAssertNil(ExternalActionURL.action(
            from: URL(string: "multiplex://open?host=devbox&action=explode")!))
        XCTAssertNil(ExternalActionURL.action(
            from: URL(string: "multiplex://elsewhere?host=devbox")!))
        XCTAssertNil(ExternalActionURL.action(
            from: URL(string: "multiplex://open?host=devbox&action=agent&script=echo%20oops")!))
    }

    func testFileConfirmationNamesPathAndLine() {
        let action = ExternalAction.openFile(
            host: .named("devbox"), path: "Sources/App.swift", line: 88)
        let confirmation = ExternalActionConfirmation.make(
            for: action, hostName: "Development Mac")
        XCTAssertEqual(confirmation.title, "Open file on Development Mac?")
        XCTAssertTrue(confirmation.message.contains("Sources/App.swift, line 88"))
        XCTAssertTrue(confirmation.message.contains("read-only"))
        XCTAssertEqual(confirmation.action, action)
    }

    @MainActor
    func testOpenFileRegistersViewerBeforeOpeningRoute() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var host = Host(name: "devbox", hostname: "127.0.0.1", username: "tester")
        host.workingDirs = ["/srv/project"]
        let store = HostStore(directory: directory, knownMirroredIDs: [])
        store.add(host)
        let workspace = TerminalWorkspace()
        var opened: TerminalWindowRoute?
        var failure: ExternalActionFailure?
        let context = ExternalActionRouter.Context(
            store: store,
            hub: ConnectionHub(),
            workspace: workspace,
            open: { opened = $0 },
            presentAgentPrompt: { _ in },
            presentFailure: { failure = $0 },
            presentConfirmation: { _ in }
        )

        await ExternalActionPerformer.perform(
            .openFile(host: .id(host.id), path: "Sources/App.swift", line: 42),
            context: context
        )

        let route = try XCTUnwrap(opened)
        let tab = try XCTUnwrap(route.tabs.first)
        XCTAssertEqual(tab.mode, .fileViewer(path: "Sources/App.swift"))
        XCTAssertNotNil(workspace.fileViewerController(for: tab.id))
        XCTAssertNil(failure)
        workspace.closeTab(tab.id)
    }

    // MARK: Session pick

    func testMostRecentSessionPicksNewestCreated() {
        let sessions = [
            TmuxSession(name: "old", windows: [], created: Date(timeIntervalSince1970: 100)),
            TmuxSession(name: "new", windows: [], created: Date(timeIntervalSince1970: 300)),
            TmuxSession(name: "mid", windows: [], created: Date(timeIntervalSince1970: 200)),
        ]
        XCTAssertEqual(ExternalActionPlan.mostRecentSession(in: sessions)?.name, "new")
    }

    func testMostRecentSessionBreaksCreationTiesByName() {
        let created = Date(timeIntervalSince1970: 100)
        let sessions = [
            TmuxSession(name: "alpha", windows: [], created: created),
            TmuxSession(name: "beta", windows: [], created: created),
        ]
        XCTAssertEqual(ExternalActionPlan.mostRecentSession(in: sessions)?.name, "beta")
    }

    func testMostRecentSessionEmptyIsNil() {
        XCTAssertNil(ExternalActionPlan.mostRecentSession(in: [])?.name)
    }

    // MARK: Setup script selection

    func testSetupScriptSelectionResolvesRememberedExplicitAndNone() {
        let remembered = SessionScript(name: "remembered", body: "source old")
        let explicit = SessionScript(name: "explicit", body: "source new")
        let available = [remembered, explicit]

        XCTAssertEqual(
            ExternalActionPlan.setupScript(
                for: .remembered,
                available: available,
                remembered: remembered
            ),
            remembered
        )
        XCTAssertEqual(
            ExternalActionPlan.setupScript(
                for: .id(explicit.id),
                available: available,
                remembered: remembered
            ),
            explicit
        )
        XCTAssertNil(ExternalActionPlan.setupScript(
            for: .none,
            available: available,
            remembered: remembered
        ))
    }

    func testDeletedExplicitSetupScriptFailsSoftToNone() {
        XCTAssertNil(ExternalActionPlan.setupScript(
            for: .id(UUID()),
            available: [],
            remembered: SessionScript(name: "remembered", body: "source old")
        ))
    }
}
