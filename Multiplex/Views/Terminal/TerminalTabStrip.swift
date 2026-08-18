import Observation
import UIKit
import UniformTypeIdentifiers

/// A pointer drag may skip UIKit's lift delay everywhere except Designed for
/// iPad on Mac, where arming at mouse-down steals the tab's ordinary click.
enum TerminalTabDragPolicy {
    static func allowsPointerDragBeforeLiftDelay(isIOSAppOnMac: Bool) -> Bool {
        !isIOSAppOnMac
    }

    static var allowsPointerDragBeforeLiftDelay: Bool {
        allowsPointerDragBeforeLiftDelay(
            isIOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac
        )
    }
}

/// Local-object marker shared with the terminal's file-drop gate. The provider
/// carries only a process-local representation; this second gate keeps the
/// file surface honest even if UIKit hands nested targets only the local item.
struct TerminalTabDragPayload {
    var stripID: UUID
    var tabID: UUID
}

/// UIKit tab strip rendered in the window's multiviewer source-label voice:
/// square cells in compressed caps, each with its own tally dot.
@MainActor
final class TerminalTabStripView: UIView, UIDropInteractionDelegate {
    static let cellSpacing: CGFloat = 4

    /// Process-local and outside `public.item`: other drop surfaces cannot
    /// mistake this representation for text or a file.
    private static let dragType = UTType(
        tag: "application/x-multiplex-window-tab",
        tagClass: .mimeType,
        conformingTo: nil
    )

    /// Closures deliberately stay out of the key: retained cells route every
    /// action through this view, whose callback properties `apply` refreshes.
    private struct PendingDropAnimation {
        var sourceID: UUID
        var destinationCenter: CGPoint
        var displacedIDs: Set<UUID>
    }

    private struct RenderKey: Equatable {
        struct Cell: Equatable {
            var id: UUID
            var title: String
            var hostName: String?
            var isActive: Bool
            var isAuxiliary: Bool
            var tallyState: TerminalTabTallyState
            var canSplit: Bool
        }

        /// What a cell's *anatomy* depends on: its identity and whether it
        /// carries a tally dot at all. Everything else a render can change is
        /// mutable in place.
        struct Structure: Equatable {
            var id: UUID
            var isAuxiliary: Bool
        }

        var cells: [Cell]

        var structure: [Structure] {
            cells.map { Structure(id: $0.id, isAuxiliary: $0.isAuxiliary) }
        }
    }

    private(set) var cells: [TerminalTabCell] = []

