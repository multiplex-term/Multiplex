import Foundation

/// One window inside a tmux session — a cell in the window spine.
struct TmuxWindow: Identifiable, Hashable {
    var index: Int
    var name: String
    var isActive: Bool
    var hasBell: Bool
    var hasActivity: Bool

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
