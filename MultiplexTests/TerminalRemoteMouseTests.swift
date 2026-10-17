import SwiftTerm
import UIKit
import XCTest
@testable import Multiplex

/// The fork's remote mouse seams, byte for byte on the wire: a claimed long
/// press becomes press / cell-quantized motion / release (herdr's pane-resize
/// drag), and the selection block's MENU chip sends a right click whose SGR
/// release names button 2 — a left-button release would dismiss the very
/// menu the press opened.
@MainActor
final class TerminalRemoteMouseTests: XCTestCase {
    /// SwiftTerm hands terminal responses to the delegate on a later main
    /// turn: wait (spinning the run loop) until `count` sends landed.
    private func waitForSends(_ delegate: CapturingTerminalDelegate, count: Int) {
        let landed = expectation(
            for: NSPredicate { _, _ in delegate.sent.count >= count },
            evaluatedWith: nil)
        wait(for: [landed], timeout: 3)
    }

    /// Give a send that should NOT happen the same main turns to show up.
    private func settle() {
        let nothing = expectation(description: "settle")
        nothing.isInverted = true
        wait(for: [nothing], timeout: 0.3)
    }

    private func sgrTracking() -> (TerminalView, CapturingTerminalDelegate) {
        let (terminal, delegate) = CapturingTerminalDelegate.makeTerminal()
        terminal.feed(text: "\u{1B}[?1002h\u{1B}[?1006h") // button tracking, SGR
        return (terminal, delegate)
    }

    private func text(_ delegate: CapturingTerminalDelegate) -> [String] {
        delegate.sent.map { String(decoding: $0, as: UTF8.self) }
    }

    func testClaimedLongPressDragSendsPressMotionRelease() {
        let (terminal, delegate) = sgrTracking()
        var offered: [(col: Int, row: Int)] = []
        terminal.longPressMouseDragFilter = { cell, _ in
            offered.append(cell)
            return true
        }

        XCTAssertTrue(terminal.beginRemoteMouseDrag(at: terminal.pointForCell(col: 5, row: 2)))
        XCTAssertTrue(terminal.remoteMouseDragActive)
        // Same cell: quantized away. New cell: one motion report.
        terminal.continueRemoteMouseDrag(at: terminal.pointForCell(col: 5, row: 2))
        terminal.continueRemoteMouseDrag(at: terminal.pointForCell(col: 6, row: 2))
        terminal.endRemoteMouseDrag(at: terminal.pointForCell(col: 6, row: 2))
        waitForSends(delegate, count: 3)

        XCTAssertEqual(offered.map(\.col), [5])
        XCTAssertEqual(offered.map(\.row), [2])
        XCTAssertFalse(terminal.remoteMouseDragActive)
        XCTAssertEqual(text(delegate), [
            "\u{1B}[<0;6;3M",
            "\u{1B}[<32;7;3M",
            "\u{1B}[<0;7;3m",
        ])
    }

    func testDeclinedCellKeepsTheLongPressLocal() {
        let (terminal, delegate) = sgrTracking()
        terminal.longPressMouseDragFilter = { _, _ in false }
        XCTAssertFalse(terminal.beginRemoteMouseDrag(at: terminal.pointForCell(col: 1, row: 1)))
        settle()
        XCTAssertTrue(delegate.sent.isEmpty)
    }

    func testRightClickReleaseNamesTheButton() {
        let (terminal, delegate) = sgrTracking()
        XCTAssertTrue(terminal.sendRemoteRightClick(atBufferPosition: Position(col: 5, row: 2)))
        waitForSends(delegate, count: 2)
        XCTAssertEqual(text(delegate), [
            "\u{1B}[<2;6;3M",
            "\u{1B}[<2;6;3m",
        ])
    }

    /// Pans scroll the remote: wheel reports while the client tracks the
    /// mouse, pinned to the given anchor point.
    func testRemoteScrollSendsWheelReportsUnderMouseTracking() {
        let (terminal, delegate) = sgrTracking()
        terminal.performRemoteScroll(ticks: 2, at: terminal.pointForCell(col: 3, row: 4))
        waitForSends(delegate, count: 2)
        XCTAssertEqual(text(delegate), [
            "\u{1B}[<64;4;5M",
            "\u{1B}[<64;4;5M",
        ])
    }

    /// Without mouse tracking, the alternate screen gets DECCKM-aware cursor
    /// keys — one batched send per pan tick.
    func testRemoteScrollSendsCursorKeysOnTheAlternateScreen() {
        let (terminal, delegate) = CapturingTerminalDelegate.makeTerminal()
        terminal.feed(text: "\u{1B}[?1049h\u{1B}[?1h") // alternate screen, DECCKM
        terminal.performRemoteScroll(ticks: -3)
        waitForSends(delegate, count: 1)
        XCTAssertEqual(delegate.sent, [
            EscapeSequences.moveDownApp + EscapeSequences.moveDownApp + EscapeSequences.moveDownApp,
        ])
    }

    func testRightClickNeedsMouseReporting() {
        let (terminal, delegate) = CapturingTerminalDelegate.makeTerminal()
        XCTAssertFalse(terminal.sendRemoteRightClick(atBufferPosition: Position(col: 5, row: 2)))
        settle()
        XCTAssertTrue(delegate.sent.isEmpty)
    }
}
