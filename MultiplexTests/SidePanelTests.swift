import XCTest
@testable import Multiplex

@MainActor
final class SidePanelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SidePanelTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testWidthDefaultsAndClamps() {
        XCTAssertEqual(SidePanelWidth.defaultWidth(for: .iPad), 440)
        XCTAssertEqual(SidePanelWidth.defaultWidth(for: .visionOS), 520)
        XCTAssertEqual(SidePanelWidth.defaultVisionOverhang, 440, "the right edge starts 440 pt past the glass")
        XCTAssertEqual(SidePanelWidth.maxVisionOverhang, 800, "360 pt of outward travel from the default")
        XCTAssertEqual(
            SidePanelWidth.visionStripWidth(windowWidth: 1_400),
            2_800,
            "twice the window, so the strip starts at the window's leading edge"
        )
        XCTAssertEqual(SidePanelWidth.visionStripWidth(windowWidth: .nan), 0)

        // Overlay: both bounds, and a pane too small for card + terminal.
        XCTAssertEqual(SidePanelWidth.clamped(200, paneWidth: 1_000), 320)
        XCTAssertEqual(SidePanelWidth.clamped(900, paneWidth: 1_000), 680)
        XCTAssertEqual(SidePanelWidth.clamped(440, paneWidth: 500), 320)
        XCTAssertEqual(SidePanelWidth.clamped(.nan, paneWidth: 1_000), 320)
        // visionOS: continuous inside a sanity range.
        XCTAssertEqual(SidePanelWidth.clampedVision(473), 473, "no snapping — a release lands where it was")
        XCTAssertEqual(SidePanelWidth.clampedVision(-1_000), 360)
        XCTAssertEqual(SidePanelWidth.clampedVision(10_000), 2_400)
        XCTAssertEqual(SidePanelWidth.clampedVision(.nan), 520)
        // As stored: iPad keeps only the floor (the pane clamps at use).
        XCTAssertEqual(SidePanelWidth.clampedStored(100, for: .iPad), 320)
        XCTAssertEqual(SidePanelWidth.clampedStored(900, for: .iPad), 900)
        XCTAssertEqual(SidePanelWidth.clampedStored(5_000, for: .visionOS), 2_400)

