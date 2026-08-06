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
            // an exec channel's minimal PATH never picked up.
            command += RemoteCommandEnvironment.herdrPathPrefix
                + "{ command -v herdr >/dev/null 2>&1"
                + " || [ -x \"$HOME/.cargo/bin/herdr\" ]; } && "
                + "{ echo \(presentMarker); "
                + "herdr session list --json 2>/dev/null || true; }; "
        case .tmux:
            // `-u` on every tmux invocation, always: an exec channel
            // inherits no locale, and tmux's `-F` writer then sanitizes
            // every multibyte character in a session name to `_`.
            command += RemoteCommandEnvironment.pathPrefix
                + "command -v tmux >/dev/null 2>&1 && "
                + "{ echo \(presentMarker); "
                + "tmux -u list-sessions -F 'D #{session_name}' 2>/dev/null || true; }; "
        }
        return command + "echo \(endMarker); "
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
    static func read(_ output: String) -> Reading {
        guard output.contains(beginMarker) else {
            return Reading(results: [:], remainder: output)
        }
        var results: [Host.SessionBackend: Result] = [:]
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)[...]
        var leading: [Substring] = []
        var blockStarted = false

        while let line = lines.first {
            guard let backend = header(line) else {
                // Noise before the block is kept; anything after it ends the
                // scan for good.
                if blockStarted { break }
                leading.append(line)
                lines = lines.dropFirst()
                continue
            }
            blockStarted = true
            lines = lines.dropFirst()
            var region: [Substring] = []
            var terminated = false
            while let line = lines.first {
                lines = lines.dropFirst()
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
        return Reading(
            results: results,
            remainder: (leading + lines).joined(separator: "\n")
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
