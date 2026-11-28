import Foundation

/// Host Settings ▸ Agent browser ▸ INSTALL SKILL: what the app runs on the
/// host, and how it reads the answer. Pure.
///
/// The app never carries the skill's text. `mpx skill install` writes the
/// copy embedded in the host's own `mpx`, so what an agent reads always
/// matches the `mpx browser` it will call.
enum AgentSkillInstall {
    /// One skills directory `mpx` could not write into, in its own words.
    struct Refusal: Equatable, Sendable {
        var directory: String
        var reason: String
    }

    enum Outcome: Equatable, Sendable {
        /// The `SKILL.md` files now on the host — one per skills directory
        /// (`~/.agents/skills` and `~/.claude/skills`).
        case installed([String])
        /// `mpx` ran, and at least one directory refused the skill.
        case incomplete(installed: [String], refused: [Refusal])
        /// No `mpx` on the host's PATH or in the usual places.
        case missingCLI
        /// An `mpx` from before `skill install --json` existed.
        case outdatedCLI
        /// `mpx` failed, or the shell ended first; its stderr, if it said
        /// anything.
        case failed(String)
        /// Nothing came back before the deadline.
        case silent
        /// The SSH connection itself failed; the sentence says why.
        case unreachable(String)
    }

    /// The POSIX script: the same search as the bridge's, so the button
    /// finds exactly the `mpx` the agent browser runs.
    static func script(preferred: String? = nil) -> String {
        AgentBrowserLaunch.exec("skill install --json", preferred: preferred)
    }

    /// The stdin bytes for the shell channel.
    static func payload(preferred: String? = nil) -> String {
        ShellHandoff.payload(for: RemoteShellEnvelope.handoff(script(preferred: preferred)))
    }

    /// The answer, if `line` is it. A login shell prints what it likes
    /// around the command (a motd, an rc file's chatter); only the one JSON
    /// line `mpx` writes — or the script's own "missing" — is read.
    static func outcome(fromLine line: String) -> Outcome? {
        guard let value = JSONValue.parse(line), case .object = value else { return nil }
        if value["mpx"]?.stringValue == "missing" { return .missingCLI }
        guard value["skill"]?.stringValue != nil,
              case .array(let installed)? = value["installed"]
        else { return nil }
        let paths = installed.compactMap(\.stringValue)
        var refused: [Refusal] = []
        if case .array(let failed)? = value["failed"] {
            refused = failed.map {
                Refusal(
                    directory: $0["dir"]?.stringValue ?? "",
                    reason: $0["error"]?.stringValue ?? ""
                )
            }
        }
        if refused.isEmpty, !paths.isEmpty { return .installed(paths) }
        return .incomplete(installed: paths, refused: refused)
    }

    /// The channel ended with no answer line.
    static func outcome(endedWith detail: String?, stderr: String) -> Outcome {
        if AgentBrowserLaunch.isOutdatedCLI(stderr: stderr) { return .outdatedCLI }
        let said = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(said.isEmpty ? (detail ?? "") : said)
    }
}
