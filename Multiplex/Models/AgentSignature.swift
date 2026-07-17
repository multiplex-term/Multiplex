import Foundation

/// Which CLI agent is driving a tmux pane.
enum AgentKind: String, Hashable, Codable, CaseIterable {
    case claudeCode
    case codex
    case pi

    /// Strip header / accessibility voice.
    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        }
    }

    /// Deck telemetry token ("3 WIN · 2h · CLAUDE").
    var telemetryLabel: String {
        switch self {
        case .claudeCode: "CLAUDE"
        case .codex: "CODEX"
        case .pi: "PI"
        }
    }

    /// What the "new session + agent" flows type into the fresh shell (and
    /// use as the session's base name). Typed, never executed directly —
    /// the login shell's PATH resolves it like a human launching the agent.
    var launchCommand: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .pi: "pi"
        }
    }

    /// Whether the agent exposes title/dialog transitions that the attention
    /// classifier has been verified against. Pi's identifying title remains
    /// static while work runs, so detection and helpers stay available while
    /// attention deliberately fails soft.
    var hasVerifiedAttentionSignals: Bool {
        switch self {
        case .claudeCode, .codex: true
        case .pi: false
        }
    }
}

/// One `pid ppid args` row of the probe's `ps -eo pid=,ppid=,args=` stage.
struct PSRow: Hashable {
    var pid: Int
    var ppid: Int
    var args: String
}

/// How Multiplex recognizes an agent from probe output. All rules verified
/// against real processes on 2026-07-10 (Claude Code v2.1.206, Codex
/// rust-v0.144.x) and 2026-07-15 (Pi v0.80.7, npm + native) — see
/// local-plan/agent-harness-helpers.md §1.1 for the original experiment
/// matrix. Everything here is pure and pinned by AgentSignatureTests; when
/// an agent changes its signature, this file and its tests are the whole
/// blast radius.
enum AgentSignature {
    /// Cheap first pass over one pane's `#{pane_current_command}` +
    /// `#{pane_title}`. Order matters.
    static func classify(command: String, title: String) -> AgentKind? {
        // Exact process signals always beat a stale OSC title.
        if let direct = agentNamed(command) { return direct }
        // Claude Code sets its pane title via OSC 0/2 (undocumented, stable
        // through v2.1.x). Never match bare "claude" — the default title is
        // whatever a shell prompt wrote there, often a hostname.
        if title.contains("Claude Code") || title.hasPrefix("✳ ") { return .claudeCode }
        // Pi's npm entrypoint remains `node` to tmux on macOS, while its
        // interactive UI writes this narrow OSC title. Pi leaves that title
        // behind after returning to the shell, so it is authoritative only
        // while the observed npm wrapper still owns the pane. Native Pi
        // reports `pi` above; overridden titles fall through to the ps walk.
        if command == "node", title.hasPrefix("π - ") { return .pi }
        // macOS native launcher: ~/.local/bin/claude is a symlink into
        // versions/<semver>, and the BSD comm is the resolved file's
        // basename — a bare version number. Nothing else realistically runs
        // in a pane with a semver comm.
        if isBareVersionNumber(command) { return .claudeCode }
        // "node" alone is never enough — the process-tree walk decides.
        return nil
    }

    /// In-band fallback for a plain shell whose transport has no SSH exec
    /// surface (a direct mosh shell), or whose remote `ps` cannot expose
    /// pgid/tpgid. SSH plain shells normally use `ShellAgentProbe` instead,
    /// because process identity is authoritative and clears cleanly on exit.
    ///
    /// Keep this deliberately narrow: Claude identifies itself in its OSC
    /// title, Codex has a versioned screen masthead and a unique approval
    /// title, and a spinner may only preserve an already-known kind. Pi's OSC
    /// title is omitted because Pi leaves it stale after exit. Visible lines
    /// stay lazy so an explicit title signature never translates the screen.
    static func classifyTerminal(
        title: String,
        visibleLines: @autoclosure () -> [String],
        isAlternateScreen: Bool,
        previous: AgentKind?
    ) -> AgentKind? {
        if title.contains("Claude Code") || title.hasPrefix("✳ ") {
            return .claudeCode
        }
        if title.contains("Action Required |") {
            return .codex
        }

        let codexMasthead = visibleLines().contains { line in
            line.contains("OpenAI Codex") && line.contains("(v")
        }
        if codexMasthead { return .codex }

        if AgentAttention.hasSpinnerPrefix(title),
           let previous,
           previous.hasVerifiedAttentionSignals {
            return previous
        }
        // Codex normally owns the alternate screen for its whole lifetime;
        // its masthead can scroll out after a long turn, so preserve a
        // previously established identity until the TUI restores the shell's
        // normal buffer. The process probe remains authoritative on SSH.
        if previous == .codex, isAlternateScreen { return .codex }
        return nil
    }

