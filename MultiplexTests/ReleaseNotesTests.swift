import XCTest
@testable import Multiplex

final class ReleaseNotesTests: XCTestCase {
    // MARK: Content

    /// The card speaks for the newest release only — 1.4's features, not a
    /// merge of every release the log still carries.
    func testTheCardAnnouncesTheNewestRelease() {
        XCTAssertEqual(ReleaseNotes.version, "1.4")
        XCTAssertEqual(ReleaseNotes.releases.first?.version, ReleaseNotes.version)
        XCTAssertEqual(ReleaseNotes.promise, ReleaseNotes.current.promise)
    }

    /// The card's whole premise is four rows, and the fourth is where the
    /// platform filter earns its keep: an iPhone or iPad reader is told the
    /// keys tap back, a Vision Pro reader (which has no haptics) gets the
    /// File Viewer's PDFs and sound files instead.
    func testTheCardsFourthRowIsTheOneAboutThisPlatform() {
        for platform in ReleaseNotePlatform.allCases {
            XCTAssertEqual(
                ReleaseNotes.highlights(for: platform).count,
                ReleaseNotes.highlightCount,
                "\(platform) must fill the card"
            )
        }
        XCTAssertEqual(ReleaseNotes.highlights(for: .pad).last?.id, "haptics")
        XCTAssertEqual(ReleaseNotes.highlights(for: .vision).last?.id, "fvmedia")
        XCTAssertEqual(ReleaseNotes.highlights(for: .phone).last?.id, "haptics")
    }

    func testHapticsNeverReachAVisionPro() {
        let padIDs = ReleaseNotes.entries(for: .pad).map(\.id)
        XCTAssertTrue(padIDs.contains("haptics"))
        XCTAssertTrue(padIDs.contains("keycommands"))

        let visionIDs = ReleaseNotes.entries(for: .vision).map(\.id)
        XCTAssertFalse(visionIDs.contains("haptics"))
        XCTAssertTrue(visionIDs.contains("keycommands"))
        XCTAssertTrue(visionIDs.contains("fvmedia"))

        let phoneIDs = ReleaseNotes.entries(for: .phone).map(\.id)
        XCTAssertTrue(phoneIDs.contains("haptics"))
    }

    /// The 1.3.1 record rides along under the 1.4 log, and its platform
    /// scoping still holds: the floating bars never on an iPad, the key rail
    /// never on a Vision Pro.
    func testTheBankedOneThreeOneRecordKeepsItsPlatformScoping() throws {
        let v131 = try XCTUnwrap(
            ReleaseNotes.releases.first { $0.version == "1.3.1" },
            "the log dropped the 1.3.1 record"
        )
        let padIDs = v131.entries(for: .pad).map(\.id)
        XCTAssertFalse(padIDs.contains("ornaments"))
        XCTAssertFalse(padIDs.contains("ninety"))
        XCTAssertFalse(padIDs.contains("wheelpin"))
        XCTAssertTrue(padIDs.contains("keyrail"))
        XCTAssertTrue(padIDs.contains("metal"))

        let visionIDs = v131.entries(for: .vision).map(\.id)
        XCTAssertTrue(visionIDs.contains("ornaments"))
        XCTAssertTrue(visionIDs.contains("ninety"))
        XCTAssertFalse(visionIDs.contains("keyrail"))

        let phoneIDs = v131.entries(for: .phone).map(\.id)
        XCTAssertTrue(phoneIDs.contains("keyrail"))
        XCTAssertFalse(phoneIDs.contains("ornaments"))
    }

    /// The 1.3 record rides along too, and its platform scoping still holds:
    /// GLASS never on an iPad, keep-alive never on a Vision Pro.
    func testTheBankedThirteenRecordKeepsItsPlatformScoping() throws {
        let v13 = try XCTUnwrap(
            ReleaseNotes.releases.first { $0.version == "1.3" },
            "the log dropped the 1.3 record"
        )
        let padIDs = v13.entries(for: .pad).map(\.id)
        XCTAssertFalse(padIDs.contains("glass"))
        XCTAssertTrue(padIDs.contains("keepalive"))
        XCTAssertTrue(padIDs.contains("titlebar"))

        let visionIDs = v13.entries(for: .vision).map(\.id)
        XCTAssertTrue(visionIDs.contains("glass"))
        XCTAssertFalse(visionIDs.contains("keepalive"))
        XCTAssertFalse(visionIDs.contains("titlebar"))
    }

