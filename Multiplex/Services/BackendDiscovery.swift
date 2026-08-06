import Foundation

/// The cheap half of mixed-backend support: every wall tick asks the OTHER
/// multiplexer whether it is installed and how many sessions it is holding,
/// riding the primary probe's own exec channel.
///
/// Measured on the dev harness (tmux 3.6a + herdr 0.8.0, loopback sshd,
/// 2026-08-05): +1 ms when the other backend is absent, +4–9 ms and under
/// 1 KB when it is present. That is inside the noise of what the tmux probe
/// already spent on its `command -v herdr` presence check, which this
/// replaces — the rider answers presence *and* session count.
///
/// A full second probe is emphatically NOT free (a herdr host is 25 KB/tick
/// against tmux's 3.5 KB), which is why discovery only ever produces an
/// *offer*: `Host.secondaryBackends` is written by an explicit press, never
/// by this. See `local-plan/mixed-backend-deck-plan.md`.
///
/// Pure; both probe builders compose the rider and both parsers strip the
/// region before their own line walkers ever see it.
enum BackendDiscovery {
    struct Result: Equatable, Sendable {
        var backend: Host.SessionBackend
        /// The binary is on the host. False means genuinely absent, which is
        /// a different offer than "installed, nothing running".
        var isInstalled: Bool
        /// Names as the other backend listed them. Presentation only — the
        /// offer states a count — but carried so a future surface can name
        /// what it found without a second round trip.
        var sessionNames: [String]

        var sessionCount: Int { sessionNames.count }
        /// The one condition that earns a rail offer.
        var offersSessions: Bool { isInstalled && !sessionNames.isEmpty }
    }

    /// Region framing. Emitted at the very TOP of a probe, before the
    /// primary's own presence guard — that guard `exit`s, and a host with no
    /// tmux but live herdr sessions is exactly a case worth discovering.
    /// Being in the head also puts the region ahead of the capture tails, so
    /// nothing a pane prints can be mistaken for discovery output.
    static let beginMarker = "MULTIPLEX_DISCOVER"
    static let endMarker = "MULTIPLEX_DISCOVER_END"
    /// Distinguishes "not installed" from "installed but answered nothing".
    /// Without it both look like an empty region, and the offer copy would
    /// have to guess.
    private static let presentMarker = "MPXD_PRESENT"

    // MARK: - Command

    /// One extra region asking `backend` to identify itself. Every stage is
    /// `2>/dev/null`-silenced and `|| true`-guarded — Citadel throws on a
    /// nonzero exit, so the probe's fail-soft discipline is not optional.
    static func riderCommand(for backend: Host.SessionBackend) -> String {
        var command = "echo \(beginMarker) \(backend.rawValue); "
        switch backend {
        case .herdr:
            // cargo installs a Rust binary where tmux would never live, so
            // the herdr PATH is its own; `-x` covers a `~/.cargo/bin` that
            // an exec channel's minimal PATH never picked up. The list verb
            // is `HerdrProbe`'s own — the shape `parseSessionNames` reads is
            // produced in exactly one place.
            command += RemoteCommandEnvironment.herdrPathPrefix
                + "{ command -v herdr >/dev/null 2>&1"
                + " || [ -x \"$HOME/.cargo/bin/herdr\" ]; } && "
                + "{ echo \(presentMarker); "
                + HerdrProbe.sessionListVerb + "; }; "
        case .tmux:
            // `TmuxProbe.tmuxCommand` carries the mandatory `-u`: an exec
            // channel inherits no locale, and tmux's `-F` writer then
            // sanitizes every multibyte character in a session name to `_`.
            command += RemoteCommandEnvironment.pathPrefix
                + "command -v tmux >/dev/null 2>&1 && "
                + "{ echo \(presentMarker); "
                + "\(TmuxProbe.tmuxCommand) list-sessions -F 'D #{session_name}'"
                + " 2>/dev/null || true; }; "
        }
        return command + "echo \(endMarker); "
    }

    /// The riders one probe prepends to its own command, composed once so
    /// both probe builders — and the next backend's — agree on the rule.
    ///
    /// ⚠ The riders LEAD. `read` consumes only the leading region block, and
    /// that placement is the security property: a probe response carries
    /// panes' visible screens in its capture tails, so a rider emitted after
    /// them would let terminal content forge an offer (or get the tails
    /// swallowed as region body and blank every miniature). It is also why
    /// they precede a probe's own presence guard, which `exit`s: a host with
    /// no herdr but live tmux sessions is exactly a case worth discovering.
    ///
    /// Sorted by raw value so the command is byte-stable across launches —
    /// a `Set`'s iteration order is seeded per process.
    static func riderPrefix(
        discovering: Set<Host.SessionBackend>, excluding own: Host.SessionBackend
    ) -> String {
        discovering.subtracting([own])
            .sorted { $0.rawValue < $1.rawValue }
            .map(riderCommand(for:))
            .joined()
    }

    // MARK: - Parse

