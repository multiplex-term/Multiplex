import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class AgentPromptSheetUIKitTests: XCTestCase {
    func testFormStatePreservesSeedsAndLiveDescriptions() {
        let request = makeRequest(directory: nil, model: nil)
        var state = AgentPromptFormState(request: request)

        XCTAssertEqual(state.directory, "/srv/app")
        XCTAssertEqual(state.directoryLabel, "/srv/app")
        XCTAssertEqual(
            state.directoryDetail,
            "Starts in /srv/app. Choose Home to use the login shell's default."
        )
        XCTAssertEqual(state.model, "")
        XCTAssertEqual(state.modelDetail, "Uses Codex's own default model.")

        state.directory = "~"
        state.model = "  gpt-5.1-codex  "
        XCTAssertEqual(state.directoryLabel, "Home")
        XCTAssertEqual(
            state.directoryDetail,
            "Uses the host's login-shell home directory."
        )
        let expectedCommand = request.agent.launchCommand(
            model: "gpt-5.1-codex",
            initialPrompt: ""
        )
        XCTAssertEqual(
            state.modelDetail,
            "Launches as \(expectedCommand)."
        )
    }

    func testLaunchActionTrimsOptionalFieldsAndPreservesRouteChoices() {
        let scriptID = UUID()
        var request = makeRequest(directory: "~", model: " seeded ")
        request.setupScript = .id(scriptID)
        var state = AgentPromptFormState(request: request)
        state.prompt = " \n  Inspect the flaky test. \t\n"
        state.model = "  gpt-5.1-codex  "

        XCTAssertEqual(
            state.launchAction,
            .openAgent(
                host: .id(request.host.id),
                agent: .codex,
                prompt: "Inspect the flaky test.",
                askForPrompt: false,
                directory: "~",
                setupScript: .id(scriptID),
                model: "gpt-5.1-codex",
                target: .newSession
            )
        )

        state.prompt = " \n\t "
        state.model = "   "
        XCTAssertEqual(
            state.launchAction,
            .openAgent(
                host: .id(request.host.id),
                agent: .codex,
                prompt: nil,
                askForPrompt: false,
                directory: "~",
                setupScript: .id(scriptID),
                model: nil,
                target: .newSession
            )
        )
    }

    func testSessionTargetRidesResubmitAndNamesItselfInTheTitle() {
        var request = makeRequest(directory: nil, model: nil)
        request.target = .existingSession(name: "main", placement: .workspace)
        let state = AgentPromptFormState(request: request)

        // Where the launch types is part of what the person approves here.
        XCTAssertEqual(state.title, "Codex on devbox · main")
        guard case .openAgent(_, _, _, _, _, _, _, let target, _) = state.launchAction
        else { return XCTFail("expected openAgent") }
        XCTAssertEqual(target, .existingSession(name: "main", placement: .workspace))

        XCTAssertEqual(
            AgentPromptFormState(request: makeRequest(directory: nil, model: nil)).title,
            "Codex on devbox"
        )
    }

    func testNativeControllerPreservesLayoutMenusAccessibilityAndLaunch() {
        let request = makeRequest(directory: "~", model: nil)
        var submissions: [ExternalAction] = []
        var dismissCount = 0
        let controller = AgentPromptSheetViewController(
            request: request,
            submit: { submissions.append($0) }
        )
        controller.onDismiss = { dismissCount += 1 }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 720, height: 640)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.title, "Codex on devbox")
        XCTAssertEqual(controller.navigationItem.largeTitleDisplayMode, .never)
        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.title, "Cancel")
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.title, "Launch")
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.style, .plain)
        XCTAssertNil(controller.navigationItem.rightBarButtonItem?.customView)
        XCTAssertEqual(controller.contentStack.spacing, 18)
        XCTAssertEqual(AgentPromptSheetViewController.outerInset, 18)
        XCTAssertEqual(AgentPromptSheetViewController.contentMaximumWidth, 680)

        let headers = descendants(of: UIKitChassisLabel.self, in: controller.view)
            .filter { $0.accessibilityTraits.contains(.header) }
        XCTAssertEqual(headers.map(\.accessibilityLabel), [
            "First prompt", "Model", "Directory",
        ])

        let prompt = descendants(of: UITextView.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentPrompt.prompt"
        }
        XCTAssertEqual(prompt?.accessibilityLabel, "Prompt")
        XCTAssertEqual(prompt?.accessibilityHint, "What should Codex do?")

        let model = descendants(of: UITextField.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentPrompt.model"
        }
        XCTAssertEqual(model?.accessibilityLabel, "Optional model for Codex")
        XCTAssertEqual(model?.autocorrectionType, .no)
        XCTAssertEqual(
            model?.autocapitalizationType,
            UITextAutocapitalizationType.none
        )

        let modelMenu = descendants(of: UIButton.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentPrompt.modelMenu"
        }
        XCTAssertEqual(modelMenu?.accessibilityLabel, "Configured models for Codex")
        XCTAssertEqual(menuTitles(modelMenu?.menu), [
            "gpt-5.1-codex", "o3", "Agent default",
        ])

        let directory = descendants(of: UIButton.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentPrompt.directory"
        }
        XCTAssertEqual(directory?.accessibilityLabel, "Starting directory")
        XCTAssertEqual(directory?.accessibilityValue, "Home")
        XCTAssertEqual(menuTitles(directory?.menu), ["/srv/app", "/tmp", "Home"])

        prompt?.text = "  Fix the parser.  "
        if let prompt {
            prompt.delegate?.textViewDidChange?(prompt)
        }
        model?.text = "  o3  "
        model?.sendActions(for: .editingChanged)
        send(controller.navigationItem.rightBarButtonItem)

        XCTAssertEqual(submissions, [
            .openAgent(
                host: .id(request.host.id),
                agent: .codex,
                prompt: "Fix the parser.",
                askForPrompt: false,
                directory: "~",
                setupScript: .remembered,
                model: "o3",
                target: .newSession
            ),
        ])
        XCTAssertEqual(dismissCount, 1)

        controller.appAppearance = .light
        XCTAssertEqual(controller.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(navigation.overrideUserInterfaceStyle, .light)
        controller.appAppearance = .dark
        XCTAssertEqual(controller.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(navigation.overrideUserInterfaceStyle, .dark)
    }

    func testCancelDismissesWithoutSubmitting() {
        let request = makeRequest(directory: nil, model: nil)
        var submissions: [ExternalAction] = []
        var dismissCount = 0
        let controller = AgentPromptSheetViewController(
            request: request,
            submit: { submissions.append($0) }
        )
        controller.onDismiss = { dismissCount += 1 }
        controller.loadViewIfNeeded()

        send(controller.navigationItem.leftBarButtonItem)

        XCTAssertTrue(submissions.isEmpty)
        XCTAssertEqual(dismissCount, 1)
    }

    private func makeRequest(directory: String?, model: String?) -> AgentPromptRequest {
        var host = Host(
            name: "devbox",
            hostname: "127.0.0.1",
            username: "dev"
        )
        host.workingDirs = ["/srv/app", "/tmp"]
        host.agentLaunchModels[AgentKind.codex.rawValue] = ["gpt-5.1-codex", "o3"]
        return AgentPromptRequest(
            host: host,
            agent: .codex,
            directory: directory,
            setupScript: .remembered,
            model: model
        )
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

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var result: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }
}
