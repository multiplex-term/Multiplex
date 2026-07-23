import Foundation

/// The macOS locked-keychain trap: Claude Code keeps its credentials in the
/// Mac's login keychain, and an SSH or tmux session never unlocks it (no GUI
/// login happened), so on a headless/remote Mac the CLI starts as if the
/// user were signed out even though their login is intact. The wall probe
/// detects the visible symptom — a Claude pane parked on its sign-in
/// screen — and then asks the host one cheap, secret-free question to
/// confirm the cause before the deck shows its unlock tip.
///
/// Everything here is pure command-building/classification, exercised
/// directly by `KeychainLockCheckTests`. Claude Code is currently the only
/// supported agent that stores credentials in the keychain (Codex and Pi use
/// files), so the needles and the probed item are Claude's; add per-agent
/// entries here if another CLI grows the same failure mode.
enum KeychainLockCheck {
    /// The keychain item Claude Code reads at startup (`security
    /// find-generic-password -s "Claude Code-credentials"`). Probing this
    /// exact item mirrors the read Claude itself performs: testing lock
    /// state requires a *data* read — attribute searches succeed on a
    /// locked keychain — and only an unlock-needing operation surfaces the
    /// non-interactive session's `errSecInteractionNotAllowed`.
    static let claudeCredentialService = "Claude Code-credentials"

    /// What the host-side check concluded.
    enum Verdict: Equatable {
        /// The credential item exists but its data cannot be read in this
        /// non-interactive session — the locked-keychain trap the tip
        /// explains, and the same failure Claude Code's own read hits.
        case locked
        /// The credential read succeeded — the keychain is unlocked, so a
        /// sign-in screen has some other cause (revoked token, sign-out).
        case unlocked
        /// No stored credential exists; the sign-in screen is genuine
        /// first-time login, not a keychain problem.
        case credentialsMissing
        /// Not a Mac — structural, cached for the connection's lifetime.
        case notMacOS
        /// The check didn't produce a readable answer. Fail-soft: no tip.
        case indeterminate
    }

    /// One exec round-trip, classified host-side so the credential never
    /// crosses the wire: every stdout is discarded into /dev/null (the `-w`
    /// read's stdout is the secret) and LOCKED is decided *structurally*,
    /// not by error text. Verified over a real sshd on macOS 27
    /// (2026-07-23): a locked keychain's data read fails **silently** —
    /// exit 128 (errSecUserCanceled), empty stderr, no "User interaction is
    /// not allowed" — so string-matching the locked case never fires. What
    /// does hold: the *attribute* search (no `-w`) succeeds on a locked
    /// keychain, and the data read succeeds only when the keychain is
    /// unlocked. Therefore: data readable → OK; item findable but data
    /// unreadable → LOCKED (exactly Claude Code's own predicament in this
    /// session); no item → MISSING (that error string is stable and was
    /// verified over the same path). Always exits 0: Citadel throws on a
    /// non-zero exit status, and a failed check must read as "no sentinel",
    /// never a torn-down control connection.
    static let checkCommand =
        "if [ \"$(uname -s 2>/dev/null)\" != Darwin ]; then echo 'MPX_KEYCHAIN NA'; "
        + "elif security find-generic-password -s '\(claudeCredentialService)' -w >/dev/null 2>&1; "
        + "then echo 'MPX_KEYCHAIN OK'; "
        + "elif err=$(security find-generic-password -s '\(claudeCredentialService)' 2>&1 >/dev/null); "
        + "then echo 'MPX_KEYCHAIN LOCKED'; "
        + "else case \"$err\" in "
        + "*'could not be found'*) echo 'MPX_KEYCHAIN MISSING';; "
        + "*) echo 'MPX_KEYCHAIN OTHER';; "
        + "esac; fi"

    /// Classify the check's output. Line-scanned so login banners/MOTD noise
    /// around the sentinel can't confuse it; anything unrecognized is
    /// `.indeterminate`, never an error.
    static func parse(_ output: String) -> Verdict {
        let sentinel = "MPX_KEYCHAIN "
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(sentinel) else { continue }
            switch trimmed.dropFirst(sentinel.count) {
            case "LOCKED": return .locked
            case "OK": return .unlocked
            case "MISSING": return .credentialsMissing
            case "NA": return .notMacOS
            default: return .indeterminate
            }
        }
        return .indeterminate
    }

    /// Claude Code's signed-out surfaces, as they appear in a capture-pane
    /// tail — verified against v2.1.218 on 2026-07-23 (the first three
    /// captured verbatim from a sandboxed signed-out run; the composer
    /// status observed on a real locked-keychain Mac over SSH): the startup
    /// login selector, the OAuth screen a headless/SSH Mac gets parked on
    /// (no browser can open, so it sits at the paste-code prompt), the
    /// composer's signed-out status row — an onboarded install skips the
    /// selector and starts the main UI with this footer (the header then
    /// shows API Usage Billing, which is deliberately NOT a needle: that
    /// text is a legitimate standing header for signed-in Console-billing
    /// users) — and the in-session banner when a credential read fails
    /// mid-run. Phrase-exact needles (same discipline as
    /// `UpdatePromptWatch`) so prose that merely mentions /login can't
    /// trigger the host check.
    private static let claudeLoginNeedles = [
        "Select login method",           // startup selector
        "Use the url below to sign in",  // "Browser didn't open? Use the url below to sign in (c to copy)"
        "Paste code here if prompted",   // the OAuth code prompt below that URL
        "Not logged in · Run /login",    // composer status on an onboarded, signed-out install
        "Please run /login",             // "Invalid API key · Please run /login" et al.
    ]

    /// Whether a session's capture tail currently shows Claude Code's
    /// sign-in screen. Callers additionally require the pane's detected
    /// agent to be Claude Code, so leftover login text scrolled behind a
    /// shell prompt can't re-trigger after the CLI exits.
    static func showsClaudeLoginScreen(in tail: [String]) -> Bool {
        tail.contains { line in
            claudeLoginNeedles.contains { line.contains($0) }
        }
    }
}

/// Standing host-level tip state: which sessions' Claude panes sit on the
/// sign-in screen while the host keychain is confirmed locked. The deck rail
/// renders it; `HostConnectionModel` re-derives it on every probe and clears
/// it the moment the screen moves on or the keychain unlocks.
struct KeychainLockNotice: Equatable {
    var sessionNames: [String]
}
