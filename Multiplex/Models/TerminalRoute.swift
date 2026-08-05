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
        /// Attach the full herdr client to one herdr session — the tile
        /// press on a herdr-backend host. The session name is both target
        /// and identity (herdr keeps them unique — they're directories),
        /// and attach auto-creates/restarts, so a spine-less stopped tile
        /// presses too. A real terminal like `.attach`: restores across
        /// launches, resumes per `SessionResumePolicy`.
        case herdrAttach(sessionName: String)
        /// The viewport — an inline browser tab, docked beside the sessions
        /// that produced its URL and moved with the same merge/split
        /// machinery. Not a terminal: no remote command, no tmux session, no
        /// transport. Never restored across launches — a viewport is
        /// summoned, not restored (`TerminalWindowRoot.syncTabs` strips
        /// viewport tabs whose controller didn't survive the process).
        case viewport(urlString: String)
        /// The file viewer — the host's files and git diffs as an inline
        /// tab, the viewport's sibling: no PTY transport of its own record
        /// (the controller dials SSH for reads), never restored across
        /// launches (same `syncTabs` strip rule). `path` is only the
        /// summoning label; the live location belongs to the controller.
        case fileViewer(path: String)

        /// Keeps the pre-directory call shape valid (and mirrors how records
        /// persisted by older builds decode: directory absent → nil).
        static func create(sessionName: String) -> Mode {
            .create(sessionName: sessionName, directory: nil)
        }

        /// The attach mode for one session on this host — the tmux attach
        /// or the herdr client, decided by the host's backend in exactly
        /// one place so no mint site can disagree. Name-based on purpose:
        /// callers holding only a name (auto-attach entries, widget
        /// targets) must not fabricate a session record to qualify.
        static func attach(host: Host, sessionName: String) -> Mode {
            switch host.sessionBackend {
            case .tmux: .attach(sessionName: sessionName)
            case .herdr: .herdrAttach(sessionName: sessionName)
            }
        }

        static func attach(host: Host, session: TmuxSession) -> Mode {
            attach(host: host, sessionName: session.name)
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
        case .herdrAttach(let sessionName):
            return HerdrSessionLaunch.attachCommand(sessionName: sessionName)
        case .shell, .viewport, .fileViewer:
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
        case .herdrAttach(let sessionName):
            // The attach line needs a shell (PATH export before the exec);
            // execvp gets that shell as its argv.
            return "sh -c \(HerdrSessionLaunch.attachCommand(sessionName: sessionName).shellQuoted)"
        case .shell, .viewport, .fileViewer:
            return nil
        }
    }

    var displayName: String {
        switch mode {
        case .attach(let name), .create(let name, _): name
        case .herdrAttach(let sessionName): sessionName
        case .shell: "shell"
        case .viewport(let urlString): Self.viewportLabel(urlString)
        case .fileViewer(let path): Self.fileViewerLabel(path)
        }
    }

    /// The multiplexer session this tab is bound to (a herdr tab answers
    /// its herdr session name — the probe's session records use it, so
    /// agent detection and focus dedupe match the same way); nil for a
    /// plain shell (which has no probe entry, so no agent detection) and
    /// for the viewport and file viewer.
    var sessionName: String? {
        switch mode {
        case .attach(let name), .create(let name, _): name
        case .herdrAttach(let sessionName): sessionName
        case .shell, .viewport, .fileViewer: nil
        }
    }

    /// The remote session namespace this route belongs to. Unlike
    /// `Host.sessionBackend`, this stays fixed for the lifetime of an open
    /// tab, so switching a host's deck backend can never make a restored tmux
    /// tab focus or close a same-named herdr session (or vice versa).
    var sessionBackend: Host.SessionBackend? {
        switch mode {
        case .attach, .create: .tmux
        case .herdrAttach: .herdr
        case .shell, .viewport, .fileViewer: nil
        }
    }

    /// The extra `+ TAB` entry this tab offers beyond the leading New
    /// Session.
    ///
    /// Every tab leads with another session, attached as a second Multiplex
    /// tab: a Multiplex tab IS a session attach on either backend, and app
    /// chrome is the only surface that can mint one — remote-level
    /// structure (tmux windows, herdr tabs) already belongs to the
    /// backend's own prefix keys and the shortcut panel. A herdr tab
    /// appends the one remote-level entry worth a row: a tab inside its
    /// session's focused workspace, which adds no Multiplex tab at all —
    /// herdr's focus is session-wide, so a second client attached to the
    /// same session would only mirror the first, and the herdr client
    /// already on screen is what renders the new tab.
    var extraNewTabTarget: NewTabTarget? {
        sessionBackend == .herdr ? .herdrWorkspaceTab : nil
    }

    /// The two shapes of a `+ TAB` mint, holding the copy each surface
    /// (the menu entries, the control's label, the failure alert) must
    /// agree on.
    enum NewTabTarget: Hashable {
        case session
        case herdrWorkspaceTab

        /// The menu entry's name. `.session` leads every menu — the agent
        /// entries below it keep their own names — and `.herdrWorkspaceTab`
        /// follows them on herdr tabs.
        var menuTitle: String {
            switch self {
            case .session: "New Session"
            case .herdrWorkspaceTab: "New Tab in Workspace"
            }
        }

        /// The `+ TAB` control's label, keyed by the menu it opens.
        static func controlAccessibilityLabel(
            offering extra: NewTabTarget?
        ) -> String {
            extra == .herdrWorkspaceTab
                ? "New tab: another session, a tab in this herdr workspace, "
                    + "or the file viewer"
                : "New tab: another session or the file viewer"
        }

        var failureTitle: String {
            switch self {
            case .session: "Couldn't Create Session"
            case .herdrWorkspaceTab: "Couldn't Create Tab"
            }
        }
    }

    /// The tab speaks tmux itself — the gate for tmux-specific chrome (the
    /// TMUX shortcut popover, Copy Mode's app-owned state). A herdr tab is
    /// a probe-backed session too, but its client owns those interactions.
    var usesTmux: Bool {
        switch mode {
        case .attach, .create: true
        case .herdrAttach, .shell, .viewport, .fileViewer: false
        }
    }

    var isViewport: Bool {
        if case .viewport = mode { return true }
        return false
    }

    var isFileViewer: Bool {
        if case .fileViewer = mode { return true }
        return false
    }

    /// A tab whose surface is a controller-owned monitor, not a terminal:
    /// the viewport and the file viewer. These make no responder claim,
    /// carry no tally dot, wear the slim monitor chrome, and are stripped
    /// by `syncTabs` when their controller didn't survive the process.
    var isAuxiliaryPane: Bool { isViewport || isFileViewer }

    var viewportURL: URL? {
        guard case .viewport(let urlString) = mode else { return nil }
        return URL(string: urlString)
    }

    /// The viewport's tab-cell/UMD label: `⌗ 5173` for an explicit port
    /// (the dev-server case, where the port *is* the page's identity), the
    /// host otherwise. `⌗` — U+2317 VIEWDATA SQUARE — is the viewport mark
    /// everywhere; a page never wears a tally dot.
    static func viewportLabel(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "⌗" }
        if let port = url.port { return "⌗ \(port)" }
        return "⌗ \(url.host() ?? "page")"
    }

    /// The file viewer's tab-cell/UMD label: `▤` + the last path component.
    /// `▤` — U+25A4 SQUARE WITH HORIZONTAL FILL — is the file-viewer mark
    /// everywhere, the viewport's sibling; a file never wears a tally dot.
    static func fileViewerLabel(_ path: String) -> String {
        fileViewerLabel(name: FileTree.name(of: path))
    }

    /// The name-based spelling — the live controller labels itself with the
    /// file on screen, which is not a path. The ▤ mark lives here only.
    static func fileViewerLabel(name: String) -> String {
        name.isEmpty ? "▤" : "▤ \(name)"
    }
}

