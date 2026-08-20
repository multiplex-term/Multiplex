import UIKit
import XCTest
@testable import Multiplex

/// The host-record and wall rules that make one host show two multiplexers.
@MainActor
final class MixedBackendTests: XCTestCase {
    private func mixedHost() -> Host {
        var host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        host.secondaryBackends = [.herdr]
        return host
    }

    // MARK: The record

    func testMonitoredBackendsLeadsWithThePrimary() {
        var host = mixedHost()
        XCTAssertEqual(host.monitoredBackends, [.tmux, .herdr])
        XCTAssertTrue(host.showsBackendIdentity)

        host.sessionBackend = .herdr
        host.secondaryBackends = [.tmux]
        XCTAssertEqual(host.monitoredBackends, [.herdr, .tmux])

        // The shipping default: one backend, no new chrome anywhere.
        let plain = Host(name: "a", hostname: "b", username: "c")
        XCTAssertEqual(plain.monitoredBackends, [.tmux])
        XCTAssertFalse(plain.showsBackendIdentity)
        XCTAssertTrue(plain.secondaryBackends.isEmpty)
    }

    func testTheRecordDecodesForgivinglyAndOldBuildsAreUnaffected() throws {
        // Unknown raw values drop per element rather than throwing the host
        // away — `sessionBackend`'s rule, applied to the set.
        let json = """
        {
          "name": "devbox", "hostname": "10.0.0.2", "username": "dev",
          "sessionBackend": "tmux",
          "secondaryBackends": ["herdr", "zellij", "tmux"]
        }
        """
        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        // "zellij" is unknown; "tmux" is the primary and may never also be a
        // secondary (`monitoredBackends` would list it twice).
        XCTAssertEqual(host.secondaryBackends, [.herdr])
        XCTAssertEqual(host.monitoredBackends, [.tmux, .herdr])

        // A record with no key at all behaves exactly as it always did.
        let legacy = try JSONDecoder().decode(Host.self, from: Data("""
        {"name": "a", "hostname": "b", "username": "c"}
        """.utf8))
        XCTAssertTrue(legacy.secondaryBackends.isEmpty)
    }

    func testAddingABackendRebuildsTheProbeConnection() {
        // The probe command is backend-shaped, so the field must be part of
        // the connection identity — the same reasoning that already puts
        // `sessionBackend` there.
        let plain = Host(name: "a", hostname: "b", username: "c")
        var mixed = plain
        mixed.secondaryBackends = [.herdr]
        XCTAssertFalse(plain.hasSameConnectionModelConfiguration(as: mixed))
    }

    // MARK: The tile's backend identity

    func testTheTileSaysItsBackendOnlyOnAMixedHost() {
        // Single-backend hosts keep the shipped chassis exactly — a tinted
        // wall where the backend is not in question would be decoration.
        for backend in Host.SessionBackend.allCases {
            let plain = UIKitChassis.tileBezel(backend: backend, tinted: false)
            XCTAssertEqual(plain, UIKitChassis.bezel, "\(backend)")
        }
        // tmux keeps graphite even on a mixed host: it is the app's premise,
        // so only the deviation is tinted (the MOSH badge's rule).
        XCTAssertEqual(
            UIKitChassis.tileBezel(backend: .tmux, tinted: true),
            UIKitChassis.bezel
        )
        XCTAssertNotEqual(
            UIKitChassis.tileBezel(backend: .herdr, tinted: true),
            UIKitChassis.bezel
        )
    }

