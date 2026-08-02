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
            existingNames: ["main", "codex"],
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
            existingNames: [],
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
            existingNames: [],
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
            existingNames: ["codex"],
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
            name: "release-watch",
            agent: .codex,
            model: "gpt-5.1-codex",
            initialPrompt: "Inspect the wall",
            directory: "/srv/app",
            script: script
        )])
        XCTAssertEqual(dismissCount, 1)
    }

    func testShellLaunchChoiceRemovesAgentFieldsAndTheirSectionSpace() throws {
        let host = makeHost()
        let shellPreferences = NewSessionPreferences(defaults: isolatedDefaults())
        let shell = NewSessionViewController(
            host: host,
            existingNames: [],
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
            existingNames: [],
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
            compact: false,
            selected: true,
            duplicateAttachTitle: "Attach in New Window",
            openTabAccessibilityText: "Shows its open window",
            attach: { attaches += 1 },
            attachNewWindow: {},
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
        XCTAssertEqual(descendants(of: UIKitChassisChip.self, in: customView).count, 3)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(
                item.hidesSharedBackground,
                "The custom TALLY stack must not receive a shared Glass capsule"
            )
        }
        if #available(iOS 27.0, *) {
            XCTAssertTrue(
                item.isPaddingRemoved,
                "System bar padding must not inflate the exact TALLY stack geometry"
            )
        }
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

    private func makeHost() -> Host {
        Host(
            name: "devbox",
            hostname: "127.0.0.1",
            port: 2222,
            username: "dev"
        )
    }

    private func makeSession() -> TmuxSession {
        TmuxSession(
            name: "agent",
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

    private func menuTitles(_ menu: UIMenu?) -> [String] {
        guard let menu else { return [] }
        return menu.children.flatMap { child -> [String] in
            if let action = child as? UIAction { return [action.title] }
            if let submenu = child as? UIMenu { return menuTitles(submenu) }
            return []
        }
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
