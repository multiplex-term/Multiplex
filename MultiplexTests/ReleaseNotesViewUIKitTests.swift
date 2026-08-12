import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class ReleaseNotesViewUIKitTests: XCTestCase {
    // MARK: The launch card

    func testTheCardShowsThisPlatformsFourChangesAndBothChips() throws {
        let controller = WhatsNewViewController(platform: .pad)
        render(controller, width: 620, height: 700)

        let rendered = renderedText(in: controller.view).joined(separator: "\n")
        for highlight in ReleaseNotes.highlights(for: .pad) {
            XCTAssertTrue(
                rendered.contains(highlight.title.uppercased()),
                "the card dropped \(highlight.id)"
            )
            XCTAssertTrue(rendered.contains(highlight.body))
        }
        XCTAssertTrue(rendered.contains(ReleaseNotes.promise))
        XCTAssertTrue(rendered.contains(ReleaseNotes.version))
        XCTAssertTrue(rendered.contains("iPad"), "the platform-scoped row keeps its tag")

        let alsoLine = try XCTUnwrap(ReleaseNotes.alsoLine(for: .pad))
        XCTAssertTrue(rendered.contains(alsoLine))

        XCTAssertNotNil(chip(named: "whatsNew.fullNotes", in: controller.view))
        XCTAssertNotNil(chip(named: "whatsNew.done", in: controller.view))
    }

    /// Vision Pro is told about the floating bars and never about the key
    /// rail's window edge, which it does not have.
    func testTheVisionCardSwapsInTheFloatingBarsAndLeavesOutTheKeyRail() {
        let controller = WhatsNewViewController(platform: .vision)
        render(controller, width: 620, height: 700)

        let rendered = renderedText(in: controller.view).joined(separator: "\n")
        XCTAssertTrue(rendered.contains("BARS FLOAT BELOW THE WINDOW"))
        XCTAssertFalse(rendered.contains("THE KEY RAIL MEETS THE WINDOW'S EDGE"))
    }

    func testBothChipsReportThroughTheirOwnCallback() throws {
        let controller = WhatsNewViewController(platform: .phone)
        render(controller, width: 375, height: 700)

        var done = 0
        var fullNotes = 0
        controller.onDone = { done += 1 }
        controller.onFullNotes = { fullNotes += 1 }

        _ = try XCTUnwrap(chip(named: "whatsNew.done", in: controller.view))
            .accessibilityActivate()
        _ = try XCTUnwrap(chip(named: "whatsNew.fullNotes", in: controller.view))
            .accessibilityActivate()

        XCTAssertEqual(done, 1)
        XCTAssertEqual(fullNotes, 1)
    }

    /// The card's one promise is that it ends: four rows and the chips inside
    /// one phone screen, so the sheet's content-sized detent never has to
    /// clamp. A fifth row, or a body that grows into a paragraph, breaks the
    /// shape this direction was chosen for — the measurement is the editorial
    /// guard on that. (Accessibility text sizes still scroll, by design.)
    func testTheCardStaysOnePhoneScreen() throws {
        let controller = WhatsNewViewController(platform: .phone)
        render(controller, width: 375, height: 900)

        let scrollView = try XCTUnwrap(
            descendants(of: UIScrollView.self, in: controller.view).first
        )
        XCTAssertLessThanOrEqual(
            scrollView.contentSize.height,
            // Every phone from the 5.4-inch mini up clears this with room.
            // A 4.7-inch SE's sheet tops out right about here, so the card
            // lands on its limit there and the detent clamps the last few
            // points — the graceful end of the ladder, not a broken screen.
            640,
            "the launch card no longer fits a phone screen in one read"
        )
    }

    // MARK: The full record

    /// Both releases' records, each under its own header — a reader updating
    /// from 1.2 straight to 1.3.1 is owed 1.3's story too.
    func testTheLogCarriesEveryReleasesChangesForItsPlatform() {
        let controller = ReleaseLogViewController(platform: .pad)
        render(controller, width: 720, height: 4_800)

        let rendered = renderedText(in: controller.view).joined(separator: "\n")
        for release in ReleaseNotes.releases {
            // The header is a chassis label, which uppercases its text.
            XCTAssertTrue(rendered.contains("MULTIPLEX \(release.version)"))
            XCTAssertTrue(rendered.contains(release.promise))
            for entry in release.entries(for: .pad) {
                XCTAssertTrue(
                    rendered.contains(entry.title.uppercased()),
                    "the log dropped \(release.version)'s \(entry.id)"
                )
                XCTAssertTrue(rendered.contains(entry.body), "\(entry.id) lost its body")
            }
            for bank in release.banks(for: .pad) {
                XCTAssertTrue(rendered.contains(bank.bank.title))
            }
        }
        XCTAssertFalse(
            rendered.contains(ReleaseNoteBank.appearance.title),
            "an empty bank must not head a section"
        )
        XCTAssertFalse(rendered.contains("GLASS"))
    }

    func testTheLogIsTheCardsSuperset() {
        let log = ReleaseLogViewController(platform: .vision)
        render(log, width: 720, height: 4_800)
        let rendered = renderedText(in: log.view).joined(separator: "\n")

        for highlight in ReleaseNotes.highlights(for: .vision) {
            for id in highlight.covers {
                guard let entry = ReleaseNotes.allEntries.first(where: { $0.id == id })
                else { continue }
                XCTAssertTrue(
                    rendered.contains(entry.title.uppercased()),
                    "the log must still carry \(id), which the card summarised"
                )
            }
        }
    }

    // MARK: Helpers

    private func render(_ controller: UIViewController, width: CGFloat, height: CGFloat) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutIfNeeded()
    }

    private func chip(named identifier: String, in root: UIView) -> UIKitChassisChip? {
        descendants(of: UIKitChassisChip.self, in: root)
            .first { $0.accessibilityIdentifier == identifier }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for subview in root.subviews {
            found.append(contentsOf: descendants(of: type, in: subview))
        }
        return found
    }

    private func renderedText(in root: UIView) -> [String] {
        var result: [String] = []
        if let label = root as? UILabel {
            if let text = label.attributedText?.string {
                result.append(text)
            } else if let text = label.text {
                result.append(text)
            }
        }
        for subview in root.subviews {
            result.append(contentsOf: renderedText(in: subview))
        }
        return result
    }
}
