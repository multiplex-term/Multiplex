import XCTest
@testable import Multiplex

final class ReleaseNotesTests: XCTestCase {
    // MARK: Content

    /// The card's whole premise is four rows, and the fourth is where the
    /// platform filter earns its keep: an iPad reader is told about the title
    /// bar, a Vision Pro reader about GLASS, and neither hears the other's.
    func testTheCardsFourthRowIsTheOneAboutThisPlatform() {
        for platform in ReleaseNotePlatform.allCases {
            XCTAssertEqual(
                ReleaseNotes.highlights(for: platform).count,
                ReleaseNotes.highlightCount,
                "\(platform) must fill the card"
            )
        }
        XCTAssertEqual(ReleaseNotes.highlights(for: .pad).last?.id, "titlebar")
        XCTAssertEqual(ReleaseNotes.highlights(for: .vision).map(\.id).contains("glass"), true)
        XCTAssertEqual(ReleaseNotes.highlights(for: .phone).last?.id, "alerts")
    }

    func testGlassIsNeverPromisedToAnIPadAndKeepAliveNeverToAVisionPro() {
        let padIDs = ReleaseNotes.entries(for: .pad).map(\.id)
        XCTAssertFalse(padIDs.contains("glass"))
        XCTAssertTrue(padIDs.contains("keepalive"))
        XCTAssertTrue(padIDs.contains("titlebar"))

        let visionIDs = ReleaseNotes.entries(for: .vision).map(\.id)
        XCTAssertTrue(visionIDs.contains("glass"))
        XCTAssertFalse(visionIDs.contains("keepalive"))
        XCTAssertFalse(visionIDs.contains("titlebar"))

        let phoneIDs = ReleaseNotes.entries(for: .phone).map(\.id)
        XCTAssertTrue(phoneIDs.contains("keepalive"))
        XCTAssertFalse(phoneIDs.contains("titlebar"))
    }

    /// A highlight shown where the change it summarises does not exist would
    /// promise a feature the reader cannot find.
    func testNoHighlightIsShownWhereItsOwnChangeIsNot() {
        let byID = Dictionary(
            uniqueKeysWithValues: ReleaseNotes.allEntries.map { ($0.id, $0) }
        )
        for highlight in ReleaseNotes.allHighlights {
            XCTAssertFalse(highlight.covers.isEmpty, "\(highlight.id) covers nothing")
            for id in highlight.covers {
                let entry = try? XCTUnwrap(byID[id], "\(highlight.id) names a missing entry")
                guard let entry else { continue }
                XCTAssertTrue(
                    highlight.platforms.isSubset(of: entry.platforms),
                    "\(highlight.id) is shown where \(id) does not ship"
                )
            }
        }
    }

    func testABankIsOnlyHeadedWhenThisPlatformHasSomethingInIt() {
        let padBanks = ReleaseNotes.banks(for: .pad).map(\.bank)
        XCTAssertFalse(
            padBanks.contains(.appearance),
            "APPEARANCE holds only GLASS, so it must not head an empty section on iPad"
        )
        XCTAssertTrue(ReleaseNotes.banks(for: .vision).map(\.bank).contains(.appearance))
        for (_, entries) in ReleaseNotes.banks(for: .phone) {
            XCTAssertFalse(entries.isEmpty)
        }
    }

    /// The card says what it is leaving out, and must never re-offer something
    /// it already showed — "herdr, or both at once" covers two log entries, so
    /// neither may reappear in the same breath as "also in 1.3".
    func testTheAlsoLineNeverRenamesSomethingTheCardAlreadyShowed() throws {
        for platform in ReleaseNotePlatform.allCases {
            let also = try XCTUnwrap(ReleaseNotes.alsoLine(for: platform))
            let shown = ReleaseNotes.highlights(for: platform)
                .reduce(into: Set<String>()) { $0.formUnion($1.covers) }
            for id in shown {
                guard let mention = ReleaseNotes.allEntries
                    .first(where: { $0.id == id })?.mention else { continue }
                XCTAssertFalse(
                    also.contains(mention),
                    "\(platform)'s also line re-offers \(id)"
                )
            }
        }
    }