    private let stackView = UIStackView()
    private let dragScopeID = UUID()
    private var installedDropHosts: Set<ObjectIdentifier> = []
    private var dropTargetID: UUID?
    private var pendingDropAnimation: PendingDropAnimation?
    private var items: [TerminalTabStrip.Item] = []
    private var allowsSplit = true
    private var activate: (UUID) -> Void = { _ in }
    private var split: (UUID) -> Void = { _ in }
    private var close: (UUID) -> Void = { _ in }
    private var reorder: (UUID, UUID) -> Void = { _, _ in }
    private var configurationGeneration = 0
    /// The session controllers the live observation registration covers, in
    /// item order. `nil` until the first arming.
    private var observedControllers: [ObjectIdentifier]?
    private var renderedKey: RenderKey?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shouldGroupAccessibilityChildren = true

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.spacing = Self.cellSpacing
        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        installDropTarget(on: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// The SwiftUI source let the source-label cells determine the strip's
    /// height. Keep that intrinsic measurement explicit so every host (the
    /// iOS rail and the visionOS ornament) consumes the same geometry.
    ///
    /// Arithmetic on purpose, never a constraint solve: the stack is
    /// required-pinned to this frame-managed view, and asking that live
    /// subtree to fit a zero proposal from inside a layout pass can COMMIT
    /// the degenerate solve instead of rolling it back — every authored
    /// constant came out multiplied by one tiny factor and the rail drew
    /// stacked glyphs over dead hit regions until a bounds change (device
    /// rotation) forced a fresh pass (user-reported).
    func fittingContentSize() -> CGSize {
        guard !cells.isEmpty else { return .zero }
        var width: CGFloat = 0
        var height: CGFloat = 0
        for cell in cells {
            let size = cell.intrinsicContentSize
            width += size.width
            height = max(height, size.height)
        }
        width += Self.cellSpacing * CGFloat(cells.count - 1)
        return CGSize(width: ceil(width), height: ceil(height))
    }

    override var intrinsicContentSize: CGSize {
        fittingContentSize()
    }

    func apply(
        items: [TerminalTabStrip.Item],
        allowsSplit: Bool,
        activate: @escaping (UUID) -> Void,
        split: @escaping (UUID) -> Void,
        close: @escaping (UUID) -> Void,
        reorder: @escaping (UUID, UUID) -> Void = { _, _ in }
    ) {
        self.items = items
        self.allowsSplit = allowsSplit
        self.activate = activate
        self.split = split
        self.close = close
        self.reorder = reorder
        accessibilityLabel = String(localized: "\(items.count) tabs")

        // The window re-renders this strip on every observed change of its
        // own (a ~5 s host probe is enough), and an Observation registration
        // can only be superseded, never cancelled — re-arming per render
        // would strand one dead tracking per render against every tab's
        // still-`.live` status. What the tracking actually covers is the tab
        // controllers' identities, so re-arm only when that list changes and
        // otherwise let the standing registration do its job, rendering from
        // a plain (unregistered) read.
        let tracked = trackedControllerIdentities()
        guard tracked != observedControllers else {
            render(states: items.map { TerminalTabTallyState(item: $0) })
            return
        }
        observedControllers = tracked
        configurationGeneration &+= 1
        observeStatusesAndRender(generation: configurationGeneration)
    }

    func activateTab(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        activate(id)
    }

    func splitTab(id: UUID) {
        guard canSplit(id: id) else { return }
        split(id)
    }

    func closeTab(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        close(id)
    }

    func reorderTab(id sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              items.contains(where: { $0.id == sourceID }),
              items.contains(where: { $0.id == targetID })
        else { return }
        reorder(sourceID, targetID)
    }

    func menu(for id: UUID) -> UIMenu {
        var actions: [UIMenuElement] = []
        if canSplit(id: id) {
            actions.append(UIAction(
                title: String(localized: "Move to New Window"),
                image: UIImage(systemName: "macwindow.badge.plus")
            ) { [weak self] _ in
                self?.splitTab(id: id)
            })
        }
        actions.append(UIAction(
            title: String(localized: "Close Tab"),
            image: UIImage(systemName: "xmark"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.closeTab(id: id)
        })
        return UIMenu(children: actions)
    }

    /// Expands the sort target from the tiny cell itself to the rail/ornament
    /// that frames it. One installation per host keeps repeated renders inert.
    func installDropTarget(on host: UIView) {
        guard installedDropHosts.insert(ObjectIdentifier(host)).inserted else { return }
        host.addInteraction(UIDropInteraction(delegate: self))
    }

    private func canSplit(id: UUID) -> Bool {
        allowsSplit && items.count > 1 && items.contains(where: { $0.id == id })
    }

    private func dragItem(for tabID: UUID, session: UIDragSession) -> UIDragItem? {
        guard items.count > 1,
              items.contains(where: { $0.id == tabID }),
              let dragType = Self.dragType
        else { return nil }
        let payload = TerminalTabDragPayload(stripID: dragScopeID, tabID: tabID)
        session.localContext = payload
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: dragType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }
        let item = UIDragItem(itemProvider: provider)
        item.localObject = payload
        return item
    }

    private func canHandleTabDrag(_ session: UIDropSession) -> Bool {
        guard items.count > 1,
              let payload = dragPayload(from: session)
        else { return false }
        return payload.stripID == dragScopeID
            && items.contains(where: { $0.id == payload.tabID })
    }

    private func dropTarget(for session: UIDropSession) -> UUID? {
        guard canHandleTabDrag(session),
              let sourceID = dragPayload(from: session)?.tabID
        else { return nil }

        let location = session.location(in: self)
        if let source = cells.first(where: { $0.itemID == sourceID }),
           location.x >= source.frame.minX - Self.cellSpacing / 2,
           location.x <= source.frame.maxX + Self.cellSpacing / 2 {
            return nil
        }
        return cells
            .filter { $0.itemID != sourceID }
            .min {
                abs(location.x - $0.frame.midX) < abs(location.x - $1.frame.midX)
            }?
            .itemID
    }

    private func setDropTarget(_ id: UUID?) {
        dropTargetID = id
        for cell in cells {
            cell.setDropTarget(cell.itemID == id)
        }
    }

    private func dragPayload(from session: UIDropSession) -> TerminalTabDragPayload? {
        if let payload = session.localDragSession?.localContext as? TerminalTabDragPayload {
            return payload
        }
        return session.items.lazy
            .compactMap { $0.localObject as? TerminalTabDragPayload }
            .first
    }

    /// Rebuild the stack at its committed order without exposing that jump,
    /// then let UIKit's velocity-aware drop animator carry every displaced
    /// neighbor from its presentation slot. The dragged preview itself flies
    /// to the source cell's exact final center.
    private func prepareDropAnimation(sourceID: UUID, targetID: UUID) {
        finishDropAnimation()
        layoutIfNeeded()
        let oldCenters = Dictionary(uniqueKeysWithValues: cells.map { cell in
            (cell.itemID, center(of: cell))
        })

        UIView.performWithoutAnimation {
            reorderTab(id: sourceID, to: targetID)
            layoutIfNeeded()
        }

        guard let sourceCell = cells.first(where: { $0.itemID == sourceID }) else { return }
        let destinationCenter = center(of: sourceCell)
        var displacedIDs = Set<UUID>()
        UIView.performWithoutAnimation {
            for cell in cells where cell.itemID != sourceID {
                guard let oldCenter = oldCenters[cell.itemID] else { continue }
                let finalCenter = center(of: cell)
                let offset = CGVector(
                    dx: oldCenter.x - finalCenter.x,
                    dy: oldCenter.y - finalCenter.y
                )
                guard abs(offset.dx) > 0.5 || abs(offset.dy) > 0.5 else { continue }
                cell.transform = CGAffineTransform(
                    translationX: offset.dx,
                    y: offset.dy
                )
                displacedIDs.insert(cell.itemID)
            }
        }
        pendingDropAnimation = PendingDropAnimation(
            sourceID: sourceID,
            destinationCenter: destinationCenter,
            displacedIDs: displacedIDs
        )
    }

    private func center(of cell: TerminalTabCell) -> CGPoint {
        cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: self)
    }

