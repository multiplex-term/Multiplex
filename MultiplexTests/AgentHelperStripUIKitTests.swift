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

    func testTitleTapCollapsesToDotAndDotTapRestoresTheRail() throws {
        AgentHelperStripCollapse.shared.setCollapsed(false)
        defer { AgentHelperStripCollapse.shared.setCollapsed(false) }
        let controller = makeController(agent: .claudeCode)
        controller.loadViewIfNeeded()

        let title = try XCTUnwrap(
            descendants(of: UIControl.self, in: controller.view).first {
                $0.accessibilityIdentifier == "agentHelpers.agent"
            }
        )
        XCTAssertEqual(title.accessibilityLabel, "Hide Claude Code helpers")
        title.sendActions(for: .touchUpInside)

        XCTAssertTrue(AgentHelperStripCollapse.shared.isCollapsed)
        let dot = try XCTUnwrap(button("agentHelpers.dot", in: controller.view))
        XCTAssertEqual(dot.accessibilityLabel, "Show Claude Code helpers")
        XCTAssertNil(button("agentHelpers.more", in: controller.view))
        let diameter = AgentHelperStripViewController.collapsedDotDiameter
        XCTAssertEqual(
            controller.fittingContentSize(),
            CGSize(width: diameter, height: diameter)
        )

        dot.sendActions(for: .touchUpInside)
        XCTAssertFalse(AgentHelperStripCollapse.shared.isCollapsed)
        XCTAssertNotNil(button("agentHelpers.more", in: controller.view))
        XCTAssertNil(button("agentHelpers.dot", in: controller.view))
    }

    /// ✳ and ◆ draw through fallback fonts whose line metrics disagree with
    /// SF Mono's, so title/label centering visibly un-centered the mark.
    /// The dot centers rendered ink bounds instead — prove it in pixels.
    func testCollapsedDotCentersEveryAgentMarkOnItsInk() throws {
        AgentHelperStripCollapse.shared.setCollapsed(true)
        defer { AgentHelperStripCollapse.shared.setCollapsed(false) }
        for agent in AgentKind.allCases {
            let controller = makeController(agent: agent)
            controller.loadViewIfNeeded()
            let dot = try XCTUnwrap(button("agentHelpers.dot", in: controller.view))
            let diameter = AgentHelperStripViewController.collapsedDotDiameter
            dot.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.layoutIfNeeded()

            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(
                size: dot.bounds.size,
                format: format
            ).image { dot.layer.render(in: $0.cgContext) }
            let ink = try XCTUnwrap(
                inkBoundingBox(in: image),
                "\(agent) dot rendered no ink"
            )
            XCTAssertEqual(
                ink.midX, diameter / 2, accuracy: 1.5,
                "\(agent) mark off-center horizontally"
            )
            XCTAssertEqual(
                ink.midY, diameter / 2, accuracy: 1.5,
                "\(agent) mark off-center vertically"
            )
        }
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

    /// Bounding box, in points, of every pixel with visible alpha.
    private func inkBoundingBox(in image: UIImage) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 16 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let scale = image.scale
        return CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }
}