/// PATH setup shared by pure route builders and the remote probe/services.
/// Keeping it in the model layer lets services depend inward while
/// `TerminalRoute` never reaches outward into a probe service just to build
/// its persisted route's PTY command.
enum RemoteCommandEnvironment {
    static let pathPrefix =
        "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin\"; export PATH; "
    static let herdrPathPrefix =
        pathPrefix + "PATH=\"$PATH:$HOME/.cargo/bin\"; export PATH; "
}

/// The PTY handoff for a full herdr client. Session actions that don't belong
/// to a persisted terminal route remain in `HerdrProbe`; attach lives here for
/// the same reason tmux's legacy create-and-attach builder does below.
enum HerdrSessionLaunch {
    static let primarySessionName = "default"

    static func attachCommand(sessionName: String) -> String {
        let name = sessionName.isEmpty ? primarySessionName : sessionName
        return RemoteCommandEnvironment.herdrPathPrefix
            + "exec herdr session attach \(name.shellQuoted)"
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
        // `-u` for the same reason every TmuxProbe invocation carries it: the
        // create prints the server's chosen session name back to the app, and
        // an exec channel's empty locale would sanitize a non-ASCII one.
        "multiplex_tmux() { if command -v systemd-run >/dev/null 2>&1"
        + " && systemd-run --user --scope --quiet -- tmux -u \"$@\" 2>/dev/null;"
        + " then return 0; fi; tmux -u \"$@\"; }; "

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
