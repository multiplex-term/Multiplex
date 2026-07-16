import Foundation

/// Finds the foreground CLI agent in a plain SSH PTY. Unlike a tmux tab, a
/// plain shell has no pane id for the fleet probe to address. An exec channel
/// on the same SSH transport is nevertheless a sibling of the PTY channel
/// under sshd, so its `$PPID` identifies the one server-side session that owns
/// both. The command discovers that sibling's tty, then reports only enough ps
/// data to classify the tty's foreground process group — plus that group
/// leader's working directory (`/proc` on Linux, `lsof` on macOS/BSD), which
/// is what lets a plain shell locate the agent's session file for the
/// HISTORY surface.
///
/// Every stage is fail-soft. Hosts whose `ps` lacks pgid/tpgid support produce
/// `.unavailable`; a host without /proc or lsof merely loses the working
/// directory, never detection.
enum ShellAgentProbe {
    enum Outcome: Equatable {
        /// The exec could not locate/query this connection's PTY.
        case unavailable
        /// The PTY was queried successfully; nil agent means its foreground
        /// process group contains no supported agent. The working directory
        /// is the foreground group's cwd when the host could reveal it.
        case available(AgentKind?, workingDirectory: String?)
    }

    static let marker = "MULTIPLEX_SHELL_PS"
    static let cwdMarker = "MULTIPLEX_SHELL_CWD"

    /// The cwd stage prefers the foreground group *leader* (pid == pgid —
    /// the agent or its wrapper), falling back to any foreground row if the
    /// leader already exited. `readlink /proc` is free on Linux; macOS pays
    /// one narrow `lsof -p` only at this probe's cadence.
    static let command =
        "p=$PPID; "
        + "t=$(ps -eo ppid=,tty= 2>/dev/null | "
        + "awk -v p=\"$p\" '$1 == p && $2 != \"?\" && $2 != \"??\" "
        + "{ print $2; exit }'); "
        + "if [ -n \"$t\" ]; then "
        + "r=$(ps -t \"$t\" -o pid=,ppid=,pgid=,tpgid=,args= 2>/dev/null); "
        + "if [ $? -eq 0 ]; then "
        + "printf '\\n\(marker)\\n%s\\n' \"$r\"; "
        + "fg=$(printf '%s\\n' \"$r\" | awk '$4 > 0 && $3 == $4 "
        + "{ if ($1 == $3) { print $1; found=1; exit } if (!alt) alt = $1 } "
        + "END { if (!found && alt) print alt }'); "
        + "if [ -n \"$fg\" ]; then "
        + "c=$(readlink \"/proc/$fg/cwd\" 2>/dev/null); "
        + "[ -n \"$c\" ] || c=$(lsof -a -p \"$fg\" -d cwd -Fn 2>/dev/null | "
        + "awk '/^n\\// { print substr($0, 2); exit }'); "
        + "if [ -n \"$c\" ]; then printf '\(cwdMarker)\\n%s\\n' \"$c\"; fi; "
        + "fi; fi; fi"

    static func parse(_ output: String) -> Outcome {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let markerIndex = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == marker
        }) else { return .unavailable }

        var sawProcessRow = false
        var foregroundRows: [PSRow] = []
        var workingDirectory: String?
        var inCwdSection = false
        for rawLine in lines.suffix(from: lines.index(after: markerIndex)) {
            if rawLine.trimmingCharacters(in: .whitespacesAndNewlines) == cwdMarker {
                inCwdSection = true
                continue
            }
            if inCwdSection {
                if workingDirectory == nil {
                    let path = String(rawLine).trimmingCharacters(in: .whitespaces)
                    if path.hasPrefix("/") { workingDirectory = path }
                }
                continue
            }
            let fields = rawLine.split(
                maxSplits: 4,
                omittingEmptySubsequences: true,
                whereSeparator: \Character.isWhitespace
            )
            guard fields.count == 5,
                  let pid = Int(fields[0]),
                  let ppid = Int(fields[1]),
                  let processGroup = Int(fields[2]),
                  let foregroundGroup = Int(fields[3])
            else { continue }
            sawProcessRow = true
            guard foregroundGroup > 0,
                  processGroup == foregroundGroup
            else { continue }
            foregroundRows.append(PSRow(
                pid: pid,
                ppid: ppid,
                args: String(fields[4])
            ))
        }
        guard sawProcessRow else { return .unavailable }

        // All rows in the terminal's foreground process group are eligible:
        // npm/node wrappers and their native children share that group, while
        // a suspended/background agent has a different pgid and was filtered
        // above. Match in ps order, which puts the group leader first.
        return .available(
            foregroundRows.lazy.compactMap {
                AgentSignature.match(argv: $0.args)
            }.first,
            workingDirectory: workingDirectory
        )
    }
}
