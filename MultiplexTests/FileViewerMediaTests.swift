import PDFKit
import UIKit
import XCTest
@testable import Multiplex

/// The ▤ viewer's PDF and sound screens: the clip's transport contract, the
/// remote that drives it, and PDFKit's screen with its readouts. Fixtures are
/// built in memory — a PCM WAV header over silence, a `UIGraphicsPDFRenderer`
/// document — so nothing here reaches disk or a host.
@MainActor
final class FileViewerMediaTests: XCTestCase {
    // MARK: Audio clip

    func testAudioClipReadsTheLengthAndKeepsSeeksInsideIt() throws {
        let clip = try Self.clip(seconds: 2)
        XCTAssertEqual(clip.duration, 2, accuracy: 0.05)
        XCTAssertFalse(clip.isPlaying)
        XCTAssertEqual(clip.currentTime, 0, accuracy: 0.01)

        clip.seek(to: 1)
        XCTAssertEqual(clip.currentTime, 1, accuracy: 0.05)
        // Past the end holds a hair short of it, so PLAY after a full scrub
        // still plays; before the start clamps to zero.
        clip.seek(to: 99)
        XCTAssertLessThan(clip.currentTime, clip.duration)
        XCTAssertGreaterThan(clip.currentTime, clip.duration - 0.2)
        clip.seek(to: -5)
        XCTAssertEqual(clip.currentTime, 0, accuracy: 0.01)
        clip.skip(by: FileViewerAudioClip.skipInterval)
        XCTAssertLessThan(clip.currentTime, clip.duration)
    }

    func testAudioClipRefusesBytesCoreAudioCannotRead() {
        XCTAssertThrowsError(try FileViewerAudioClip(
            data: Data("not a sound file".utf8), fileName: "x.mp3", volumeStore: .shared
        ))
        XCTAssertThrowsError(try FileViewerAudioClip(
            data: Data(), fileName: "empty.wav", volumeStore: .shared
        ))
    }

    /// The name is only a hint: sound bytes under a stray or missing
    /// extension are still sniffed and read.
    func testAudioClipReadsSoundBytesWhateverTheNameSays() {
        let wav = Self.wavData(seconds: 1)
        for name in ["mystery.bin", "noext", "renamed.mp3"] {
            XCTAssertNoThrow(try FileViewerAudioClip(data: wav, fileName: name, volumeStore: .shared))
        }
    }

    func testClockLabelFloorsAndGrowsAnHourField() {
        XCTAssertEqual(FileViewerAudioClock.label(0), "0:00")
        XCTAssertEqual(FileViewerAudioClock.label(0.9), "0:00")
        XCTAssertEqual(FileViewerAudioClock.label(59.9), "0:59")
        XCTAssertEqual(FileViewerAudioClock.label(61), "1:01")
        XCTAssertEqual(FileViewerAudioClock.label(3725), "1:02:05")
        XCTAssertEqual(FileViewerAudioClock.label(.nan), "0:00")
        XCTAssertEqual(FileViewerAudioClock.label(.infinity), "0:00")
    }

    // MARK: Audio screen

    func testAudioScreenIsARemoteForTheClip() throws {
        let clip = try Self.clip(seconds: 2)
        let screen = FileViewerAudioContentView(volumeStore: .shared)
        screen.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        screen.apply(clip: clip, name: "tone.wav")
        screen.layoutIfNeeded()

        XCTAssertEqual(screen.playChip.accessibilityLabel, "Play")
        XCTAssertEqual(screen.backChip.accessibilityLabel, "Back 15 seconds")
        XCTAssertEqual(screen.forwardChip.accessibilityLabel, "Forward 15 seconds")
        XCTAssertEqual(screen.elapsedLabel.text, "0:00")
        XCTAssertEqual(screen.remainingLabel.text, "0:02")
        XCTAssertEqual(screen.lampCaption, "ready")

        clip.seek(to: 1)
        screen.refresh()
        XCTAssertEqual(screen.elapsedLabel.text, "0:01")
        XCTAssertEqual(screen.slider.value, 0.5, accuracy: 0.03)
        XCTAssertEqual(screen.slider.accessibilityValue, "0:01 of 0:02")
        XCTAssertEqual(screen.lampCaption, "paused")

        // The scrubber drives the clip; the skip chips ride the same seek.
        screen.slider.value = 0.25
        screen.slider.sendActions(for: .valueChanged)
        XCTAssertEqual(clip.currentTime, 0.5, accuracy: 0.05)
        XCTAssertTrue(screen.backChip.accessibilityActivate())
        XCTAssertEqual(clip.currentTime, 0, accuracy: 0.01)
        XCTAssertEqual(screen.lampCaption, "ready")
        XCTAssertTrue(screen.forwardChip.accessibilityActivate())
        XCTAssertLessThan(clip.currentTime, clip.duration)
        XCTAssertGreaterThan(clip.currentTime, 0)
    }

