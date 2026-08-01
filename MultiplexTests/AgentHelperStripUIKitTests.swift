import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class AgentHelperStripUIKitTests: XCTestCase {
    func testNativeRailKeepsCustomCommandsFirstAndRoutesEveryTap() throws {
        let custom = CustomAgentCommand(
            content: "review the diff",
            autoSubmit: false,
            showInBar: true
        )
        var sent: [AgentCommand] = []
        let controller = makeController(
            agent: .codex,
            customCommands: [custom],
            send: { sent.append($0) }
        )
        controller.loadViewIfNeeded()

        let controls = descendants(of: UIButton.self, in: controller.view)
        let customIndex = try XCTUnwrap(controls.firstIndex {
            $0.accessibilityIdentifier == "agentHelpers.custom.\(custom.id.uuidString)"
        })
        let firstBuiltInIndex = try XCTUnwrap(controls.firstIndex {
            $0.accessibilityIdentifier?.hasPrefix("agentHelpers.command.") == true
        })
        XCTAssertLessThan(customIndex, firstBuiltInIndex)

        let customButton = controls[customIndex]
        XCTAssertEqual(
            customButton.accessibilityLabel,
            "Custom command review the diff, type only"
        )
        customButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(sent, [custom.agentCommand])

        let builtIn = controls[firstBuiltInIndex]
        builtIn.sendActions(for: .touchUpInside)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.label.capitalized, builtIn.accessibilityLabel)
    }

    func testPlacementOverridesFeedBarAndMoreAndMenuKeepsCustomSection() {
        let custom = CustomAgentCommand(
            content: "explain failures",
            showInBar: false
        )
        let controller = makeController(
            agent: .claudeCode,
            builtInPlacements: ["/clear": .more, "/context": .bar],
            customCommands: [custom]
        )
        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.barBuiltInCommands.contains { $0.id == "/clear" })
        XCTAssertTrue(controller.barBuiltInCommands.contains { $0.id == "/context" })
        XCTAssertTrue(controller.moreBuiltInCommands.contains { $0.id == "/clear" })
        XCTAssertEqual(controller.moreCustomCommands, [custom])

        let menu = controller.makeMoreMenu()
        let titles = menuTitles(menu)
        XCTAssertTrue(titles.contains("/clear"))
        XCTAssertTrue(titles.contains("Custom"))
        XCTAssertTrue(titles.contains("explain failures"))
        XCTAssertTrue(titles.contains("Customize Commands…"))
    }

    func testEquivalentConfigurationPreservesAttachedMoreMenuAndCustomizeAction() throws {
        let controller = makeController(agent: .codex)
        controller.loadViewIfNeeded()

        let more = try XCTUnwrap(button("agentHelpers.more", in: controller.view))
        let menu = try XCTUnwrap(more.menu)
        let customize = try XCTUnwrap(menuAction("Customize Commands…", in: menu))
        XCTAssertTrue(more.showsMenuAsPrimaryAction)
        XCTAssertTrue(
            (more.actions(forTarget: more, forControlEvent: .touchUpInside) ?? []).isEmpty
        )

        var usedUpdatedCallback = false
        var equivalent = controller.configuration
        equivalent.send = { _ in }
        equivalent.saveCommandConfiguration = { _, _ in }
        equivalent.openPaywall = { usedUpdatedCallback = true }
        equivalent.isFocusOwner = { true }
        controller.update(configuration: equivalent)

        let updatedMore = try XCTUnwrap(button("agentHelpers.more", in: controller.view))
        let updatedMenu = try XCTUnwrap(updatedMore.menu)
        let updatedCustomize = try XCTUnwrap(menuAction(
            "Customize Commands…",
            in: updatedMenu
        ))
        XCTAssertTrue(updatedMore === more)
        XCTAssertTrue(updatedMenu === menu)
        XCTAssertTrue(updatedCustomize === customize)

        controller.perform(.openPaywall)
        XCTAssertTrue(usedUpdatedCallback)

        let custom = CustomAgentCommand(
            content: "explain the failures",
            showInBar: false
        )
        var changed = equivalent
        changed.customCommands = [custom]
        controller.update(configuration: changed)

        let changedMore = try XCTUnwrap(button("agentHelpers.more", in: controller.view))
        let changedMenu = try XCTUnwrap(changedMore.menu)
        XCTAssertFalse(changedMore === more)
        XCTAssertTrue(menuTitles(changedMenu).contains(custom.menuLabel))
    }

    func testEquivalentHistoryObservationPreservesHistoryAndMenuIdentities() throws {
        let controller = makeController(agent: .claudeCode)
        controller.loadViewIfNeeded()
        controller.applyHistoryAvailability(true)

        let more = try XCTUnwrap(button("agentHelpers.more", in: controller.view))
        let history = try XCTUnwrap(button("agentHelpers.history", in: controller.view))
        let menu = try XCTUnwrap(more.menu)
        let customize = try XCTUnwrap(menuAction("Customize Commands…", in: menu))

        controller.applyHistoryAvailability(true)

        let updatedMore = try XCTUnwrap(button("agentHelpers.more", in: controller.view))
        let updatedHistory = try XCTUnwrap(button(
            "agentHelpers.history",
            in: controller.view
        ))
        let updatedMenu = try XCTUnwrap(updatedMore.menu)
        let updatedCustomize = try XCTUnwrap(menuAction(
            "Customize Commands…",
            in: updatedMenu
        ))
        XCTAssertTrue(updatedMore === more)
        XCTAssertTrue(updatedHistory === history)
        XCTAssertTrue(updatedMenu === menu)
        XCTAssertTrue(updatedCustomize === customize)

        controller.applyHistoryAvailability(false)
        XCTAssertNil(button("agentHelpers.history", in: controller.view))
        XCTAssertFalse(try XCTUnwrap(button(
            "agentHelpers.more",
            in: controller.view
        )) === more)
    }

    func testLockedSurfaceIsPassiveUntilProChipAndHistoryLockRoutesPaywall() throws {
        var paywallCount = 0
        let controller = makeController(
            agent: .claudeCode,
            canShowCommands: false,
            historyLocked: true,
            openPaywall: { paywallCount += 1 }
        )
        controller.loadViewIfNeeded()

        let pro = try XCTUnwrap(button("agentHelpers.pro", in: controller.view))
        XCTAssertEqual(pro.accessibilityLabel, "Agent helpers Pro")
        pro.sendActions(for: .touchUpInside)
        XCTAssertEqual(paywallCount, 1)
        XCTAssertTrue(renderedText(in: controller.view).contains(
            "Free daily command taps return tomorrow"
        ))

        controller.applyHistoryAvailability(true)
        controller.perform(.history)
        XCTAssertEqual(paywallCount, 2)
    }

    func testHistoryOnlyAppearsForObservedClaudeCapability() {
        let claude = makeController(agent: .claudeCode)
        claude.loadViewIfNeeded()
        XCTAssertNil(button("agentHelpers.history", in: claude.view))
        claude.applyHistoryAvailability(true)
        XCTAssertEqual(
            button("agentHelpers.history", in: claude.view)?.accessibilityLabel,
            "Message history for Claude Code"
        )

        let codex = makeController(agent: .codex)
        codex.loadViewIfNeeded()
        XCTAssertFalse(codex.historyAvailable)
        XCTAssertNil(button("agentHelpers.history", in: codex.view))
    }

    func testDockedAndFloatingSizingPreserveTheTwoStripContracts() {
        let docked = makeController(contentSafeArea: UIEdgeInsets(
            top: 0,
            left: 20,
            bottom: 0,
            right: 18
        ))
        docked.loadViewIfNeeded()
        XCTAssertEqual(
            docked.fittingContentSize(for: 760),
            CGSize(width: 760, height: AgentHelperStripViewController.dockedHeight)
        )

        let floating = makeController(
            floating: true,
            floatingMaximumWidth: 420
        )
        floating.loadViewIfNeeded()
        let floatingSize = floating.fittingContentSize(for: 900)
        XCTAssertEqual(floatingSize.width, 420)
        XCTAssertGreaterThan(floatingSize.height, AgentHelperStripViewController.chipHeight)
        XCTAssertLessThan(floatingSize.height, AgentHelperStripViewController.dockedHeight)
        XCTAssertEqual(floating.view.layer.borderWidth, 1)
        XCTAssertEqual(floating.view.layer.cornerRadius, 12)
    }

    func testActionRouterForwardsCommandsPaywallAndSaveClosures() {
        var sent: AgentCommand?
        var paywall = false
        let command = AgentCommand.slash("review")
        let controller = makeController(
            send: { sent = $0 },
            openPaywall: { paywall = true }
        )
        controller.perform(.send(command))
        controller.perform(.openPaywall)
        XCTAssertEqual(sent, command)
        XCTAssertTrue(paywall)
    }

    private func makeController(
        agent: AgentKind = .codex,
        canShowCommands: Bool = true,
        builtInPlacements: [String: AgentCommandPlacement] = [:],
        customCommands: [CustomAgentCommand] = [],
        historyLocked: Bool = false,
        floating: Bool = false,
        floatingMaximumWidth: CGFloat? = nil,
        contentSafeArea: UIEdgeInsets = .zero,
        send: @escaping (AgentCommand) -> Void = { _ in },
        openPaywall: @escaping () -> Void = {}
    ) -> AgentHelperStripViewController {
        AgentHelperStripViewController(configuration: AgentHelperStripConfiguration(
            agent: agent,
            canShowCommands: canShowCommands,
            builtInPlacements: builtInPlacements,
            customCommands: customCommands,
            historyController: nil,
            historyLocked: historyLocked,
            floating: floating,
            floatingMaximumWidth: floatingMaximumWidth,
            contentSafeArea: contentSafeArea,
            send: send,
            saveCommandConfiguration: { _, _ in },
            openPaywall: openPaywall,
            isFocusOwner: { false }
        ))
    }

    private func button(_ identifier: String, in root: UIView) -> UIButton? {
        descendants(of: UIButton.self, in: root).first {
            $0.accessibilityIdentifier == identifier
        }
    }

    private func menuTitles(_ menu: UIMenu) -> [String] {
        [menu.title] + menu.children.flatMap { element -> [String] in
            if let submenu = element as? UIMenu { return menuTitles(submenu) }
            if let action = element as? UIAction { return [action.title] }
            return []
        }
    }

    private func menuAction(_ title: String, in menu: UIMenu) -> UIAction? {
        for element in menu.children {
            if let action = element as? UIAction, action.title == title {
                return action
            }
            if let submenu = element as? UIMenu,
               let action = menuAction(title, in: submenu)
            {
                return action
            }
        }
        return nil
    }

    private func renderedText(in root: UIView) -> [String] {
        descendants(of: UILabel.self, in: root).compactMap {
            $0.text ?? $0.attributedText?.string
        }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }
}
