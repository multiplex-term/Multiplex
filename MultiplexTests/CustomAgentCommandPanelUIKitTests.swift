import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class CustomAgentCommandPanelUIKitTests: XCTestCase {
    func testNativePanelStartsWithStableBlankDraftAndPreservesPanelContract() {
        let controller = makeController(commands: [])
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.drafts.commands.count, 1)
        XCTAssertEqual(controller.drafts.commands.first?.content, "")
        XCTAssertEqual(
            controller.fittingContentSize().width,
            CustomAgentCommandPanelViewController.preferredWidth
        )
        XCTAssertEqual(
            controller.preferredContentSize,
            controller.fittingContentSize()
        )
        XCTAssertNotNil(view("customCommands.title", in: controller.view))
        XCTAssertNotNil(view("customCommands.builtInAccordion", in: controller.view))
        XCTAssertEqual(
            descendants(of: UITextView.self, in: controller.view).first?.accessibilityLabel,
            "Command content"
        )
    }

    func testBuiltInAccordionRendersEveryCommandAndPlacementOverridesStayMinimal() throws {
        let controller = makeController(
            agent: .codex,
            builtInPlacements: [
                "STOP": .more,
                "/new": .bar,
                "removed-command": .bar,
            ]
        )
        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.isBuiltInExpanded)
        XCTAssertEqual(controller.builtInPlacementOverrides, ["STOP": .more])
        let accordion = try XCTUnwrap(
            control("customCommands.builtInAccordion", in: controller.view)
        )
        XCTAssertEqual(accordion.accessibilityLabel, "Built-in commands")
        XCTAssertEqual(accordion.accessibilityValue, "Collapsed")

        accordion.sendActions(for: .touchUpInside)
        XCTAssertTrue(controller.isBuiltInExpanded)
        XCTAssertEqual(
            control("customCommands.builtInAccordion", in: controller.view)?
                .accessibilityValue,
            "Expanded"
        )
        XCTAssertEqual(
            descendants(of: UIView.self, in: controller.view).filter {
                $0.accessibilityIdentifier?.hasPrefix("customCommands.placement.") == true
            }.count,
            AgentCommandSet.all(for: .codex).count
        )

        let stop = try XCTUnwrap(
            AgentCommandSet.all(for: .codex).first { $0.id == "STOP" }
        )
        controller.setBuiltInPlacement(.bar, for: stop)
        XCTAssertNil(controller.builtInPlacementOverrides[stop.id])
        controller.setBuiltInPlacement(.more, for: stop)
        XCTAssertEqual(controller.builtInPlacementOverrides[stop.id], .more)
    }

    func testPlacementChoiceMatchesPlainTallySegmentVisualContract() throws {
        let stop = try XCTUnwrap(
            AgentCommandSet.all(for: .codex).first { $0.id == "STOP" }
        )
        let controller = makeController(
            agent: .codex,
            builtInPlacements: [stop.id: .more]
        )
        controller.loadViewIfNeeded()
        controller.toggleBuiltInCommands()
        controller.view.frame = CGRect(x: 0, y: 0, width: 560, height: 720)
        controller.view.layoutIfNeeded()

        let choice = try XCTUnwrap(
            view("customCommands.placement.\(stop.id)", in: controller.view)
        )
        let segments = descendants(of: UIControl.self, in: choice).filter {
            $0.accessibilityLabel == "Bar" || $0.accessibilityLabel == "More"
        }
        let bar = try XCTUnwrap(segments.first { $0.accessibilityLabel == "Bar" })
        let more = try XCTUnwrap(segments.first { $0.accessibilityLabel == "More" })
        let segmentStack = try XCTUnwrap(
            descendants(of: UIStackView.self, in: choice).first {
                $0.arrangedSubviews.count == 2
                    && $0.arrangedSubviews.allSatisfy { $0 is UIControl }
            }
        )

        XCTAssertEqual(CustomCommandChoiceMetrics.height, 34)
        XCTAssertEqual(CustomCommandChoiceMetrics.selectionAnimationDuration, 0.14)
        XCTAssertEqual(segmentStack.axis, .horizontal)
        XCTAssertEqual(segmentStack.alignment, .fill)
        XCTAssertEqual(segmentStack.distribution, .fillEqually)
        XCTAssertEqual(segmentStack.spacing, CustomCommandChoiceMetrics.seam)
        XCTAssertTrue(choice.constraints.contains {
            $0.firstAttribute == .height
                && $0.relation == .equal
                && $0.constant == CustomCommandChoiceMetrics.height
        })
        XCTAssertEqual(bar.bounds.width, more.bounds.width, accuracy: 0.5)
        XCTAssertTrue(descendants(of: UIButton.self, in: choice).isEmpty)
        assertColor(choice.backgroundColor, equals: UIKitChassis.bezelHi, in: choice)
        XCTAssertFalse(bar.accessibilityTraits.contains(.selected))
        XCTAssertTrue(more.accessibilityTraits.contains(.selected))
        assertColor(bar.backgroundColor, equals: UIKitChassis.chassis, in: choice)
        assertColor(more.backgroundColor, equals: UIKitChassis.bezelHi, in: choice)
        assertColor(
            bar.layer.borderColor.map(UIColor.init(cgColor:)),
            equals: UIKitChassis.bezelHi,
            in: choice
        )
        assertColor(
            more.layer.borderColor.map(UIColor.init(cgColor:)),
            equals: UIKitChassis.signal2,
            in: choice
        )

        bar.sendActions(for: .touchUpInside)

        XCTAssertEqual(controller.resolvedPlacement(for: stop), .bar)
        XCTAssertTrue(bar.accessibilityTraits.contains(.selected))
        XCTAssertFalse(more.accessibilityTraits.contains(.selected))
        assertColor(bar.backgroundColor, equals: UIKitChassis.bezelHi, in: choice)
        assertColor(more.backgroundColor, equals: UIKitChassis.chassis, in: choice)
    }

    func testTextSwitchMoveDeleteAndAddMutateDraftsByStableID() throws {
        let first = CustomAgentCommand(content: "first")
        let second = CustomAgentCommand(content: "second", autoSubmit: false)
        let controller = makeController(commands: [first, second])
        controller.loadViewIfNeeded()

        let editor = try XCTUnwrap(
            descendants(of: UITextView.self, in: controller.view).first {
                $0.accessibilityIdentifier == "customCommands.content.\(first.id.uuidString)"
            }
        )
        editor.text = "edited\nover two lines"
        editor.delegate?.textViewDidChange?(editor)
        XCTAssertEqual(
            controller.drafts.command(id: first.id)?.content,
            "edited\nover two lines"
        )

        let submit = try XCTUnwrap(
            descendants(of: UIControl.self, in: row(first.id, in: controller.view)).first {
                $0.accessibilityIdentifier == "customCommands.switch.submit"
            }
        )
        XCTAssertEqual(submit.accessibilityValue, "On")
        submit.sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.drafts.command(id: first.id)?.autoSubmit, false)
        XCTAssertEqual(submit.accessibilityValue, "Off")

        let down = try XCTUnwrap(
            control("customCommands.moveDown.\(first.id.uuidString)", in: controller.view)
        )
        down.sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.drafts.commands.map(\.id), [second.id, first.id])

        let delete = try XCTUnwrap(
            control("customCommands.delete.\(first.id.uuidString)", in: controller.view)
        )
        delete.sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.drafts.commands.map(\.id), [second.id])

        let add = try XCTUnwrap(
            descendants(of: UIKitChassisChip.self, in: controller.view).first {
                $0.accessibilityIdentifier == "customCommands.add"
            }
        )
        XCTAssertTrue(add.accessibilityActivate())
        XCTAssertEqual(controller.drafts.commands.count, 2)
        XCTAssertEqual(controller.drafts.commands.last?.content, "")
    }

    func testDoneNormalizesCommandsAndPlacementsWhileCancelDoesNotSave() throws {
        let duplicateA = CustomAgentCommand(content: "  review this  ")
        let duplicateB = CustomAgentCommand(content: "review this")
        var savedCommands: [CustomAgentCommand]?
        var savedPlacements: [String: AgentCommandPlacement]?
        var cancelled = false
        let controller = CustomAgentCommandPanelViewController(
            agent: .claudeCode,
            commands: [duplicateA, duplicateB, CustomAgentCommand(content: " ")],
            builtInPlacements: ["/clear": .more, "/resume": .bar],
            save: {
                savedCommands = $0
                savedPlacements = $1
            },
            cancel: { cancelled = true }
        )
        controller.loadViewIfNeeded()

        let done = try XCTUnwrap(
            descendants(of: UIKitChassisChip.self, in: controller.view).first {
                $0.accessibilityIdentifier == "customCommands.done"
            }
        )
        XCTAssertTrue(done.accessibilityActivate())
        XCTAssertEqual(savedCommands?.map(\.content), ["review this"])
        XCTAssertEqual(savedPlacements, ["/clear": .more])
        XCTAssertFalse(cancelled)

        let cancel = try XCTUnwrap(
            descendants(of: UIKitChassisChip.self, in: controller.view).first {
                $0.accessibilityIdentifier == "customCommands.cancel"
            }
        )
        XCTAssertTrue(cancel.accessibilityActivate())
        XCTAssertTrue(cancelled)
    }

    func testManyRowsCapOnlyTheEditorScrollViewport() throws {
        let controller = makeController(commands: (0..<20).map {
            CustomAgentCommand(content: "command \($0)")
        })
        controller.loadViewIfNeeded()
        _ = controller.fittingContentSize()

        let scroll = try XCTUnwrap(
            descendants(of: UIScrollView.self, in: controller.view).first {
                $0.accessibilityIdentifier == "customCommands.scroll"
            }
        )
        XCTAssertEqual(
            scroll.constraints.first {
                $0.identifier == "customCommands.listHeight"
            }?.constant,
            CustomAgentCommandPanelViewController.maximumEditorHeight
        )
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertNotNil(view("customCommands.done", in: controller.view))
    }

    private func makeController(
        agent: AgentKind = .codex,
        commands: [CustomAgentCommand] = [CustomAgentCommand(content: "review")],
        builtInPlacements: [String: AgentCommandPlacement] = [:]
    ) -> CustomAgentCommandPanelViewController {
        CustomAgentCommandPanelViewController(
            agent: agent,
            commands: commands,
            builtInPlacements: builtInPlacements,
            save: { _, _ in },
            cancel: {}
        )
    }

    private func row(_ id: UUID, in root: UIView) -> UIView {
        view("customCommands.row.\(id.uuidString)", in: root) ?? root
    }

    private func control(_ identifier: String, in root: UIView) -> UIControl? {
        descendants(of: UIControl.self, in: root).first {
            $0.accessibilityIdentifier == identifier
        }
    }

    private func view(_ identifier: String, in root: UIView) -> UIView? {
        descendants(of: UIView.self, in: root).first {
            $0.accessibilityIdentifier == identifier
        }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches = root as? T == nil ? [] : [root as! T]
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }

    private func assertColor(
        _ actual: UIColor?,
        equals expected: UIColor,
        in view: UIView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = actual?.resolvedColor(with: view.traitCollection)
        let expected = expected.resolvedColor(with: view.traitCollection)
        XCTAssertTrue(actual?.isEqual(expected) == true, file: file, line: line)
    }
}