    /// The count is derived, so it can never drift from what is on screen.
    func testTheAlsoLineCountsExactlyTheChangesItDoesNotName() throws {
        for platform in ReleaseNotePlatform.allCases {
            let shown = ReleaseNotes.highlights(for: platform)
                .reduce(into: Set<String>()) { $0.formUnion($1.covers) }
            let remaining = ReleaseNotes.entries(for: platform)
                .filter { !shown.contains($0.id) }
            let named = remaining.compactMap(\.mention).prefix(3)
            let also = try XCTUnwrap(ReleaseNotes.alsoLine(for: platform))

            XCTAssertTrue(also.hasPrefix("Also in \(ReleaseNotes.version): "))
            for mention in named {
                XCTAssertTrue(also.contains(mention), "\(platform) dropped \(mention)")
            }
            let unnamed = remaining.count - named.count
            if unnamed > 0 {
                XCTAssertTrue(
                    also.hasSuffix("— and \(unnamed) more."),
                    "\(platform) miscounts the rest: \(also)"
                )
            }
        }
    }

    func testEveryChangeIsWrittenOnce() {
        let ids = ReleaseNotes.allEntries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate entry id")
        let highlightIDs = ReleaseNotes.allHighlights.map(\.id)
        XCTAssertEqual(Set(highlightIDs).count, highlightIDs.count)
        for entry in ReleaseNotes.allEntries {
            XCTAssertFalse(entry.platforms.isEmpty, "\(entry.id) ships nowhere")
        }
    }

    // MARK: The launch gate

    /// The rule no fresh install can prove by hand: 1.2 stamped nothing, so a
    /// missing stamp on an install that is already in use means "updated",
    /// not "new". Getting this backwards silences the notes for exactly the
    /// people they were written for.
    func testAnInstallUpdatingFromAVersionThatStampedNothingIsShownTheNotes() {
        XCTAssertEqual(
            ReleaseNotesGate.decide(
                lastSeen: nil,
                current: "1.3",
                installHasPriorUse: true
            ),
            .show
        )
    }

    func testAFirstRunIsStampedWithoutEverShowingTheNotes() {
        XCTAssertEqual(
            ReleaseNotesGate.decide(
                lastSeen: nil,
                current: "1.3",
                installHasPriorUse: false
            ),
            .stampSilently
        )
    }

    func testAPatchReleaseDoesNotReopenTheCard() {
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.3", current: "1.3", installHasPriorUse: true),
            .nothing
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.3", current: "1.3.1", installHasPriorUse: true),
            .nothing
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.3.0", current: "1.3.9", installHasPriorUse: true),
            .nothing
        )
    }

    func testANewMinorOrMajorReopensTheCard() {
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.3", current: "1.4", installHasPriorUse: true),
            .show
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.9", current: "2.0", installHasPriorUse: true),
            .show
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1", current: "1.1", installHasPriorUse: true),
            .show
        )
    }

    /// A TestFlight build older than the stamp, and a stamp nobody can parse.
    /// Neither is a reason to nag; a broken stamp is repaired by showing once.
    func testADowngradeIsSilentAndAnUnreadableStampRecovers() {
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.4", current: "1.3", installHasPriorUse: true),
            .nothing
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "beta", current: "1.3", installHasPriorUse: true),
            .show
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.3", current: "", installHasPriorUse: true),
            .nothing
        )
    }

    // MARK: The stamp

    func testTheSeenStampReadsBackAndStartsEmpty() throws {
        let suite = "app.multiplexterm.tests.releaseNotes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ReleaseNotesStore(defaults: defaults)
        XCTAssertNil(store.lastSeenVersion)
        store.markSeen("1.3")
        XCTAssertEqual(ReleaseNotesStore(defaults: defaults).lastSeenVersion, "1.3")
    }
}
