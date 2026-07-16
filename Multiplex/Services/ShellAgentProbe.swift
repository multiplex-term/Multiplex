import Foundation

/// Finds the foreground CLI agent in a plain SSH PTY. Unlike a tmux tab, a
/// plain shell has no pane id for the fleet probe to address. An exec channel
/// on the same SSH transport is nevertheless a sibling of the PTY channel
/// under sshd, so its `$PPID` identifies the one server-side session that owns
/// both. The command discovers that sibling's tty, then reports only enough ps
/// data to classify the tty's foreground process group.
///
/// Every stage is fail-soft. Hosts whose `ps` lacks pgid/tpgid support produce
/// `.unavailable`; the controller falls back to narrow in-band terminal
/// signatures without affecting the shell.
enum ShellAgentProbe {
    enum Outcome: Equatable {
        /// The exec could not locate/query this connection's PTY.
        case unavailable
        /// The PTY was queried successfully; nil means its foreground process
        /// group contains no supported agent.
        case available(AgentKind?)
    }

    static let marker = "MULTIPLEX_SHELL_PS"

    static let command =
        "p=$PPID; "
        + "t=$(ps -eo ppid=,tty= 2>/dev/null | "
        + "awk -v p=\"$p\" '$1 == p && $2 != \"?\" && $2 != \"??\" "
        + "{ print $2; exit }'); "
        + "if [ -n \"$t\" ]; then "
        + "r=$(ps -t \"$t\" -o pid=,ppid=,pgid=,tpgid=,args= 2>/dev/null); "
        + "if [ $? -eq 0 ]; then "
        + "printf '\\n\(marker)\\n%s\\n' \"$r\"; "
        + "fi; fi"

    static func parse(_ output: String) -> Outcome {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let markerIndex = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == marker
        }) else { return .unavailable }

        var sawProcessRow = false
        var foregroundRows: [PSRow] = []
        for rawLine in lines.suffix(from: lines.index(after: markerIndex)) {
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
        return .available(foregroundRows.lazy.compactMap {
            AgentSignature.match(argv: $0.args)
        }.first)
    }
}
