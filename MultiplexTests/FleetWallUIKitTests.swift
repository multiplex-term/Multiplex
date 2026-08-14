import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class FleetWallUIKitTests: XCTestCase {
    func testNewSessionStateReprefillsOnlyUntouchedInputs() {
        let defaults = isolatedDefaults()
        let preferences = NewSessionPreferences(defaults: defaults)
        var host = makeHost()
        host.agentLaunchModels[AgentKind.codex.rawValue] = ["o3"]

        var state = NewSessionFormState(
            host: host,
            existingNames: [host.sessionBackend: ["main", "codex"]],
            preferences: preferences
        )
        XCTAssertEqual(state.launchMode, .shell)
        XCTAssertEqual(state.name, "main-2")
        XCTAssertEqual(state.commandPreview, "login shell")

        state.selectAgent(.codex)
        XCTAssertEqual(state.name, "codex-2")
        XCTAssertEqual(state.model, "")
        XCTAssertEqual(state.commandPreview, "codex")

        state.name = "release-watch"
        state.model = "o3"
        state.selectAgent(.pi)
        XCTAssertEqual(state.name, "release-watch")
        XCTAssertEqual(state.model, "o3")
        XCTAssertEqual(
            state.commandPreview,
            AgentKind.pi.launchCommand(model: "o3", initialPrompt: "")
        )

        state.selectShell()
        XCTAssertEqual(state.name, "release-watch")
        XCTAssertNil(state.agentToLaunch)
        XCTAssertNil(state.modelToLaunch)
        XCTAssertEqual(state.commandPreview, "login shell")
    }

    func testNewSessionStatePersistsOnlyOptedInLaunchChoices() {
        let defaults = isolatedDefaults()
        let preferences = NewSessionPreferences(defaults: defaults)
        var host = makeHost()
        let script = SessionScript(name: "Bootstrap", body: "source .venv/bin/activate")
        host.sessionScripts = [script]

        var state = NewSessionFormState(
            host: host,
            existingNames: [host.sessionBackend: []],
            preferences: preferences
        )
        state.selectAgent(.codex)
        state.model = "  o3  "
        state.initialPrompt = "Inspect the wall"
        state.script = script
        state.remembersLastLaunch = true
        state.savePreferences()

        XCTAssertTrue(preferences.remembersLastLaunch)
        XCTAssertEqual(preferences.rememberedAgent, .codex)
        XCTAssertEqual(preferences.rememberedModel(for: .codex), "o3")
        XCTAssertEqual(preferences.rememberedScript(for: host), script)

        let restored = NewSessionFormState(
            host: host,
            existingNames: [host.sessionBackend: []],
            preferences: preferences
        )
        XCTAssertEqual(restored.agentToLaunch, .codex)
        XCTAssertEqual(restored.name, "codex")
        XCTAssertEqual(restored.model, "o3")
        XCTAssertEqual(restored.script, script)
        XCTAssertEqual(restored.initialPrompt, "")
    }

    func testNativeNewSessionSheetKeepsMenusAccessibilityAndSubmission() throws {
        let defaults = isolatedDefaults()
        let preferences = NewSessionPreferences(defaults: defaults)
        var host = makeHost()
        let script = SessionScript(name: "Bootstrap", body: "source .venv/bin/activate")
        host.workingDirs = ["/srv/app", "/tmp"]
        host.sessionScripts = [script]
        host.agentLaunchModels[AgentKind.codex.rawValue] = ["o3", "gpt-5.1-codex"]
        preferences.save(
            remembersLastLaunch: true,
            agent: .codex,
            model: "o3",
            script: script,
            hostID: host.id
        )

        var submissions: [NewSessionSubmission] = []
        var dismissCount = 0
        let controller = NewSessionViewController(
            host: host,
            existingNames: [host.sessionBackend: ["codex"]],
            preferences: preferences,
            create: { submissions.append($0) }
        )
        controller.onDismiss = { dismissCount += 1 }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 680, height: 760)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.title, "New Session")
        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.title, "Cancel")
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.title, "Create & Attach")
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.style, .plain)
        XCTAssertNil(
            controller.navigationItem.rightBarButtonItem?.customView,
            "The system bar item must draw the beta's native Glass face"
        )
        XCTAssertEqual(NewSessionViewController.contentMaximumWidth, 600)
        XCTAssertEqual(NewSessionViewController.outerInset, 18)

        let headers = descendants(of: UIKitChassisLabel.self, in: controller.view)
            .filter { $0.accessibilityTraits.contains(.header) }
        XCTAssertEqual(headers.compactMap(\.accessibilityLabel), [
            "Target host",
            "Session identity",
            "Launch",
            "Setup script",
            "Directory",
        ])

        let name = try XCTUnwrap(descendants(of: UITextField.self, in: controller.view).first {
            $0.accessibilityIdentifier == "newSession.name"
        })
        XCTAssertEqual(name.text, "codex-2")
        XCTAssertEqual(name.autocorrectionType, .no)
        let model = try XCTUnwrap(descendants(of: UITextField.self, in: controller.view).first {
            $0.accessibilityIdentifier == "newSession.model"
        })
        XCTAssertEqual(model.text, "o3")
        XCTAssertEqual(model.accessibilityLabel, "Optional model for Codex")
        let modelMenu = try XCTUnwrap(descendants(of: UIButton.self, in: controller.view).first {
            $0.accessibilityIdentifier == "newSession.modelMenu"
        })
        XCTAssertEqual(menuTitles(modelMenu.menu), ["o3", "gpt-5.1-codex", "Agent default"])
        XCTAssertEqual(modelMenu.buttonType, .custom)
        XCTAssertNil(modelMenu.configuration)
        let scriptMenu = try XCTUnwrap(descendants(of: UIButton.self, in: controller.view).first {
            $0.accessibilityIdentifier == "newSession.script"
        })
        XCTAssertEqual(menuTitles(scriptMenu.menu), ["Bootstrap", "None"])
        let directoryMenu = try XCTUnwrap(descendants(of: UIButton.self, in: controller.view).first {
            $0.accessibilityIdentifier == "newSession.directory"
        })
        XCTAssertEqual(menuTitles(directoryMenu.menu), ["/srv/app", "/tmp", "Home"])

        let launchChoice = try XCTUnwrap(descendants(of: UIView.self, in: controller.view).first {
            $0.accessibilityIdentifier == "newSession.launchChoice"
        })
        XCTAssertEqual(
            launchChoice.backgroundColor?.resolvedColor(with: launchChoice.traitCollection),
            UIKitChassis.bezelHi.resolvedColor(with: launchChoice.traitCollection)
        )
        XCTAssertEqual(launchChoice.bounds.height, 34, accuracy: 0.5)
        let launchButtons = descendants(of: UIButton.self, in: launchChoice)
        XCTAssertEqual(launchButtons.count, 2)
        XCTAssertTrue(launchButtons.allSatisfy {
            $0.buttonType == .custom && $0.configuration == nil
        })
        let expectedBorder = UIKitChassis.bezelHi
            .resolvedColor(with: controller.traitCollection)
        for menuButton in [modelMenu, scriptMenu, directoryMenu] {
            XCTAssertEqual(
                menuButton.layer.borderColor.map { UIColor(cgColor: $0) },
                expectedBorder
            )
        }

        name.text = "release-watch"
        name.sendActions(for: .editingChanged)
        model.text = "gpt-5.1-codex"
        model.sendActions(for: .editingChanged)
        let prompt = try XCTUnwrap(descendants(of: UITextView.self, in: controller.view).first {
            $0.accessibilityIdentifier == "newSession.initialPrompt"
        })
        prompt.text = "Inspect the wall"
        prompt.delegate?.textViewDidChange?(prompt)
        send(controller.navigationItem.rightBarButtonItem)

        XCTAssertEqual(submissions, [NewSessionSubmission(
            backend: .tmux,
            name: "release-watch",
            agent: .codex,
            model: "gpt-5.1-codex",
            initialPrompt: "Inspect the wall",
            directory: "/srv/app",
            script: script,
            tabTargetSession: nil
        )])
        XCTAssertEqual(dismissCount, 1)
    }

    func testShellLaunchChoiceRemovesAgentFieldsAndTheirSectionSpace() throws {
        let host = makeHost()
        let shellPreferences = NewSessionPreferences(defaults: isolatedDefaults())
        let shell = NewSessionViewController(
            host: host,
            existingNames: [host.sessionBackend: []],
            preferences: shellPreferences,
            create: { _ in }
        )
        shell.loadViewIfNeeded()
        shell.view.frame = CGRect(x: 0, y: 0, width: 640, height: 760)
        shell.view.layoutIfNeeded()

        let shellSection = try XCTUnwrap(descendants(of: UIView.self, in: shell.view)
            .first { $0.accessibilityIdentifier == "newSession.launchSection" })
        let shellFields = try XCTUnwrap(descendants(of: UIView.self, in: shell.view)
            .first { $0.accessibilityIdentifier == "newSession.agentFields" })
        XCTAssertTrue(
            shellFields.superview?.isHidden == true,
            "SHELL must remove the optional agent row's wrapper, not merely blank its contents"
        )

        let agentPreferences = NewSessionPreferences(defaults: isolatedDefaults())
        agentPreferences.save(
            remembersLastLaunch: true,
            agent: .codex,
            model: nil,
            script: nil,
            hostID: host.id
        )
        let agent = NewSessionViewController(
            host: host,
            existingNames: [host.sessionBackend: []],
            preferences: agentPreferences,
            create: { _ in }
        )
        agent.loadViewIfNeeded()
        agent.view.frame = CGRect(x: 0, y: 0, width: 640, height: 760)
        agent.view.layoutIfNeeded()

        let agentSection = try XCTUnwrap(descendants(of: UIView.self, in: agent.view)
            .first { $0.accessibilityIdentifier == "newSession.launchSection" })
        let agentFields = try XCTUnwrap(descendants(of: UIView.self, in: agent.view)
            .first { $0.accessibilityIdentifier == "newSession.agentFields" })
        XCTAssertFalse(agentFields.superview?.isHidden ?? true)
        XCTAssertGreaterThan(
            agentSection.bounds.height - shellSection.bounds.height,
            80,
            "The SHELL layout should collapse the complete model/prompt row like the legacy conditional"
        )
    }

    func testEquivalentWallUpdatePreservesHostMenuSourceAndLegacyBadgeMetrics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetWallMenuIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = makeHost()
        try JSONEncoder().encode([host]).write(
            to: directory.appendingPathComponent("hosts.json"),
            options: .atomic
        )

        let store = HostStore(directory: directory, knownMirroredIDs: [])
        let hub = ConnectionHub()
        let network = NetworkChangeMonitor()
        let workspace = TerminalWorkspace()
        var configuration = FleetWallConfiguration(
            store: store,
            hub: hub,
            networkChanges: network,
            workspace: workspace,
            terminalOpener: TerminalRouteOpener(destination: .window, action: { _ in }),
            presentation: .shellRail,
            selectedTerminal: nil,
            shellSafeArea: .zero,
            reduceMotion: true,
            sceneIsActive: false,
            addHost: {},
            editHost: { _ in },
            openSettings: {},
            openFAQ: {}
        )
        let controller = FleetWallViewController(configuration: configuration)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        controller.view.layoutIfNeeded()

        let original = try XCTUnwrap(descendants(of: UIButton.self, in: controller.view).first {
            $0.accessibilityLabel == "Host options for devbox"
        })
        let originalMenu = try XCTUnwrap(original.menu)
        XCTAssertEqual(
            original.intrinsicContentSize,
            CGSize(
                width: ceil(18 + (10 * Theme.typeScale)),
                height: ceil(10 + (10 * Theme.typeScale))
            )
        )

        // Shell layout updates replace callback values even when every
        // rendered host/menu field is unchanged.
        configuration.openFAQ = { _ = host.id }
        configuration.shellSafeArea = UIEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
        controller.update(configuration: configuration)
        controller.view.layoutIfNeeded()

        let updated = try XCTUnwrap(descendants(of: UIButton.self, in: controller.view).first {
            $0.accessibilityLabel == "Host options for devbox"
        })
        XCTAssertTrue(updated === original)
        XCTAssertTrue(updated.menu === originalMenu)
    }

    func testStandardHostRailFacesKeepLegacyGeometryWithoutNativeGrounds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetWallHostRailGeometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = makeHost()
        try JSONEncoder().encode([host]).write(
            to: directory.appendingPathComponent("hosts.json"),
            options: .atomic
        )

        let configuration = FleetWallConfiguration(
            store: HostStore(directory: directory, knownMirroredIDs: []),
            hub: ConnectionHub(),
            networkChanges: NetworkChangeMonitor(),
            workspace: TerminalWorkspace(),
            terminalOpener: TerminalRouteOpener(destination: .window, action: { _ in }),
            presentation: .standard,
            selectedTerminal: nil,
            shellSafeArea: .zero,
            reduceMotion: true,
            sceneIsActive: false,
            addHost: {},
            editHost: { _ in },
            openSettings: {},
            openFAQ: {}
        )
        let controller = FleetWallViewController(configuration: configuration)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        controller.view.layoutIfNeeded()

        let shell = try XCTUnwrap(descendants(of: UIKitChassisChip.self, in: controller.view)
            .first { $0.accessibilityLabel == "Open shell on devbox" })
        let menu = try XCTUnwrap(descendants(of: UIButton.self, in: controller.view)
            .first { $0.accessibilityLabel == "Host options for devbox" })
        let caption = UILabel()
        caption.attributedText = NSAttributedString(
            string: "SHELL",
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.1,
            ]
        )
        XCTAssertEqual(shell.intrinsicContentSize, CGSize(
            width: ceil(caption.intrinsicContentSize.width + 18),
            height: ceil(caption.intrinsicContentSize.height + 10)
        ))
        XCTAssertEqual(menu.intrinsicContentSize, CGSize(
            width: ceil(10 * Theme.typeScale + 18),
            height: ceil(10 * Theme.typeScale + 10)
        ))
        XCTAssertTrue(shell.superview === menu.superview)
        let controls = try XCTUnwrap(shell.superview as? UIStackView)
        XCTAssertEqual(controls.alignment, .center)
        XCTAssertEqual(controls.arrangedSubviews.count, 3)
        for face in controls.arrangedSubviews {
            XCTAssertEqual(
                face.frame.midY,
                shell.frame.midY,
                accuracy: 0.5,
                "CONNECTED, SHELL, and overflow must share one centerline"
            )
        }
        XCTAssertEqual(menu.frame.minX - shell.frame.maxX, 14, accuracy: 0.5)
        XCTAssertEqual(
            shell.frame.midY,
            menu.frame.midY,
            accuracy: 0.5,
            "SHELL and the overflow badge must remain vertically centered"
        )
        XCTAssertTrue(shell.forFirstBaselineLayout is UILabel)
        XCTAssertEqual(menu.buttonType, .custom)
        XCTAssertNil(menu.configuration)
        XCTAssertEqual(
            shell.backgroundColor?.resolvedColor(with: controller.traitCollection),
            UIKitChassis.chassis.resolvedColor(with: controller.traitCollection)
        )
        XCTAssertEqual(
            menu.backgroundColor?.resolvedColor(with: controller.traitCollection),
            UIKitChassis.chassis.resolvedColor(with: controller.traitCollection)
        )
        let expectedBorder = UIKitChassis.bezelHi.resolvedColor(
            with: controller.traitCollection
        )
        XCTAssertEqual(
            shell.layer.borderColor.map { UIColor(cgColor: $0) },
            expectedBorder
        )
        XCTAssertEqual(
            menu.layer.borderColor.map { UIColor(cgColor: $0) },
            expectedBorder
        )
        // STANDBY keeps the connected-only SHELL face in the row at zero
        // alpha, exactly like SwiftUI's opacity slot; phase changes cannot
        // resize or shift the host rail.
        XCTAssertEqual(shell.alpha, 0)
        XCTAssertFalse(shell.isUserInteractionEnabled)
    }

    func testSessionTileRendersLiveAttentionAndNativeContextActions() {
        let session = makeSession()
        var attaches = 0
        let tile = FleetSessionTileView()
        tile.configure(FleetSessionTileConfiguration(
            hostID: UUID(),
            session: session,
            lines: ["$ codex", "Waiting for approval…"],
            attention: .needsYou(.permission),
            usesTmuxAttentionFallback: true,
            hasOpenTab: true,
            sessionBackend: .tmux,
            showsBackendIdentity: false,
            compact: false,
            selected: true,
            duplicateAttachTitle: "Attach in New Window",
            openTabAccessibilityText: "Shows its open window",
            attach: { attaches += 1 },
            attachNewWindow: {},
            newHerdrTab: {},
            delete: {},
            droppedSession: { _ in }
        ))
        tile.frame = CGRect(x: 0, y: 0, width: 360, height: 190)
        tile.layoutIfNeeded()

        XCTAssertEqual(tile.layer.borderWidth, 1.5)
        XCTAssertTrue(tile.accessibilityLabel?.contains("agent needs your input") == true)
        XCTAssertTrue(tile.accessibilityLabel?.contains("Shows its open window") == true)
        XCTAssertTrue(tile.accessibilityActivate())
        XCTAssertEqual(attaches, 1)
        let menu = tile.menuProvider?()
        XCTAssertEqual(menuTitles(menu), ["Attach in New Window", "Delete Session…"])

        let copy = visibleText(in: tile)
        XCTAssertTrue(copy.contains("WAITING FOR APPROVAL…"))
        XCTAssertTrue(copy.contains("NEEDS YOU"))
        XCTAssertTrue(copy.contains("LIVE"))
    }

    func testCrowdedLiveSessionTileKeepsTelemetryOutsideTheLamp() throws {
        let tile = FleetSessionTileView()
        tile.configure(FleetSessionTileConfiguration(
            hostID: UUID(),
            session: makeSession(name: "long-running-session"),
            lines: ["$ codex", "Working…"],
            attention: .busy,
            usesTmuxAttentionFallback: true,
            hasOpenTab: true,
            sessionBackend: .tmux,
            showsBackendIdentity: false,
            compact: false,
            selected: false,
            duplicateAttachTitle: "Attach in New Window",
            openTabAccessibilityText: "Shows its open window",
            attach: {},
            attachNewWindow: {},
            newHerdrTab: {},
            delete: {},
            droppedSession: { _ in }
        ))
        // Deterministically reproduce the pressure from iOS-on-Mac's 1.3×
        // type boost: the trailing telemetry wins by one priority point, but
        // the ATTACH/LIVE overlay must still reserve its complete live face.
        tile.frame = CGRect(x: 0, y: 0, width: 220, height: 190)
        tile.layoutIfNeeded()

        let live = try XCTUnwrap(descendants(of: UIKitTallyLamp.self, in: tile).first {
            $0.accessibilityLabel == "live"
        })
        let telemetry = try XCTUnwrap(descendants(of: UILabel.self, in: tile).first {
            $0.text?.hasPrefix("1 WIN") == true
        })
        telemetry.setContentCompressionResistancePriority(
            UILayoutPriority(UILayoutPriority.defaultHigh.rawValue + 1),
            for: .horizontal
        )
        tile.setNeedsLayout()
        tile.layoutIfNeeded()

        let liveSlot = try XCTUnwrap(live.superview)
        XCTAssertLessThanOrEqual(
            live.frame.maxX,
            liveSlot.bounds.maxX,
            "The LIVE lamp must stay inside the ATTACH/LIVE overlay slot"
        )
        let liveFrame = live.convert(live.bounds, to: tile)
        let telemetryFrame = telemetry.convert(telemetry.bounds, to: tile)
        XCTAssertLessThanOrEqual(
            liveFrame.maxX,
            telemetryFrame.minX,
            "The LIVE lamp must reserve its full width instead of painting over telemetry"
        )
    }

    /// herdr states no client count, so a herdr tile's lamp answers for the
    /// one client the app can verify: its own open terminal tab. Without one
    /// the tile keeps offering ATTACH rather than claiming a state nothing
    /// reported.
    func testHerdrNewSessionSheetOffersTheDirectoryChoice() throws {
        var host = makeHost()
        host.sessionBackend = .herdr
        host.workingDirs = ["/srv/app"]
        let controller = NewSessionViewController(
            host: host,
            existingNames: [host.sessionBackend: []]
        ) { _ in }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 680, height: 760)
        controller.view.layoutIfNeeded()

        let headers = descendants(of: UIKitChassisLabel.self, in: controller.view)
            .filter { $0.accessibilityTraits.contains(.header) }
        XCTAssertTrue(
            headers.compactMap(\.accessibilityLabel).contains("Directory"),
            "the herdr mint roots a session's world — the picker is truthful "
                + "on both backends"
        )
    }

    func testNewSessionTabTargetIsHerdrOnlyAndNeedsNoName() {
        let preferences = NewSessionPreferences(defaults: isolatedDefaults())
        var host = makeHost()
        host.sessionBackend = .herdr
        var state = NewSessionFormState(
            host: host,
            existingNames: [host.sessionBackend: ["main", "deploy"]],
            preferences: preferences
        )
        XCTAssertEqual(state.tabTargetChoices, ["main", "deploy"])
        XCTAssertNil(state.tabTargetSession)
        XCTAssertEqual(state.directoryFallbackTitle, "Home")

        state.name = "   "
        XCTAssertFalse(state.canSubmit)
        state.selectTabTarget("deploy")
        XCTAssertTrue(state.canSubmit, "A tab needs no name — herdr numbers it")
        XCTAssertEqual(state.submission.tabTargetSession, "deploy")
        XCTAssertEqual(state.directoryFallbackTitle, "Focused Pane")
        XCTAssertTrue(state.targetDetail.contains("deploy"))

        state.selectTabTarget("gone")
        XCTAssertNil(
            state.tabTargetSession,
            "Only a session the probe listed may become a tab target"
        )

        let tmuxState = NewSessionFormState(
            host: makeHost(),
            existingNames: [host.sessionBackend: ["main"]],
            preferences: preferences
        )
        XCTAssertTrue(
            tmuxState.tabTargetChoices.isEmpty,
            "tmux windows belong to the prefix keys — the deck mint stays session-first"
        )
    }

    func testHerdrNewSessionSheetCreatesRowSwapsTheMintForATab() throws {
        var host = makeHost()
        host.sessionBackend = .herdr
        var submissions: [NewSessionSubmission] = []
        let controller = NewSessionViewController(
            host: host,
            existingNames: [host.sessionBackend: ["main"]],
            preferences: NewSessionPreferences(defaults: isolatedDefaults()),
            create: { submissions.append($0) }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 680, height: 760)
        controller.view.layoutIfNeeded()

        let creates = try XCTUnwrap(descendants(of: UIButton.self, in: controller.view).first {
            $0.accessibilityIdentifier == "newSession.creates"
        })
        XCTAssertEqual(menuTitles(creates.menu), ["New Session", "Tab in “main”"])

        let name = try XCTUnwrap(descendants(of: UITextField.self, in: controller.view).first {
            $0.accessibilityIdentifier == "newSession.name"
        })
        XCTAssertFalse(isEffectivelyHidden(name, below: controller.view))

        let tabAction = try XCTUnwrap(flattenedActions(creates.menu).first {
            $0.title == "Tab in “main”"
        })
        tabAction.performWithSender(nil, target: nil)
        controller.view.layoutIfNeeded()

        XCTAssertTrue(
            isEffectivelyHidden(name, below: controller.view),
            "A tab needs no name — the identity section leaves with the choice"
        )
        send(controller.navigationItem.rightBarButtonItem)
        XCTAssertEqual(submissions.map(\.tabTargetSession), ["main"])

        // A tmux host never grows the row.
        let tmux = NewSessionViewController(
            host: makeHost(),
            existingNames: [host.sessionBackend: ["main"]],
            preferences: NewSessionPreferences(defaults: isolatedDefaults()),
            create: { _ in }
        )
        tmux.loadViewIfNeeded()
        XCTAssertTrue(descendants(of: UIButton.self, in: tmux.view).allSatisfy {
            $0.accessibilityIdentifier != "newSession.creates"
        })
    }

    func testHerdrSessionTileLampFollowsThisAppsOwnOpenTab() {
        // The record herdr's adapter produces: no clients, ever.
        var session = makeSession(name: "main")
        session.clientCount = 0

        func tile(hasOpenTab: Bool) -> FleetSessionTileView {
            let tile = FleetSessionTileView()
            tile.configure(FleetSessionTileConfiguration(
                hostID: UUID(),
                session: session,
                lines: ["$ herdr"],
                attention: nil,
                usesTmuxAttentionFallback: false,
                hasOpenTab: hasOpenTab,
                sessionBackend: .herdr,
                showsBackendIdentity: false,
                compact: false,
                selected: false,
                duplicateAttachTitle: "Attach in New Window",
                openTabAccessibilityText: "Shows its open window",
                attach: {},
                attachNewWindow: {},
                newHerdrTab: {},
                delete: {},
                droppedSession: { _ in }
            ))
            tile.frame = CGRect(x: 0, y: 0, width: 360, height: 190)
            tile.layoutIfNeeded()
            return tile
        }

        let open = tile(hasOpenTab: true)
        XCTAssertEqual(
            menuTitles(open.menuProvider?()),
            ["Attach in New Window", "New Tab in Workspace", "Delete Session…"],
            "A herdr tile carries the terminal window's + TAB row"
        )
        XCTAssertTrue(shownText(in: open).contains("LIVE"))
        XCTAssertFalse(shownText(in: open).contains("ATTACH"))
        XCTAssertTrue(open.accessibilityLabel?.contains("live") == true)

        let closed = tile(hasOpenTab: false)
        XCTAssertFalse(shownText(in: closed).contains("LIVE"))
        XCTAssertTrue(shownText(in: closed).contains("ATTACH"))
        XCTAssertTrue(closed.accessibilityLabel?.contains("not attached") == true)

        // A tmux tile still reads the probe: an open tab is not what makes
        // it live, and a client attached elsewhere still does.
        XCTAssertTrue(Host.SessionBackend.tmux.isSessionLive(
            clientCount: 1, hasOpenTab: false))
        XCTAssertFalse(Host.SessionBackend.tmux.isSessionLive(
            clientCount: 0, hasOpenTab: true))
    }

    func testSessionTileDragIsLocalStableAndHasNoBrightPreviewPlatter() throws {
        let hostID = UUID()
        let sourceSession = makeSession(name: "agent")
        let targetSession = makeSession(name: "deploy")
        var dropped: [String] = []

        func makeTile(
            session: TmuxSession,
            droppedSession: @escaping (String) -> Void
        ) -> FleetSessionTileView {
            let tile = FleetSessionTileView()
            tile.configure(FleetSessionTileConfiguration(
                hostID: hostID,
                session: session,
                lines: ["$ tmux"],
                attention: nil,
                usesTmuxAttentionFallback: true,
                hasOpenTab: false,
                sessionBackend: .tmux,
                showsBackendIdentity: false,
                compact: false,
                selected: false,
                duplicateAttachTitle: "Attach in New Window",
                openTabAccessibilityText: "",
                attach: {},
                attachNewWindow: {},
                newHerdrTab: {},
                delete: {},
                droppedSession: droppedSession
            ))
            tile.frame = CGRect(x: 0, y: 0, width: 360, height: 190)
            tile.layoutIfNeeded()
            return tile
        }

        let source = makeTile(session: sourceSession, droppedSession: { _ in })
        let target = makeTile(session: targetSession, droppedSession: { dropped.append($0) })
        let drag = try XCTUnwrap(
            source.interactions.compactMap { $0 as? UIDragInteraction }.first
        )
        let dragSession = FleetDragSessionStub()
        let items = source.dragInteraction(drag, itemsForBeginning: dragSession)
        dragSession.items = items
        let item = try XCTUnwrap(items.first)
        let preview = try XCTUnwrap(item.previewProvider?())

        XCTAssertEqual(preview.parameters.backgroundColor, UIColor.clear)
        XCTAssertEqual(preview.parameters.visiblePath?.bounds, source.bounds)
        XCTAssertEqual(preview.parameters.shadowPath?.bounds, source.bounds)
        XCTAssertTrue(source.dragInteraction(
            drag,
            sessionIsRestrictedToDraggingApplication: dragSession
        ))
        XCTAssertTrue(source.dragInteraction(
            drag,
            prefersFullSizePreviewsFor: dragSession
        ))

        let drop = try XCTUnwrap(
            target.interactions.compactMap { $0 as? UIDropInteraction }.first
        )
        let dropSession = FleetDropSessionStub(
            items: items,
            localDragSession: dragSession
        )
        XCTAssertEqual(
            target.dropInteraction(drop, sessionDidUpdate: dropSession).operation,
            .move
        )
        target.dropInteraction(drop, performDrop: dropSession)
        // The reorder payload is the dragged tile's `SessionKey.storageKey`,
        // not its bare name: a mixed host's saved order is a list of these,
        // and two backends can hold the same name.
        XCTAssertEqual(dropped, [sourceSession.id.storageKey])

        let sourceDrop = try XCTUnwrap(
            source.interactions.compactMap { $0 as? UIDropInteraction }.first
        )
        XCTAssertEqual(
            source.dropInteraction(sourceDrop, sessionDidUpdate: dropSession).operation,
            .forbidden,
            "The source tile is not a destination"
        )
    }

    func testSessionTilePressSurvivesThePointerDragOnIOSAppOnMac() throws {
        XCTAssertTrue(
            FleetTileDragPolicy.allowsPointerDragBeforeLiftDelay(isIOSAppOnMac: false)
        )
        XCTAssertFalse(
            FleetTileDragPolicy.allowsPointerDragBeforeLiftDelay(isIOSAppOnMac: true),
            "A drag armed at mouse-down fails the tile's tap recognizer, "
                + "leaving the context menu as the only way to attach"
        )

        let tile = FleetSessionTileView()
        var attached = 0
        tile.configure(FleetSessionTileConfiguration(
            hostID: UUID(),
            session: makeSession(),
            lines: ["$ tmux"],
            attention: nil,
            usesTmuxAttentionFallback: true,
            hasOpenTab: false,
            sessionBackend: .tmux,
            showsBackendIdentity: false,
            compact: false,
            selected: false,
            duplicateAttachTitle: "Attach in New Window",
            openTabAccessibilityText: "",
            attach: { attached += 1 },
            attachNewWindow: {},
            newHerdrTab: {},
            delete: {},
            droppedSession: { _ in }
        ))

        XCTAssertTrue(
            tile.gestureRecognizers?.contains { $0 is UITapGestureRecognizer } ?? false,
            "The press is a tap recognizer, so the drag must not arm before its lift"
        )
        XCTAssertTrue(tile.accessibilityActivate())
        XCTAssertEqual(attached, 1)

        #if compiler(>=6.4)
        if #available(iOS 27.0, visionOS 27.0, *) {
            let drag = try XCTUnwrap(
                tile.interactions.compactMap { $0 as? UIDragInteraction }.first
            )
            // Unset on Mac, where UIKit's own default is already the safe one.
            XCTAssertEqual(
                drag.allowsPointerDragBeforeLiftDelay,
                FleetTileDragPolicy.allowsPointerDragBeforeLiftDelay
            )
        }
        #endif
    }

    func testEmptyFleetWallMountsOnlyNativeControllersAndAwaitingAction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetWallUIKitTests-\(UUID().uuidString)")
        let store = HostStore(directory: directory, knownMirroredIDs: [])
        let hub = ConnectionHub()
        let workspace = TerminalWorkspace()
        let network = NetworkChangeMonitor()
        var addCount = 0
        let configuration = FleetWallConfiguration(
            store: store,
            hub: hub,
            networkChanges: network,
            workspace: workspace,
            terminalOpener: TerminalRouteOpener(destination: .window, action: { _ in }),
            presentation: .standard,
            selectedTerminal: nil,
            shellSafeArea: .zero,
            reduceMotion: true,
            sceneIsActive: false,
            addHost: { addCount += 1 },
            editHost: { _ in },
            openSettings: {},
            openFAQ: {}
        )
        let controller = FleetWallContainerViewController(configuration: configuration)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        controller.view.layoutIfNeeded()

        XCTAssertFalse(controllerTree(controller).contains {
            String(describing: type(of: $0)).contains("UIHostingController")
        })
        XCTAssertTrue(visibleText(in: controller.view).contains("AWAITING SIGNAL"))
        let add = try XCTUnwrap(descendants(of: UIKitChassisChip.self, in: controller.view)
            .first { $0.accessibilityLabel == "Add host" })
        XCTAssertTrue(add.accessibilityActivate())
        XCTAssertEqual(addCount, 1)
    }

    #if !os(visionOS)
    func testClassicDeckActionsOptOutOfSharedNavigationBarBackground() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetWallNavigationChrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = FleetWallConfiguration(
            store: HostStore(directory: directory, knownMirroredIDs: []),
            hub: ConnectionHub(),
            networkChanges: NetworkChangeMonitor(),
            workspace: TerminalWorkspace(),
            terminalOpener: TerminalRouteOpener(destination: .window, action: { _ in }),
            presentation: .standard,
            selectedTerminal: nil,
            shellSafeArea: .zero,
            reduceMotion: true,
            sceneIsActive: false,
            addHost: {},
            editHost: { _ in },
            openSettings: {},
            openFAQ: {}
        )
        let controller = FleetWallContainerViewController(configuration: configuration)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        controller.view.layoutIfNeeded()

        let wall = try XCTUnwrap(controllerTree(controller).first {
            $0 is FleetWallViewController
        } as? FleetWallViewController)
        let item = try XCTUnwrap(wall.navigationItem.rightBarButtonItem)
        let customView = try XCTUnwrap(item.customView)
        // HOST · STATS · FAQ · SETTINGS (stats joins while collection is on,
        // its default).
        XCTAssertEqual(descendants(of: UIKitChassisChip.self, in: customView).count, 4)
        XCTAssertNotNil(descendants(of: UIKitChassisChip.self, in: customView)
            .first { $0.accessibilityLabel == "Connection stats" })
        if #available(iOS 26.0, *) {
            XCTAssertTrue(
                item.hidesSharedBackground,
                "The custom TALLY stack must not receive a shared Glass capsule"
            )
        }
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            XCTAssertTrue(
                item.isPaddingRemoved,
                "System bar padding must not inflate the exact TALLY stack geometry"
            )
        }
        #endif
    }
    #endif

    func testCompactPhoneHeaderKeepsIconCaptionsWhenTheyFit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetWallPhoneHeader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = FleetWallConfiguration(
            store: HostStore(directory: directory, knownMirroredIDs: []),
            hub: ConnectionHub(),
            networkChanges: NetworkChangeMonitor(),
            workspace: TerminalWorkspace(),
            terminalOpener: TerminalRouteOpener(destination: .shell, action: { _ in }),
            presentation: .shellCompact,
            selectedTerminal: nil,
            shellSafeArea: .zero,
            reduceMotion: true,
            sceneIsActive: false,
            addHost: {},
            editHost: { _ in },
            openSettings: {},
            openFAQ: {}
        )
        let controller = FleetWallViewController(configuration: configuration)
        controller.loadViewIfNeeded()
        // iPhone 17 Pro's 402pt canvas leaves a 350pt TALLY header after the
        // shell's 26pt side insets. That fits all three captioned actions.
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()

        let chips = descendants(of: UIKitChassisChip.self, in: controller.view)
        let add = try XCTUnwrap(chips.first { $0.accessibilityLabel == "Add host" })
        let faq = try XCTUnwrap(chips.first {
            $0.accessibilityLabel == "Frequently asked questions"
        })
        let settings = try XCTUnwrap(chips.first { $0.accessibilityLabel == "Settings" })
        XCTAssertEqual(visibleText(in: add), "HOST")
        XCTAssertEqual(visibleText(in: faq), "FAQ")
        XCTAssertEqual(visibleText(in: settings), "SETTINGS")
    }

    /// The feed's lifetime is the wall's visibility, not the scene's focus.
    /// Regression: it used to die on resign-active, so an iPad Stage Manager
    /// sibling taking focus stopped the deck probing while the user watched
    /// it — and the per-tick `BackgroundActivity` gate below it never ran.
    func testTheProbeFeedOutlivesTheSceneResigningActive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetWallFeedLifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONEncoder().encode([makeHost()]).write(
            to: directory.appendingPathComponent("hosts.json"),
            options: .atomic
        )

        var configuration = FleetWallConfiguration(
            store: HostStore(directory: directory, knownMirroredIDs: []),
            hub: ConnectionHub(),
            networkChanges: NetworkChangeMonitor(),
            workspace: TerminalWorkspace(),
            terminalOpener: TerminalRouteOpener(destination: .window, action: { _ in }),
            presentation: .shellRail,
            selectedTerminal: nil,
            shellSafeArea: .zero,
            reduceMotion: true,
            sceneIsActive: true,
            addHost: {},
            editHost: { _ in },
            openSettings: {},
            openFAQ: {}
        )
        let controller = FleetWallViewController(configuration: configuration)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        controller.view.layoutIfNeeded()
        controller.viewDidAppear(false)
        XCTAssertTrue(controller.isFeedRunningForTesting)

        configuration.sceneIsActive = false
        controller.update(configuration: configuration)
        XCTAssertTrue(
            controller.isFeedRunningForTesting,
            "a visible wall keeps probing; the per-tick gate decides, not the task's life"
        )

        controller.viewDidDisappear(false)
        XCTAssertFalse(
            controller.isFeedRunningForTesting,
            "leaving the screen is what ends a feed"
        )
    }

    private func makeHost() -> Host {
        Host(
            name: "devbox",
            hostname: "127.0.0.1",
            port: 2222,
            username: "dev"
        )
    }

    private func makeSession(name: String = "agent") -> TmuxSession {
        TmuxSession(
            name: name,
            windows: [
                TmuxWindow(
                    index: 0,
                    name: "codex",
                    isActive: true,
                    hasBell: true,
                    hasActivity: false,
                    agent: .codex,
                    paneTitle: "Action Required",
                    panes: [TmuxPane(
                        index: 0,
                        isActive: true,
                        tmuxID: "%1",
                        pid: 42,
                        tty: "ttys001",
                        command: "codex",
                        title: "Action Required",
                        agent: .codex
                    )]
                ),
            ],
            clientCount: 1,
            created: Date().addingTimeInterval(-7_200),
            tmuxID: "$1"
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "app.multiplexterm.multiplex.tests.fleet-wall.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func send(_ item: UIBarButtonItem?) {
        guard let item, let action = item.action else {
            return XCTFail("Missing navigation action")
        }
        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
    }

    private func flattenedActions(_ menu: UIMenu?) -> [UIAction] {
        guard let menu else { return [] }
        return menu.children.flatMap { child -> [UIAction] in
            if let action = child as? UIAction { return [action] }
            if let submenu = child as? UIMenu { return flattenedActions(submenu) }
            return []
        }
    }

    /// Whether any ancestor up to `root` hides the view — how a stack-hidden
    /// section's fields disappear without their own `isHidden` flipping.
    private func isEffectivelyHidden(_ view: UIView, below root: UIView) -> Bool {
        var current: UIView? = view
        while let checked = current, checked !== root {
            if checked.isHidden { return true }
            current = checked.superview
        }
        return false
    }

    private func menuTitles(_ menu: UIMenu?) -> [String] {
        guard let menu else { return [] }
        return menu.children.flatMap { child -> [String] in
            if let action = child as? UIAction { return [action.title] }
            if let submenu = child as? UIMenu { return menuTitles(submenu) }
            return []
        }
    }

    /// `visibleText` reads the whole label tree — the tile keeps both faces
    /// of its attach slot mounted so the row can't resize, so only this
    /// walk (which honours hidden/zero-alpha branches) can tell which one
    /// the eye actually sees.
    private func shownText(in root: UIView) -> String {
        guard !root.isHidden, root.alpha > 0 else { return "" }
        let own = (root as? UILabel).flatMap { $0.attributedText?.string ?? $0.text } ?? ""
        return ([own] + root.subviews.map { shownText(in: $0) })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .uppercased()
    }

    private func visibleText(in root: UIView) -> String {
        descendants(of: UILabel.self, in: root)
            .compactMap { $0.attributedText?.string ?? $0.text }
            .joined(separator: "\n")
            .uppercased()
    }

    private func controllerTree(_ root: UIViewController) -> [UIViewController] {
        [root] + root.children.flatMap { controllerTree($0) }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var result: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }
}

@MainActor
private final class FleetDragSessionStub: NSObject, UIDragSession {
    var localContext: Any?
    var items: [UIDragItem] = []
    let allowsMoveOperation = true
    let isRestrictedToDraggingApplication = true

    func location(in view: UIView) -> CGPoint { .zero }

    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
        false
    }

    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool {
        false
    }
}

@MainActor
private final class FleetDropSessionStub: NSObject, UIDropSession {
    let items: [UIDragItem]
    let localDragSession: UIDragSession?
    let allowsMoveOperation = true
    let isRestrictedToDraggingApplication = true
    var progressIndicatorStyle = UIDropSessionProgressIndicatorStyle.none
    let progress = Progress(totalUnitCount: 1)

    init(items: [UIDragItem], localDragSession: UIDragSession?) {
        self.items = items
        self.localDragSession = localDragSession
    }

    func location(in view: UIView) -> CGPoint { .zero }

    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
        false
    }

    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool {
        false
    }

    func loadObjects(
        ofClass aClass: NSItemProviderReading.Type,
        completion: @escaping ([NSItemProviderReading]) -> Void
    ) -> Progress {
        progress
    }
}
