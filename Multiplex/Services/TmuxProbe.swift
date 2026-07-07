import Foundation

/// Builds and parses the `tmux` commands used to discover remote sessions.
/// Pure functions — exercised directly by unit tests.
enum TmuxProbe {
    /// ASCII unit separator: safe field delimiter, cannot appear in tmux names.
    static let fieldSeparator: Character = "\u{1F}"
    private static let sep = "\u{1F}"

    /// One exec round-trip fetches sessions and windows together.
    /// Sessions lines start with S, window lines with W.
    ///
    /// Non-interactive SSH exec often has a minimal PATH, so common tmux
    /// locations (Homebrew, /usr/local) are appended before probing.
    static var probeCommand: String {
        let sessionFormat = "S\(sep)#{session_name}\(sep)#{session_attached}\(sep)#{session_created}"
        let windowFormat = "W\(sep)#{session_name}\(sep)#{window_index}\(sep)#{window_name}\(sep)#{window_active}\(sep)#{window_bell_flag}\(sep)#{window_activity_flag}"
        return "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin\"; export PATH; "
            + "command -v tmux >/dev/null 2>&1 || { echo MULTIPLEX_NO_TMUX; exit 0; }; "
            + "tmux list-sessions -F '\(sessionFormat)' 2>/dev/null "
            + "&& tmux list-windows -a -F '\(windowFormat)' 2>/dev/null "
            + "|| true"
    }

    /// Parse combined probe output into a `TmuxState`.
    static func parse(_ output: String) -> TmuxState {
        if output.contains("MULTIPLEX_NO_TMUX") { return .tmuxMissing }

        var sessions: [String: (attached: Bool, created: Date)] = [:]
        var order: [String] = []
        var windows: [String: [TmuxWindow]] = [:]

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)
            switch fields.first {
            case "S" where fields.count >= 4:
                let name = fields[1]
                let created = Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0)
                if sessions[name] == nil { order.append(name) }
                sessions[name] = (attached: fields[2] != "0", created: created)
            case "W" where fields.count >= 7:
                let window = TmuxWindow(
                    index: Int(fields[2]) ?? 0,
                    name: fields[3],
                    isActive: fields[4] == "1",
                    hasBell: fields[5] == "1",
                    hasActivity: fields[6] == "1"
                )
                windows[fields[1], default: []].append(window)
            default:
                continue
            }
        }

        guard !order.isEmpty else { return .noServer }

        let list = order.compactMap { name -> TmuxSession? in
            guard let info = sessions[name] else { return nil }
            return TmuxSession(
                name: name,
                windows: (windows[name] ?? []).sorted { $0.index < $1.index },
                isAttached: info.attached,
                created: info.created
            )
        }
        return .sessions(list)
    }
}
