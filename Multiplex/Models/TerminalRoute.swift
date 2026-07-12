import Foundation

/// Value handed to the terminal `WindowGroup` — one route per terminal window.
struct TerminalRoute: Codable, Hashable, Identifiable {
    enum Mode: Codable, Hashable {
        /// Attach to an existing tmux session (`tmux attach-session -t name`).
        case attach(sessionName: String)
        /// Create (or attach if it exists) a tmux session (`tmux new-session -A`),
        /// optionally starting in one of the host's working directories.
        case create(sessionName: String, directory: String?)
        /// Plain login shell, no tmux.
        case shell

        /// Keeps the pre-directory call shape valid (and mirrors how records
        /// persisted by older builds decode: directory absent → nil).
        static func create(sessionName: String) -> Mode {
            .create(sessionName: sessionName, directory: nil)
        }
    }

    var id: UUID = UUID()
    var hostID: UUID
    var mode: Mode

    /// The command handed to the remote PTY, or nil for a plain shell.
    var remoteCommand: String? {
        switch mode {
        case .attach(let name):
            return "exec tmux attach-session -t \(name.shellQuoted)"
        case .create(let name, let directory):
            return TmuxSessionLaunch.createAndAttachCommand(
                sessionName: name,
                directory: directory
            )
        case .shell:
            return nil
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
            return "tmux attach-session -t \(name.shellQuoted)"
        case .create(let name, let directory):
            var command = "tmux new-session -A -s \(name.shellQuoted)"
            if let directory {
                // No shell to cd in — mosh-server execvp()s this argv. -c
                // rides along; the bootstrap shell line expands "$HOME"
                // while stripping the quoting.
                command += " -c \(directory.shellQuotedDirectory)"
            }
            return command
        case .shell:
            return nil
        }
    }

    var displayName: String {
        switch mode {
        case .attach(let name), .create(let name, _): name
        case .shell: "shell"
        }
    }

    /// The tmux session this tab is bound to; nil for a plain shell (which
    /// has no probe entry, so no agent detection).
    var sessionName: String? {
        switch mode {
        case .attach(let name), .create(let name, _): name
        case .shell: nil
        }
    }
}

/// Starts a tmux server outside an SSH login scope when the remote supports
/// systemd user scopes. Linux hosts with `KillUserProcesses=yes` reap every
/// process left in `session-*.scope` when the SSH client disconnects; a tmux
/// server born there disappears with the terminal window. `systemd-run
/// --user --scope` moves the server under the user's service manager instead.
/// macOS, BSD, and Linux hosts without a usable user manager fall back to the
/// ordinary tmux command.
enum TmuxSessionLaunch {
    static let persistentRunnerDefinition =
        "multiplex_tmux() { if command -v systemd-run >/dev/null 2>&1"
        + " && systemd-run --user --scope --quiet -- tmux \"$@\" 2>/dev/null;"
        + " then return 0; fi; tmux \"$@\"; }; "

    /// Legacy/restored `.create` routes still create from the PTY connection.
    /// Create detached first through the persistent runner, then attach; this
    /// keeps the server alive when closing the PTY tears down its login scope.
    static func createAndAttachCommand(sessionName: String, directory: String?) -> String {
        var command = ""
        if let directory {
            // A missing configured directory falls back to the login shell's
            // initial directory ($HOME) instead of failing session creation.
            command += "cd \(directory.shellQuotedDirectory) 2>/dev/null; "
        }
        command += persistentRunnerDefinition
        command += "tmux has-session -t \("=\(sessionName)".shellQuoted) 2>/dev/null"
        command += " || multiplex_tmux new-session -d -s \(sessionName.shellQuoted) 2>/dev/null; "
        command += "exec tmux attach-session -t \(sessionName.shellQuoted)"
        return command
    }
}

extension String {
    /// Single-quote for POSIX shells; embedded quotes become '\''.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A user-entered directory quoted for a shell line: a leading `~` is
    /// rewritten to `"$HOME"` (kept outside the single quotes so the remote
    /// shell expands it); everything else is single-quoted verbatim.
    var shellQuotedDirectory: String {
        if self == "~" { return "\"$HOME\"" }
        if hasPrefix("~/") { return "\"$HOME\"/" + String(dropFirst(2)).shellQuoted }
        return shellQuoted
    }
}
