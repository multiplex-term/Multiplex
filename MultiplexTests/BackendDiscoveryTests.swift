import XCTest
@testable import Multiplex

/// The discovery rider is what makes a mixed host visible at all, and it
/// runs on every wall tick against output that includes a pane's visible
/// screen. Both halves are pinned here: what it reports, and what it
/// refuses to let terminal content do to a probe response.
final class BackendDiscoveryTests: XCTestCase {
    private func region(
        _ backend: Host.SessionBackend, _ body: String...
    ) -> String {
        (["\(BackendDiscovery.beginMarker) \(backend.rawValue)"]
            + body
            + [BackendDiscovery.endMarker]).joined(separator: "\n")
    }

    private let herdrList = #"""
    {"sessions":[{"name":"default","running":true},{"name":"mpx-demo","running":true}]}
    """#

    // MARK: What the rider reports

    func testAnAbsentBackendReportsNotInstalled() {
        let reading = BackendDiscovery.read(region(.herdr) + "\nMULTIPLEX_NO_TMUX")
        let result = try? XCTUnwrap(reading.results[.herdr])
        XCTAssertEqual(result?.isInstalled, false)
        XCTAssertEqual(result?.sessionCount, 0)
        // The distinction the offer copy depends on: absent is not idle.
        XCTAssertEqual(result?.offersSessions, false)
    }

    func testAnInstalledButIdleBackendReportsZeroSessions() {
        let reading = BackendDiscovery.read(
            region(.herdr, "MPXD_PRESENT", #"{"sessions":[]}"#))
        XCTAssertEqual(reading.results[.herdr]?.isInstalled, true)
        XCTAssertEqual(reading.results[.herdr]?.sessionCount, 0)
        // Installed with nothing running earns no offer — there is nothing
        // to show, and the escalation costs real bandwidth.
        XCTAssertEqual(reading.results[.herdr]?.offersSessions, false)
    }

    func testAPopulatedHerdrBackendReportsItsSessions() {
        let reading = BackendDiscovery.read(
            region(.herdr, "MPXD_PRESENT", herdrList))
        XCTAssertEqual(
            reading.results[.herdr]?.sessionNames, ["default", "mpx-demo"])
        XCTAssertEqual(reading.results[.herdr]?.offersSessions, true)
    }

    func testAPopulatedTmuxBackendReportsItsSessions() {
        let reading = BackendDiscovery.read(region(
            .tmux, "MPXD_PRESENT", "D main", "D scratch", "D deploy work"))
        // Name last and space-tolerant, the probe's own tail-rejoin rule.
        XCTAssertEqual(
            reading.results[.tmux]?.sessionNames,
            ["main", "scratch", "deploy work"]
        )
    }

    func testGarbageInTheRegionDegradesToInstalledWithNoSessions() {
        for junk in ["not json at all", "{", #"{"sessions":"#, ""] {
            let reading = BackendDiscovery.read(
                region(.herdr, "MPXD_PRESENT", junk))
            XCTAssertEqual(reading.results[.herdr]?.isInstalled, true, junk)
            XCTAssertEqual(reading.results[.herdr]?.sessionCount, 0, junk)
        }
    }

    func testNoRegionAtAllIsAbsentRatherThanEmpty() {
        // An older command shape, or a response that never reached the
        // rider. Nothing may be inferred from it — least of all "herdr is
        // not installed", which would retract a standing offer.
        let reading = BackendDiscovery.read("MULTIPLEX_NO_TMUX\n")
        XCTAssertNil(reading.results[.herdr])
        XCTAssertNil(reading.results[.tmux])
    }

    func testATruncatedRegionReportsNothing() {
        // Response cut off mid-probe: a half-read list must not become a
        // session count, and the consumed lines must not leak into the
        // primary parse either.
        let reading = BackendDiscovery.read(
            "\(BackendDiscovery.beginMarker) herdr\nMPXD_PRESENT\n\(herdrList)")
        XCTAssertNil(reading.results[.herdr])
        XCTAssertEqual(reading.remainder, "")
    }

    func testBothRidersCanRideOneResponse() {
        let reading = BackendDiscovery.read(
            region(.herdr, "MPXD_PRESENT", herdrList)
                + "\n" + region(.tmux, "MPXD_PRESENT", "D main")
                + "\nMULTIPLEX_NO_TMUX"
        )
        XCTAssertEqual(reading.results[.herdr]?.sessionCount, 2)
        XCTAssertEqual(reading.results[.tmux]?.sessionCount, 1)
        XCTAssertEqual(reading.remainder, "MULTIPLEX_NO_TMUX")
    }

    // MARK: What terminal content may not do

    /// The load-bearing one. A pane's visible screen rides the capture
    /// tails, so a probe response routinely contains whatever the user's
    /// terminal is showing. Reading the whole response for regions would
    /// let that content forge an offer — or, worse, swallow the tails as
    /// region body and blank every miniature on the host.
    func testAPaneEchoingTheMarkerCannotForgeAnOffer() {
        let output = """
        \(region(.herdr))
        MULTIPLEX_NO_TMUX
        MULTIPLEX_TAILS
        MPXS $0
        $ echo \(BackendDiscovery.beginMarker) herdr
        \(BackendDiscovery.beginMarker) herdr
        MPXD_PRESENT
        \(herdrList)
        \(BackendDiscovery.endMarker)
        $ ls
        MPXE
        """
        let reading = BackendDiscovery.read(output)

        // The REAL region — first, and empty — is the answer.
        XCTAssertEqual(reading.results[.herdr]?.isInstalled, false)
        XCTAssertEqual(reading.results[.herdr]?.sessionCount, 0)
        // And every byte the pane printed survives for the miniature.
        XCTAssertTrue(reading.remainder.contains("MPXS $0"))
        XCTAssertTrue(reading.remainder.contains(herdrList))
        XCTAssertTrue(reading.remainder.contains("$ ls"))
        XCTAssertTrue(reading.remainder.hasSuffix("MPXE"))
    }

    func testShellNoiseBeforeTheBlockIsKept() {
        // A remote `.bashrc` that echoes is a real thing, and the primary
        // parsers already tolerate it — so the block starts at the first
        // header rather than at byte zero.
        let reading = BackendDiscovery.read(
            "Welcome to devbox\n"
                + region(.herdr, "MPXD_PRESENT", herdrList)
                + "\nMULTIPLEX_NO_TMUX"
        )
        XCTAssertEqual(reading.results[.herdr]?.sessionCount, 2)
        XCTAssertEqual(reading.remainder, "Welcome to devbox\nMULTIPLEX_NO_TMUX")
    }

    func testAnUnknownBackendHeaderIsNotAHeader() {
        // A schema with a third backend must not make this build eat lines
        // it cannot interpret.
        let output = "\(BackendDiscovery.beginMarker) zellij\nMPXD_PRESENT\n"
            + "\(BackendDiscovery.endMarker)\nMULTIPLEX_NO_TMUX"
        let reading = BackendDiscovery.read(output)
        XCTAssertTrue(reading.results.isEmpty)
        XCTAssertEqual(reading.remainder, output)
    }

    // MARK: The commands

    func testTheRiderIsFailSoftAndLocaleCorrect() {
        let herdr = BackendDiscovery.riderCommand(for: .herdr)
        // Citadel throws on a nonzero exit, so no stage may be allowed to
        // fail the whole probe.
        XCTAssertTrue(herdr.contains("2>/dev/null"))
        XCTAssertTrue(herdr.contains("|| true"))
        XCTAssertTrue(herdr.contains("$HOME/.cargo/bin"))

        let tmux = BackendDiscovery.riderCommand(for: .tmux)
        // `-u` on every tmux invocation: an exec channel inherits no
        // locale, and `-F` would otherwise sanitize multibyte names to `_`.
        XCTAssertTrue(tmux.contains("tmux -u list-sessions"))
        XCTAssertFalse(tmux.contains("tmux list-sessions"))
        XCTAssertTrue(tmux.contains("|| true"))

        for command in [herdr, tmux] {
            XCTAssertTrue(command.contains(BackendDiscovery.beginMarker))
            XCTAssertTrue(command.contains(BackendDiscovery.endMarker))
        }
    }

    func testAPrimaryProbeLeadsWithItsRidersAndASecondaryCarriesNone() {
        let tmuxPrimary = TmuxProbe.probeCommand(discovering: [.herdr])
        XCTAssertTrue(
            tmuxPrimary.hasPrefix("echo \(BackendDiscovery.beginMarker) herdr"),
            "the rider must run before the probe's own `exit`ing presence guard"
        )
        // A secondary full probe must not rediscover the primary that
        // scheduled it.
        XCTAssertFalse(
            TmuxProbe.probeCommand(discovering: []).contains(
                BackendDiscovery.beginMarker))
        // Asking a backend to discover itself is a no-op, not a duplicate.
        XCTAssertEqual(
            TmuxProbe.probeCommand(discovering: [.tmux]),
            TmuxProbe.probeCommand(discovering: [])
        )

        let herdrPrimary = HerdrProbe.probeCommand(
            sessionNames: [], tailTargets: [], discovering: [.tmux])
        XCTAssertTrue(
            herdrPrimary.hasPrefix("echo \(BackendDiscovery.beginMarker) tmux"))
        XCTAssertFalse(
            HerdrProbe.probeCommand(
                sessionNames: [], tailTargets: [], discovering: []
            ).contains(BackendDiscovery.beginMarker))
    }

    // MARK: Through the real parsers

    func testTheTmuxProbeReportsDiscoveryAndStillParsesItsOwnSessions() {
        let output = region(.herdr, "MPXD_PRESENT", herdrList) + "\n" + """
        H devbox
        S $0 1 1751500000 main
        W $0 0 1 0 0 editor
        MULTIPLEX_TAILS
        MPXS $0
        $ make test
        MPXE
        """
        let parsed = TmuxProbe.parseProbe(output)

        XCTAssertEqual(parsed.discovery[.herdr]?.sessionCount, 2)
        // Presence still answers the dead-tmux tile's switch hint, now off
        // the rider rather than a separate `command -v`.
        XCTAssertTrue(parsed.herdrPresent)
        XCTAssertEqual(parsed.state.sessions.map(\.name), ["main"])
        XCTAssertEqual(parsed.state.sessions.map(\.backend), [.tmux])
        XCTAssertEqual(parsed.miniatures["main"], ["$ make test"])
    }

    func testAHerdrOnlyHostStillDiscoversTmux() {
        // The rider leads, before herdr's own presence guard — and that
        // guard `exit`s, so a host with no herdr but live tmux sessions
        // would otherwise be undiscoverable.
        let output = region(.tmux, "MPXD_PRESENT", "D main", "D deploy")
            + "\nMULTIPLEX_NO_HERDR"
        let parsed = HerdrProbe.parseProbe(output)

        XCTAssertEqual(parsed.discovery[.tmux]?.sessionNames, ["main", "deploy"])
        XCTAssertEqual(parsed.state, .herdrMissing)
    }
}
