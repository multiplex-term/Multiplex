import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class TerminalTabStripUIKitTests: XCTestCase {
    func testNativeStripPreservesGeometryLabelsAndActivation() {
        let activeID = UUID()
        let inactiveID = UUID()
        var activated: [UUID] = []
        let view = TerminalTabStripView()
        view.apply(
            items: [
                .init(
                    id: activeID,
                    title: "agent",
                    hostName: "devbox",
                    controller: nil,
                    isActive: true
                ),
                .init(
                    id: inactiveID,
                    title: "deploy",
                    hostName: "prod",
                    controller: nil,
                    isActive: false
                ),
            ],
            allowsSplit: true,
            activate: { activated.append($0) },
            split: { _ in },
            close: { _ in }
        )

        XCTAssertEqual(view.accessibilityLabel, "2 tabs")
        XCTAssertTrue(view.shouldGroupAccessibilityChildren)
        XCTAssertEqual(view.cells.count, 2)
        XCTAssertEqual(view.cells[0].itemID, activeID)
        XCTAssertEqual(view.cells[0].sourceLabel.accessibilityLabel, "agent · devbox")
        XCTAssertEqual(view.cells[0].accessibilityLabel, "agent tab, active")
        XCTAssertTrue(view.cells[0].accessibilityTraits.contains(.selected))
        XCTAssertEqual(view.cells[0].tallyState, .ended)
        XCTAssertNotNil(view.cells[0].dotView)
        XCTAssertEqual(view.cells[1].sourceLabel.accessibilityLabel, "deploy · prod")
        XCTAssertEqual(view.cells[1].accessibilityLabel, "deploy tab")

        view.cells[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(activated, [inactiveID])
        XCTAssertEqual(TerminalTabStripView.cellSpacing, 4)
        XCTAssertEqual(TerminalTabCell.horizontalInset, 12)
        XCTAssertEqual(TerminalTabCell.verticalInset, 7)
        XCTAssertEqual(TerminalTabCell.contentSpacing, 8)
        XCTAssertEqual(TerminalTabCell.lampSize, 6)
    }

    func testFittingHeightComesFromLegacyIntrinsicCellAnatomy() throws {
        let view = configuredView(items: [
            .init(
                id: UUID(),
                title: "main",
                hostName: "devbox",
                controller: nil,
                isActive: true
            ),
        ])
        let cell = try XCTUnwrap(view.cells.first)
        let contentHeight = max(
            cell.sourceLabel.intrinsicContentSize.height,
            TerminalTabCell.lampSize
        )
        let expectedHeight = ceil(
            contentHeight + TerminalTabCell.verticalInset * 2
        )

        XCTAssertEqual(cell.intrinsicContentSize.height, expectedHeight)
        XCTAssertEqual(view.fittingContentSize().height, expectedHeight)
        XCTAssertEqual(view.intrinsicContentSize.height, expectedHeight)
    }

    /// A real tab press synchronously updates both cells while the pressed
    /// UIControl is still dispatching its action. The control, its labels, and
    /// every hit region must survive that update; visionOS immediately asks
    /// the ornament to fit this same live subtree.
    func testTwoTabActivationKeepsIdentityAndGeometryStable() {
        let firstID = UUID()
        let secondID = UUID()
        let view = TerminalTabStripView()
        var rerender: ((UUID) -> Void)!
        rerender = { activeID in
            view.apply(
                items: [
                    .init(
                        id: firstID,
                        title: "main",
                        controller: nil,
                        isActive: activeID == firstID
                    ),
                    .init(
                        id: secondID,
                        title: "scratch",
                        controller: nil,
                        isActive: activeID == secondID
                    ),
                ],
                allowsSplit: true,
                activate: { rerender($0) },
                split: { _ in },
                close: { _ in }
            )
        }
        rerender(firstID)

        let originalSize = view.fittingContentSize()
        view.frame = CGRect(origin: .zero, size: originalSize)
        view.layoutIfNeeded()
        let originalCells = view.cells
        let originalLabels = view.cells.map(\.sourceLabel)

        view.cells[1].sendActions(for: .touchUpInside)
        view.frame.size = view.fittingContentSize()
        view.layoutIfNeeded()

        XCTAssertEqual(view.fittingContentSize(), originalSize)
        XCTAssertTrue(view.cells[0] === originalCells[0])
        XCTAssertTrue(view.cells[1] === originalCells[1])
        XCTAssertTrue(view.cells[0].sourceLabel === originalLabels[0])
        XCTAssertTrue(view.cells[1].sourceLabel === originalLabels[1])
        XCTAssertFalse(view.cells[0].accessibilityTraits.contains(.selected))
        XCTAssertTrue(view.cells[1].accessibilityTraits.contains(.selected))
        XCTAssertEqual(
            view.cells[1].frame.minX - view.cells[0].frame.maxX,
            TerminalTabStripView.cellSpacing,
            accuracy: 0.5
        )
        for cell in view.cells {
            XCTAssertGreaterThan(cell.frame.width, 0)
            XCTAssertGreaterThan(cell.frame.height, 0)
            let center = cell.convert(
                CGPoint(x: cell.bounds.midX, y: cell.bounds.midY),
                to: view
            )
            XCTAssertTrue(view.hitTest(center, with: nil) === cell)
        }
        rerender = nil
    }

    #if os(visionOS)
    func testVisionTopOrnamentKeepsArithmeticTwoTabSizeAcrossActivation() {
        let firstID = UUID()
        let secondID = UUID()
        let strip = TerminalTabStripView()
        let host = TerminalVisionTabOrnamentHostView(tabStrip: strip)
        func render(activeID: UUID) {
            strip.apply(
                items: [
                    .init(id: firstID, title: "main", controller: nil,
                          isActive: activeID == firstID),
                    .init(id: secondID, title: "scratch", controller: nil,
                          isActive: activeID == secondID),
                ],
                allowsSplit: true,
                activate: { render(activeID: $0) },
                split: { _ in },
                close: { _ in }
            )
            host.refreshFittingSize()
        }
        render(activeID: firstID)
        let originalSize = host.fittingSize()
        host.frame = CGRect(origin: .zero, size: originalSize)
        host.layoutIfNeeded()

        strip.cells[1].sendActions(for: .touchUpInside)
        host.frame.size = host.fittingSize()
        host.layoutIfNeeded()

        XCTAssertEqual(host.fittingSize(), originalSize)
        XCTAssertEqual(strip.frame.width, strip.fittingContentSize().width, accuracy: 0.5)
        XCTAssertEqual(strip.frame.height, 30, accuracy: 0.5)
        XCTAssertEqual(strip.cells.count, 2)
        XCTAssertTrue(strip.cells.allSatisfy { !$0.frame.isEmpty })
    }
    #endif

    func testAuxiliaryTabHasNoTallyLamp() {
        let id = UUID()
        let view = configuredView(items: [
            .init(
                id: id,
                title: "⌗ docs",
                hostName: nil,
                controller: nil,
                isActive: true,
                isAuxiliary: true
            ),
        ])

        XCTAssertEqual(view.cells[0].tallyState, .auxiliary)
        XCTAssertNil(view.cells[0].dotView)
        XCTAssertEqual(view.cells[0].sourceLabel.accessibilityLabel, "⌗ docs")
    }

    func testEquivalentApplyPreservesCellIdentityAndRefreshesCallbacks() {
        let id = UUID()
        let items = [
            TerminalTabStrip.Item(
                id: id,
                title: "main",
                hostName: "devbox",
                controller: nil,
                isActive: true
            ),
        ]
        var firstActivations: [UUID] = []
        var replacementActivations: [UUID] = []
        let view = TerminalTabStripView()
        view.apply(
            items: items,
            allowsSplit: true,
            activate: { firstActivations.append($0) },
            split: { _ in },
            close: { _ in }
        )
        let originalCell = view.cells[0]

        view.apply(
            items: items,
            allowsSplit: true,
            activate: { replacementActivations.append($0) },
            split: { _ in },
            close: { _ in }
        )
        view.apply(
            items: items,
            allowsSplit: true,
            activate: { replacementActivations.append($0) },
            split: { _ in },
            close: { _ in }
        )

        XCTAssertTrue(view.cells[0] === originalCell)
        view.cells[0].sendActions(for: .touchUpInside)
        XCTAssertTrue(firstActivations.isEmpty)
        XCTAssertEqual(replacementActivations, [id])
    }

    /// Status churn and tab switches must not cancel a press already tracking
    /// one of these controls, so a render that changes only what a cell wears
    /// mutates it instead of rebuilding the row.
    func testStatusAndActiveChurnMutateCellsInPlace() throws {
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let controller = TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main")),
            host: host
        )
        let id = UUID()
        let view = TerminalTabStripView()
        apply(to: view, items: [
            .init(id: id, title: "main", controller: nil, isActive: false),
        ])
        let cell = try XCTUnwrap(view.cells.first)
        let dot = try XCTUnwrap(cell.dotView)
        let label = cell.sourceLabel
        XCTAssertEqual(cell.tallyState, .ended)

        apply(to: view, items: [
            .init(id: id, title: "main", controller: controller, isActive: false),
        ])
        XCTAssertTrue(view.cells[0] === cell)
        XCTAssertTrue(cell.dotView === dot)
        XCTAssertEqual(cell.tallyState, .connecting)

        apply(to: view, items: [
            .init(id: id, title: "agent", controller: controller, isActive: false),
        ])
        XCTAssertTrue(view.cells[0] === cell)
        XCTAssertTrue(cell.sourceLabel === label)
        XCTAssertEqual(cell.sourceLabel.accessibilityLabel, "agent")

        apply(to: view, items: [
            .init(id: id, title: "agent", controller: controller, isActive: true),
        ])
        XCTAssertTrue(view.cells[0] === cell)
        XCTAssertTrue(cell.sourceLabel === label)
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))
        XCTAssertEqual(cell.accessibilityLabel, "agent tab, active")
        XCTAssertEqual(cell.sourceLabel.accessibilityLabel, "agent")

        // Only a changed identity list is allowed to rebuild the row.
        apply(to: view, items: [
            .init(id: UUID(), title: "agent", controller: controller, isActive: true),
        ])
        XCTAssertFalse(view.cells[0] === cell)
    }

    func testCellsEnableTouchContextMenuInteraction() throws {
        let id = UUID()
        let view = configuredView(items: [
            .init(id: id, title: "main", controller: nil, isActive: true),
        ])
        let cell = try XCTUnwrap(view.cells.first)

        XCTAssertTrue(cell.isContextMenuInteractionEnabled)
        XCTAssertNotNil(cell.contextMenuInteraction)
    }

    func testContextMenuAndAccessibilityActionsHonorSplitRules() {
        let firstID = UUID()
        let secondID = UUID()
        var splitIDs: [UUID] = []
        var closedIDs: [UUID] = []
        let items = [
            TerminalTabStrip.Item(
                id: firstID,
                title: "main",
                controller: nil,
                isActive: true
            ),
            TerminalTabStrip.Item(
                id: secondID,
                title: "scratch",
                controller: nil,
                isActive: false
            ),
        ]
        let view = TerminalTabStripView()
        view.apply(
            items: items,
            allowsSplit: true,
            activate: { _ in },
            split: { splitIDs.append($0) },
            close: { closedIDs.append($0) }
        )

        XCTAssertEqual(menuTitles(view.menu(for: firstID)), [
            "Move to New Window", "Close Tab",
        ])
        XCTAssertEqual(
            view.cells[0].accessibilityCustomActions?.map(\.name),
            ["Move to New Window", "Close Tab"]
        )
        view.splitTab(id: firstID)
        view.closeTab(id: secondID)
        XCTAssertEqual(splitIDs, [firstID])
        XCTAssertEqual(closedIDs, [secondID])

        view.apply(
            items: items,
            allowsSplit: false,
            activate: { _ in },
            split: { splitIDs.append($0) },
            close: { closedIDs.append($0) }
        )
        XCTAssertEqual(menuTitles(view.menu(for: firstID)), ["Close Tab"])
        XCTAssertEqual(
            view.cells[0].accessibilityCustomActions?.map(\.name),
            ["Close Tab"]
        )
        view.splitTab(id: firstID)
        XCTAssertEqual(splitIDs, [firstID])
    }

    func testSingleTabNeverOffersSplit() {
        let id = UUID()
        let view = configuredView(items: [
            .init(id: id, title: "main", controller: nil, isActive: true),
        ])

        XCTAssertEqual(menuTitles(view.menu(for: id)), ["Close Tab"])
    }

    private func configuredView(
        items: [TerminalTabStrip.Item]
    ) -> TerminalTabStripView {
        let view = TerminalTabStripView()
        apply(to: view, items: items)
        return view
    }

    private func apply(
        to view: TerminalTabStripView,
        items: [TerminalTabStrip.Item]
    ) {
        view.apply(
            items: items,
            allowsSplit: true,
            activate: { _ in },
            split: { _ in },
            close: { _ in }
        )
    }

    private func menuTitles(_ menu: UIMenu) -> [String] {
        menu.children.compactMap { ($0 as? UIAction)?.title }
    }

}
