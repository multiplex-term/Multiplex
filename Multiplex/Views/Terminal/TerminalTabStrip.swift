import Observation
import UIKit

/// UIKit tab strip rendered in the window's multiviewer source-label voice:
/// square cells in compressed caps, each with its own tally dot.
@MainActor
final class TerminalTabStripView: UIView {
    static let cellSpacing: CGFloat = 4

    /// Closures deliberately stay out of the key: retained cells route every
    /// action through this view, whose callback properties `apply` refreshes.
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
    private var items: [TerminalTabStrip.Item] = []
    private var allowsSplit = true
    private var activate: (UUID) -> Void = { _ in }
    private var split: (UUID) -> Void = { _ in }
    private var close: (UUID) -> Void = { _ in }
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
        close: @escaping (UUID) -> Void
    ) {
        self.items = items
        self.allowsSplit = allowsSplit
        self.activate = activate
        self.split = split
        self.close = close
        accessibilityLabel = "\(items.count) tabs"

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

    func menu(for id: UUID) -> UIMenu {
        var actions: [UIMenuElement] = []
        if canSplit(id: id) {
            actions.append(UIAction(
                title: "Move to New Window",
                image: UIImage(systemName: "macwindow.badge.plus")
            ) { [weak self] _ in
                self?.splitTab(id: id)
            })
        }
        actions.append(UIAction(
            title: "Close Tab",
            image: UIImage(systemName: "xmark"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.closeTab(id: id)
        })
        return UIMenu(children: actions)
    }

    private func canSplit(id: UUID) -> Bool {
        allowsSplit && items.count > 1 && items.contains(where: { $0.id == id })
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

        // A cell is a UIControl a finger can already be tracking, and this
        // strip re-renders on every observed status change (a ~5 s host probe
        // is enough) and on every tab switch. Destroying and recreating the
        // cells there cancels that in-flight touch, which is what makes a tab
        // press read as dead. Nothing structural moved, so mutate in place.
        if previousStructure == key.structure,
           cells.count == key.cells.count,
           items.count == key.cells.count {
            for index in key.cells.indices {
                cells[index].update(
                    item: items[index],
                    tallyState: states[index],
                    canSplit: key.cells[index].canSplit
                )
            }
            invalidateIntrinsicContentSize()
            requestHostSizingPass()
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
                canSplit: canSplit(id: item.id)
            )
            stackView.addArrangedSubview(cell)
            return cell
        }
        invalidateIntrinsicContentSize()
        requestHostSizingPass()
    }

    /// The host sizes this strip from `fittingContentSize()` during ITS OWN
    /// layout pass (the window's `layoutNativeChrome`), and a tally-observed
    /// render can change that size with no bounds change anywhere — nothing
    /// else re-requests the pass, so a stale strip frame would stick until
    /// rotation (user-reported). Dirty the whole ancestor chain so whichever
    /// view the host actually lays out runs again.
    private func requestHostSizingPass() {
        var ancestor: UIView? = self
        while let view = ancestor {
            view.setNeedsLayout()
            ancestor = view.superview
        }
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
final class TerminalTabCell: UIControl {
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
    private var canSplit: Bool
    private var isActive: Bool
    private var labelText: String
    private let contentStack = UIStackView()

    init(
        item: TerminalTabStrip.Item,
        tallyState: TerminalTabTallyState,
        activate: @escaping () -> Void,
        makeMenu: @escaping () -> UIMenu,
        split: @escaping () -> Void,
        close: @escaping () -> Void,
        canSplit: Bool
    ) {
        itemID = item.id
        self.tallyState = tallyState
        self.activate = activate
        self.makeMenu = makeMenu
        self.split = split
        self.close = close
        self.canSplit = canSplit
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
        isContextMenuInteractionEnabled = true

        isAccessibilityElement = true
        accessibilityTraits = Self.traits(isActive: item.isActive)
        accessibilityLabel = Self.accessibilityLabel(for: item)
        accessibilityCustomActions = makeAccessibilityActions()

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

        addTarget(self, action: #selector(pressed), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// In-place refresh for a cell whose identity and anatomy are unchanged.
    /// The control itself survives, so a press already tracking it does too.
    func update(
        item: TerminalTabStrip.Item,
        tallyState: TerminalTabTallyState,
        canSplit: Bool
    ) {
        if self.canSplit != canSplit {
            self.canSplit = canSplit
            accessibilityCustomActions = makeAccessibilityActions()
        }
        if isActive != item.isActive {
            isActive = item.isActive
            backgroundColor = Self.ground(isActive: item.isActive)
            accessibilityTraits = Self.traits(isActive: item.isActive)
            // `UIKitChassisLabel` bakes its ink at init, so an active-ground
            // change swaps the label. The cell — the control under the
            // finger — is untouched.
            labelText = Self.label(for: item)
            replaceSourceLabel(color: Self.ink(isActive: item.isActive))
        } else if labelText != Self.label(for: item) {
            labelText = Self.label(for: item)
            sourceLabel.setText(labelText)
        }
        accessibilityLabel = Self.accessibilityLabel(for: item)
        guard self.tallyState != tallyState else { return }
        self.tallyState = tallyState
        dotView?.backgroundColor = tallyState.color
        refreshLampShadow()
    }

    private func replaceSourceLabel(color: UIColor) {
        let replacement = UIKitChassisLabel(labelText, size: 10, color: color)
        replacement.isAccessibilityElement = false
        if let index = contentStack.arrangedSubviews.firstIndex(of: sourceLabel) {
            contentStack.insertArrangedSubview(replacement, at: index)
        } else {
            contentStack.addArrangedSubview(replacement)
        }
        contentStack.removeArrangedSubview(sourceLabel)
        sourceLabel.removeFromSuperview()
        sourceLabel = replacement
    }

    private static func label(for item: TerminalTabStrip.Item) -> String {
        item.hostName.map { "\(item.title) · \($0)" } ?? item.title
    }

    private static func accessibilityLabel(for item: TerminalTabStrip.Item) -> String {
        "\(item.title) tab\(item.isActive ? ", active" : "")"
    }

    private static func ink(isActive: Bool) -> UIColor {
        isActive ? UIKitChassis.signal : UIKitChassis.signal2
    }

    private static func ground(isActive: Bool) -> UIColor {
        isActive ? UIKitChassis.bezelHi : UIKitChassis.chassis
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

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: itemID as NSUUID, previewProvider: nil) {
            [makeMenu] _ in makeMenu()
        }
    }

    private func makeAccessibilityActions() -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if canSplit {
            actions.append(UIAccessibilityCustomAction(
                name: "Move to New Window",
                actionHandler: { [weak self] _ in
                    self?.split()
                    return self != nil
                }
            ))
        }
        actions.append(UIAccessibilityCustomAction(
            name: "Close Tab",
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
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
        dotView?.backgroundColor = tallyState.color
        refreshLampShadow()
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
        var hostName: String? = nil
        var controller: TerminalSessionController?
        var isActive: Bool
        /// Auxiliary tabs carry their mark in the title and no tally dot.
        var isAuxiliary = false
    }

}
