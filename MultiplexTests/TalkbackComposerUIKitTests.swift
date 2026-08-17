import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class TalkbackComposerUIKitTests: XCTestCase {
    func testCardBuildsHeaderControlsAndFieldWithIdentifiers() throws {
        let controller = makeController()
        controller.setTalkbackOpen(true)
        let composer = makeComposer(controller: controller, agent: .claudeCode)
        composer.loadViewIfNeeded()

        let identifiers = descendants(in: composer.view)
            .compactMap(\.accessibilityIdentifier)
        for expected in [
            "terminal.talkback.card",
            "terminal.talkback.close",
            "terminal.talkback.attach",
            "terminal.talkback.field",
            "terminal.talkback.send",
        ] {
            XCTAssertTrue(identifiers.contains(expected), expected)
        }
        let header = try XCTUnwrap(descendants(in: composer.view).first {
            ($0 as? UIStackView)?.accessibilityLabel?.hasPrefix("To ") == true
        })
        XCTAssertEqual(header.accessibilityLabel, "To MAIN · DEVBOX Claude Code")
        let field = try XCTUnwrap(descendants(in: composer.view).first {
            $0.accessibilityIdentifier == "terminal.talkback.field"
        } as? UITextView)
        XCTAssertEqual(field.returnKeyType, .default, "the software Return breaks a line")
        XCTAssertFalse(descendants(in: composer.view).contains {
            String(describing: type(of: $0)).contains("Hosting")
        })
    }

    func testSendIsDimUntilThereIsAMessageAndTheTabIsLive() throws {
        let controller = makeController()
        controller.setTalkbackOpen(true)
        let composer = makeComposer(controller: controller, agent: nil)
        composer.loadViewIfNeeded()
        let send = try XCTUnwrap(descendants(in: composer.view).first {
            $0.accessibilityIdentifier == "terminal.talkback.send"
        } as? TalkbackRoundButton)
        XCTAssertEqual(send.style, .dim)
        XCTAssertFalse(send.isEnabled)

        enter("hello", into: composer)
        // The tab was never connected: the draft is ready but the pane can't
        // take input, so SEND stays dim and sends nothing.
        XCTAssertEqual(controller.talkback.text, "hello", "the field is the draft's writer")
        XCTAssertEqual(controller.talkback.sendState, .ready)
        XCTAssertEqual(controller.talkbackSendState, .disabled)
        XCTAssertEqual(send.style, .dim)
        XCTAssertFalse(controller.sendTalkback(submit: true))
        XCTAssertEqual(controller.talkback.text, "hello", "an unsent draft is kept")
    }

    func testFieldHeightGrowsPerLineAndCapsAtFiveLines() {
        let controller = makeController()
        controller.setTalkbackOpen(true)
        let composer = makeComposer(controller: controller, agent: nil)
        composer.loadViewIfNeeded()
        let empty = composer.fittingContentSize(for: 720).height

        enter("one\ntwo\nthree", into: composer)
        let three = composer.fittingContentSize(for: 720).height
        XCTAssertGreaterThan(three, empty)

        enter((1...12).map(String.init).joined(separator: "\n"), into: composer)
        let twelve = composer.fittingContentSize(for: 720).height
        XCTAssertGreaterThan(twelve, three)

        enter((1...30).map(String.init).joined(separator: "\n"), into: composer)
        XCTAssertEqual(
            composer.fittingContentSize(for: 720).height,
            twelve,
            "past five lines the field scrolls inside itself"
        )
    }

    func testCompactPreviewsShrinkTheAttachmentRow() {
        let controller = makeController()
        controller.setTalkbackOpen(true)
        let composer = makeComposer(controller: controller, agent: nil, compact: false)
        composer.loadViewIfNeeded()
        let bare = composer.fittingContentSize(for: 720).height
        controller.attachTalkbackFiles([DroppedFile(name: "trace.log", data: Data("x".utf8))])
        let regular = composer.fittingContentSize(for: 720).height
        XCTAssertEqual(
            regular - bare,
            TalkbackComposerViewController.previewSize + TalkbackComposerViewController.rowSpacing
        )

        var compact = composer.configuration
        compact.presentation.compactPreviews = true
        composer.update(configuration: compact)
        XCTAssertEqual(
            composer.fittingContentSize(for: 720).height - bare,
            TalkbackComposerViewController.compactPreviewSize
                + TalkbackComposerViewController.rowSpacing
        )
        XCTAssertTrue(descendants(in: composer.view).contains {
            ($0 as? TalkbackAttachmentView)?.compact == true
        })
    }

    func testAttachingOnATabThatCannotUploadFailsTheChipInsteadOfDroppingIt() async {
        let controller = makeController(mode: .shell)
        controller.setTalkbackOpen(true)
        controller.attachTalkbackFiles([DroppedFile(name: "a.txt", data: Data("x".utf8))])
        XCTAssertEqual(controller.talkback.attachments.count, 1)
        for _ in 0..<50 {
            if controller.talkback.attachments.first?.isFailed == true { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            controller.talkback.attachments.first?.state,
            .failed("File upload requires tmux or herdr over SSH")
        )
        XCTAssertEqual(controller.talkback.sendState, .disabled)

        controller.removeTalkbackAttachment(controller.talkback.attachments[0].id)
        XCTAssertTrue(controller.talkback.attachments.isEmpty)
    }

    func testTheTalkKeyRequestsFocusOncePerPress() {
        let controller = makeController()
        XCTAssertFalse(controller.consumeTalkbackFocusRequest(), "nothing asked yet")
        controller.setTalkbackOpen(true)
        XCTAssertTrue(controller.consumeTalkbackFocusRequest())
        XCTAssertFalse(controller.consumeTalkbackFocusRequest(), "a re-render never re-focuses")
        controller.setTalkbackOpen(true)
        XCTAssertTrue(controller.consumeTalkbackFocusRequest(), "a second press asks again")
        controller.toggleTalkback()
        XCTAssertFalse(controller.talkbackOpen)
        XCTAssertFalse(controller.consumeTalkbackFocusRequest(), "closing asks for nothing")
    }

    func testHardwareReturnSendsAndEscapeHandsBackTheKeyboard() {
        let field = TalkbackTextView()
        var sent = 0
        var escaped = 0
        field.onSend = { sent += 1 }
        field.onEscape = { escaped += 1 }
        let commands = field.keyCommands ?? []
        let plainReturn = commands.first { $0.input == "\r" && $0.modifierFlags.isEmpty }
        let commandReturn = commands.first { $0.input == "\r" && $0.modifierFlags == .command }
        let escape = commands.first { $0.input == UIKeyCommand.inputEscape }
        XCTAssertNotNil(plainReturn)
        XCTAssertNotNil(commandReturn)
        XCTAssertNotNil(escape)
        XCTAssertNil(
            commands.first { $0.input == "\r" && $0.modifierFlags == .shift },
            "Shift+Return is UIKit's own newline"
        )
        for command in [plainReturn, commandReturn, escape].compactMap({ $0 }) {
            _ = field.perform(command.action)
        }
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(escaped, 1)
    }

    // MARK: Helpers

    private func makeController(mode: TerminalRoute.Mode = .attach(sessionName: "main")) -> TerminalSessionController {
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        return TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: mode),
            host: host
        )
    }

    private func makeComposer(
        controller: TerminalSessionController,
        agent: AgentKind?,
        compact: Bool = false
    ) -> TalkbackComposerViewController {
        TalkbackComposerViewController(configuration: TalkbackComposerConfiguration(
            controller: controller,
            presentation: TalkbackComposerPresentation(
                targetLabel: "MAIN · DEVBOX",
                agent: agent,
                agentState: nil,
                compactPreviews: compact,
                floating: false,
                availableWidth: 720,
                contentSafeArea: .zero
            ),
            close: {},
            focusTerminal: {}
        ))
    }

    /// The field is the draft's writer: typing goes through the text view
    /// and its delegate, exactly as the keyboard would.
    private func enter(_ text: String, into composer: TalkbackComposerViewController) {
        guard let field = descendants(in: composer.view).first(where: {
            $0.accessibilityIdentifier == "terminal.talkback.field"
        }) as? UITextView else {
            return XCTFail("no field")
        }
        field.text = text
        composer.textViewDidChange(field)
    }

    private func descendants(in root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap(descendants(in:))
    }
}
