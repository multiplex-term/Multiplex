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
    var isAttached: Bool
    var created: Date

    var id: String { name }
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
