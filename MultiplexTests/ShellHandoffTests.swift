import XCTest
@testable import Multiplex

final class ShellHandoffTests: XCTestCase {
    // MARK: Payload

    func testPayloadPrefixesSacrificialNoOpLine() {
        XCTAssertEqual(
            ShellHandoff.payload(for: "exec tmux attach-session -t 'main'"),
            ":\nexec tmux attach-session -t 'main'\n"
        )
    }

    // MARK: Update prompt detection

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testDetectsCurrentOhMyZshPrompt() {
        var watch = ShellHandoff.UpdatePromptWatch()
        XCTAssertEqual(
            watch.consume(bytes("Last login: Mon Jul 20\r\n")),
            .watching
        )
        XCTAssertEqual(
            watch.consume(bytes("[oh-my-zsh] Would you like to update? [Y/n] ")),
            .promptDetected
        )
        // One-shot: a resolved watch reports done forever after.
        XCTAssertEqual(watch.consume(bytes("more output")), .done)
    }

    func testDetectsLegacyCheckForUpdatesPrompt() {
        var watch = ShellHandoff.UpdatePromptWatch()
        XCTAssertEqual(
            watch.consume(
                bytes("[Oh My Zsh] Would you like to check for updates? [Y/n]: ")
            ),
            .promptDetected
        )
    }

    func testDetectsPromptSplitAcrossChunks() {
        var watch = ShellHandoff.UpdatePromptWatch()
        XCTAssertEqual(
            watch.consume(bytes("[oh-my-zsh] Would you like")),
            .watching
        )
        XCTAssertEqual(
            watch.consume(bytes(" to update? [Y/n] ")),
            .promptDetected
        )
    }

    func testIgnoresBannerMentionsWithoutThePromptPhrase() {
        var watch = ShellHandoff.UpdatePromptWatch()
        XCTAssertEqual(
            watch.consume(
                bytes("[oh-my-zsh] You can update manually by running `omz update`\r\n")
            ),
            .watching
        )
    }

    func testAlternateScreenTakeoverEndsTheWatch() {
        var watch = ShellHandoff.UpdatePromptWatch()
        XCTAssertEqual(
            watch.consume(bytes("\u{1b}[?1049h\u{1b}[H\u{1b}[2J")),
            .done
        )
        // Even a later prompt-shaped string can't re-arm it.
        XCTAssertEqual(
            watch.consume(bytes("[oh-my-zsh] Would you like to update? [Y/n] ")),
            .done
        )
    }

    func testScanWindowExpiresAfterByteCap() {
        var watch = ShellHandoff.UpdatePromptWatch()
        let filler = [UInt8](repeating: UInt8(ascii: "x"), count: 40_000)
        XCTAssertEqual(watch.consume(filler), .done)
        XCTAssertEqual(
            watch.consume(bytes("[oh-my-zsh] Would you like to update? [Y/n] ")),
            .done
        )
    }

    func testHighBitOutputBytesDoNotBreakScanning() {
        var watch = ShellHandoff.UpdatePromptWatch()
        // UTF-8 multibyte MOTD content interleaved with the prompt text.
        XCTAssertEqual(watch.consume(bytes("héllo — wörld\r\n")), .watching)
        XCTAssertEqual(
            watch.consume(bytes("[oh-my-zsh] Would you like to update? [Y/n] ")),
            .promptDetected
        )
    }
}
