import Foundation

/// One window inside a tmux session — a cell in the window spine.
struct TmuxWindow: Identifiable, Hashable {
    var index: Int
    var name: String
    var isActive: Bool
    var hasBell: Bool
    var hasActivity: Bool
    /// CLI agent detected in this window's *active* pane — the pane that
    /// receives keystrokes when the session is attached.
    var agent: AgentKind?

    var id: Int { index }
}

/// A tmux session as reported by `tmux list-sessions` / `list-windows`.
struct TmuxSession: Identifiable, Hashable {
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
    /// Agent in the pane an attached client is typing into — the active
    /// window's active pane. Drives the helper strip and deck telemetry.
    var activeAgent: AgentKind? {
        windows.first(where: \.isActive)?.agent
    }
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