    /// The wash must change HUE, not hierarchy: a herdr tile is a sibling of
    /// the tmux tile beside it, never a raised or highlighted one.
    func testTheHerdrWashMatchesBezelsLightnessInBothPolarities() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let bezel = TallyPalette.bezel.resolvedColor(with: traits)
            let herdr = TallyPalette.herdrBezel.resolvedColor(with: traits)
            XCTAssertNotEqual(bezel, herdr, "\(style)")
            XCTAssertEqual(
                luminance(of: herdr), luminance(of: bezel), accuracy: 3 / 255,
                "the herdr wash must read as a different tint, not a brighter tile"
            )
            // And it must actually be purple: blue above red above green.
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            herdr.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            XCTAssertGreaterThan(blue, red, "\(style)")
            XCTAssertGreaterThan(red, green, "\(style)")
        }
    }

    private func luminance(of color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// The tile carries its backend as a chassis tint and nothing else — no
    /// `TMUX`/`HRDR` chip. VoiceOver cannot see a tint, so the label is the
    /// only place that fact survives, and this is what stops the backend
    /// from being encoded in color alone.
    func testAMixedHostsTileNamesItsBackendToVoiceOver() {
        func summary(backend: Host.SessionBackend, mixed: Bool) -> String {
            var session = TmuxSession(
                name: "main", windows: [], created: .distantPast)
            session.backend = backend
            let tile = FleetSessionTileView()
            tile.configure(FleetSessionTileConfiguration(
                hostID: UUID(),
                session: session,
                lines: [],
                attention: nil,
                usesTmuxAttentionFallback: false,
                hasOpenTab: false,
                sessionBackend: backend,
                showsBackendIdentity: mixed,
                compact: false,
                selected: false,
                duplicateAttachTitle: "Attach in New Window",
                openTabAccessibilityText: "Open",
                attach: {}, attachNewWindow: {}, newHerdrTab: {},
                copyHandoffCommand: {}, delete: {}, droppedSession: { _ in }
            ))
            return tile.accessibilityLabel ?? ""
        }

        XCTAssertTrue(summary(backend: .herdr, mixed: true).contains("on herdr"))
        XCTAssertTrue(summary(backend: .tmux, mixed: true).contains("on tmux"))
        // And says nothing extra where the backend isn't in question.
        XCTAssertFalse(summary(backend: .herdr, mixed: false).contains("on herdr"))
        XCTAssertFalse(summary(backend: .tmux, mixed: false).contains("on tmux"))
    }

    // MARK: The offer

    func testTheOfferChipNamesTheBackendAndItsCount() {
        XCTAssertEqual(
            FleetBackendOffer(backend: .herdr, sessionCount: 3).chipCaption,
            "+ HERDR · 3"
        )
        XCTAssertEqual(
            FleetBackendOffer(backend: .herdr, sessionCount: 1).sessionNoun,
            "1 session"
        )
        XCTAssertEqual(
            FleetBackendOffer(backend: .tmux, sessionCount: 4).sessionNoun,
            "4 sessions"
        )
    }

    func testDismissingAnOfferIsPerHostPerBackendAndPerDevice() {
        let defaults = UserDefaults(suiteName: "mixed-backend-\(UUID().uuidString)")!
        let preferences = BackendOfferPreferences(defaults: defaults)
        let host = UUID()
        let other = UUID()

        XCTAssertFalse(preferences.isDismissed(.herdr, for: host))
        preferences.setDismissed(true, backend: .herdr, for: host)
        XCTAssertTrue(preferences.isDismissed(.herdr, for: host))
        // Scoped: another backend, and another host, are untouched.
        XCTAssertFalse(preferences.isDismissed(.tmux, for: host))
        XCTAssertFalse(preferences.isDismissed(.herdr, for: other))

        preferences.setDismissed(false, backend: .herdr, for: host)
        XCTAssertFalse(preferences.isDismissed(.herdr, for: host))

        // Removing the host takes its entry with it — nothing else prunes.
        preferences.setDismissed(true, backend: .herdr, for: host)
        preferences.forget(hostID: host)
        XCTAssertFalse(preferences.isDismissed(.herdr, for: host))
    }

    // MARK: Attention across two backends

    /// The shape of the bug fixed 2026-08-05, re-armed by mixed hosts: one
    /// backend's empty (or failed) answer must not clear the OTHER's NEEDS
    /// YOU, and — much more importantly — must not reset its edge baseline,
    /// which is the only thing that lets "the agent finished while you were
    /// away" ever fire.
    func testOneBackendsPruneLeavesTheOthersBaselineAlone() {
        var tracker = AttentionTracker<SessionKey>()
        let tmuxMain = SessionKey(backend: .tmux, name: "main")
        let herdrMain = SessionKey(backend: .herdr, name: "main")

        // Baselines for both: same NAME, different sessions.
        XCTAssertTrue(tracker.update(session: tmuxMain, state: .busy, hasBell: false).isEmpty)
        XCTAssertTrue(tracker.update(session: herdrMain, state: .busy, hasBell: false).isEmpty)

        // The tmux probe answers with no sessions; herdr's failed and is not
        // in `answered`, so only tmux's key may be pruned.
        let answered: Set<Host.SessionBackend> = [.tmux]
        tracker.prune { key in !answered.contains(key.backend) }

        // tmux starts fresh — no edge from a first sighting.
        XCTAssertTrue(tracker.update(session: tmuxMain, state: .idle, hasBell: false).isEmpty)
        // herdr's baseline survived, so its busy → idle still reports.
        XCTAssertEqual(
            tracker.update(session: herdrMain, state: .idle, hasBell: false),
            [.turnEnded]
        )
    }

    func testPruneStillWorksForSingleBackendCallers() {
        var tracker = AttentionTracker<String>()
        _ = tracker.update(session: "a", state: .busy, hasBell: false)
        _ = tracker.update(session: "b", state: .busy, hasBell: false)
        tracker.prune { $0 == "a" }
        XCTAssertTrue(tracker.update(session: "b", state: .idle, hasBell: false).isEmpty)
        XCTAssertEqual(
            tracker.update(session: "a", state: .idle, hasBell: false),
            [.turnEnded]
        )
    }
}
