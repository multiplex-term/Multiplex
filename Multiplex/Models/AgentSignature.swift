import Foundation

/// Which CLI agent is driving a tmux pane.
enum AgentKind: String, Hashable, Codable {
    case claudeCode
    case codex

    /// Strip header / accessibility voice.
    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Deck telemetry token ("3 WIN · 2h · CLAUDE").
    var telemetryLabel: String {
        switch self {
        case .claudeCode: "CLAUDE"
        case .codex: "CODEX"
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
/// rust-v0.144.x) — see local-plan/agent-harness-helpers.md §1.1 for the
/// experiment matrix. Everything here is pure and pinned by
/// AgentSignatureTests; when an agent changes its signature, this file and
/// its tests are the whole blast radius.
enum AgentSignature {
    /// Cheap first pass over one pane's `#{pane_current_command}` +
    /// `#{pane_title}`. Order matters.
    static func classify(command: String, title: String) -> AgentKind? {
        if command == "codex" { return .codex }
        // Linux reads argv[0] → "claude"; macOS reads the executable comm.
        if command == "claude" { return .claudeCode }
        // Claude Code sets its pane title via OSC 0/2 (undocumented, stable
        // through v2.1.x). Never match bare "claude" — the default title is
        // whatever a shell prompt wrote there, often a hostname.
        if title.contains("Claude Code") || title.hasPrefix("✳ ") { return .claudeCode }
        // macOS native launcher: ~/.local/bin/claude is a symlink into
        // versions/<semver>, and the BSD comm is the resolved file's
        // basename — a bare version number. Nothing else realistically runs
        // in a pane with a semver comm.
        if isBareVersionNumber(command) { return .claudeCode }
        // "node" alone is never enough — the process-tree walk decides.
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
        guard panePID > 0 else { return nil }
        var children: [Int: [PSRow]] = [:]
        var byPID: [Int: PSRow] = [:]
        for row in rows {
            children[row.ppid, default: []].append(row)
            byPID[row.pid] = row
        }
        var queue = [panePID]
        var seen = Set<Int>()
        // Depth/breadth cap: no pane tree is this big; a cycle in forged
        // input must not spin.
        while let pid = queue.first, seen.count < 512 {
            queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            if let row = byPID[pid], let kind = match(argv: row.args) { return kind }
            queue.append(contentsOf: (children[pid] ?? []).map(\.pid))
        }
        return nil
    }

    private static func agentNamed(_ name: String) -> AgentKind? {
        switch name {
        case "claude": .claudeCode
        case "codex": .codex
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
    /// After typing the payload, pause and send CR as a separate write.
    /// Codex's composer treats Enter arriving inside a rapid input burst as
    /// a pasted newline, not a submit (verified against rust-v0.144: burst
    /// "/new\r" leaves the text sitting in the composer; a CR ≥120 ms later
    /// submits). Claude Code's input doesn't care either way.
    var submitsAfterPause = false

    var id: String { label }

    /// A slash command typed, then submitted after the burst-detector pause.
    static func slash(_ name: String) -> AgentCommand {
        AgentCommand(label: "/\(name)", payload: Data(("/" + name).utf8), submitsAfterPause: true)
    }

    /// Interrupt the running turn. Esc in both TUIs.
    static let stop = AgentCommand(label: "STOP", payload: Data([0x1B]))

    /// Cycle permission / collaboration mode — Shift+Tab, which terminals
    /// send as CSI Z. A fixed default binding in both TUIs. Never ship a
    /// Ctrl+B payload here: that's the remote tmux prefix and gets eaten.
    static let mode = AgentCommand(label: "MODE", payload: Data([0x1B, 0x5B, 0x5A]))
}

/// The curated command sets, one place to tune. Slash lists verified
/// 2026-07-10 — Claude Code v2.1.x docs; Codex rust-v0.144.1 slash_command.rs
/// (note: Codex renamed /approvals → /permissions and dropped /undo).
enum AgentCommandSet {
    static func primary(for kind: AgentKind) -> [AgentCommand] {
        switch kind {
        case .claudeCode:
            [.stop, .slash("clear"), .slash("resume"), .slash("compact"),
             .slash("context"), .slash("model"), .mode]
        case .codex:
            [.stop, .slash("new"), .slash("resume"), .slash("compact"),
             .slash("model"), .slash("permissions"), .slash("review"), .mode]
        }
    }

    static func overflow(for kind: AgentKind) -> [AgentCommand] {
        switch kind {
        case .claudeCode:
            [.slash("rewind"), .slash("skills"), .slash("agents"),
             .slash("export"), .slash("status"), .slash("usage"),
             .slash("mcp")]
        case .codex:
            [.slash("diff"), .slash("status"), .slash("fork"),
             .slash("init"), .slash("mention"), .slash("skills"),
             .slash("plan"), .slash("usage")]
        }
    }
}
