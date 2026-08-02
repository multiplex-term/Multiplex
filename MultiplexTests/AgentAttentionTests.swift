import XCTest
@testable import Multiplex

/// Pins the attention rules to the states captured from the real CLIs on
/// 2026-07-11 (Claude Code v2.1.206, Codex rust-v0.144.1, tmux 3.6a) and
/// 2026-07-21 (Claude Code v2.1.216 tall AskUserQuestion) — the
/// experiment record is local-plan/agent-attention.md. Titles and dialog
/// blocks below are verbatim captures; when an agent's TUI shifts, this
/// file is where the new truth lands.
final class AgentAttentionTests: XCTestCase {
    func testOnlyAgentsWithVerifiedAttentionSignalsParticipate() {
        XCTAssertTrue(AgentKind.claudeCode.hasVerifiedAttentionSignals)
        XCTAssertTrue(AgentKind.codex.hasVerifiedAttentionSignals)
        XCTAssertFalse(AgentKind.pi.hasVerifiedAttentionSignals)

        let permissionTail = [
            "❯ 1. Yes",
            "  2. No",
            "Enter to select",
            "Do you want to proceed?",
        ]
        // Pi has neither a verified RUNNING title transition nor verified
        // question/permission shapes. Exercise those paths independently so
        // adding a generic classifier rule cannot silently opt Pi back in.
        XCTAssertNil(AgentAttention.classifyVerified(
            title: "⠙ working",
            tail: [],
            agent: .pi
        ))
        XCTAssertNil(AgentAttention.classifyVerified(
            title: "π - repo",
            tail: permissionTail,
            agent: .pi
        ))
        XCTAssertNil(AgentAttention.classifyVerified(
            title: "⠙ working",
            tail: permissionTail,
            agent: nil
        ))
        XCTAssertEqual(
            AgentAttention.classifyVerified(
                title: "⠙ working",
                tail: [],
                agent: .codex
            ),
            .busy
        )
    }

    // MARK: Title state machine

