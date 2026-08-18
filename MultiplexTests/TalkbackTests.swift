import XCTest
@testable import Multiplex

final class TalkbackTests: XCTestCase {
    // MARK: Body sanitizing

    func testSanitizedBodyKeepsLinesTabsAndUnicode() {
        XCTAssertEqual(
            TalkbackMessage.sanitizedBody("fix the flaky test\n\tthen rerun · 測試"),
            "fix the flaky test\n\tthen rerun · 測試"
        )
    }

    func testSanitizedBodyNormalizesCarriageReturns() {
        XCTAssertEqual(TalkbackMessage.sanitizedBody("a\r\nb\rc"), "a\nb\nc")
        XCTAssertEqual(TalkbackMessage.sanitizedBody("a\r\r\nb"), "a\n\nb")
    }

    func testSanitizedBodyDropsEveryControlIncludingEscapeAndCtrlB() {
        // ESC (a CSI could ride it), Ctrl-B (the remote tmux prefix), DEL, and
        // a C1 CSI introducer are all gone. Only the control bytes go — the
        // printable tail of a would-be sequence is harmless text.
        XCTAssertEqual(
            TalkbackMessage.sanitizedBody("run\u{1B}[2J it \u{02}now\u{7F}\u{9B}!"),
            "run[2J it now!"
        )
    }

    func testSanitizedBodyTrimsTrailingBlankSpaceOnly() {
        XCTAssertEqual(TalkbackMessage.sanitizedBody("  keep leading\n\n  \t"), "  keep leading")
        XCTAssertEqual(TalkbackMessage.sanitizedBody("\n\n"), "")
    }

    // MARK: Payload

    func testPayloadWrapsInBracketedPasteMarkersWhenThePaneHasThemOn() {
        let payload = TalkbackMessage.payload(body: "hello\nworld", paths: [], bracketed: true)
        var expected = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        expected.append(Data("hello\nworld".utf8))
        expected.append(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))
        XCTAssertEqual(payload, expected)
    }

    func testPayloadIsRawTextWithoutBracketedPaste() {
        XCTAssertEqual(
            TalkbackMessage.payload(body: "ls -la\n", paths: [], bracketed: false),
            Data("ls -la".utf8)
        )
    }

    func testPayloadTypesLandedPathsFirstQuotedOnlyWhereNeeded() {
        let payload = TalkbackMessage.payload(
            body: "look at these",
            paths: [".multiplex-drops/IMG_4021.jpg", "/home/dev/my report.pdf"],
            bracketed: false
        )
        XCTAssertEqual(
            String(decoding: payload, as: UTF8.self),
            ".multiplex-drops/IMG_4021.jpg '/home/dev/my report.pdf' look at these"
        )
    }

    func testPayloadWithOnlyPathsKeepsTheTrailingSpaceAndEmptyMessageIsEmpty() {
        XCTAssertEqual(
            String(decoding: TalkbackMessage.payload(body: "  ", paths: ["a.txt"], bracketed: false), as: UTF8.self),
            "a.txt "
        )
        XCTAssertTrue(TalkbackMessage.payload(body: " \n", paths: [], bracketed: true).isEmpty)
    }

    func testSubmitIsASeparateCarriageReturnAfterTheChipsPause() {
        XCTAssertEqual(TalkbackMessage.submit, Data([0x0D]))
        XCTAssertEqual(TalkbackMessage.submitDelay, .milliseconds(160))
    }

    // MARK: Draft

    func testSendStateFollowsEmptinessUploadsAndFailures() {
        var draft = TalkbackDraft()
        XCTAssertEqual(draft.sendState, .disabled, "nothing to send")
        draft.text = "   \n"
        XCTAssertEqual(draft.sendState, .disabled, "blank text is nothing")
        draft.text = "hi"
        XCTAssertEqual(draft.sendState, .ready)

        let photo = TalkbackAttachment(name: "IMG_1.jpg", byteCount: 10, kind: .image)
        draft.attachments = [photo]
        XCTAssertEqual(draft.sendState, .waiting, "an upload in flight holds the message")

        draft.update(photo.id) { $0.state = .ready(path: ".multiplex-drops/IMG_1.jpg") }
        XCTAssertEqual(draft.sendState, .ready)
        XCTAssertEqual(draft.readyPaths, [".multiplex-drops/IMG_1.jpg"])

        draft.text = ""
        XCTAssertEqual(draft.sendState, .ready, "a landed attachment alone is a message")

        draft.update(photo.id) { $0.state = .failed("Over 64 MB") }
        XCTAssertEqual(draft.sendState, .disabled, "a failed chip is never sent half")
    }

    func testClearAfterSendLeavesAnEmptyBox() {
        var draft = TalkbackDraft(text: "done", attachments: [
            TalkbackAttachment(name: "a.txt", byteCount: 1, kind: .file, state: .ready(path: "a.txt")),
        ], focusRequest: 3)
        draft.clearAfterSend()
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(draft.sendState, .disabled)
        XCTAssertEqual(draft.focusRequest, 3, "the keyboard request is not part of the message")
    }

    func testAttachmentKindReadsTheExtension() {
        XCTAssertEqual(TalkbackAttachment.kind(forName: "photo-20260817.HEIC"), .image)
        XCTAssertEqual(TalkbackAttachment.kind(forName: "trace.log"), .file)
        XCTAssertEqual(TalkbackAttachment.kind(forName: "noext"), .file)
    }

    func testPlaceholderNamesTheAgentWhenThereIsOne() {
        XCTAssertEqual(TalkbackMessage.placeholder(agentName: "Claude Code"), "Message Claude Code…")
        XCTAssertEqual(TalkbackMessage.placeholder(agentName: nil), "Message this pane…")
    }
}
