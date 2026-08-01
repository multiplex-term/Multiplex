import Observation
import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class AgentHistoryPanelUIKitTests: XCTestCase {
    func testLoadingUnavailableAndEmptyStatesKeepTheNativeStatusLayout() {
        let controller = makeController()
        controller.loadViewIfNeeded()

        XCTAssertTrue(renderedText(in: controller.view).contains("READING SESSION FILE"))
        XCTAssertEqual(descendants(of: UIActivityIndicatorView.self, in: controller.view).count, 1)
        XCTAssertEqual(statusHeight(in: controller.view), 72)

        controller.applyHistoryStatus(.unavailable("SESSION FILE NOT FOUND"))
        XCTAssertTrue(renderedText(in: controller.view).contains("SESSION FILE NOT FOUND"))
        XCTAssertEqual(descendants(of: UIActivityIndicatorView.self, in: controller.view).count, 0)
        XCTAssertEqual(statusHeight(in: controller.view), 72)

        controller.applyHistoryStatus(.loaded(
            agent: .claudeCode,
            messages: [],
            jumpAvailable: true
        ))
        XCTAssertTrue(renderedText(in: controller.view).contains("NO MESSAGES YET"))
        XCTAssertEqual(statusHeight(in: controller.view), 72)
    }

    func testLoadedMessagesRenderNewestFirstExpandToSelectableFullTextAndCollapse() throws {
        let messages = [
            message(ordinal: 0, text: "older first line\nolder hidden line"),
            message(ordinal: 1, text: "newest first line\nnewest full second line"),
        ]
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.applyHistoryStatus(.loaded(
            agent: .claudeCode,
            messages: messages,
            jumpAvailable: false
        ))

        let messageControls = descendants(of: UIControl.self, in: controller.view)
            .filter { $0.accessibilityIdentifier?.hasPrefix("agentHistory.message.") == true }
        XCTAssertEqual(
            messageControls.compactMap(\.accessibilityIdentifier),
            ["agentHistory.message.1", "agentHistory.message.0"]
        )
        XCTAssertEqual(messageControls.map(\.accessibilityLabel), ["Expand message", "Expand message"])
        XCTAssertTrue(renderedText(in: controller.view).contains("newest first line"))
        XCTAssertFalse(renderedText(in: controller.view).contains("newest full second line"))

        let newest = try XCTUnwrap(messageControls.first)
        newest.sendActions(for: .touchUpInside)

        XCTAssertEqual(newest.accessibilityLabel, "Collapse message")
        let fullText = try XCTUnwrap(
            descendants(of: UITextView.self, in: controller.view).first {
                $0.accessibilityIdentifier == "agentHistory.fullText.1"
            }
        )
        XCTAssertEqual(fullText.text, messages[1].text)
        XCTAssertTrue(fullText.isSelectable)
        XCTAssertFalse(fullText.isEditable)
        XCTAssertFalse(fullText.isScrollEnabled)

        newest.sendActions(for: .touchUpInside)
        XCTAssertEqual(newest.accessibilityLabel, "Expand message")
        XCTAssertNil(descendants(of: UITextView.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentHistory.fullText.1"
        })
    }

    func testJumpOnlyAppearsForReachableMessagesAndRoutesJumpBeforeDismiss() throws {
        let reachable = message(ordinal: 3, text: "reachable", reachable: true)
        let compacted = message(ordinal: 2, text: "peek only", reachable: false)
        var jumped: AgentUserMessage?
        var didDismiss = false
        let controller = makeController(
            startHistoryJump: { jumped = $0 },
            dismiss: { didDismiss = true }
        )
        controller.loadViewIfNeeded()
        controller.applyHistoryStatus(.loaded(
            agent: .claudeCode,
            messages: [compacted, reachable],
            jumpAvailable: true
        ))

        let jump = try XCTUnwrap(
            descendants(of: UIKitChassisChip.self, in: controller.view).first {
                $0.accessibilityIdentifier == "agentHistory.jump.3"
            }
        )
        XCTAssertEqual(
            jump.accessibilityLabel,
            "Scroll the terminal back to this message"
        )
        XCTAssertNil(descendants(of: UIKitChassisChip.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentHistory.jump.2"
        })

        XCTAssertTrue(jump.accessibilityActivate())
        XCTAssertEqual(jumped, reachable)
        XCTAssertTrue(didDismiss)
    }

    func testJumpIsWithheldWhenTheLoadedSessionCannotPage() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.applyHistoryStatus(.loaded(
            agent: .claudeCode,
            messages: [message(ordinal: 0, text: "peek")],
            jumpAvailable: false
        ))

        XCTAssertTrue(descendants(of: UIKitChassisChip.self, in: controller.view).allSatisfy {
            $0.accessibilityIdentifier?.hasPrefix("agentHistory.jump.") != true
        })
    }

    func testLongExpandedMessageAndLongListKeepBothScrollCaps() throws {
        let longText = String(repeating: "a long prompt segment ", count: 90)
        let messages = (0..<50).map {
            message(ordinal: $0, text: $0 == 49 ? longText : "prompt \($0)")
        }
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.applyHistoryStatus(.loaded(
            agent: .claudeCode,
            messages: messages,
            jumpAvailable: false
        ))

        let list = try XCTUnwrap(descendants(of: UIScrollView.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentHistory.scroll"
        })
        XCTAssertEqual(
            list.constraints.first { $0.identifier == "agentHistory.listHeight" }?.constant,
            AgentHistoryPanelViewController.maximumListHeight
        )
        XCTAssertTrue(list.isScrollEnabled)

        let newest = try XCTUnwrap(descendants(of: UIControl.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentHistory.message.49"
        })
        newest.sendActions(for: .touchUpInside)
        let fullText = try XCTUnwrap(descendants(of: UITextView.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentHistory.fullText.49"
        })
        XCTAssertTrue(fullText.isScrollEnabled)
        XCTAssertLessThanOrEqual(
            fullText.constraints.first { $0.firstAttribute == .height }?.constant ?? .infinity,
            220
        )
    }

    func testCloseChipAndIntrinsicWidthPreservePanelContract() throws {
        var didDismiss = false
        let controller = makeController(dismiss: { didDismiss = true })
        controller.loadViewIfNeeded()

        let size = controller.fittingContentSize()
        XCTAssertEqual(size.width, AgentHistoryPanelViewController.preferredWidth)
        XCTAssertEqual(controller.preferredContentSize, size)

        let close = try XCTUnwrap(descendants(of: UIKitChassisChip.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentHistory.close"
        })
        XCTAssertEqual(close.accessibilityLabel, "Close")
        XCTAssertTrue(close.accessibilityActivate())
        XCTAssertTrue(didDismiss)
    }

    func testObservationRearmsAfterAsyncStateChangesAndAppearanceClosesHistory() async {
        let source = HistorySource()
        var opened: [AgentKind] = []
        var closeCount = 0
        let controller = AgentHistoryPanelViewController(
            agent: .claudeCode,
            historyStatus: { source.status },
            openHistory: {
                opened.append($0)
                source.status = .loading
            },
            closeHistory: { closeCount += 1 },
            startHistoryJump: { _ in },
            dismiss: {}
        )
        controller.loadViewIfNeeded()

        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        XCTAssertEqual(opened, [.claudeCode])
        XCTAssertTrue(renderedText(in: controller.view).contains("READING SESSION FILE"))

        source.status = .unavailable("NO SESSION FILE")
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(renderedText(in: controller.view).contains("NO SESSION FILE"))

        source.status = .loaded(
            agent: .claudeCode,
            messages: [message(ordinal: 8, text: "observed prompt")],
            jumpAvailable: true
        )
        await Task.yield()
        await Task.yield()
        XCTAssertNotNil(descendants(of: UIControl.self, in: controller.view).first {
            $0.accessibilityIdentifier == "agentHistory.message.8"
        })

        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        XCTAssertEqual(closeCount, 1)
    }

    private func makeController(
        startHistoryJump: @escaping (AgentUserMessage) -> Void = { _ in },
        dismiss: @escaping () -> Void = {}
    ) -> AgentHistoryPanelViewController {
        AgentHistoryPanelViewController(
            agent: .claudeCode,
            historyStatus: { nil },
            openHistory: { _ in },
            closeHistory: {},
            startHistoryJump: startHistoryJump,
            dismiss: dismiss
        )
    }

    private func message(
        ordinal: Int,
        text: String,
        reachable: Bool = true
    ) -> AgentUserMessage {
        AgentUserMessage(
            ordinal: ordinal,
            text: text,
            timestamp: nil,
            reachable: reachable
        )
    }

    private func statusHeight(in root: UIView) -> CGFloat? {
        descendants(of: UIStackView.self, in: root)
            .first { $0.accessibilityIdentifier == "agentHistory.status" }?
            .constraints.first { $0.firstAttribute == .height }?.constant
    }

    private func renderedText(in root: UIView) -> [String] {
        let labels = descendants(of: UILabel.self, in: root)
            .compactMap { $0.text ?? $0.attributedText?.string }
        let textViews = descendants(of: UITextView.self, in: root).compactMap(\.text)
        return labels + textViews
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches = root as? T == nil ? [] : [root as! T]
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }
}

@MainActor
@Observable
private final class HistorySource {
    var status: TerminalSessionController.AgentHistoryStatus?
}