    /// The panel names the file: a moved tab rebuilds the pane, and the new
    /// remote binds to the same clip at the same position.
    func testAudioScreenRebindsWithoutLosingThePosition() throws {
        let clip = try Self.clip(seconds: 3)
        clip.seek(to: 2)
        let screen = FileViewerAudioContentView(volumeStore: .shared)
        screen.apply(clip: clip, name: "tone.wav")
        XCTAssertEqual(screen.elapsedLabel.text, "0:02")
        XCTAssertEqual(screen.remainingLabel.text, "0:03")

        // A quiet watch reload hands the position to the replacement clip.
        let replacement = try Self.clip(seconds: 3)
        replacement.adoptPosition(from: clip)
        XCTAssertEqual(replacement.currentTime, 2, accuracy: 0.05)
        XCTAssertEqual(clip.currentTime, 0, accuracy: 0.01, "the replaced clip is rewound")
        screen.apply(clip: replacement, name: "tone.wav")
        XCTAssertEqual(screen.elapsedLabel.text, "0:02")
        XCTAssertTrue(screen.clip === replacement)
    }

    // MARK: Volume

    func testAudioVolumeClampsAndReadsOut() {
        XCTAssertEqual(FileViewerAudioVolume.clamped(1.5), 1)
        XCTAssertEqual(FileViewerAudioVolume.clamped(-0.2), 0)
        XCTAssertEqual(FileViewerAudioVolume.clamped(.nan), 1)
        XCTAssertEqual(FileViewerAudioVolume.clamped(0.35), 0.35)
        XCTAssertEqual(FileViewerAudioVolume.percentLabel(0.354), "35%")
        XCTAssertEqual(FileViewerAudioVolume.percentLabel(1), "100%")
        XCTAssertEqual(FileViewerAudioVolume.percentLabel(0), "0%")
    }

    func testVolumeStorePersistsTheLevelDeviceLocally() throws {
        let suite = "FileViewerMediaTests.volume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = FileViewerAudioVolumeStore(defaults: defaults)
        XCTAssertEqual(store.volume, 1, "a fresh install listens at full level")
        store.set(0.4)
        XCTAssertEqual(store.volume, 0.4)
        store.set(2)
        XCTAssertEqual(store.volume, 1, "the store clamps like the model")
        store.set(0.25)
        XCTAssertEqual(FileViewerAudioVolumeStore(defaults: defaults).volume, 0.25)
    }

