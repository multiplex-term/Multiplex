import XCTest
@testable import Multiplex

/// Pins the attention rules to the states captured from the real CLIs on
/// 2026-07-11 (Claude Code v2.1.206, Codex rust-v0.144.1, tmux 3.6a) — the
/// experiment record is local-plan/agent-attention.md. Titles and dialog
/// blocks below are verbatim captures; when an agent's TUI shifts, this
/// file is where the new truth lands.
final class AgentAttentionTests: XCTestCase {
    // MARK: Title state machine

    func testTitleIdleStates() {
        // Claude Code before/after work, Codex idle (cwd basename), and the
        // non-agent defaults a shell leaves behind.
        XCTAssertEqual(AgentAttention.classify(title: "✳ Claude Code", tail: []), .idle)
        XCTAssertEqual(AgentAttention.classify(title: "✳ Write haiku about terminals", tail: []), .idle)
        XCTAssertEqual(AgentAttention.classify(title: "wd", tail: []), .idle)
        XCTAssertEqual(AgentAttention.classify(title: "Jhen-MBPr14.local", tail: []), .idle)
        XCTAssertEqual(AgentAttention.classify(title: "", tail: []), .idle)
    }

    func testTitleBusyStates() {
        // Braille spinner prefix while a turn is in flight — the glyph
        // animates across the block, so the whole range must match.
        XCTAssertEqual(AgentAttention.classify(title: "⠂ Create probe.txt file", tail: []), .busy)
        XCTAssertEqual(AgentAttention.classify(title: "⠐ Write haiku about terminals", tail: []), .busy)
        XCTAssertEqual(AgentAttention.classify(title: "⠦ wd", tail: []), .busy)
        XCTAssertEqual(AgentAttention.classify(title: "⣿ anything", tail: []), .busy)
        // A Braille char elsewhere must not read as busy.
        XCTAssertEqual(AgentAttention.classify(title: "fix ⠂ handling", tail: []), .idle)
    }

    func testCodexActionRequiredTitle() {
        // Codex names its approval wait in the title, blinking [ ! ]/[ . ].
        XCTAssertEqual(
            AgentAttention.classify(title: "[ ! ] Action Required | wd", tail: []),
            .needsYou(.permission))
        XCTAssertEqual(
            AgentAttention.classify(title: "[ . ] Action Required | wd", tail: []),
            .needsYou(.permission))
    }

    // MARK: Question shapes (capture-pane tail)

    /// Claude Code Bash permission dialog, verbatim (v2.1.206,
    /// --permission-mode default). Title stays in spinner state throughout
    /// — content is the only outside sign.
    private let permissionDialog = [
        "❯ Run the shell command: touch probe.txt",
        "⏺ Bash(touch probe.txt)",
        " Bash command",
        "   touch probe.txt",
        "   Create empty probe.txt file",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and always allow access to wd/ from this project",
        "   3. No",
        " Esc to cancel · Tab to amend · ctrl+e to explain",
    ]

    /// Claude Code AskUserQuestion, verbatim.
    private let askUserDialog = [
        " ☐ Preference",
        "Do you prefer cats or dogs?",
        "❯ 1. Cats",
        "     You prefer cats",
        "  2. Dogs",
        "     You prefer dogs",
        "  3. Type something.",
        "  4. Chat about this",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ]

    /// Codex command approval, verbatim (--ask-for-approval untrusted).
    private let codexApproval = [
        "• Running mkdir -p /tmp/mplx-codex-probe2",
        "  Would you like to run the following command?",
        "  Environment: local",
        "  $ mkdir -p /tmp/mplx-codex-probe2",
        "› 1. Yes, proceed (y)",
        "  2. Yes, and don't ask again for commands that start with `mkdir -p /tmp/mplx-codex-probe2` (p)",
        "  3. No, and tell Codex what to do differently (esc)",
        "  Press enter to confirm or esc to cancel",
    ]

    /// Claude Code folder-trust prompt, verbatim (fresh directory).
    private let trustPrompt = [
        " Quick safety check: Is this a project you created or one you trust?",
        " Claude Code'll be able to read, edit, and execute files here.",
        " ❯ 1. Yes, I trust this folder",
        "   2. No, exit",
        " Enter to confirm · Esc to cancel",
    ]

    func testPermissionDialogOutranksSpinnerTitle() {
        XCTAssertEqual(
            AgentAttention.classify(title: "⠂ Create probe.txt file", tail: permissionDialog),
            .needsYou(.permission))
    }

    func testAskUserQuestionClassifiesAsQuestion() {
        XCTAssertEqual(
            AgentAttention.classify(title: "⠂ Create probe.txt file", tail: askUserDialog),
            .needsYou(.question))
    }

