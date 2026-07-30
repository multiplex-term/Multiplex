import Foundation

/// Command builders for the file viewer's git reads — pure string assembly,
/// unit-tested, same discipline as `TmuxProbe`: every path rides as one
/// shell-quoted argv, stderr is silenced, and the command always exits 0
/// (Citadel's `executeCommand` throws on a nonzero exit) while the REAL
/// exit code trails the output behind a sentinel, so "not a repo" and
/// "empty diff" stay distinguishable.
///
/// `-c core.quotepath=false` keeps non-ASCII paths as raw UTF-8 instead of
/// octal escapes; controls still quote, which `GitDiffFile.unquote` handles.
/// `--no-ext-diff` ensures a host's configured diff tool can never run under
/// an app-initiated read.
enum GitCommands {
    static let exitSentinel = "\nMPXFV_EXIT:"

    /// `(body, exitCode)` from a sentinel-tailed command's output. The
    /// sentinel is the final thing the command prints, so the LAST
    /// occurrence is always ours; a missing sentinel reports nil (the exec
    /// channel itself failed mid-stream).
    static func splitExit(_ output: String) -> (body: String, exit: Int?) {
        if let range = output.range(of: exitSentinel, options: .backwards) {
            let code = Int(
                output[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return (String(output[..<range.lowerBound]), code)
        }
        // An empty body puts the sentinel — minus its leading newline — at
        // the very start.
        let bare = String(exitSentinel.dropFirst())
        if output.hasPrefix(bare) {
            let code = Int(
                output.dropFirst(bare.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return ("", code)
        }
        return (output, nil)
    }

    private static func tailed(_ command: String) -> String {
        TmuxProbe.pathPrefix + command + " 2>/dev/null; printf '\\nMPXFV_EXIT:%s' \"$?\""
    }

    private static func git(_ root: String, _ arguments: String) -> String {
        "git -C \(root.shellQuoted) -c core.quotepath=false \(arguments)"
    }

    /// Repo root and branch in one round trip. The two queries are
    /// independently silenced on purpose: an unborn HEAD (fresh repo, no
    /// commit yet) fails `--abbrev-ref HEAD` while `--show-toplevel` still
    /// answers, and the toplevel is the verdict that matters. Body line 1 is
    /// the toplevel, line 2 is `MPXFV_BR:<branch>`; exit ≠ 0 means "not
    /// inside a work tree".
    static let branchSentinel = "MPXFV_BR:"

    static func repoProbe(path: String) -> String {
        let quoted = path.shellQuoted
        return TmuxProbe.pathPrefix
            + "t=$(git -C \(quoted) rev-parse --show-toplevel 2>/dev/null); s=$?; "
            + "b=$(git -C \(quoted) rev-parse --abbrev-ref HEAD 2>/dev/null); "
            + "printf '%s\\n\(branchSentinel)%s' \"$t\" \"$b\"; "
            + "printf '\\nMPXFV_EXIT:%s' \"$s\""
    }

    /// `(toplevel, branch)` out of `repoProbe`'s body. Branch is nil when
    /// empty (unborn HEAD) or `HEAD` (detached — the header shows the word
    /// only when git itself would).
    static func parseRepoProbe(body: String) -> (toplevel: String?, branch: String?) {
        var toplevel: String?
        var branch: String?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(branchSentinel) {
                let value = String(line.dropFirst(branchSentinel.count))
                branch = value.isEmpty ? nil : value
            } else if toplevel == nil, line.hasPrefix("/") {
                toplevel = String(line)
            }
        }
        return (toplevel, branch)
    }

    static func status(root: String) -> String {
        tailed(git(root, "status --porcelain=v1 -z --untracked-files=normal"))
    }

    /// The watch tick's whole git read in ONE round trip — branch, porcelain
    /// status, and shortstat, sentinel-framed (the deck's one-exec probe
    /// discipline; a 5 s cadence must not cost three channel setups).
    /// Layout: `MPXFV_BR:<branch>\n<status -z bytes>\nMPXFV_STAT:<shortstat>`
    /// then the usual exit sentinel carrying the STATUS command's code.
    static let watchStatSentinel = "\nMPXFV_STAT:"

    static func watchProbe(root: String) -> String {
        let quoted = root.shellQuoted
        return TmuxProbe.pathPrefix
            + "printf '\(branchSentinel)%s\\n' "
            + "\"$(git -C \(quoted) rev-parse --abbrev-ref HEAD 2>/dev/null)\"; "
            + "git -C \(quoted) -c core.quotepath=false status --porcelain=v1 -z"
            + " --untracked-files=normal 2>/dev/null; s=$?; "
            + "printf '\\nMPXFV_STAT:'; "
            + "git -C \(quoted) diff --shortstat --no-ext-diff HEAD -- 2>/dev/null; "
            + "printf '\\nMPXFV_EXIT:%s' \"$s\""
    }

    struct WatchProbe: Equatable {
        var branch: String?
        var statuses: [GitFileStatus]
        var shortStat: GitShortStat
    }

    /// nil when the status command failed (not a repo anymore, git gone).
    /// Both sentinels are matched from the back — they are the last things
    /// printed, and a -z filename could theoretically embed lookalikes.
    static func parseWatchProbe(_ output: String) -> WatchProbe? {
        let (body, exit) = splitExit(output)
        guard exit == 0 else { return nil }
        guard let statRange = body.range(of: watchStatSentinel, options: .backwards)
        else { return nil }
        let shortStat = GitShortStat.parse(String(body[statRange.upperBound...]))
        let head = body[..<statRange.lowerBound]
        guard head.hasPrefix(branchSentinel) else { return nil }
        let afterSentinel = head.dropFirst(branchSentinel.count)
        let branchLine = afterSentinel.prefix(while: { $0 != "\n" })
        let statusBytes = afterSentinel.dropFirst(branchLine.count).dropFirst()
        return WatchProbe(
            branch: branchLine.isEmpty ? nil : String(branchLine),
            statuses: GitFileStatus.parse(porcelainZ: String(statusBytes)),
            shortStat: shortStat
        )
    }

    /// The tree header's ± counts. `HEAD --` so staged and unstaged changes
    /// both count; prints nothing on a clean tree.
    static func shortstat(root: String) -> String {
        tailed(git(root, "diff --shortstat --no-ext-diff HEAD --"))
    }

    /// One file's uncommitted changes (staged + unstaged) vs HEAD.
    static func diffFile(root: String, path: String) -> String {
        tailed(git(root, "diff --no-color --no-ext-diff HEAD -- \(path.shellQuoted)"))
    }

    /// The whole working tree vs HEAD — the review surface.
    static func fullDiff(root: String) -> String {
        tailed(git(root, "diff --no-color --no-ext-diff HEAD --"))
    }

    /// An untracked file rendered as an all-additions diff. `--no-index`
    /// exits 1 whenever the sides differ — routine here, which is exactly
    /// why the sentinel carries the code instead of the channel failing.
    static func untrackedDiff(root: String, path: String) -> String {
        tailed(git(root, "diff --no-color --no-ext-diff --no-index -- /dev/null \(path.shellQuoted)"))
    }
}