    /// One pass over a probe response: what the riders answered, and the
    /// response with their regions removed.
    struct Reading: Equatable {
        /// Absent for a backend means the response carried no region for it
        /// — an older command shape, or a response cut short. Deliberately
        /// different from an installed-but-idle answer.
        var results: [Host.SessionBackend: Result]
        /// What the primary parser sees. Its line walkers ignore
        /// unrecognized lines, so today's regions would pass through
        /// harmlessly — but a backend's list format is not this app's to
        /// freeze, and a future one printing something record-shaped must
        /// not be able to reach the session list. Removing it is the
        /// guarantee; ignoring it is a coincidence.
        var remainder: String
    }

    /// Reads the LEADING block of discovery regions and returns the rest
    /// untouched.
    ///
    /// ⚠ Leading is the security property, not a convenience. The riders are
    /// emitted before anything else a probe prints, so the first region
    /// block is always theirs. Scanning the whole response instead would
    /// let a *pane* — whose visible screen rides the capture tails — print
    /// `MULTIPLEX_DISCOVER herdr` and either forge an offer or, worse, get
    /// the tails swallowed as region content. Once a non-region line
    /// follows the block, nothing later is read or removed.
    ///
    /// Arbitrary noise BEFORE the block is tolerated (a remote `.bashrc`
    /// that echoes is a real thing, and the primary parsers already tolerate
    /// it); the block simply starts at the first header.
    /// Deliberately walks the response one line at a time and slices the
    /// remainder, rather than `split`ting it into lines and re-`joined`ing
    /// what is left. The block is a leading fragment, so the remainder is
    /// literally a prefix plus a suffix of the input — and both probe parsers
    /// slice their capture-tail region off before walking it, precisely so
    /// the bulk of every response (25 KB of pane screens on a herdr host) is
    /// tokenized once, not once as probe records and again as terminal lines.
    /// Materializing every line here would undo that for both of them.
    static func read(_ output: String) -> Reading {
        // Match on UTF-8: this scans the whole response, and the grapheme-
        // aware `String.contains` pays for correctness the marker's ASCII
        // does not need.
        guard output.utf8.firstRange(of: beginMarker.utf8) != nil else {
            return Reading(results: [:], remainder: output)
        }
        var results: [Host.SessionBackend: Result] = [:]
        var cursor = output[...]
        var blockStart: String.Index?

        /// Consumes and returns the next line, newline dropped.
        func nextLine() -> Substring? {
            guard !cursor.isEmpty else { return nil }
            guard let newline = cursor.firstIndex(of: "\n") else {
                defer { cursor = cursor[cursor.endIndex...] }
                return cursor
            }
            defer { cursor = cursor[cursor.index(after: newline)...] }
            return cursor[..<newline]
        }

        while true {
            let lineStart = cursor.startIndex
            guard let line = nextLine() else { break }
            guard let backend = header(line) else {
                // Noise before the block is kept; the first line after it ends
                // the scan for good — and is put back, since it belongs to the
                // remainder.
                if blockStart != nil {
                    cursor = output[lineStart...]
                    break
                }
                continue
            }
            if blockStart == nil { blockStart = lineStart }
            var region: [Substring] = []
            var terminated = false
            while let line = nextLine() {
                if line == endMarker {
                    terminated = true
                    break
                }
                region.append(line)
            }
            // An unterminated region means the response was truncated
            // mid-probe: report nothing rather than a half-read list, and
            // treat everything consumed as region so it can't leak into the
            // primary parse either.
            if terminated {
                results[backend] = result(from: region, backend: backend)
            }
        }
        guard let blockStart else { return Reading(results: [:], remainder: output) }
        // Concatenating the untouched slices reproduces the response byte for
        // byte minus the block — no separator to re-guess, so a response with
        // or without a trailing newline round-trips either way.
        return Reading(
            results: results,
            remainder: String(output[..<blockStart]) + String(cursor)
        )
    }

    private static func header(_ line: Substring) -> Host.SessionBackend? {
        guard line.hasPrefix(beginMarker + " ") else { return nil }
        return Host.SessionBackend(
            rawValue: String(line.dropFirst(beginMarker.count + 1)))
    }

    private static func result(
        from region: [Substring], backend: Host.SessionBackend
    ) -> Result {
        guard region.contains(where: { $0 == presentMarker }) else {
            return Result(backend: backend, isInstalled: false, sessionNames: [])
        }
        return Result(
            backend: backend,
            isInstalled: true,
            sessionNames: sessionNames(in: region, backend: backend)
        )
    }

    private static func sessionNames(
        in lines: [some StringProtocol], backend: Host.SessionBackend
    ) -> [String] {
        switch backend {
        case .herdr:
            // Reuse the mint's own list parser so one shape has one reader.
            // nil (unreadable) and [] (a valid empty list) both mean "no
            // sessions to offer" here; only the mint needs them apart.
            for line in lines {
                if let names = HerdrProbe.parseSessionNames(String(line)) {
                    return names
                }
            }
            return []
        case .tmux:
            // `D <name>`, name last and space-tolerant — the probe's own
            // tail-rejoin rule. A `D` tag rather than the probe's `S` so a
            // stripped region can never be confused with a record line.
            return lines.compactMap { line in
                guard line.hasPrefix("D ") else { return nil }
                let name = String(line.dropFirst(2))
                return name.isEmpty ? nil : name
            }
        }
    }

}
