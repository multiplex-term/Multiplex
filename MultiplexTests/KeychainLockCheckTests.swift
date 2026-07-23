import XCTest
@testable import Multiplex

/// Pins the locked-keychain check: the host-side command's secret-safe
/// shape, the sentinel classification, and the Claude sign-in needles.
///
/// Ground truth captured 2026-07-23 against Claude Code v2.1.218 and a real
/// sshd on macOS 27: the sign-in screens below are verbatim capture-pane
/// output, and the locked keychain's data read fails **silently** (exit
/// 128, empty stderr — errSecUserCanceled; the old "User interaction is
/// not allowed" text never appears), while the attribute search still
/// succeeds. That's why LOCKED is structural (item findable, data
/// unreadable) and only MISSING string-matches ("could not be found",
/// verified over the same path).
final class KeychainLockCheckTests: XCTestCase {
    // MARK: Command shape

    func testCheckCommandProbesClaudeItemWithoutTransportingTheSecret() {
        let command = KeychainLockCheck.checkCommand
        // The exact read Claude Code performs at startup, secret to
        // /dev/null…
        XCTAssertTrue(command.contains(
            "security find-generic-password -s 'Claude Code-credentials' -w >/dev/null 2>&1"))
        // …then the attribute-only search that distinguishes locked from
        // missing (stderr captured, attribute stdout discarded).
        XCTAssertTrue(command.contains(
            "err=$(security find-generic-password -s 'Claude Code-credentials' 2>&1 >/dev/null)"))
        // A `-g` flag would print the secret to stderr, where the
        // classifier reads. (Substring "-g" alone occurs inside
        // "find-generic-password" — match the space-delimited flag.)
        XCTAssertFalse(command.contains(" -g "))
    }

    func testCheckCommandGatesOnDarwinAndAlwaysAnswers() {
        let command = KeychainLockCheck.checkCommand
        XCTAssertTrue(command.contains("uname -s"))
        XCTAssertTrue(command.contains("Darwin"))
        // Every branch prints a sentinel; the last statement is the closing
        // `fi`, so the exec exits 0 (Citadel throws on non-zero status).
        for sentinel in ["NA", "OK", "LOCKED", "MISSING", "OTHER"] {
            XCTAssertTrue(
                command.contains("echo 'MPX_KEYCHAIN \(sentinel)'"),
                "missing sentinel \(sentinel)"
            )
        }
        XCTAssertTrue(command.hasSuffix("fi"))
        // LOCKED must NOT depend on error text — a locked read is silent on
        // macOS 27. Only the missing-item phrase is string-matched.
        XCTAssertFalse(command.contains("interaction is not allowed"))
        XCTAssertTrue(command.contains("*'could not be found'*"))
    }

    // MARK: Output classification

    func testParseVerdicts() {
        XCTAssertEqual(KeychainLockCheck.parse("MPX_KEYCHAIN LOCKED"), .locked)
        XCTAssertEqual(KeychainLockCheck.parse("MPX_KEYCHAIN OK"), .unlocked)
        XCTAssertEqual(
            KeychainLockCheck.parse("MPX_KEYCHAIN MISSING"),
            .credentialsMissing
        )
        XCTAssertEqual(KeychainLockCheck.parse("MPX_KEYCHAIN NA"), .notMacOS)
        XCTAssertEqual(
            KeychainLockCheck.parse("MPX_KEYCHAIN OTHER"),
            .indeterminate
        )
    }

    func testParseSurvivesLoginNoiseAndWhitespace() {
        // MOTD / login banners can precede exec output on some hosts.
        let noisy = """
        Welcome to studio.local
        Last login: Wed Jul 22 21:14:09
        MPX_KEYCHAIN LOCKED
        """
        XCTAssertEqual(KeychainLockCheck.parse(noisy), .locked)
        XCTAssertEqual(KeychainLockCheck.parse("  MPX_KEYCHAIN OK  \n"), .unlocked)
    }

    func testParseFailsSoftOnGarbage() {
        XCTAssertEqual(KeychainLockCheck.parse(""), .indeterminate)
        XCTAssertEqual(KeychainLockCheck.parse("command not found"), .indeterminate)
        XCTAssertEqual(
            KeychainLockCheck.parse("MPX_KEYCHAIN"),  // sentinel word alone
            .indeterminate
        )
        // Prose mentioning the sentinel mid-line is not a sentinel line.
        XCTAssertEqual(
            KeychainLockCheck.parse("saw MPX_KEYCHAIN LOCKED earlier"),
            .indeterminate
        )
    }

    // MARK: Sign-in screen needles (verbatim v2.1.218 captures, 2026-07-23)

    func testDetectsStartupLoginSelector() {
        let tail = [
            "       █████████                                        *",
            "      ██▄█████▄██                        *",
            "       █████████      *",
            ".......█ █   █ █..........................................",
            "",
            " Claude Code can be used with your Claude subscription or billed based on API usage through your",
            " Console account.",
            "",
            " Select login method:",
            "",
            " ❯ 1. Claude account with subscription · Pro, Max, Team, or Enterprise",
            "   2. Anthropic Console account · API usage billing",
            "   3. 3rd-party platform · Amazon Bedrock, Microsoft Foundry, or Vertex AI",
        ]
        XCTAssertTrue(KeychainLockCheck.showsClaudeLoginScreen(in: tail))
    }

    func testDetectsOAuthUrlScreen() {
        // The screen a headless/SSH Mac gets parked on: no browser can
        // open, so the pane sits at the paste-code prompt. Both its stable
        // rows are needles; either alone suffices (long URLs can push the
        // header out of a short pane).
        let tail = [
            " Browser didn't open? Use the url below to sign in (c to copy)",
            "",
            "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&resp",
            "onse_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3A",
            "",
            " Paste code here if prompted >",
        ]
        XCTAssertTrue(KeychainLockCheck.showsClaudeLoginScreen(in: tail))
        XCTAssertTrue(KeychainLockCheck.showsClaudeLoginScreen(
            in: [" Paste code here if prompted >"]))
    }

    func testDetectsSignedOutComposerStatus() {
        // An onboarded install with unreadable credentials skips the
        // selector and starts the composer with this status row (observed
        // on a real locked-keychain Mac over SSH, v2.1.218; the header
        // reads "API Usage Billing" there, which is deliberately not a
        // needle — signed-in Console-billing users show it too).
        let tail = [
            " ────────────────────────────────────────",
            " ❯ ",
            " ────────────────────────────────────────",
            "   Not logged in · Run /login",
        ]
        XCTAssertTrue(KeychainLockCheck.showsClaudeLoginScreen(in: tail))
    }

    func testDetectsInSessionCredentialFailureBanner() {
        let tail = [
            " ✗ Invalid API key · Please run /login",
            "",
            " ❯ ",
        ]
        XCTAssertTrue(KeychainLockCheck.showsClaudeLoginScreen(in: tail))
    }

    func testIgnoresProseAndOtherAgents() {
        XCTAssertFalse(KeychainLockCheck.showsClaudeLoginScreen(in: []))
        // Mentioning /login (or "login", or a URL) in prose must not
        // trigger the host check — needles are phrase-exact.
        XCTAssertFalse(KeychainLockCheck.showsClaudeLoginScreen(in: [
            "$ man security",
            "how do I use /login?",
            "Select a login shell for the new user",
            "open the url below in a browser",
        ]))
        XCTAssertFalse(KeychainLockCheck.showsClaudeLoginScreen(in: [
            "OpenAI Codex (v0.144.1)",
            "codex",
        ]))
    }
}
