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
        view.apply(
            items: items,
            allowsSplit: true,
            activate: { _ in },
            split: { _ in },
            close: { _ in }
        )
        return view
    }

    private func menuTitles(_ menu: UIMenu) -> [String] {
        menu.children.compactMap { ($0 as? UIAction)?.title }
    }

}