    /// Authority pass: does this ps row's argv belong to an agent?
    /// Matches argv[0] basename exactly — NEVER substring-of-args (Claude
    /// Desktop helpers, Zed's claude-agent-sdk, and --user-data-dir=…/Claude
    /// flags all false-positive otherwise). The interpreter rule covers
    /// shebang/JS wrappers ("node …/bin/claude", "node …/codex.js" spawn
    /// chains still expose the native child, but old installs may not).
    static func match(argv args: String) -> AgentKind? {
        let argv = args.split(separator: " ")
        guard let first = argv.first else { return nil }
        if let kind = agentNamed(basename(of: first)) { return kind }
        if ["node", "bun"].contains(basename(of: first)), argv.count > 1 {
            return agentNamed(basename(of: argv[1]))
        }
        return nil
    }

    /// Walk panePID and its descendants (the pane's own process tree —
    /// scoping is what keeps argv matching safe) for the first agent match.
    static func agentInTree(rows: [PSRow], panePID: Int) -> AgentKind? {
        agentsInTrees(rows: rows, panePIDs: [panePID])[panePID]
    }

    /// Classify several pane roots from one process snapshot. The full wall
    /// probe can contain many splits (and linked windows repeat pane PIDs),
    /// so build the PID indexes once and walk each unique root once instead
    /// of rebuilding dictionaries for every pane.
    static func agentsInTrees(rows: [PSRow], panePIDs: [Int]) -> [Int: AgentKind] {
        var children: [Int: [PSRow]] = [:]
        var byPID: [Int: PSRow] = [:]
        for row in rows {
            children[row.ppid, default: []].append(row)
            byPID[row.pid] = row
        }

        var result: [Int: AgentKind] = [:]
        for panePID in Set(panePIDs) where panePID > 0 {
            var queue = [panePID]
            var cursor = 0
            var seen = Set<Int>()
            // Depth/breadth cap: no pane tree is this big; a cycle in forged
            // input must not spin. An index cursor keeps traversal O(n).
            while cursor < queue.count, seen.count < 512 {
                let pid = queue[cursor]
                cursor += 1
                guard seen.insert(pid).inserted else { continue }
                if let row = byPID[pid], let kind = match(argv: row.args) {
                    result[panePID] = kind
                    break
                }
                queue.append(contentsOf: (children[pid] ?? []).map(\.pid))
            }
        }
        return result
    }

    private static func agentNamed(_ name: String) -> AgentKind? {
        switch name {
        case "claude": .claudeCode
        case "codex": .codex
        case "pi": .pi
        default: nil
        }
    }

    private static func basename(of token: Substring) -> String {
        String(token.split(separator: "/").last ?? token)
    }

