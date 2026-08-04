import SwiftTerm
import UIKit
import XCTest
@testable import Multiplex

/// Locks the send-path recency stamp that typing-aware chrome stands on:
/// the focused-pane agent probe and the visionOS hover-region rebuild both
/// skip their tick while `hasRecentUserInput` answers true. Every input
/// road funnels through `TerminalView.send`, so this one seam covers IME
/// commits, the key rail, kitty hardware keys, and dictation alike.
@MainActor
final class TerminalTypingQuietTests: XCTestCase {
    func testFreshTerminalReportsNoRecentInput() {
        let terminal = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 420, height: 200)
        )
        XCTAssertFalse(terminal.hasRecentUserInput(within: .seconds(60)))
    }

    func testSendStampsRecencyAndAgesOut() {
        let terminal = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 420, height: 200)
        )
        terminal.send(txt: "x")
        XCTAssertTrue(
            terminal.hasRecentUserInput(within: .seconds(60)),
            "a keystroke just went out — the quiet window must be open"
        )
        XCTAssertFalse(
            terminal.hasRecentUserInput(within: .nanoseconds(1)),
            "microseconds have passed since the send — a 1ns window has aged out"
        )
    }
}