    private func finishDropAnimation(sourceID: UUID? = nil) {
        guard let pendingDropAnimation,
              sourceID == nil || sourceID == pendingDropAnimation.sourceID
        else { return }
        UIView.performWithoutAnimation {
            for cell in cells where pendingDropAnimation.displacedIDs.contains(cell.itemID) {
                cell.transform = .identity
            }
        }
        self.pendingDropAnimation = nil
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        canHandle session: UIDropSession
    ) -> Bool {
        canHandleTabDrag(session)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidEnter session: UIDropSession
    ) {
        setDropTarget(dropTarget(for: session))
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        let target = dropTarget(for: session)
        setDropTarget(target)
        return UIDropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidExit session: UIDropSession
    ) {
        setDropTarget(nil)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidEnd session: UIDropSession
    ) {
        setDropTarget(nil)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        previewForDropping item: UIDragItem,
        withDefault defaultPreview: UITargetedDragPreview
    ) -> UITargetedDragPreview? {
        guard let payload = item.localObject as? TerminalTabDragPayload,
              let pendingDropAnimation,
              payload.tabID == pendingDropAnimation.sourceID
        else { return defaultPreview }
        let target = UIDragPreviewTarget(
            container: self,
            center: pendingDropAnimation.destinationCenter
        )
        return defaultPreview.retargetedPreview(with: target)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        performDrop session: UIDropSession
    ) {
        let sourceID = dragPayload(from: session)?.tabID
        let targetID = dropTarget(for: session)
        setDropTarget(nil)
        guard let sourceID, let targetID else { return }
        prepareDropAnimation(sourceID: sourceID, targetID: targetID)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        item: UIDragItem,
        willAnimateDropWith animator: UIDragAnimating
    ) {
        guard let payload = item.localObject as? TerminalTabDragPayload,
              let pendingDropAnimation,
              payload.tabID == pendingDropAnimation.sourceID
        else { return }
        animator.addAnimations { [weak self] in
            guard let self,
                  self.pendingDropAnimation?.sourceID == pendingDropAnimation.sourceID
            else { return }
            for cell in self.cells
                where pendingDropAnimation.displacedIDs.contains(cell.itemID) {
                cell.transform = .identity
            }
        }
        animator.addCompletion { [weak self] _ in
            self?.finishDropAnimation(sourceID: pendingDropAnimation.sourceID)
        }
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        concludeDrop session: UIDropSession
    ) {
        finishDropAnimation()
    }

