import UIKit
import XCTest
@testable import Multiplex

/// The side panel's resize mechanics: a drag freezes the card into a picture
/// and moves only frames; the release thaws it and reports the geometry.
@MainActor
final class SidePanelViewControllerTests: XCTestCase {
    private final class FakeAuxiliaryController: AuxiliaryPaneController {
        var tabLabel = "⌗ test"
        var routeMode: TerminalRoute.Mode { .viewport(urlString: "https://example.com") }
        func shutdown() {}
    }

    private var window: UIWindow!

    override func setUp() {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_200, height: 700))
        window.isHidden = false
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
    }

    /// The visionOS strip for a 1400-pt window: 2800 wide, glass edge at 1400.
    private let visionWindowWidth: CGFloat = 1_400

    private func makePanel(
        style: SidePanelPresentationStyle,
        width: CGFloat,
        overhang: CGFloat = SidePanelWidth.defaultVisionOverhang,
        stripWindowWidth: CGFloat = 1_400,
        resize: @escaping (CGFloat, CGFloat, SidePanelResizePhase) -> Void = { _, _, _ in }
    ) -> SidePanelViewController {
        let panel = SidePanelViewController(
            controller: FakeAuxiliaryController(),
            paneController: UIViewController(),
            presentationStyle: style,
            width: width,
            overhang: overhang,
            split: {},
            close: {},
            resize: resize
        )
        window.rootViewController = panel
        panel.view.frame = style == .visionOrnament
            ? CGRect(
                x: 0,
                y: 0,
                width: SidePanelWidth.visionStripWidth(windowWidth: stripWindowWidth),
                height: 700
            )
            : CGRect(x: 0, y: 0, width: width + SidePanelViewController.seamOverhang, height: 700)
        panel.view.layoutIfNeeded()
        return panel
    }

    func testVisionDragsFreezeTheCardMoveOneEdgeAndThawOnRelease() {
        var ended: (width: CGFloat, overhang: CGFloat)?
        let panel = makePanel(style: .visionOrnament, width: 520) { width, overhang, phase in
            if phase == .ended { ended = (width, overhang) }
        }
        let rightEdge = visionWindowWidth + SidePanelWidth.defaultVisionOverhang
        XCTAssertEqual(panel.cardFrameForTesting.maxX, rightEdge, "440 pt past the glass")
        XCTAssertFalse(panel.isFrozenForTesting)

        // Left handle: the right edge stays.
        panel.simulateLeadingDragForTesting(translation: 0, phase: .began)
        panel.simulateLeadingDragForTesting(translation: -40, phase: .changed)
        // Events only mark layout dirty; the frame lands on the next pass.
        panel.view.layoutIfNeeded()
        XCTAssertTrue(panel.isFrozenForTesting, "movement pictures the card instead of reflowing it")
        XCTAssertEqual(panel.cardFrameForTesting.maxX, rightEdge)
        XCTAssertEqual(panel.cardFrameForTesting.minX, rightEdge - 560)
        panel.simulateLeadingDragForTesting(translation: -40, phase: .ended)
        XCTAssertFalse(panel.isFrozenForTesting, "release brings the live views back")
        XCTAssertEqual(ended?.width, 560)
        XCTAssertEqual(ended?.overhang, 440)

        // Right handle: the left edge stays.
        let leftEdge = rightEdge - 560
        panel.simulateTrailingDragForTesting(translation: 0, phase: .began)
        panel.simulateTrailingDragForTesting(translation: 200, phase: .changed)
        panel.view.layoutIfNeeded()
        XCTAssertTrue(panel.isFrozenForTesting)
        XCTAssertEqual(panel.cardFrameForTesting.minX, leftEdge)
        XCTAssertEqual(panel.cardFrameForTesting.maxX, rightEdge + 200)
        panel.simulateTrailingDragForTesting(translation: 200, phase: .ended)
        XCTAssertFalse(panel.isFrozenForTesting)
        XCTAssertEqual(ended?.width, 760)
        XCTAssertEqual(ended?.overhang, 640)

        // Stored for a wide window, shown in a 600-pt one (strip 1200): the
        // card clamps live, keeps the stored values, and a drag starts from
        // what it shows — never from the stored reach.
        var began: (width: CGFloat, overhang: CGFloat)?
        let squeezed = makePanel(
            style: .visionOrnament,
            width: 1_520,
            overhang: 440,
            stripWindowWidth: 600
        ) { width, overhang, phase in
            if phase == .began { began = (width, overhang) }
        }
        XCTAssertEqual(squeezed.cardFrameForTesting.minX, SidePanelWidth.minimumTerminalWidth)
        XCTAssertEqual(squeezed.cardFrameForTesting.width, 720)
        XCTAssertEqual(squeezed.panelWidth, 1_520, "kept for a window that grows back")
        squeezed.simulateTrailingDragForTesting(translation: 0, phase: .began)
        XCTAssertEqual(began?.width, 720)
        XCTAssertEqual(began?.overhang, 440)
        squeezed.simulateTrailingDragForTesting(translation: 10, phase: .ended)
        XCTAssertEqual(squeezed.panelWidth, 730)
        XCTAssertEqual(squeezed.overhang, 450)
    }

    func testIPadWindowDrivenTicksFreezeUntilRelease() {
        var reported: [(CGFloat, SidePanelResizePhase)] = []
        let panel = makePanel(style: .iPadOverlay, width: 440) { width, _, phase in
            reported.append((width, phase))
        }
        panel.simulateLeadingDragForTesting(translation: 0, phase: .began)
        panel.simulateLeadingDragForTesting(translation: -30, phase: .changed)
        // The window clamps and answers with the card width, as it does live.
        panel.updateWidth(470)
        XCTAssertTrue(panel.isFrozenForTesting)
        XCTAssertEqual(reported.last?.0, 470)
        XCTAssertEqual(reported.last?.1, .changed)

        panel.simulateLeadingDragForTesting(translation: -30, phase: .ended)
        XCTAssertFalse(panel.isFrozenForTesting)
        XCTAssertEqual(reported.last?.1, .ended)
    }
}
