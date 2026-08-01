import SwiftTerm
import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class TerminalTallyKeyControlTests: XCTestCase {
    func testNativeKeyRoutesActivationAndExposesLatchedAccessibility() {
        var activations = 0
        let key = TerminalTallyKeyControl(
            face: .text(
                "CTRL",
                font: UIKitChassis.monoFont(11, weight: .semibold),
                kerning: 1.1
            ),
            width: 46,
            height: 34,
            accessibilityLabel: "Control",
            accessibilityIdentifier: "test.control",
            action: { activations += 1 }
        )

        XCTAssertEqual(key.intrinsicContentSize, CGSize(width: 46, height: 34))
        XCTAssertEqual(key.accessibilityLabel, "Control")
        XCTAssertEqual(key.accessibilityIdentifier, "test.control")
        XCTAssertTrue(key.accessibilityTraits.contains(.button))
        XCTAssertFalse(key.accessibilityTraits.contains(.selected))

        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(key.accessibilityActivate())
        XCTAssertEqual(activations, 2)

        key.isLatched = true
        XCTAssertTrue(key.accessibilityTraits.contains(.selected))
    }

    func testNativeControlComboKeepsOrderLabelsAndTypedLetters() {
        var letters: [String] = []
        let combo = TerminalCtrlComboView(
            faceHeight: 34,
            padding: 8,
            fontSize: 15,
            send: { letters.append($0) }
        )

        XCTAssertEqual(combo.intrinsicContentSize, CGSize(width: 114, height: 50))
        XCTAssertEqual(combo.accessibilityIdentifier, "terminal.ctrlCombos")
        XCTAssertEqual(combo.keys.map(\.accessibilityLabel), ["Control C", "Control B"])
        XCTAssertEqual(
            combo.keys.map(\.accessibilityIdentifier),
            ["terminal.ctrlCombos.c", "terminal.ctrlCombos.b"]
        )

        combo.keys[0].sendActions(for: .touchUpInside)
        combo.keys[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(letters, ["c", "b"])
    }
}

#if !os(visionOS)
@MainActor
final class TerminalKeyBarUIKitTests: XCTestCase {
    func testWidthLadderPreservesEveryDocumentedFloor() {
        XCTAssertEqual(specification(width: 1024, returns: true).tier, .full)
        XCTAssertEqual(
            specification(width: 768, returns: true).tier,
            .twoSymbolsAndPages
        )
        XCTAssertEqual(
            specification(width: 420, returns: true).tier,
            .returnAndTmuxFloor
        )
        XCTAssertEqual(
            specification(width: 375, returns: true).tier,
            .essentialsFloor
        )
        XCTAssertEqual(specification(width: 390, returns: false).tier, .tightTmux)

        XCTAssertEqual(
            specification(
                width: 420,
                returns: true,
                safeArea: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            ).tier,
            .essentialsFloor
        )
    }

    func testNativeRailBuildsTallyControlsWithoutAHostedView() throws {
        let terminal = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 420, height: 200)
        )
        let bar = TerminalKeyBar(
            terminal: terminal,
            controller: nil,
            performTmuxShortcut: { _ in },
            finishTmuxCopyMode: {},
            showsTmuxShortcuts: true
        )
        bar.frame = CGRect(x: 0, y: 0, width: 420, height: TerminalKeyBar.barHeight)
        bar.layoutIfNeeded()

        XCTAssertEqual(bar.intrinsicContentSize.height, 48)
        XCTAssertFalse(bar.renderedKeys.isEmpty)
        XCTAssertEqual(
            bar.renderedKeys.prefix(3).map(\.accessibilityIdentifier),
            [
                "terminal.keybar.escape",
                "terminal.keybar.control",
                "terminal.keybar.tab",
            ]
        )
        XCTAssertEqual(
            bar.renderedKeys.first {
                $0.accessibilityIdentifier == "terminal.keybar.control"
            }?.accessibilityLabel,
            "Control"
        )
        XCTAssertTrue(bar.subviews.contains { $0 is TerminalTallyKeyControl })
        XCTAssertFalse(descendants(in: bar).contains {
            String(describing: type(of: $0)).contains("Hosting")
        })
    }

    private func specification(
        width: CGFloat,
        returns: Bool,
        safeArea: UIEdgeInsets = .zero
    ) -> TerminalKeyBarLayout.Specification {
        TerminalKeyBarLayout.specification(
            width: width,
            contentSafeArea: safeArea,
            showsTmux: true,
            includesReturn: returns
        )
    }

    private func descendants(in root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap(descendants(in:))
    }
}
#else
@MainActor
final class TerminalKeyClusterUIKitTests: XCTestCase {
    func testNativeSlabsPreserveRegularAndCompactGeometry() {
        let context = TerminalKeyClusterContext()
        let leading = TerminalKeyClusterGroupView(
            role: .leading,
            metric: .regular,
            context: context
        )
        let trailing = TerminalKeyClusterGroupView(
            role: .trailing,
            metric: .regular,
            context: context
        )
        let standalone = TerminalKeyClusterGroupView(
            role: .standalone,
            metric: .regular,
            context: context
        )

        XCTAssertEqual(leading.intrinsicContentSize, CGSize(width: 174, height: 44))
        XCTAssertEqual(trailing.intrinsicContentSize, CGSize(width: 342, height: 44))
        XCTAssertEqual(
            standalone.fittingSize(maximumWidth: 600),
            CGSize(width: 504, height: 44)
        )
        XCTAssertEqual(
            standalone.fittingSize(maximumWidth: 420),
            CGSize(width: 392, height: 44)
        )
        XCTAssertEqual(
            standalone.fittingSize(maximumWidth: 375),
            CGSize(width: 228, height: 44)
        )
    }

    func testNativeSlabsKeepKeyOrderRepeatSemanticsAndAccessibility() {
        let context = TerminalKeyClusterContext()
        let leading = TerminalKeyClusterGroupView(
            role: .leading,
            metric: .regular,
            context: context
        )
        let trailing = TerminalKeyClusterGroupView(
            role: .trailing,
            metric: .regular,
            context: context
        )

        XCTAssertEqual(
            leading.keys.map(\.accessibilityIdentifier),
            [
                "terminal.keyCluster.escape",
                "terminal.keyCluster.control",
                "terminal.keyCluster.tab",
            ]
        )
        XCTAssertEqual(
            trailing.keys.map(\.accessibilityIdentifier),
            [
                "terminal.keyCluster.left",
                "terminal.keyCluster.up",
                "terminal.keyCluster.down",
                "terminal.keyCluster.right",
                "terminal.keyCluster.return",
                "terminal.keyCluster.keyboard",
            ]
        )
        XCTAssertTrue(trailing.keys.prefix(4).allSatisfy(\.repeats))
        XCTAssertFalse(trailing.keys.suffix(2).contains(where: \.repeats))
        XCTAssertEqual(leading.layer.cornerRadius, 12)
        XCTAssertEqual(leading.layer.borderWidth, 1)
        XCTAssertFalse((leading.subviews + trailing.subviews).contains {
            String(describing: type(of: $0)).contains("Hosting")
        })
    }
}
#endif