    /// Everything `TerminalTabTallyState` reads observably is one session
    /// controller's `status`, so this list is the whole tracked set.
    private func trackedControllerIdentities() -> [ObjectIdentifier] {
        items.compactMap { item in
            guard !item.isAuxiliary, let controller = item.controller else { return nil }
            return ObjectIdentifier(controller)
        }
    }

    /// Observation callbacks are one-shot. Each status change snapshots and
    /// re-arms the native strip, while a new item configuration invalidates
    /// callbacks registered for its predecessor.
    private func observeStatusesAndRender(generation: Int) {
        guard generation == configurationGeneration else { return }
        let states = withObservationTracking {
            items.map { TerminalTabTallyState(item: $0) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeStatusesAndRender(generation: generation)
            }
        }
        render(states: states)
    }

    private func render(states: [TerminalTabTallyState]) {
        let key = RenderKey(cells: zip(items, states).map { item, state in
            RenderKey.Cell(
                id: item.id,
                title: item.title,
                hostName: item.hostName,
                isActive: item.isActive,
                isAuxiliary: item.isAuxiliary,
                tallyState: state,
                canSplit: canSplit(id: item.id)
            )
        })
        guard renderedKey != key else { return }
        let previousStructure = renderedKey?.structure
        renderedKey = key

        // A cell is an interaction view a finger can already be tracking, and this
        // strip re-renders on every observed status change (a ~5 s host probe
        // is enough), tab switch, and reorder. Destroying and recreating the
        // cells there cancels that in-flight interaction. Reuse by identity
        // even when the order changed, then only rearrange the stack.
        if let reusable = reusableCells(
            from: previousStructure,
            to: key.structure
        ), items.count == key.cells.count {
            if !zip(cells, reusable).allSatisfy({ $0 === $1 }) {
                for cell in cells {
                    stackView.removeArrangedSubview(cell)
                }
                cells = reusable
                for cell in cells {
                    stackView.addArrangedSubview(cell)
                }
            }
            for index in key.cells.indices {
                cells[index].update(
                    item: items[index],
                    tallyState: states[index],
                    canSplit: key.cells[index].canSplit,
                    canReorder: items.count > 1
                )
            }
            setDropTarget(dropTargetID)
            // Keep invalidation local. Each host already requests its own
            // geometry pass after `apply`; walking the ancestor chain here can
            // pull unrelated pending descendants into a shell animation.
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            return
        }

        for arrangedSubview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        cells = zip(items, states).map { item, state in
            let cell = TerminalTabCell(
                item: item,
                tallyState: state,
                activate: { [weak self] in self?.activateTab(id: item.id) },
                makeMenu: { [weak self] in
                    self?.menu(for: item.id) ?? UIMenu(children: [])
                },
                split: { [weak self] in self?.splitTab(id: item.id) },
                close: { [weak self] in self?.closeTab(id: item.id) },
                beginDrag: { [weak self] session in
                    self?.dragItem(for: item.id, session: session)
                },
                canSplit: canSplit(id: item.id),
                canReorder: items.count > 1
            )
            stackView.addArrangedSubview(cell)
            return cell
        }
        setDropTarget(dropTargetID)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func reusableCells(
        from previous: [RenderKey.Structure]?,
        to next: [RenderKey.Structure]
    ) -> [TerminalTabCell]? {
        guard let previous,
              previous.count == next.count,
              previous.count == cells.count
        else { return nil }

        var byID: [UUID: (isAuxiliary: Bool, cell: TerminalTabCell)] = [:]
        for (structure, cell) in zip(previous, cells) {
            guard byID[structure.id] == nil else { return nil }
            byID[structure.id] = (structure.isAuxiliary, cell)
        }
        var result: [TerminalTabCell] = []
        for structure in next {
            guard let existing = byID[structure.id],
                  existing.isAuxiliary == structure.isAuxiliary
            else { return nil }
            result.append(existing.cell)
        }
        return result
    }
}

enum TerminalTabTallyState: Equatable {
    case auxiliary
    case live
    case connecting
    case ended

