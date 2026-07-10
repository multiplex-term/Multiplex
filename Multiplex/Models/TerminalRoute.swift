import Foundation

/// Value handed to the terminal `WindowGroup` — one route per terminal window.
struct TerminalRoute: Codable, Hashable, Identifiable {
    enum Mode: Codable, Hashable {
        /// Attach to an existing tmux session (`tmux attach-session -t name`).
        case attach(sessionName: String)
        /// Create (or attach if it exists) a tmux session (`tmux new-session -A`).
        case create(sessionName: String)
        /// Plain login shell, no tmux.
        case shell
    }

    var id: UUID = UUID()
    var hostID: UUID
    var mode: Mode

    /// The command handed to the remote PTY, or nil for a plain shell.
    var remoteCommand: String? {
        switch mode {
        case .attach(let name):
            "exec tmux attach-session -t \(name.shellQuoted)"
        case .create(let name):
            "exec tmux new-session -A -s \(name.shellQuoted)"
        case .shell:
            nil
        }
    }

    /// The command handed to `mosh-server` after `--`, or nil for a login
    /// shell. Same tmux invocation as `remoteCommand` minus the `exec`
    /// prefix: `exec` is a shell builtin, and mosh-server execvp()s its
    /// trailing argv directly — the bootstrap shell line only strips the
    /// quoting, no shell wraps the command itself.
    var moshRemoteCommand: String? {
        switch mode {
        case .attach(let name):
            "tmux attach-session -t \(name.shellQuoted)"
        case .create(let name):
            "tmux new-session -A -s \(name.shellQuoted)"
        case .shell:
            nil
        }
    }

    var displayName: String {
        switch mode {
        case .attach(let name), .create(let name): name
        case .shell: "shell"
        }
    }

    /// The tmux session this tab is bound to; nil for a plain shell (which
    /// has no probe entry, so no agent detection).
    var sessionName: String? {
        switch mode {
        case .attach(let name), .create(let name): name
        case .shell: nil
        }
    }
}

extension String {
    /// Single-quote for POSIX shells; embedded quotes become '\''.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