    func testTitleIdleStates() {
        // Claude Code before/after work, Codex idle (cwd basename), and the
        // non-agent defaults a shell leaves behind.
        XCTAssertEqual(AgentAttention.classify(title: "✳ Claude Code", tail: []), .idle)
        XCTAssertEqual(AgentAttention.classify(title: "✳ Write haiku about terminals", tail: []), .idle)
        XCTAssertEqual(AgentAttention.classify(title: "wd", tail: []), .idle)
        // Pi's title identifies the TUI but stays static during work; without
        // a reliable transition signal attention deliberately fails soft.
        XCTAssertEqual(AgentAttention.classify(title: "π - Multiplex", tail: []), .idle)
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

    /// Claude Code AskUserQuestion with four described options, verbatim
    /// (v2.1.216, live capture 2026-07-21, 53-column tmux pane). Wrapped
    /// descriptions put `❯ 1.` 22 lines above the hint row — past the old
    /// 15-line window, which classified this as `.idle`: no NEEDS YOU
    /// badge, no notification (user-reported on iPhone, whose ~44-column
    /// panes wrap even further).
    private let tallAskUserDialog = [
        "─────────────────────────────────────────────────────",
        " ☐ List scope",
        "",
        "The spec says \"show online devices in the current",
        "workspace\" — strictly online-only, or all workspace",
        "devices with online status? (CLI convention: online =",
        "last_alive_time within 5 min, so strictly-online",
        "lists will visibly flap as devices flake.)",
        "",
        "❯ 1. All devices, online first (Recommended)",
        "     List every workspace device sorted online-first",
        "     with a clear ● Online / ○ Offline (Xm ago)",
        "     status like the CLI. Offline rows are dimmed.",
        "     More stable UI, and offline-but-expected devices",
        "     are visible (often what you're debugging).",
        "  2. Online only",
        "     Strictly filter to alive-within-5-min devices.",
        "     Cleaner list matching the literal spec, but",
        "     devices flapping around the threshold",
        "     appear/disappear, and you can't see a device",
        "     that just dropped.",
        "  3. Online + recently offline",
        "     Show online devices plus devices seen in the",
        "     last N hours (e.g. 24h); hide long-dead ones.",
        "     Middle ground, but introduces an arbitrary",
        "     cutoff to explain.",
        "  4. Type something.",
        "─────────────────────────────────────────────────────",
        "  5. Chat about this",
        "",
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

    func testTallAskUserQuestionCaretBeyondHintWindow() {
        // While the dialog is up the title has already dropped its spinner
        // ("✳ …", observed live) — content alone must carry the state.
        XCTAssertEqual(
            AgentAttention.classify(
                title: "✳ Implement devices panel with online status",
                tail: tallAskUserDialog),
            .needsYou(.question))
        XCTAssertEqual(
            AgentAttention.classify(title: "⠂ Implement devices panel", tail: tallAskUserDialog),
            .needsYou(.question))
    }

    func testCaretOnLaterOptionKeepsQuestionState() {
        // Arrow keys move the caret off option 1 — the dialog is still up,
        // so the standing needs-you state must not flicker back to idle.
        let navigated = askUserDialog.map { line in
            switch line {
            case "❯ 1. Cats": "  1. Cats"
            case "  2. Dogs": "❯ 2. Dogs"
            default: line
            }
        }
        XCTAssertEqual(
            AgentAttention.classify(title: "✳ Preference", tail: navigated),
            .needsYou(.question))
    }

    func testCaretRowRequiresOrdinalThenDot() {
        // A prompt echo starting with a bare number or "1st…" must not read
        // as an option row even when hint-like prose sits at the bottom
        // (working *on* these strings puts them in real transcripts).
        let prose = [
            "❯ 1st of all, check the docs",
            "❯ 1 more thing to try",
            "❯ 123. numbered like a spec section",
            "the hint stem is Enter to select · reviewed above",
        ]
        XCTAssertEqual(AgentAttention.classify(title: "✳ Claude Code", tail: prose), .idle)
    }

    func testCaretWithoutHintStaysIdle() {
        // An option-shaped row inside the caret window with no hint row in
        // the trailing window is transcript history, not a live dialog.
        let scrolled = ["❯ 1. Yes"]
            + Array(repeating: "output line", count: AgentAttention.questionWindow)
        XCTAssertEqual(AgentAttention.classify(title: "✳ Claude Code", tail: scrolled), .idle)
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

    // MARK: Dialog summaries (notification body copy)

    func testQuestionDialogSummaryLeadsWithHeaderAndQuestion() {
        XCTAssertEqual(
            AgentAttention.dialogSummary(in: askUserDialog, kind: .question),
            "Preference — Do you prefer cats or dogs?")
    }

    func testTallQuestionDialogSummaryJoinsWrappedTextAndClips() {
        let summary = AgentAttention.dialogSummary(in: tallAskUserDialog, kind: .question)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.hasPrefix(
            "List scope — The spec says \"show online devices in the current workspace\"") == true)
        // Wrapped question rows join into prose; runaway text stays a glance.
        XCTAssertEqual(summary?.count, 180)
        XCTAssertTrue(summary?.hasSuffix("…") == true)
    }

    func testPermissionDialogSummaryUsesToolHaloLine() {
        XCTAssertEqual(
            AgentAttention.dialogSummary(in: permissionDialog, kind: .permission),
            "Bash(touch probe.txt)")
    }

    func testCodexApprovalSummaryUsesCommandLine() {
        XCTAssertEqual(
            AgentAttention.dialogSummary(in: codexApproval, kind: .permission),
            "$ mkdir -p /tmp/mplx-codex-probe2")
    }

    func testDialogSummaryFailsSoftWhenStructureIsAbsent() {
        // The trust prompt carries neither a tool halo nor a command line;
        // an idle screen has no dialog at all. Both fall back to nil so the
        // notification keeps its task-summary/place copy.
        XCTAssertNil(AgentAttention.dialogSummary(in: trustPrompt, kind: .permission))
        XCTAssertNil(AgentAttention.dialogSummary(in: [], kind: .question))
        XCTAssertNil(AgentAttention.dialogSummary(
            in: ["❯ 1. Cats", "Enter to select"], kind: .question))
    }

    // MARK: Notification copy

    func testNotificationCopyLeadsWithDialogContent() {
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let copy = AttentionCenter.copy(for: AttentionAlert(
            host: host,
            sessionName: "claude-ctor-devices-panel",
            agent: .claudeCode,
            event: .needsInput(.question),
            paneTitle: "✳ Implement devices panel with online status",
            dialogSummary: "List scope — The spec says…"
        ))
        XCTAssertEqual(copy.title, "Claude Code has a question")
        // Identifiers move to the subtitle so a long session name cannot
        // truncate the question out of the banner.
        XCTAssertEqual(copy.subtitle, "claude-ctor-devices-panel · devbox")
        XCTAssertEqual(copy.body, "List scope — The spec says…")
    }

    func testNotificationCopyFallsBackToTaskSummaryThenPlace() {
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let turnEnd = AttentionCenter.copy(for: AttentionAlert(
            host: host,
            sessionName: "main",
            agent: .claudeCode,
            event: .turnEnded,
            paneTitle: "✳ Write haiku about terminals"
        ))
        XCTAssertEqual(turnEnd.title, "Claude Code finished")
        XCTAssertEqual(turnEnd.subtitle, "main · devbox")
        XCTAssertEqual(turnEnd.body, "Write haiku about terminals")
        // No dialog copy and no task summary (Codex titles carry a cwd):
        // the place stays the body rather than duplicating into both slots.
        let bare = AttentionCenter.copy(for: AttentionAlert(
            host: host,
            sessionName: "wd",
            agent: .codex,
            event: .turnEnded,
            paneTitle: "wd"
        ))
        XCTAssertEqual(bare.title, "Codex finished")
        XCTAssertNil(bare.subtitle)
        XCTAssertEqual(bare.body, "wd · devbox")
    }

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
        XCTAssertNil(AgentAttention.taskSummary(title: "π - Multiplex", agent: .pi))
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
        P $1 0 0 1 %1 4242 /dev/pts/1 2.1.206 ⠂ Create probe.txt file
        """
        let sessions = TmuxProbe.parse(output).sessions
        XCTAssertEqual(sessions.first?.activeWindow?.paneTitle, "⠂ Create probe.txt file")
        // Bare-semver comm still classifies the agent while the busy title
        // (no "✳"/"Claude Code") gives the title rule nothing.
        XCTAssertEqual(sessions.first?.activeAgent, .claudeCode)
    }

    // MARK: Notification tap

    func testTapTargetUserInfoRoundTrip() {
        let session = AttentionTapTarget(
            hostID: UUID(), sessionName: "main", backend: .herdr)
        XCTAssertEqual(AttentionTapTarget(userInfo: session.userInfo), session)
        XCTAssertTrue(session.sessionIsAttachable)

        let tab = AttentionTapTarget(
            hostID: UUID(), sessionName: "shell", backend: .tmux, tabID: UUID())
        XCTAssertEqual(AttentionTapTarget(userInfo: tab.userInfo), tab)
        // A tab-scoped alert's session name is display copy — pressing its
        // banner must never mint an attach to a namesake session.
        XCTAssertFalse(tab.sessionIsAttachable)

        // A banner from another payload shape decodes to nil (the press
        // just foregrounds the app), and so does a corrupted backend.
        XCTAssertNil(AttentionTapTarget(userInfo: [:]))
        var corrupted = session.userInfo
        corrupted["attentionBackend"] = "screen"
        XCTAssertNil(AttentionTapTarget(userInfo: corrupted))
    }

    func testAlertBuildsTapTargetFromHostIdentity() {
        var host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        host.sessionBackend = .herdr
        let target = AttentionAlert(
            host: host,
            sessionName: "deploy",
            agent: .pi,
            event: .turnEnded,
            paneTitle: ""
        ).tapTarget
        XCTAssertEqual(target.hostID, host.id)
        XCTAssertEqual(target.sessionName, "deploy")
        XCTAssertEqual(target.backend, .herdr)
        XCTAssertNil(target.tabID)
    }

    @MainActor
    func testTapRevealsOpenTabBySessionIdentity() {
        let center = AttentionCenter()
        let workspace = TerminalWorkspace()
        center.workspace = workspace
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let tmuxTab = TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main"))
        let herdrTab = TerminalRoute(hostID: host.id, mode: .herdrAttach(sessionName: "main"))
        var revealed: [UUID] = []
        workspace.registerWindow(TerminalWorkspace.WindowEntry(
            id: UUID(),
            tabs: [tmuxTab, herdrTab],
            label: "terminal",
            reveal: { revealed.append($0) },
            surrender: { [] },
            adopt: { _ in }
        ))
        var submitted: [ExternalAction] = []
        center.performExternalAction = { submitted.append($0) }

        // Backend is identity: both namespaces hold "main", and each press
        // must reveal its own backend's tab.
        center.handleTap(AttentionTapTarget(
            hostID: host.id, sessionName: "main", backend: .herdr))
        XCTAssertEqual(revealed, [herdrTab.id])
        center.handleTap(AttentionTapTarget(
            hostID: host.id, sessionName: "main", backend: .tmux))
        XCTAssertEqual(revealed, [herdrTab.id, tmuxTab.id])

        // A tab-scoped alert reveals its exact tab even though a plain
        // shell has no session identity to match.
        let shellTab = TerminalRoute(hostID: host.id, mode: .shell)
        workspace.registerWindow(TerminalWorkspace.WindowEntry(
            id: UUID(),
            tabs: [shellTab],
            label: "shell",
            reveal: { revealed.append($0) },
            surrender: { [] },
            adopt: { _ in }
        ))
        center.handleTap(AttentionTapTarget(
            hostID: host.id, sessionName: "shell", backend: .tmux, tabID: shellTab.id))
        XCTAssertEqual(revealed.last, shellTab.id)

        // Every press above found its window — none may fall through to
        // the external-action seam.
        XCTAssertTrue(submitted.isEmpty)
    }

    @MainActor
    func testTapWithoutOpenWindowAttachesViaExternalSeam() {
        let center = AttentionCenter()
        center.workspace = TerminalWorkspace()
        var submitted: [ExternalAction] = []
        center.performExternalAction = { submitted.append($0) }
        let hostID = UUID()

        // A session-scoped alert re-attaches through the widget seam (the
        // router queues behind the app lock and raises the deck itself).
        center.handleTap(AttentionTapTarget(
            hostID: hostID, sessionName: "deploy", backend: .herdr))
        XCTAssertEqual(submitted, [.openShell(host: .id(hostID), sessionName: "deploy")])

        // A tab-scoped alert whose tab died stops at the reveal attempt:
        // its "shell" display name is not an attachable session.
        center.handleTap(AttentionTapTarget(
            hostID: hostID, sessionName: "shell", backend: .tmux, tabID: UUID()))
        XCTAssertEqual(submitted.count, 1)
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
        let locked = EntitlementStore(defaults: defaults, startStoreKit: false)
        center.entitlements = locked
        XCTAssertFalse(locked.isPro)
        XCTAssertFalse(center.isActive)

        defaults.set(true, forKey: "MultiplexProUnlocked")
        let unlocked = EntitlementStore(defaults: defaults, startStoreKit: false)
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
