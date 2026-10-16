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

    /// The keystroke→paint sampler behind the Connection Stats echo readout
    /// rides the same stamp: the first output after a send yields exactly
    /// one sample, and output with no new keystroke yields none.
    func testFirstFeedAfterSendYieldsOneEchoSample() {
        let terminal = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 420, height: 200)
        )
        let samples = EchoSampleBox()
        terminal.echoLatencySampleHandler = { milliseconds in
            samples.append(milliseconds)
        }
        terminal.feed(text: "banner\r\n")
        XCTAssertTrue(samples.values.isEmpty, "output before any keystroke is not an echo")

        terminal.send(txt: "x")
        terminal.feed(text: "x")
        terminal.feed(text: "more output")
        XCTAssertEqual(samples.values.count, 1, "one sample per keystroke stamp")
        XCTAssertGreaterThanOrEqual(samples.values.first ?? -1, 0)
    }
}

/// The handler runs on the feed thread; the test feeds from main, but the
/// box stays safe for either.
private final class EchoSampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