        let pane = CGRect(x: 0, y: 100, width: 1_000, height: 700)
        XCTAssertEqual(
            SidePanelWidth.overlayContainerFrame(pane: pane, bottom: 760, width: 440, leadingOverhang: 12),
            CGRect(x: 540, y: 108, width: 452, height: 644),
            "8 pt inside the pane, the seam's overhang past the card's leading edge"
        )
    }

    func testVisionGeometryKeepsTheCardInsideTheStripAndOffTheTerminalReserve() {
        // A 1400-pt window: strip 2800, glass edge at 1400.
        let strip = SidePanelWidth.visionStripWidth(windowWidth: 1_400)
        let standard = SidePanelWidth.clampedVisionGeometry(width: 520, overhang: 440, stripWidth: strip)
        XCTAssertEqual(standard.width, 520)
        XCTAssertEqual(standard.overhang, 440)
        let reach = SidePanelWidth.clampedVisionGeometry(width: 3_000, overhang: 440, stripWidth: strip)
        XCTAssertEqual(reach.width, 1_520, "the left edge stops 320 pt into the window: the terminal reserve")
        XCTAssertEqual(reach.overhang, 440)
        let farOut = SidePanelWidth.clampedVisionGeometry(width: 520, overhang: 1_000, stripWidth: strip)
        XCTAssertEqual(farOut.overhang, 800, "the right edge never hangs past maxVisionOverhang")
        XCTAssertEqual(farOut.width, 520)
        let pulledIn = SidePanelWidth.clampedVisionGeometry(width: 520, overhang: -2_000, stripWidth: strip)
        XCTAssertEqual(pulledIn.overhang, -720, "the right edge stops at reserve + minimum width into the window")
        XCTAssertEqual(pulledIn.width, 360)
        let broken = SidePanelWidth.clampedVisionGeometry(width: .nan, overhang: .nan, stripWidth: strip)
        XCTAssertEqual(broken.width, 520)
        XCTAssertEqual(broken.overhang, 440)

        // A narrower window clamps the same stored geometry live.
        let narrow = SidePanelWidth.visionStripWidth(windowWidth: 600)
        let squeezed = SidePanelWidth.clampedVisionGeometry(width: 1_520, overhang: 440, stripWidth: narrow)
        XCTAssertEqual(squeezed.width, 720)
        XCTAssertEqual(squeezed.overhang, 440)
        let tiny = SidePanelWidth.clampedVisionGeometry(width: 520, overhang: 440, stripWidth: 600)
        XCTAssertEqual(tiny.overhang, 300, "inside the strip")
        XCTAssertEqual(tiny.width, 360, "the minimum width wins over the reserve in a window too narrow for both")
    }

    func testVisionDragGeometryMovesOneEdgeAtATime() {
        // (520, 440) in a 1400-pt window: strip 2800, right edge at 1840.
        let strip = SidePanelWidth.visionStripWidth(windowWidth: 1_400)
        let start = (width: CGFloat(520), overhang: CGFloat(440))
        let leading = SidePanelWidth.visionGeometry(draggingLeadingEdgeBy: -40, from: start, stripWidth: strip)
        XCTAssertEqual(leading.width, 560)
        XCTAssertEqual(leading.overhang, 440, "the right edge stays put")
        let reach = SidePanelWidth.visionGeometry(draggingLeadingEdgeBy: -2_000, from: start, stripWidth: strip)
        XCTAssertEqual(reach.width, 1_520, "the left edge stops 320 pt into the window")
        let narrower = SidePanelWidth.visionGeometry(draggingTrailingEdgeBy: -100, from: start, stripWidth: strip)
        XCTAssertEqual(narrower.width, 420)
        XCTAssertEqual(narrower.overhang, 340, "the left edge stays put")
        let out = SidePanelWidth.visionGeometry(draggingTrailingEdgeBy: 1_000, from: start, stripWidth: strip)
        XCTAssertEqual(out.overhang, 800, "360 pt of outward travel, then the edge stops")
        XCTAssertEqual(out.width, 880)
        let minimum = SidePanelWidth.visionGeometry(draggingTrailingEdgeBy: -400, from: start, stripWidth: strip)
        XCTAssertEqual(minimum.width, 360)
        XCTAssertEqual(minimum.overhang, 280, "inward past the minimum width the edge stops too")
    }

    func testPolicyMatrix() {
        struct Case {
            let style: SidePanelPresentationStyle
            let width: CGFloat
            let compact: Bool
            let terminal: Bool
            let override: String?
            let expected: Bool
        }
        let cases = [
            Case(style: .iPadOverlay, width: 659.999, compact: false,
                 terminal: true, override: nil, expected: false),
            Case(style: .iPadOverlay, width: 660, compact: false,
                 terminal: true, override: nil, expected: true),
            Case(style: .iPadOverlay, width: 1_024, compact: true,
                 terminal: true, override: nil, expected: false),
            Case(style: .iPadOverlay, width: 1_024, compact: false,
                 terminal: false, override: nil, expected: false),
            Case(style: .visionOrnament, width: 0, compact: true,
                 terminal: true, override: nil, expected: true),
            Case(style: .visionOrnament, width: 2_000, compact: false,
                 terminal: false, override: nil, expected: false),
            Case(style: .iPadOverlay, width: 1_024, compact: false,
                 terminal: true, override: "0", expected: false),
            Case(style: .visionOrnament, width: 2_000, compact: false,
                 terminal: true, override: "0", expected: false),
            Case(style: .iPadOverlay, width: 1_024, compact: false,
                 terminal: true, override: "1", expected: true),
            Case(style: .iPadOverlay, width: 600, compact: false,
                 terminal: true, override: "unknown", expected: false),
        ]

        for testCase in cases {
            let override = testCase.override ?? "nil"
            XCTAssertEqual(
                SidePanelPolicy.admitsPanel(
                    style: testCase.style,
                    paneWidth: testCase.width,
                    isCompactWidth: testCase.compact,
                    anchorIsTerminal: testCase.terminal,
                    environmentOverride: testCase.override
                ),
                testCase.expected,
                "\(testCase.style), width=\(testCase.width), compact=\(testCase.compact), "
                    + "terminal=\(testCase.terminal), override=\(override)"
            )
        }
    }

    func testWidthStorePersistsPerPlatformAndGlassRelative() {
        let store = SidePanelWidthStore(defaults: defaults)
        XCTAssertEqual(store.width(for: .iPad), 440)
        XCTAssertEqual(store.width(for: .visionOS), 520)
        XCTAssertEqual(store.visionOverhang, 440, "the right edge starts 440 pt past the glass")

        store.setWidth(560, for: .iPad)
        store.setVisionGeometry(width: 500, overhang: 1_000)
        XCTAssertEqual(store.visionOverhang, 800, "never farther out than the right handle can go")
        store.setWidth(900, for: .visionOS)
        XCTAssertEqual(store.width(for: .visionOS), 900, "a width-only write keeps the right edge")

        let restored = SidePanelWidthStore(defaults: defaults)
        XCTAssertEqual(restored.width(for: .iPad), 560)
        XCTAssertEqual(restored.width(for: .visionOS), 900)
        XCTAssertEqual(restored.visionOverhang, 800)

        // Junk on disk normalizes on read.
        defaults.set(100, forKey: "MultiplexSidePanelWidth.iPad")
        defaults.set(5_000, forKey: "MultiplexSidePanelWidth.visionOS")
        defaults.set(5_000, forKey: "MultiplexSidePanelOverhang.visionOS")
        let normalized = SidePanelWidthStore(defaults: defaults)
        XCTAssertEqual(normalized.width(for: .iPad), 320)
        XCTAssertEqual(normalized.width(for: .visionOS), 2_400)
        XCTAssertEqual(normalized.visionOverhang, 800)
    }
}
