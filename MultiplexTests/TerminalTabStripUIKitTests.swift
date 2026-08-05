import UIKit
import UniformTypeIdentifiers
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

        XCTAssertTrue(view.cells[1].accessibilityActivate())
        XCTAssertEqual(activated, [inactiveID])
        XCTAssertEqual(TerminalTabStripView.cellSpacing, 4)
        XCTAssertEqual(TerminalTabCell.horizontalInset, 12)
        XCTAssertEqual(TerminalTabCell.verticalInset, 7)
        XCTAssertEqual(TerminalTabCell.contentSpacing, 8)
        XCTAssertEqual(TerminalTabCell.lampSize, 6)
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

        XCTAssertTrue(view.cells[1].accessibilityActivate())
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

        XCTAssertTrue(strip.cells[1].accessibilityActivate())
        host.frame.size = host.fittingSize()
        host.layoutIfNeeded()

        XCTAssertEqual(host.fittingSize(), originalSize)
        XCTAssertEqual(strip.frame.width, strip.fittingContentSize().width, accuracy: 0.5)
        XCTAssertEqual(strip.frame.height, 30, accuracy: 0.5)
        XCTAssertTrue(host.interactions.contains { $0 is UIDropInteraction })
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
        XCTAssertTrue(view.cells[0].accessibilityActivate())
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

    func testTabDragDropReordersInPlaceAndStaysInsideItsWindow() throws {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        var items = [
            TerminalTabStrip.Item(
                id: firstID, title: "main", controller: nil, isActive: true
            ),
            TerminalTabStrip.Item(
                id: secondID, title: "scratch", controller: nil, isActive: false
            ),
            TerminalTabStrip.Item(
                id: thirdID, title: "deploy", controller: nil, isActive: false
            ),
        ]
        let view = TerminalTabStripView()
        func render() {
            view.apply(
                items: items,
                allowsSplit: true,
                activate: { _ in },
                split: { _ in },
                close: { _ in },
                reorder: { sourceID, targetID in
                    guard let sourceIndex = items.firstIndex(where: { $0.id == sourceID }),
                          let targetIndex = items.firstIndex(where: { $0.id == targetID })
                    else { return }
                    let moved = items.remove(at: sourceIndex)
                    items.insert(moved, at: targetIndex)
                    render()
                }
            )
        }
        render()
        view.frame = CGRect(origin: .zero, size: view.fittingContentSize())
        let scrollView = TerminalTabScrollView(frame: CGRect(
            x: 0, y: 0, width: view.frame.width + 80, height: view.frame.height + 12
        ))
        let window = UIWindow(frame: scrollView.bounds)
        window.addSubview(scrollView)
        window.makeKeyAndVisible()
        scrollView.addSubview(view)
        view.installDropTarget(on: scrollView)
        view.layoutIfNeeded()

        let originalCells = Dictionary(uniqueKeysWithValues: view.cells.map {
            ($0.itemID, ObjectIdentifier($0))
        })
        let source = view.cells[0]
        let target = view.cells[2]
        let drag = try XCTUnwrap(
            source.interactions.compactMap { $0 as? UIDragInteraction }.first
        )
        let dragSession = TerminalTabDragSessionStub()
        let dragItems = source.dragInteraction(drag, itemsForBeginning: dragSession)
        dragSession.items = dragItems
        let item = try XCTUnwrap(dragItems.first)
        let preview = try XCTUnwrap(item.previewProvider?())

        XCTAssertTrue(drag.isEnabled)
        XCTAssertEqual(source.accessibilityHint, "Drag to reorder within this window")
        XCTAssertFalse(
            item.itemProvider.hasItemConformingToTypeIdentifier(UTType.item.identifier)
        )
        XCTAssertTrue(item.localObject is TerminalTabDragPayload)
        XCTAssertEqual(preview.parameters.backgroundColor, UIColor.clear)
        XCTAssertEqual(preview.parameters.visiblePath?.bounds, source.bounds)
        XCTAssertTrue(source.dragInteraction(
            drag,
            sessionIsRestrictedToDraggingApplication: dragSession
        ))
        XCTAssertTrue(source.dragInteraction(
            drag,
            prefersFullSizePreviewsFor: dragSession
        ))
        source.dragInteraction(drag, sessionWillBegin: dragSession)
        XCTAssertFalse(
            scrollView.isScrollEnabled,
            "The tab rail must yield its pan once UIKit commits to the lift"
        )

        XCTAssertFalse(
            target.interactions.contains { $0 is UIDropInteraction },
            "The whole rail owns the drop, not the small destination cell"
        )
        let drop = try XCTUnwrap(
            scrollView.interactions.compactMap { $0 as? UIDropInteraction }.first
        )
        let dropSession = TerminalTabDropSessionStub(
            items: dragItems,
            localDragSession: dragSession,
            location: CGPoint(x: target.frame.midX, y: 500)
        )
        XCTAssertFalse(
            TerminalPaneViewController.isFileDropCandidate(dropSession),
            "A tab that strays into the pane must never raise its upload target"
        )
        XCTAssertTrue(view.dropInteraction(drop, canHandle: dropSession))
        view.dropInteraction(drop, sessionDidEnter: dropSession)
        XCTAssertEqual(target.layer.borderWidth, 2)
        XCTAssertEqual(
            view.dropInteraction(drop, sessionDidUpdate: dropSession).operation,
            .move,
            "A lift released well below the rail must remain a forgiving sort"
        )
        view.dropInteraction(drop, performDrop: dropSession)

        XCTAssertEqual(items.map(\.id), [secondID, thirdID, firstID])
        XCTAssertEqual(view.cells.map(\.itemID), [secondID, thirdID, firstID])
        XCTAssertEqual(
            view.cells.map { ObjectIdentifier($0) },
            [secondID, thirdID, firstID].compactMap { originalCells[$0] }
        )
        XCTAssertEqual(target.layer.borderWidth, 1)
        XCTAssertNotEqual(view.cells[0].transform, .identity)
        XCTAssertNotEqual(view.cells[1].transform, .identity)
        XCTAssertEqual(view.cells[2].transform, .identity)

        // UIKit asks for the landing preview only after `performDrop`. It must
        // fly to the moved source's final center, while the displaced cells
        // ride the exact same system animator instead of jumping underneath.
        let defaultPreview = UITargetedDragPreview(
            view: source,
            parameters: UIDragPreviewParameters(),
            target: UIDragPreviewTarget(container: scrollView, center: .zero)
        )
        let retargeted = view.dropInteraction(
            drop,
            previewForDropping: item,
            withDefault: defaultPreview
        )
        let landingPreview = try XCTUnwrap(retargeted)
        let finalSourceCenter = source.convert(
            CGPoint(x: source.bounds.midX, y: source.bounds.midY),
            to: view
        )
        XCTAssertTrue(landingPreview.target.container === view)
        XCTAssertEqual(landingPreview.target.center.x, finalSourceCenter.x, accuracy: 0.5)
        XCTAssertEqual(landingPreview.target.center.y, finalSourceCenter.y, accuracy: 0.5)

        let animator = TerminalTabDropAnimatorSpy()
        view.dropInteraction(drop, item: item, willAnimateDropWith: animator)
        XCTAssertEqual(animator.animationCount, 1)
        XCTAssertEqual(animator.completionCount, 1)
        animator.runAnimations()
        XCTAssertTrue(view.cells.allSatisfy { $0.transform == .identity })
        animator.complete(at: .end)
        view.dropInteraction(drop, concludeDrop: dropSession)
        source.dragInteraction(drag, sessionDidEnd: dragSession, with: .move)
        XCTAssertTrue(scrollView.isScrollEnabled)

        let otherWindow = configuredView(items: [
            .init(id: firstID, title: "main", controller: nil, isActive: true),
            .init(id: thirdID, title: "deploy", controller: nil, isActive: false),
        ])
        let otherTarget = otherWindow.cells[1]
        dropSession.location = CGPoint(x: otherTarget.frame.midX, y: 0)
        let otherDrop = try XCTUnwrap(
            otherWindow.interactions.compactMap { $0 as? UIDropInteraction }.first
        )
        XCTAssertFalse(otherWindow.dropInteraction(otherDrop, canHandle: dropSession))
        XCTAssertEqual(
            otherWindow.dropInteraction(otherDrop, sessionDidUpdate: dropSession).operation,
            .forbidden
        )
    }

    func testTabPointerDragPolicyPreservesDesignedForIPadClicks() {
        XCTAssertTrue(
            TerminalTabDragPolicy.allowsPointerDragBeforeLiftDelay(isIOSAppOnMac: false)
        )
        XCTAssertFalse(
            TerminalTabDragPolicy.allowsPointerDragBeforeLiftDelay(isIOSAppOnMac: true)
        )
    }

    func testSingleTabNeverOffersSplitOrDrag() throws {
        let id = UUID()
        let view = configuredView(items: [
            .init(id: id, title: "main", controller: nil, isActive: true),
        ])

        XCTAssertEqual(menuTitles(view.menu(for: id)), ["Close Tab"])
        let drag = try XCTUnwrap(
            view.cells[0].interactions.compactMap { $0 as? UIDragInteraction }.first
        )
        XCTAssertFalse(drag.isEnabled)
        XCTAssertNil(view.cells[0].accessibilityHint)
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

@MainActor
private final class TerminalTabDropAnimatorSpy: NSObject, UIDragAnimating {
    private var animations: [() -> Void] = []
    private var completions: [(UIViewAnimatingPosition) -> Void] = []

    var animationCount: Int { animations.count }
    var completionCount: Int { completions.count }

    func addAnimations(_ animations: @escaping () -> Void) {
        self.animations.append(animations)
    }

    func addCompletion(
        _ completion: @escaping (UIViewAnimatingPosition) -> Void
    ) {
        completions.append(completion)
    }

    func runAnimations() {
        animations.forEach { $0() }
    }

    func complete(at position: UIViewAnimatingPosition) {
        completions.forEach { $0(position) }
    }
}

@MainActor
private final class TerminalTabDragSessionStub: NSObject, UIDragSession {
    var localContext: Any?
    var items: [UIDragItem] = []
    let allowsMoveOperation = true
    let isRestrictedToDraggingApplication = true

    func location(in view: UIView) -> CGPoint { .zero }

    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
        itemsContain(typeIdentifiers)
    }

    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool {
        false
    }

    private func itemsContain(_ typeIdentifiers: [String]) -> Bool {
        items.contains { item in
            typeIdentifiers.contains { type in
                item.itemProvider.hasItemConformingToTypeIdentifier(type)
            }
        }
    }
}

@MainActor
private final class TerminalTabDropSessionStub: NSObject, UIDropSession {
    let items: [UIDragItem]
    let localDragSession: UIDragSession?
    let allowsMoveOperation = true
    let isRestrictedToDraggingApplication = true
    var progressIndicatorStyle = UIDropSessionProgressIndicatorStyle.none
    let progress = Progress(totalUnitCount: 1)
    var location: CGPoint

    init(
        items: [UIDragItem],
        localDragSession: UIDragSession?,
        location: CGPoint
    ) {
        self.items = items
        self.localDragSession = localDragSession
        self.location = location
    }

    func location(in view: UIView) -> CGPoint { location }

    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
        items.contains { item in
            typeIdentifiers.contains { type in
                item.itemProvider.hasItemConformingToTypeIdentifier(type)
            }
        }
    }

    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool {
        false
    }

    func loadObjects(
        ofClass aClass: NSItemProviderReading.Type,
        completion: @escaping ([NSItemProviderReading]) -> Void
    ) -> Progress {
        progress
    }
}
