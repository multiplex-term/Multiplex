import SwiftTerm
import UIKit
import XCTest
@testable import Multiplex

/// Captures what a terminal view sends, so a chord's bytes are assertable
/// end to end through the same delegate path a rail key uses.
@MainActor
final class CapturingTerminalDelegate: NSObject, TerminalViewDelegate {
    var sent: [[UInt8]] = []

    /// A fresh terminal view wired to a fresh capturing delegate.
    static func makeTerminal() -> (TerminalView, CapturingTerminalDelegate) {
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = CapturingTerminalDelegate()
        terminal.terminalDelegate = delegate
        return (terminal, delegate)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent.append(Array(data))
    }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The fork seam: an app-authored chord encodes exactly as a hardware press
/// would in the terminal's current mode — legacy without kitty flags, CSI u
/// with them, DECCKM-aware for arrows.
@MainActor
final class KeyChordEncodingTests: XCTestCase {
    private func bytes(
        _ key: TerminalKeyChord.Key,
        _ modifiers: TerminalKeyChord.Modifiers = [],
        on terminal: TerminalView
    ) -> [UInt8]? {
        terminal.bytes(for: TerminalKeyChord(key: key, modifiers: modifiers))
    }

    func testLegacyChordsMatchTheHardwareRules() {
        let (terminal, _) = CapturingTerminalDelegate.makeTerminal()
        XCTAssertEqual(bytes(.enter, [.shift], on: terminal), [0x0A], "Shift+Enter is LF without kitty flags")
        XCTAssertEqual(bytes(.enter, on: terminal), [0x0D])
        XCTAssertEqual(bytes(.enter, [.option], on: terminal), [0x1B, 0x0D], "Option+Enter is ESC CR")
        XCTAssertEqual(bytes(.tab, [.shift], on: terminal), [0x1B, 0x5B, 0x5A], "Shift+Tab is CSI Z")
        XCTAssertEqual(bytes(.tab, on: terminal), [0x09])
        XCTAssertEqual(bytes(.escape, on: terminal), [0x1B])
        XCTAssertEqual(bytes(.backspace, on: terminal), [0x7F])
        XCTAssertEqual(bytes(.backspace, [.control], on: terminal), [0x08])
        XCTAssertEqual(
            bytes(.backspace, [.option], on: terminal),
            [0x1B, 0x7F],
            "Option+Backspace is ESC DEL — readline's backward-kill-word, the shipped third default"
        )
        XCTAssertEqual(bytes(.space, [.control], on: terminal), [0x00])
        XCTAssertEqual(bytes(.space, on: terminal), [0x20])
        XCTAssertEqual(bytes(.character("c"), [.control], on: terminal), [0x03])
        XCTAssertEqual(
            bytes(.character("c"), [.control, .shift], on: terminal),
            [0x03],
            "Legacy Ctrl+Shift+letter is Ctrl+letter"
        )
        XCTAssertEqual(bytes(.character("x"), [.option], on: terminal), [0x1B, 0x78], "Option+letter is ESC letter")
        XCTAssertEqual(bytes(.character("a"), [.shift], on: terminal), Array("A".utf8))
        XCTAssertEqual(bytes(.character("a"), on: terminal), Array("a".utf8))
        XCTAssertEqual(bytes(.left, [.option], on: terminal), EscapeSequences.emacsBack)
        XCTAssertEqual(bytes(.right, [.option], on: terminal), EscapeSequences.emacsForward)
        XCTAssertEqual(bytes(.left, [.control], on: terminal), EscapeSequences.controlLeft)
        XCTAssertEqual(bytes(.up, [.shift], on: terminal), [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41], "Shift+Up is CSI 1;2A")

        // Arrows follow DECCKM.
        XCTAssertEqual(bytes(.up, on: terminal), EscapeSequences.moveUpNormal)
        terminal.feed(byteArray: [0x1B, 0x5B, 0x3F, 0x31, 0x68][...]) // CSI ? 1 h
        XCTAssertEqual(bytes(.up, on: terminal), EscapeSequences.moveUpApp)
        XCTAssertEqual(bytes(.down, on: terminal), EscapeSequences.moveDownApp)
    }

    func testKittyFlagsSwitchToCSIUEncodings() {
        let (terminal, _) = CapturingTerminalDelegate.makeTerminal()
        terminal.feed(byteArray: [0x1B, 0x5B, 0x3E, 0x31, 0x75][...]) // CSI > 1 u: disambiguate
        XCTAssertFalse(terminal.getTerminal().keyboardEnhancementFlags.isEmpty)
        XCTAssertEqual(
            bytes(.enter, [.shift], on: terminal),
            Array("\u{1B}[13;2u".utf8),
            "Shift+Enter rides CSI u once kitty flags are on"
        )
        XCTAssertEqual(bytes(.enter, on: terminal), [0x0D], "Plain Enter stays legacy under disambiguate")
        XCTAssertEqual(bytes(.character("c"), [.control], on: terminal), Array("\u{1B}[99;5u".utf8))
        XCTAssertEqual(bytes(.up, [.option], on: terminal), Array("\u{1B}[1;3A".utf8))
        XCTAssertEqual(bytes(.tab, [.shift], on: terminal), Array("\u{1B}[9;2u".utf8))
        XCTAssertEqual(bytes(.backspace, [.option], on: terminal), Array("\u{1B}[127;3u".utf8))
        XCTAssertEqual(bytes(.character("a"), on: terminal), Array("a".utf8), "Plain text stays text")
    }
}
