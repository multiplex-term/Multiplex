import Foundation

/// What an agent's pane is doing, as seen from outside — classified from
/// the probe's `pane_title` plus the capture-pane tail. Verified against
/// Claude Code v2.1.206 and Codex rust-v0.144.1 inside tmux 3.6a on
/// 2026-07-11; tall AskUserQuestion dialogs re-verified live against
/// v2.1.216 on 2026-07-21. Experiment captures live in
/// local-plan/agent-attention.md.
enum PaneAgentState: Equatable {
    /// Turn in flight — Claude Code and Codex prefix their OSC title with a
    /// Braille spinner glyph (U+2800…U+28FF) while working.
    case busy
    /// Composer up, waiting for a prompt.
    case idle
    /// Blocked on the user: a permission/approval dialog or a question.
    case needsYou(AttentionKind)
}

enum AttentionKind: Equatable {
    /// "Do you want to proceed?" / "Would you like to run…" — approval to act.
    case permission
    /// AskUserQuestion and other option choosers.
    case question
}

/// One notification-worthy edge between two probe observations.
enum AttentionEvent: Equatable {
    case turnEnded
    case needsInput(AttentionKind)
    /// Opt-in remote bell (hooks / terminal_bell) surfaced by tmux's
    /// latched `window_bell_flag`.
    case bell

    /// When several edges land on one session in one tick (a hook's bell
    /// often coincides with the turn end it marks), the most actionable one
    /// wins the session's single banner slot. Needs-input outranks a plain
    /// turn end outranks a bare bell.
    var priority: Int {
        switch self {
        case .needsInput: 3
        case .turnEnded: 2
        case .bell: 1
        }
    }
}

/// A ready-to-deliver attention moment; `AttentionCenter` applies focus
/// policy and posts it.
struct AttentionAlert {
    var host: Host
    var sessionName: String
    /// Present for an event emitted by a plain-shell tab. tmux probe events
    /// remain session-scoped because the same remote session may have more
    /// than one attached client, while every plain shell is its own process.
    var tabID: UUID? = nil
    var agent: AgentKind?
    var event: AttentionEvent
    var paneTitle: String
}

/// The state classifier. Everything here matches *structure*, not prose —
/// the agents' spinner verbs and dialog copy are undocumented UI that
/// already shifted once (v2.1.206 dropped the "esc to interrupt" hint the
/// obvious detector would have keyed on). Fail-soft like `AgentSignature`:
/// a state we can't read is `.idle`, never an error.
enum AgentAttention {
    /// How many trailing capture lines may anchor a live dialog — both TUIs
    /// keep the dialog's hint/question row against the bottom of the screen
    /// and collapse a resolved dialog in place (they redraw; it doesn't
    /// linger in the tail), so a hint here is a dialog that is up *now*.
    static let questionWindow = 15

    /// How far above the bottom the selection caret may sit. The hint row
    /// stays inside `questionWindow`, but AskUserQuestion renders every
    /// option's full description *below* the caret, so a multi-option
    /// dialog separates `❯ N.` from its own hint row by more than 15
    /// wrapped lines (observed live on v2.1.216: 22 lines at 53 columns —
    /// and an iPhone pane is ~44 columns, wrapping further). Still bounded:
    /// the dialog redraws inside the live pane, and pairing with the hint
    /// keeps this out of scrollback-prose territory.
    static let questionCaretWindow = 45

    /// Classify only agents whose outside-the-pane signals are known. Keeping
    /// this boundary here prevents a newly detected agent from accidentally
    /// inheriting Claude/Codex alerts or RUNNING telemetry.
    static func classifyVerified(
        title: String,
        tail: [String],
        agent: AgentKind?
    ) -> PaneAgentState? {
        guard agent?.hasVerifiedAttentionSignals == true else { return nil }
        return classify(title: title, tail: tail)
    }

    static func classify(title: String, tail: [String]) -> PaneAgentState {
        // Codex names the state outright while waiting for approval:
        // "[ ! ] Action Required | <cwd>" (blinks [ ! ] / [ . ]).
        if title.contains("Action Required |") { return .needsYou(.permission) }
        // Claude Code keeps its spinner title through dialogs — the dialog
        // itself is the only outside sign, so content outranks the title.
        if let kind = questionShape(in: tail) { return .needsYou(kind) }
        if hasSpinnerPrefix(title) { return .busy }
        return .idle
    }

    /// Claude Code and Codex prefix the title with a Braille spinner while a
    /// turn is in flight (Claude Code: "⠂ Create probe.txt file", Codex:
    /// "⠦ wd") and drop it when the turn ends ("✳ …" / bare cwd).
    static func hasSpinnerPrefix(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(first.value)
    }