    /// The slider writes the app-wide level; every clip follows the store on
    /// its own, and a second panel (another tab, another window) mirrors it —
    /// neither needs the panel that moved it.
    func testVolumeSliderDrivesTheStoreAndEveryClipAndPanelFollow() async throws {
        let suite = "FileViewerMediaTests.volume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FileViewerAudioVolumeStore(defaults: defaults)

        let clip = try Self.clip(seconds: 1, volumeStore: store)
        let screen = FileViewerAudioContentView(volumeStore: store)
        screen.apply(clip: clip, name: "a.wav")
        XCTAssertEqual(screen.volumeLabel.text, "100%")
        XCTAssertEqual(screen.volumeSlider.accessibilityLabel, "Volume")

        screen.volumeSlider.value = 0.4
        screen.volumeSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(store.volume, 0.4, accuracy: 0.001)
        XCTAssertEqual(screen.volumeLabel.text, "40%")
        XCTAssertEqual(screen.volumeSlider.accessibilityValue, "40%")
        await Self.settle { clip.volume == 0.4 }
        XCTAssertEqual(clip.volume, 0.4, accuracy: 0.001)

        // A clip made after the change is born at the listener's level, and
        // its panel opens on it.
        let later = try Self.clip(seconds: 1, volumeStore: store)
        XCTAssertEqual(later.volume, 0.4, accuracy: 0.001)
        let other = FileViewerAudioContentView(volumeStore: store)
        other.apply(clip: later, name: "b.wav")
        XCTAssertEqual(other.volumeSlider.value, 0.4, accuracy: 0.001)

        // Moving the level in one panel reaches the other clip and panel
        // through the store — no refresh of theirs involved.
        screen.volumeSlider.value = 0.7
        screen.volumeSlider.sendActions(for: .valueChanged)
        await Self.settle { later.volume == 0.7 && other.volumeLabel.text == "70%" }
        XCTAssertEqual(later.volume, 0.7, accuracy: 0.001)
        XCTAssertEqual(other.volumeSlider.value, 0.7, accuracy: 0.001)
        XCTAssertEqual(other.volumeLabel.text, "70%")

        // A drag's frames coalesce to whole percents before the store writes.
        screen.volumeSlider.value = 0.70004
        screen.volumeSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(store.volume, 0.7, accuracy: 0.0001)
    }

    // MARK: PDF screen

    func testPDFScreenReportsPagesAndKeepsThePageAcrossAReload() throws {
        let document = try XCTUnwrap(PDFDocument(data: Self.pdfData(pages: 3)))
        let screen = FileViewerPDFContentView()
        screen.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        screen.apply(document: document)
        screen.layoutIfNeeded()

        XCTAssertEqual(screen.pdfView.document?.pageCount, 3)
        XCTAssertFalse(screen.pageBadge.isHidden)
        XCTAssertEqual(screen.pageBadge.accessibilityLabel, "PAGE 1 / 3")
        XCTAssertTrue(screen.zoomChip.isHidden, "at fit there is nothing to reset")
        XCTAssertEqual(screen.pdfView.displayMode, .singlePageContinuous)
        XCTAssertTrue(screen.pdfView.autoScales)

        // Zooming in (which switches PDFKit's autoScales off, as a pinch
        // does) surfaces the reset chip with the multiple of fit; the chip
        // re-arms the fit, so the next resize fits again instead of holding
        // the old scale.
        screen.pdfView.scaleFactor = screen.pdfView.scaleFactorForSizeToFit * 2
        screen.setNeedsLayout()
        screen.layoutIfNeeded()
        XCTAssertFalse(screen.pdfView.autoScales)
        XCTAssertFalse(screen.zoomChip.isHidden)
        XCTAssertEqual(screen.zoomChip.accessibilityLabel, "Zoom 200 percent; resets to fit")
        XCTAssertTrue(screen.zoomChip.accessibilityActivate())
        XCTAssertTrue(screen.pdfView.autoScales)
        XCTAssertEqual(
            screen.pdfView.scaleFactor, screen.pdfView.scaleFactorForSizeToFit, accuracy: 0.001
        )
        XCTAssertTrue(screen.zoomChip.isHidden)
        screen.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        screen.layoutIfNeeded()
        XCTAssertEqual(
            screen.pdfView.scaleFactor, screen.pdfView.scaleFactorForSizeToFit, accuracy: 0.001,
            "an armed fit follows the width"
        )
        XCTAssertTrue(screen.zoomChip.isHidden)

        // A reader on page 3 sees the rebuilt document open on page 3.
        screen.pdfView.go(to: try XCTUnwrap(document.page(at: 2)))
        screen.setNeedsLayout()
        screen.layoutIfNeeded()
        XCTAssertEqual(screen.pdfView.currentPage.map { document.index(for: $0) }, 2)
        let rebuilt = try XCTUnwrap(PDFDocument(data: Self.pdfData(pages: 4)))
        screen.apply(document: rebuilt)
        screen.layoutIfNeeded()
        XCTAssertTrue(screen.pdfView.document === rebuilt)
        XCTAssertEqual(screen.pdfView.currentPage.map { rebuilt.index(for: $0) }, 2)
        XCTAssertEqual(screen.pageBadge.accessibilityLabel, "PAGE 3 / 4")
    }