    @MainActor
    init(item: TerminalTabStrip.Item) {
        if item.isAuxiliary {
            self = .auxiliary
            return
        }
        guard let controller = item.controller else {
            self = .ended
            return
        }
        switch controller.status {
        case .live:
            self = .live
        case .connecting:
            self = .connecting
        case .ended:
            self = .ended
        }
    }

    @MainActor
    var color: UIColor {
        switch self {
        case .auxiliary, .ended: UIKitChassis.signal3
        case .live: TallyPalette.tally
        case .connecting: TallyPalette.caution
        }
    }
}

@MainActor
final class TerminalTabCell: UIView,
    UIContextMenuInteractionDelegate, UIDragInteractionDelegate
{
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 7
    static let contentSpacing: CGFloat = 8
    static let lampSize: CGFloat = 6

    let itemID: UUID
    private(set) var tallyState: TerminalTabTallyState
    private(set) var dotView: UIView?
    private(set) var sourceLabel: UIKitChassisLabel

    private let activate: () -> Void
    private let makeMenu: () -> UIMenu
    private let split: () -> Void
    private let close: () -> Void
    private let beginDrag: (UIDragSession) -> UIDragItem?
    private var canSplit: Bool
    private var canReorder: Bool
    private var isActive: Bool
    private var labelText: String
    private let contentStack = UIStackView()
    private weak var tabDragInteraction: UIDragInteraction?
    private weak var suspendedScrollView: UIScrollView?
    private var suspendedScrollWasEnabled = true
    private var isDropTarget = false {
        didSet {
            guard oldValue != isDropTarget else { return }
            refreshBorderAndLamp()
        }
    }

    init(
        item: TerminalTabStrip.Item,
        tallyState: TerminalTabTallyState,
        activate: @escaping () -> Void,
        makeMenu: @escaping () -> UIMenu,
        split: @escaping () -> Void,
        close: @escaping () -> Void,
        beginDrag: @escaping (UIDragSession) -> UIDragItem?,
        canSplit: Bool,
        canReorder: Bool
    ) {
        itemID = item.id
        self.tallyState = tallyState
        self.activate = activate
        self.makeMenu = makeMenu
        self.split = split
        self.close = close
        self.beginDrag = beginDrag
        self.canSplit = canSplit
        self.canReorder = canReorder
        isActive = item.isActive
        labelText = Self.label(for: item)
        sourceLabel = UIKitChassisLabel(
            labelText,
            size: 10,
            color: Self.ink(isActive: item.isActive)
        )
        super.init(frame: .zero)

        backgroundColor = Self.ground(isActive: item.isActive)
        layer.borderWidth = 1
        refreshBorderAndLamp()
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 3))
        addGestureRecognizer(UITapGestureRecognizer(
            target: self,
            action: #selector(pressed)
        ))
        addInteraction(UIContextMenuInteraction(delegate: self))

