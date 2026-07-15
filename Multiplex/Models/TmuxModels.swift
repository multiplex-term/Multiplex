import Foundation

/// One pane inside a tmux window. The probe retains every pane so the wall
/// can report agents in background splits; `isActive` still identifies the
/// only pane that receives helper-chip keystrokes.
struct TmuxPane: Identifiable, Hashable, Codable {
    var index: Int
    var isActive: Bool
    /// tmux's server-wide pane id (`%7`). Unlike an index, this survives
    /// pane reordering and is shared by linked windows.
    var tmuxID: String
    /// Root process tmux started for this pane. Used only to scope the
    /// fail-soft process-tree fallback.
    var pid: Int
    var tty: String
    var command: String
    var title: String
    var agent: AgentKind?

    var id: String { tmuxID.isEmpty ? String(index) : tmuxID }

    /// Stable while the same foreground program owns the pane. OSC titles
    /// deliberately stay out: agent spinners rewrite them continuously and
    /// must not invalidate the process fallback cache every frame.
    var processFingerprint: TmuxPaneFingerprint {
        TmuxPaneFingerprint(
            tmuxID: tmuxID,
            pid: pid,
            tty: tty,
            command: command
        )
    }
}

struct TmuxPaneFingerprint: Hashable {
    var tmuxID: String
    var pid: Int
    var tty: String
    var command: String
}

/// Result of the terminal window's lightweight focused-pane check.
/// `isDefinitive == false` means direct signals were inconclusive and the
/// scoped process query failed; callers retain a result only while the pane
/// fingerprint itself remains unchanged.
struct ActivePaneAgentDetection: Equatable {
    var fingerprint: TmuxPaneFingerprint
    var agent: AgentKind?
    var isDefinitive: Bool
}

/// One window inside a tmux session — a cell in the window spine.
struct TmuxWindow: Identifiable, Hashable, Codable {
    var index: Int
    var name: String
    var isActive: Bool
    var hasBell: Bool
    var hasActivity: Bool
    /// CLI agent detected in this window's *active* pane — the pane that
    /// receives keystrokes when the session is attached.
    var agent: AgentKind?
    /// The active pane's OSC title — Claude Code and Codex encode busy/idle
    /// (and Codex its approval wait) here; `AgentAttention` classifies it.
    var paneTitle: String = ""
    /// All panes from a live probe. Optional only so device-local snapshots
    /// written before multi-pane detection continue to decode; new probes
    /// always populate it.
    var panes: [TmuxPane]? = nil

    var id: Int { index }

    var activePane: TmuxPane? {
        panes?.first(where: \.isActive)
    }

    var activeAgent: AgentKind? {
        activePane?.agent ?? agent
    }

    var detectedAgents: [AgentKind] {
        if let panes { return panes.compactMap(\.agent) }
        return agent.map { [$0] } ?? []
    }

    var paneCount: Int {
        panes?.count ?? 1
    }
}

/// A tmux session as reported by `tmux list-sessions` / `list-windows`.
struct TmuxSession: Identifiable, Hashable, Codable {
    var name: String
    var windows: [TmuxWindow]
    /// Attached client count (`session_attached` is a count, not a flag).
    var clientCount: Int = 0
    var created: Date
    /// tmux's own id ("$3") — the only unambiguous capture-pane target;
    /// names can prefix-collide.
    var tmuxID: String = ""

    var id: String { name }
    var isAttached: Bool { clientCount > 0 }
    var windowCount: Int { windows.count }
    /// The window an attached client is looking at.
    var activeWindow: TmuxWindow? {
        windows.first(where: \.isActive)
    }
    /// Agent in the pane an attached client is typing into — the active
    /// window's active pane. Drives the helper strip; FleetWall separately
    /// aggregates every detected pane.
    var activeAgent: AgentKind? {
        activeWindow?.activeAgent
    }
    /// Every detected agent pane, including background splits and inactive
    /// windows. FleetWall uses this broader view; helper chips intentionally
    /// continue to use `activeAgent`.
    var detectedAgents: [AgentKind] {
        windows.flatMap(\.detectedAgents)
    }
    var agentPanes: [TmuxPane] {
        windows.flatMap { $0.panes ?? [] }.filter { $0.agent != nil }
    }
    var paneCount: Int {
        windows.reduce(0) { $0 + $1.paneCount }
    }
}

/// Pure ordering rules for the deck's per-host session tiles. tmux owns the
/// sessions themselves; Multiplex stores only their names as a device-local
/// presentation preference. New sessions stay at the front in tmux's
/// newest-first order, while stale saved names simply disappear.
enum SessionOrdering {
    static func ordered(_ sessions: [TmuxSession], saved: [String]?) -> [TmuxSession] {
        let newestFirst = Array(sessions.reversed())
        guard let saved else { return newestFirst }

        let byName = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0) })
        let savedNames = Set(saved)
        let newSessions = newestFirst.filter { !savedNames.contains($0.name) }
        return newSessions + saved.compactMap { byName[$0] }
    }

    /// Applies the destination emitted by SwiftUI's reorder container.
    /// Multiple sources preserve their current visual order.
    static func moving(
        _ sources: [String], before destination: String?, in order: [String]
    ) -> [String] {
        let sourceSet = Set(sources)
        let moving = order.filter(sourceSet.contains)
        guard !moving.isEmpty else { return order }

        var remaining = order.filter { !sourceSet.contains($0) }
        let insertion = destination.flatMap { remaining.firstIndex(of: $0) } ?? remaining.endIndex
        remaining.insert(contentsOf: moving, at: insertion)
        return remaining
    }

    /// Older OS fallback: dropping onto a tile moves the source into that
    /// tile's current slot, regardless of drag direction.
    static func moving(_ source: String, to target: String, in order: [String]) -> [String] {
        guard let sourceIndex = order.firstIndex(of: source),
              let targetIndex = order.firstIndex(of: target),
              sourceIndex != targetIndex
        else { return order }

        var result = order
        let moved = result.remove(at: sourceIndex)
        result.insert(moved, at: targetIndex)
        return result
    }
}

/// Last-known wall state for one host — what a cold launch paints while the
/// probe reconnects (the same staleness the wall already shows between
/// ticks). Attention state is deliberately absent: NEEDS YOU and agent
/// alerts must be re-earned by a live probe, never restored from disk.
struct DeckSnapshot: Codable, Equatable {
    var sessions: [TmuxSession]
    var miniatures: [String: [String]]
}

/// What a host's tmux server currently looks like.
enum TmuxState: Equatable {
    case unknown
    case probing
    case sessions([TmuxSession])
    case noServer          // tmux installed, no server running
    case tmuxMissing       // tmux not on PATH
    case failed(String)

    var sessions: [TmuxSession] {
        if case .sessions(let list) = self { return list }
        return []
    }
}