    func testCodexApprovalContent() {
        XCTAssertEqual(
            AgentAttention.classify(title: "⠧ wd", tail: codexApproval),
            .needsYou(.permission))
    }

    func testTrustPromptDetectedEvenWithNonAgentTitle() {
        // At first launch the shell's title (a hostname) is still up.
        XCTAssertEqual(
            AgentAttention.classify(title: "Jhen-MBPr14.local", tail: trustPrompt),
            .needsYou(.permission))
    }

    func testComposerAndTranscriptDoNotFalsePositive() {
        // Idle composer + status rail: `❯` alone and prompt echoes must not
        // read as an option list; "auto-allows" prose in the What's-new
        // panel must not read as a hint.
        let idleScreen = [
            "`/commit-push-pr` now auto-allows `git push` to the repo's configured push remote",
            "❯ Write a two-line haiku about terminals, then stop.",
            "⏺ Cursor blinks and waits—",
            "  green text on a black ocean.",
            "✻ Worked for 10s",
            "❯ ",
            "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents",
        ]
        XCTAssertEqual(AgentAttention.classify(title: "✳ Write haiku about terminals", tail: idleScreen), .idle)
        XCTAssertEqual(AgentAttention.classify(title: "⠐ Write haiku about terminals", tail: idleScreen), .busy)
    }

    func testDialogOutsideTrailingWindowIsIgnored() {
        // A dialog that scrolled past the live region is history, not state.
        let scrolledAway = permissionDialog + Array(repeating: "output line", count: AgentAttention.questionWindow)
        XCTAssertEqual(
            AgentAttention.classify(title: "✳ Claude Code", tail: scrolledAway),
            .idle)
    }

    // MARK: Notification copy

    func testTaskSummaryStripsStateGlyph() {
        XCTAssertEqual(
            AgentAttention.taskSummary(title: "✳ Write haiku about terminals", agent: .claudeCode),
            "Write haiku about terminals")
        XCTAssertEqual(
            AgentAttention.taskSummary(title: "⠂ Create probe.txt file", agent: .claudeCode),
            "Create probe.txt file")
        // The launch default carries no task; Codex titles carry a cwd.
        XCTAssertNil(AgentAttention.taskSummary(title: "✳ Claude Code", agent: .claudeCode))
        XCTAssertNil(AgentAttention.taskSummary(title: "⠦ wd", agent: .codex))
        XCTAssertNil(AgentAttention.taskSummary(title: "", agent: .claudeCode))
    }

    // MARK: Tracker edges

    func testFirstSightIsBaselineNotEdge() {
        var tracker = AttentionTracker()
        // Relaunching next to a long-standing dialog must not re-notify.
        XCTAssertEqual(
            tracker.update(session: "main", state: .needsYou(.permission), hasBell: false),
            [])
    }

    func testTurnEndEdgeFiresOnce() {
        var tracker = AttentionTracker()
        _ = tracker.update(session: "main", state: .busy, hasBell: false)
        XCTAssertEqual(
            tracker.update(session: "main", state: .idle, hasBell: false),
            [.turnEnded])
        XCTAssertEqual(
            tracker.update(session: "main", state: .idle, hasBell: false),
            [])
    }

    func testNeedsInputEdgeFiresOnceAndPerKind() {
        var tracker = AttentionTracker()
        _ = tracker.update(session: "main", state: .busy, hasBell: false)
        XCTAssertEqual(
            tracker.update(session: "main", state: .needsYou(.permission), hasBell: false),
            [.needsInput(.permission)])
        // The dialog persisting across ticks is the same state, not a new edge.
        XCTAssertEqual(
            tracker.update(session: "main", state: .needsYou(.permission), hasBell: false),
            [])
        // A different dialog kind is a new edge.
        XCTAssertEqual(
            tracker.update(session: "main", state: .needsYou(.question), hasBell: false),
            [.needsInput(.question)])
        // Dialog answered, turn resumes, then ends: exactly one turn end.
        XCTAssertEqual(tracker.update(session: "main", state: .busy, hasBell: false), [])
        XCTAssertEqual(tracker.update(session: "main", state: .idle, hasBell: false), [.turnEnded])
    }

    func testDialogDismissedWithoutTurnEndStaysQuiet() {
        var tracker = AttentionTracker()
        _ = tracker.update(session: "main", state: .needsYou(.permission), hasBell: false)
        _ = tracker.update(session: "main", state: .needsYou(.permission), hasBell: false)
        // needsYou → idle is the user answering; they were there.
        XCTAssertEqual(tracker.update(session: "main", state: .idle, hasBell: false), [])
    }