    /// A highlight shown where the change it summarises does not exist would
    /// promise a feature the reader cannot find.
    func testNoHighlightIsShownWhereItsOwnChangeIsNot() {
        for release in ReleaseNotes.releases {
            let byID = Dictionary(
                uniqueKeysWithValues: release.entries.map { ($0.id, $0) }
            )
            for highlight in release.highlights {
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
    }

    func testABankIsOnlyHeadedWhenThisPlatformHasSomethingInIt() {
        for release in ReleaseNotes.releases {
            for platform in ReleaseNotePlatform.allCases {
                for (_, entries) in release.banks(for: platform) {
                    XCTAssertFalse(entries.isEmpty)
                }
            }
        }
        // Before 1.4, APPEARANCE held only GLASS, so it must not head an empty
        // section on iPad in those records; 1.4's live theme editing is for
        // every platform, so there it heads a section everywhere.
        for release in ReleaseNotes.releases where release.version != "1.4" {
            XCTAssertFalse(release.banks(for: .pad).map(\.bank).contains(.appearance))
        }
        let v13 = ReleaseNotes.releases.first { $0.version == "1.3" }
        XCTAssertEqual(v13?.banks(for: .vision).map(\.bank).contains(.appearance), true)
        for platform in ReleaseNotePlatform.allCases {
            XCTAssertTrue(ReleaseNotes.banks(for: platform).map(\.bank).contains(.appearance))
        }
    }

    /// The card says what it is leaving out, and must never re-offer something
    /// it already showed.
    func testTheAlsoLineNeverRenamesSomethingTheCardAlreadyShowed() throws {
        for release in ReleaseNotes.releases {
            for platform in ReleaseNotePlatform.allCases {
                let also = try XCTUnwrap(release.alsoLine(for: platform))
                let shown = release.highlights(for: platform)
                    .reduce(into: Set<String>()) { $0.formUnion($1.covers) }
                for id in shown {
                    guard let mention = release.entries
                        .first(where: { $0.id == id })?.mention else { continue }
                    XCTAssertFalse(
                        also.contains(mention),
                        "\(release.version) \(platform)'s also line re-offers \(id)"
                    )
                }
            }
        }
    }

    /// The count is derived, so it can never drift from what is on screen.
    func testTheAlsoLineCountsExactlyTheChangesItDoesNotName() throws {
        for release in ReleaseNotes.releases {
            for platform in ReleaseNotePlatform.allCases {
                let shown = release.highlights(for: platform)
                    .reduce(into: Set<String>()) { $0.formUnion($1.covers) }
                let remaining = release.entries(for: platform)
                    .filter { !shown.contains($0.id) }
                let named = remaining.compactMap(\.mention).prefix(3)
                let also = try XCTUnwrap(release.alsoLine(for: platform))

                XCTAssertTrue(also.hasPrefix("Also in \(release.version): "))
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
    }

    func testEveryChangeIsWrittenOnce() {
        let versions = ReleaseNotes.releases.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count, "duplicate release")
        for release in ReleaseNotes.releases {
            let ids = release.entries.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "duplicate entry id in \(release.version)")
            let highlightIDs = release.highlights.map(\.id)
            XCTAssertEqual(Set(highlightIDs).count, highlightIDs.count)
            for entry in release.entries {
                XCTAssertFalse(entry.platforms.isEmpty, "\(entry.id) ships nowhere")
            }
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
                current: "1.3.1",
                installHasPriorUse: true
            ),
            .show
        )
    }

    func testAFirstRunIsStampedWithoutEverShowingTheNotes() {
        XCTAssertEqual(
            ReleaseNotesGate.decide(
                lastSeen: nil,
                current: "1.3.1",
                installHasPriorUse: false
            ),
            .stampSilently
        )
    }

    /// A release that writes notes of its own reopens the card at any version
    /// component — `ReleaseNotes.version` moving to 1.3.1 is what carries
    /// 1.3.1's notes to the people who already saw 1.3's.
    func testANewNotesReleaseReopensTheCard() {
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.3", current: "1.3.1", installHasPriorUse: true),
            .show
        )
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

    /// A patch BUILD without notes of its own leaves `ReleaseNotes.version`
    /// alone, compares equal, and must not re-present old notes.
    func testABuildWithoutItsOwnNotesDoesNotReopenTheCard() {
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.3", current: "1.3", installHasPriorUse: true),
            .nothing
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(
                lastSeen: "1.3.1",
                current: "1.3.1",
                installHasPriorUse: true
            ),
            .nothing
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(
                lastSeen: "1.3.0",
                current: "1.3",
                installHasPriorUse: true
            ),
            .nothing
        )
    }

    /// A TestFlight build older than the stamp, and a stamp nobody can parse.
    /// Neither is a reason to nag; a broken stamp is repaired by showing once.
    func testADowngradeIsSilentAndAnUnreadableStampRecovers() {
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.4", current: "1.3.1", installHasPriorUse: true),
            .nothing
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "1.3.9", current: "1.3.1", installHasPriorUse: true),
            .nothing
        )
        XCTAssertEqual(
            ReleaseNotesGate.decide(lastSeen: "beta", current: "1.3.1", installHasPriorUse: true),
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
        store.markSeen("1.3.1")
        XCTAssertEqual(ReleaseNotesStore(defaults: defaults).lastSeenVersion, "1.3.1")
    }
}