        isAccessibilityElement = true
        accessibilityTraits = Self.traits(isActive: item.isActive)
        accessibilityLabel = Self.accessibilityLabel(for: item)
        accessibilityHint = canReorder ? String(localized: "Drag to reorder within this window") : nil
        accessibilityCustomActions = makeAccessibilityActions()

        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = canReorder
        #if compiler(>=6.4)
        if #available(iOS 27.0, visionOS 27.0, *),
           TerminalTabDragPolicy.allowsPointerDragBeforeLiftDelay {
            drag.allowsPointerDragBeforeLiftDelay = true
        }
        #endif
        addInteraction(drag)
        tabDragInteraction = drag

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = Self.contentSpacing
        contentStack.isUserInteractionEnabled = false
        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.horizontalInset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.horizontalInset
            ),
            contentStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Self.verticalInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Self.verticalInset
            ),
        ])

        if tallyState != .auxiliary {
            let dot = UIView()
            dot.backgroundColor = tallyState.color
            dot.layer.cornerRadius = Self.lampSize / 2
            dot.isAccessibilityElement = false
            dot.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: Self.lampSize),
                dot.heightAnchor.constraint(equalToConstant: Self.lampSize),
            ])
            dotView = dot
            refreshLampShadow()
        }
        sourceLabel.isAccessibilityElement = false
        contentStack.addArrangedSubview(sourceLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// In-place refresh for a cell whose identity and anatomy are unchanged.
    /// The view itself survives, so a press already tracking it does too.
    func update(
        item: TerminalTabStrip.Item,
        tallyState: TerminalTabTallyState,
        canSplit: Bool,
        canReorder: Bool
    ) {
        if self.canSplit != canSplit {
            self.canSplit = canSplit
            accessibilityCustomActions = makeAccessibilityActions()
        }
        if self.canReorder != canReorder {
            self.canReorder = canReorder
            tabDragInteraction?.isEnabled = canReorder
            accessibilityHint = canReorder ? String(localized: "Drag to reorder within this window") : nil
        }
        let nextLabelText = Self.label(for: item)
        if labelText != nextLabelText {
            labelText = nextLabelText
            sourceLabel.setText(nextLabelText)
        }
        if isActive != item.isActive {
            isActive = item.isActive
            backgroundColor = Self.ground(isActive: item.isActive)
            accessibilityTraits = Self.traits(isActive: item.isActive)
            // Keep the arranged-subview tree untouched while this view's own
            // touch action is switching tabs. The host may measure the
            // strip before that action has unwound.
            sourceLabel.setInk(Self.ink(isActive: item.isActive))
        }
        accessibilityLabel = Self.accessibilityLabel(for: item)
        if self.tallyState != tallyState {
            self.tallyState = tallyState
            dotView?.backgroundColor = tallyState.color
            refreshLampShadow()
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private static func label(for item: TerminalTabStrip.Item) -> String {
        item.hostName.map { "\(item.title) · \($0)" } ?? item.title
    }

    private static func accessibilityLabel(for item: TerminalTabStrip.Item) -> String {
        item.isActive
            ? String(localized: "\(item.title) tab, active")
            : String(localized: "\(item.title) tab")
    }

    private static func ink(isActive: Bool) -> UIColor {
        isActive ? UIKitChassis.signal : UIKitChassis.signal2
    }

    private static func ground(isActive: Bool) -> UIColor {
        // PROTOTYPE(GLASS): tabs are strata chips over the smoke; pinned
        // LIGHT keeps the baseline grounds (§8 v1 — glass is dark-only).
        guard GlassPrototype.enabled else {
            return isActive ? UIKitChassis.bezelHi : UIKitChassis.chassis
        }
        return GlassPrototype.material(
            GlassPrototype.strataMaterial,
            fallback: isActive ? TallyPalette.bezelHi : TallyPalette.chassis
        )
    }

    private static func traits(isActive: Bool) -> UIAccessibilityTraits {
        isActive ? [.button, .selected] : .button
    }

    override var intrinsicContentSize: CGSize {
        // Arithmetic from the label's text measurement and the authored
        // constants — contentStack is required-pinned to the edges, so the
        // cell's size is fully determined without asking the engine. A
        // nested zero-proposal fit here, running while the strip's own
        // measurement was in flight, is what collapsed the whole rail.
        let label = sourceLabel.intrinsicContentSize
        let lamp = dotView == nil ? 0 : Self.lampSize
        let lampWidth = dotView == nil ? 0 : Self.lampSize + Self.contentSpacing
        return CGSize(
            width: ceil(label.width + lampWidth + Self.horizontalInset * 2),
            height: ceil(max(label.height, lamp) + Self.verticalInset * 2)
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshBorderAndLamp()
    }

    override func accessibilityActivate() -> Bool {
        activate()
        return true
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: itemID as NSUUID, previewProvider: nil) { [makeMenu] _ in
            makeMenu()
        }
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        itemsForBeginning session: UIDragSession
    ) -> [UIDragItem] {
        guard let item = beginDrag(session) else { return [] }
        item.previewProvider = { [weak self] in
            guard let self else { return nil }
            return UIDragPreview(
                view: self,
                parameters: self.dragPreviewParameters()
            )
        }
        return [item]
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        previewForLifting item: UIDragItem,
        session: UIDragSession
    ) -> UITargetedDragPreview? {
        UITargetedDragPreview(view: self, parameters: dragPreviewParameters())
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionWillBegin session: UIDragSession
    ) {
        // Unlike deck tiles, tabs sit inside a horizontal UIScrollView. Once
        // UIKit has committed to a lift, suspend that competing pan recognizer
        // until the drop ends or it can consume the movement and strand the
        // lifted cell over its original slot.
        guard let scrollView = sequence(first: superview, next: { $0?.superview })
            .compactMap({ $0 as? UIScrollView })
            .first
        else { return }
        suspendedScrollView = scrollView
        suspendedScrollWasEnabled = scrollView.isScrollEnabled
        scrollView.isScrollEnabled = false
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionDidEnd session: UIDragSession,
        with operation: UIDropOperation
    ) {
        suspendedScrollView?.isScrollEnabled = suspendedScrollWasEnabled
        suspendedScrollView = nil
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionIsRestrictedToDraggingApplication session: UIDragSession
    ) -> Bool {
        true
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        prefersFullSizePreviewsFor session: UIDragSession
    ) -> Bool {
        true
    }

    func setDropTarget(_ targeted: Bool) {
        isDropTarget = targeted
    }

    private func makeAccessibilityActions() -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if canSplit {
            actions.append(UIAccessibilityCustomAction(
                name: String(localized: "Move to New Window"),
                actionHandler: { [weak self] _ in
                    self?.split()
                    return self != nil
                }
            ))
        }
        actions.append(UIAccessibilityCustomAction(
            name: String(localized: "Close Tab"),
            actionHandler: { [weak self] _ in
                self?.close()
                return self != nil
            }
        ))
        return actions
    }

    @objc private func pressed() {
        activate()
    }

    private func refreshBorderAndLamp() {
        let border = isDropTarget ? UIKitChassis.signal2 : UIKitChassis.bezelHi
        layer.borderColor = border.resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = isDropTarget ? 2 : 1
        dotView?.backgroundColor = tallyState.color
        refreshLampShadow()
    }

    private func dragPreviewParameters() -> UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        let path = UIBezierPath(rect: bounds)
        parameters.backgroundColor = .clear
        parameters.visiblePath = path
        parameters.shadowPath = path
        return parameters
    }

    private func refreshLampShadow() {
        guard let dotView else { return }
        if tallyState == .live {
            dotView.layer.shadowColor = TallyPalette.tally
                .resolvedColor(with: traitCollection).cgColor
            dotView.layer.shadowOpacity = 0.7
            dotView.layer.shadowRadius = 3
            dotView.layer.shadowOffset = .zero
        } else {
            dotView.layer.shadowColor = UIColor.clear.cgColor
            dotView.layer.shadowOpacity = 0
            dotView.layer.shadowRadius = 0
        }
    }
}

enum TerminalTabStrip {
    struct Item: Identifiable {
        let id: UUID
        var title: String
        /// Shown when the window's tabs span more than one host.
        var hostName: String?
        var controller: TerminalSessionController?
        var isActive: Bool
        /// Auxiliary tabs carry their mark in the title and no tally dot.
        var isAuxiliary = false
    }

}
