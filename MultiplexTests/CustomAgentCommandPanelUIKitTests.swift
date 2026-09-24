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
                "TRANSCRIPT": .more,
                "/new": .bar,
                "removed-command": .bar,
            ]
        )
        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.isBuiltInExpanded)
        XCTAssertEqual(controller.builtInPlacementOverrides, ["TRANSCRIPT": .more])
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

        // A stock BAR built-in: moving it to MORE records an override, moving
        // it back to its default clears the entry rather than pinning it.
        let transcript = try XCTUnwrap(
            AgentCommandSet.all(for: .codex).first { $0.id == "TRANSCRIPT" }
        )
        controller.setBuiltInPlacement(.bar, for: transcript)
        XCTAssertNil(controller.builtInPlacementOverrides[transcript.id])
        controller.setBuiltInPlacement(.more, for: transcript)
        XCTAssertEqual(controller.builtInPlacementOverrides[transcript.id], .more)
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
        var matches: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }

}