    private static func isBareVersionNumber(_ command: String) -> Bool {
        let parts = command.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

/// One helper chip: the label it shows and the bytes it types. Chips only
/// ever *type* — a stale command fails visibly in the agent's own input box.
struct AgentCommand: Identifiable, Hashable {
    var label: String
    var payload: Data
    /// The command consumes one free-tier daily taste when it is actually
    /// sent. Keyboard-equivalent helpers deliberately leave this false.
    var consumesSlashChipTaste = false
    /// After typing the payload, pause and send CR as a separate write.
    /// Codex's composer treats Enter arriving inside a rapid input burst as
    /// a pasted newline, not a submit (verified against rust-v0.144: burst
    /// "/new\r" leaves the text sitting in the composer; a CR ≥120 ms later
    /// submits). The other supported agents accept the delayed shape too.
    var submitsAfterPause = false

    var id: String { label }

    /// A slash command typed, then submitted after the burst-detector pause.
    static func slash(_ name: String) -> AgentCommand {
        AgentCommand(
            label: "/\(name)",
            payload: Data(("/" + name).utf8),
            consumesSlashChipTaste: true,
            submitsAfterPause: true
        )
    }

    /// Interrupt the running turn. Esc in every supported TUI.
    static let stop = AgentCommand(label: "STOP", payload: Data([0x1B]))

    /// Cycle permission / collaboration mode — Shift+Tab, which terminals
    /// send as CSI Z. A fixed default binding in Claude Code and Codex. Never
    /// ship a Ctrl+B payload here: that's the remote tmux prefix and gets eaten.
    static let mode = AgentCommand(label: "MODE", payload: Data([0x1B, 0x5B, 0x5A]))

    /// Cycle Pi's thinking level. Pi also binds Shift+Tab, but calling this
    /// MODE would misdescribe its effect.
    static let think = AgentCommand(label: "THINK", payload: Data([0x1B, 0x5B, 0x5A]))

    /// Toggle Codex's transcript overlay — Ctrl+T (0x14), a fixed default
    /// binding in the rust TUI. Only the tmux prefix (Ctrl+B) is special;
    /// Ctrl+T passes through to the pane untouched.
    static let transcript = AgentCommand(label: "TRANSCRIPT", payload: Data([0x14]))

    /// Pi's default bindings. Ctrl+O expands/collapses tool output; Ctrl+T
    /// expands/collapses thinking blocks (users can remap them in Pi).
    static let tools = AgentCommand(label: "TOOLS", payload: Data([0x0F]))
    static let thinking = AgentCommand(label: "THINKING", payload: Data([0x14]))

    /// Page the agent's transcript — PgUp/PgDn are CSI 5~/6~ (fixed; unlike
    /// arrows they have no DECCKM variant). Claude Code pages with them.
    static let pageUp = AgentCommand(label: "PG UP", payload: Data([0x1B, 0x5B, 0x35, 0x7E]))
    static let pageDown = AgentCommand(label: "PG DN", payload: Data([0x1B, 0x5B, 0x36, 0x7E]))
}

/// Where one built-in helper appears. The stock command set supplies the
/// default; per-host synced overrides move individual commands between the
/// scrolling bar and MORE without changing the bytes they type.
enum AgentCommandPlacement: String, Codable, Hashable {
    case bar
    case more
}

/// The curated command sets, one place to tune. Slash lists verified
/// 2026-07-10 — Claude Code v2.1.x docs; Codex rust-v0.144.1 slash_command.rs
/// (note: Codex renamed /approvals → /permissions and dropped /undo).
/// Pi's list was verified against v0.80.7 on 2026-07-15.
enum AgentCommandSet {
    static func primary(for kind: AgentKind) -> [AgentCommand] {
        switch kind {
        case .claudeCode:
            var commands: [AgentCommand] = [
                .stop, .slash("clear"), .slash("resume"), .slash("compact"),
                .slash("rewind"), .slash("model"), .slash("effort"), .mode,
            ]
            #if os(visionOS)
            // visionOS has no key rail (SwiftTerm never plumbs an accessory
            // there), so transcript paging lives on the strip; iPad's
            // TerminalKeyBar already carries autorepeating PgUp/PgDn.
            commands += [.pageUp, .pageDown]
            #endif
            return commands
        case .codex:
            return [.stop, .slash("new"), .slash("resume"), .slash("model"),
                    .slash("permissions"), .slash("review"),
                    .transcript, .mode]
        case .pi:
            return [.stop, .slash("new"), .slash("resume"), .slash("compact"),
                    .slash("model"), .slash("tree"), .think, .tools]
        }
    }

    static func overflow(for kind: AgentKind) -> [AgentCommand] {
        switch kind {
        case .claudeCode:
            [.slash("context"), .slash("skills"), .slash("agents"),
             .slash("export"), .slash("status"), .slash("usage"),
             .slash("mcp")]
        case .codex:
            [.slash("compact"), .slash("diff"), .slash("status"), .slash("fork"),
             .slash("init"), .slash("mention"), .slash("skills"),
             .slash("plan"), .slash("usage")]
        case .pi:
            [.slash("session"), .slash("fork"), .slash("clone"),
             .slash("settings"), .slash("scoped-models"), .slash("copy"),
             .thinking, .slash("reload"), .slash("hotkeys")]
        }
    }

    /// Every built-in in stable display order: stock bar commands first,
    /// followed by stock MORE commands. Moving a command changes only which
    /// destination filters it out; relative order remains deterministic.
    static func all(for kind: AgentKind) -> [AgentCommand] {
        primary(for: kind) + overflow(for: kind)
    }

    static func commands(
        in placement: AgentCommandPlacement,
        for kind: AgentKind,
        placementOverrides: [String: AgentCommandPlacement] = [:]
    ) -> [AgentCommand] {
        all(for: kind).filter { command in
            resolvedPlacement(
                for: command.id,
                kind: kind,
                placementOverrides: placementOverrides
            ) == placement
        }
    }

    static func defaultPlacement(
        for commandID: String,
        kind: AgentKind
    ) -> AgentCommandPlacement? {
        if primary(for: kind).contains(where: { $0.id == commandID }) { return .bar }
        if overflow(for: kind).contains(where: { $0.id == commandID }) { return .more }
        return nil
    }

    static func resolvedPlacement(
        for commandID: String,
        kind: AgentKind,
        placementOverrides: [String: AgentCommandPlacement]
    ) -> AgentCommandPlacement? {
        guard let stockPlacement = defaultPlacement(for: commandID, kind: kind)
        else { return nil }
        return placementOverrides[commandID] ?? stockPlacement
    }

    /// Persist only meaningful deviations from the current stock layout.
    /// Stale commands disappear when an upstream agent removes/renames one,
    /// while future built-ins still arrive in their curated default location.
    static func normalizedPlacementOverrides(
        _ placementOverrides: [String: AgentCommandPlacement],
        for kind: AgentKind
    ) -> [String: AgentCommandPlacement] {
        var normalized: [String: AgentCommandPlacement] = [:]
        for command in all(for: kind) {
            guard let override = placementOverrides[command.id],
                  let stockPlacement = defaultPlacement(for: command.id, kind: kind),
                  override != stockPlacement
            else { continue }
            normalized[command.id] = override
        }
        return normalized
    }
}