    func testSinglePagePDFShowsNoPageReadoutAndLinksGoToTheApp() throws {
        let document = try XCTUnwrap(PDFDocument(data: Self.pdfData(pages: 1)))
        let screen = FileViewerPDFContentView()
        var pressed: [String] = []
        screen.openLink = { pressed.append($0) }
        screen.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        screen.apply(document: document)
        screen.layoutIfNeeded()

        XCTAssertTrue(screen.pageBadge.isHidden)
        // PDFKit hands a pressed URL to the app instead of opening it; the
        // pane routes it through the same link sheet a markdown link meets.
        screen.linkPressed(try XCTUnwrap(URL(string: "https://example.com/spec")))
        XCTAssertEqual(pressed, ["https://example.com/spec"])
    }

    /// PDFKit locks the document behind the user password; the pane's LOCKED
    /// panel unlocks the same object in place, which is what lets the
    /// controller re-publish the document rather than re-read the file.
    func testPasswordProtectedPDFUnlocksInPlace() throws {
        let plain = try XCTUnwrap(PDFDocument(data: Self.pdfData(pages: 2)))
        let sealed = try XCTUnwrap(plain.dataRepresentation(options: [
            PDFDocumentWriteOption.userPasswordOption: "s3cret",
            PDFDocumentWriteOption.ownerPasswordOption: "s3cret",
        ]))
        let locked = try XCTUnwrap(PDFDocument(data: sealed))
        XCTAssertTrue(locked.isLocked)
        XCTAssertFalse(locked.unlock(withPassword: "wrong"))
        XCTAssertTrue(locked.isLocked)
        XCTAssertTrue(locked.unlock(withPassword: "s3cret"))
        XCTAssertFalse(locked.isLocked)
        XCTAssertEqual(locked.pageCount, 2)
    }

    // MARK: Fixtures

    static func clip(
        seconds: Double, volumeStore: FileViewerAudioVolumeStore = .shared
    ) throws -> FileViewerAudioClip {
        try FileViewerAudioClip(
            data: wavData(seconds: seconds), fileName: "tone.wav", volumeStore: volumeStore
        )
    }

    /// Store changes reach clips and panels one main-actor hop later
    /// (Observation's hook fires before the write lands); yield until the
    /// hop has landed, bounded so a regression fails instead of hanging.
    static func settle(until done: @escaping @MainActor () -> Bool) async {
        var attempts = 0
        while attempts < 50, !done() {
            attempts += 1
            await Task.yield()
        }
    }

    /// 16-bit mono PCM silence under a canonical RIFF/WAVE header — the
    /// smallest thing Core Audio reads with an exact duration.
    static func wavData(seconds: Double, sampleRate: Int = 8000) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let payload = frames * 2
        var data = Data()
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payload))
        data.append(Data(count: payload))
        return data
    }

    static func pdfData(pages: Int) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        return renderer.pdfData { context in
            for index in 0..<pages {
                context.beginPage()
                ("Page \(index + 1)" as NSString).draw(
                    at: CGPoint(x: 20, y: 20),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 14)]
                )
            }
        }
    }
}

private extension FileViewerAudioContentView {
    /// The lamp's caption, as VoiceOver reads it.
    var lampCaption: String? {
        descendants.compactMap { $0 as? UIKitTallyLamp }.first?.accessibilityLabel
    }
}

private extension UIView {
    var descendants: [UIView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