    /// A dialog blocked on the user renders a caret-selected numbered
    /// option list plus a confirm-hint line. Requiring both — the hint in
    /// the trailing window, the caret in the wider dialog region — keeps
    /// prompt echoes ("❯ Write a haiku…") and scrollback prose from
    /// false-positiving.
    static func questionShape(in tail: [String]) -> AttentionKind? {
        let lines = tail.suffix(questionWindow)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { line in confirmHints.contains { line.contains($0) } })
        else { return nil }
        let dialogRegion = tail.suffix(questionCaretWindow)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard dialogRegion.contains(where: isCaretOptionRow) else { return nil }
        let isPermission = lines.contains { line in
            permissionMarks.contains { line.contains($0) }
        }
        return isPermission ? .permission : .question
    }

    /// The selection caret's own row — "❯ 1. Yes" / "› 3. No". Any ordinal
    /// matches: arrow keys move the caret off option 1 while the dialog
    /// stays up (and any attached client's arrows move it for every
    /// client), so keying on "1." dropped the standing needs-you state the
    /// moment someone navigated. The ordinal-then-dot shape is what keeps
    /// prompt echoes ("❯ 1st of all…") from reading as an option row.
    private static func isCaretOptionRow(_ line: String) -> Bool {
        guard line.hasPrefix("❯") || line.hasPrefix("›") else { return false }
        let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
        let ordinal = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...2).contains(ordinal.count) else { return false }
        return rest.dropFirst(ordinal.count).hasPrefix(".")
    }

    /// Notification copy from a Claude Code title: the task summary after
    /// the state glyph ("✳ Write haiku about terminals"). Codex titles
    /// carry the cwd, not a task — nil there. The summary can lag a prompt
    /// behind (observed), so it's flavor, never the headline.
    static func taskSummary(title: String, agent: AgentKind?) -> String? {
        guard agent == .claudeCode else { return nil }
        var text = title
        if let first = text.unicodeScalars.first,
           first.value == 0x2733 /* ✳ */ || (0x2800...0x28FF).contains(first.value) {
            text = String(text.unicodeScalars.dropFirst())
                .trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, text != "Claude Code" else { return nil }
        return text
    }

    /// Hint lines that accompany a blocking dialog. Trailing punctuation
    /// and separators vary; these stems don't (v2.1.206 / rust-v0.144.1).
    private static let confirmHints = [
        "Do you want to proceed",       // Claude Code tool permission
        "Would you like to run",        // Codex command approval
        "Press enter to confirm",       // Codex approval hint row
        "Enter to confirm",             // Claude Code trust prompt hint row
        "Enter to select",              // Claude Code AskUserQuestion hint row
    ]

    /// Within a detected dialog, these mark the permission family.
    private static let permissionMarks = [
        "Do you want to proceed",
        "Would you like to run",
        "Bash command",
        "trust this folder",
    ]
}

/// Edge detector over successive observations of one host's sessions —
/// pure, owned by `HostConnectionModel`, exercised directly by tests.
/// The first sighting of a session is a baseline, not an edge: relaunching
/// the app next to a long-waiting dialog must not re-notify (the wall
/// badge shows standing state; events are for changes).
struct AttentionTracker {
    private struct Observation: Equatable {
        var state: PaneAgentState?
        var hasBell: Bool
    }

    private var previous: [String: Observation] = [:]

    /// Feed one observation; get the events this edge produces. `state` is
    /// nil when the session has no detected agent (bells still track).
    mutating func update(
        session: String,
        state: PaneAgentState?,
        hasBell: Bool
    ) -> [AttentionEvent] {
        let prior = previous[session]
        previous[session] = Observation(state: state, hasBell: hasBell)
        guard let prior else { return [] }
        var events: [AttentionEvent] = []
        // window_bell_flag latches until the window is next viewed, so only
        // the rising edge means a new bell.
        if hasBell, !prior.hasBell {
            events.append(.bell)
        }
        if prior.state == .busy, state == .idle {
            events.append(.turnEnded)
        }
        if case .needsYou(let kind) = state, prior.state != state {
            events.append(.needsInput(kind))
        }
        return events
    }

    /// Drop sessions that no longer exist so a recreated namesake starts
    /// from a fresh baseline.
    mutating func prune(keeping sessions: Set<String>) {
        previous = previous.filter { sessions.contains($0.key) }
    }

    mutating func reset() {
        previous = [:]
    }
}