    func testSameTickEventsCoalesceToMostActionable() {
        // A remote hook can ring the bell on the same tick the turn ends;
        // the hub posts one banner, priority-ordered.
        var tracker = AttentionTracker()
        _ = tracker.update(session: "main", state: .busy, hasBell: false)
        let events = tracker.update(session: "main", state: .idle, hasBell: true)
        XCTAssertTrue(events.contains(.bell))
        XCTAssertTrue(events.contains(.turnEnded))
        XCTAssertEqual(events.max(by: { $0.priority < $1.priority }), .turnEnded)
        // needs-input outranks everything.
        XCTAssertGreaterThan(AttentionEvent.needsInput(.permission).priority, AttentionEvent.turnEnded.priority)
        XCTAssertGreaterThan(AttentionEvent.turnEnded.priority, AttentionEvent.bell.priority)
    }

    func testBellRisingEdgeOnly() {
        var tracker = AttentionTracker()
        _ = tracker.update(session: "main", state: nil, hasBell: false)
        XCTAssertEqual(
            tracker.update(session: "main", state: nil, hasBell: true),
            [.bell])
        // window_bell_flag latches; a still-set flag is not a new bell.
        XCTAssertEqual(
            tracker.update(session: "main", state: nil, hasBell: true),
            [])
    }

    func testPruneResetsBaselineForRecreatedSession() {
        var tracker = AttentionTracker()
        _ = tracker.update(session: "main", state: .busy, hasBell: false)
        tracker.prune(keeping: [])
        // Same name, new session: first sight again, no phantom turn-end.
        XCTAssertEqual(tracker.update(session: "main", state: .idle, hasBell: false), [])
    }

    func testAgentLossDropsStateWithoutEvents() {
        var tracker = AttentionTracker()
        _ = tracker.update(session: "main", state: .busy, hasBell: false)
        // Probe flap: agent detection misses a tick (state nil) — no edge.
        XCTAssertEqual(tracker.update(session: "main", state: nil, hasBell: false), [])
        // Recovery to idle after a nil is not busy→idle.
        XCTAssertEqual(tracker.update(session: "main", state: .idle, hasBell: false), [])
    }

    // MARK: Probe plumbing

    func testProbeParseCarriesPaneTitle() {
        let output = """
        S $1 0 1751000000 main
        W $1 0 1 0 0 editor
        P $1 0 1 4242 2.1.206 ⠂ Create probe.txt file
        """
        let sessions = TmuxProbe.parse(output).sessions
        XCTAssertEqual(sessions.first?.activeWindow?.paneTitle, "⠂ Create probe.txt file")
        // Bare-semver comm still classifies the agent while the busy title
        // (no "✳"/"Claude Code") gives the title rule nothing.
        XCTAssertEqual(sessions.first?.activeAgent, .claudeCode)
    }

    // MARK: Pro gate

    @MainActor
    func testAlertsGatedByPro() {
        let defaults = UserDefaults(suiteName: "attention-pro-test")!
        defaults.removePersistentDomain(forName: "attention-pro-test")
        let center = AttentionCenter()
        center.alertsEnabled = true

        // No entitlement wired → locked → inactive even with the switch on.
        XCTAssertFalse(center.isActive)

        // Explicit lock (DEBUG's absent-key default is unlocked, so set it).
        defaults.set(false, forKey: "MultiplexProUnlocked")
        let locked = EntitlementStore(defaults: defaults)
        center.entitlements = locked
        XCTAssertFalse(locked.isPro)
        XCTAssertFalse(center.isActive)

        defaults.set(true, forKey: "MultiplexProUnlocked")
        let unlocked = EntitlementStore(defaults: defaults)
        center.entitlements = unlocked
        XCTAssertTrue(unlocked.isPro)
        XCTAssertTrue(center.isActive)    // Pro + switch on → active

        // The switch still wins when Pro is owned.
        center.alertsEnabled = false
        XCTAssertFalse(center.isActive)
        defaults.removePersistentDomain(forName: "attention-pro-test")
    }

    func testParseTailsKeepsFullDialogWhileMiniatureClips() {
        let dialog = permissionDialog.joined(separator: "\n")
        let output = "MULTIPLEX_TAILS\nMPXS $1\n\(dialog)\n\nMPXE"
        let sessions = [TmuxSession(name: "main", windows: [], created: .init(), tmuxID: "$1")]
        let tails = TmuxProbe.parseTails(output, sessions: sessions)
        XCTAssertEqual(tails["main"]?.count, permissionDialog.count)
        XCTAssertEqual(tails["main"]?.first, "❯ Run the shell command: touch probe.txt")
        let miniature = TmuxProbe.miniatureTail(tails["main"] ?? [])
        XCTAssertEqual(miniature.count, TmuxProbe.miniatureLines)
        XCTAssertEqual(miniature.last, " Esc to cancel · Tab to amend · ctrl+e to explain")
    }
}
