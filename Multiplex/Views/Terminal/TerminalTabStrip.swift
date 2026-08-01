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

        var cells: [Cell]
    }

    private(set) var cells: [TerminalTabCell] = []

    private let stackView = UIStackView()
    private var items: [TerminalTabStrip.Item] = []
    private var allowsSplit = true
    private var activate: (UUID) -> Void = { _ in }
    private var split: (UUID) -> Void = { _ in }
    private var close: (UUID) -> Void = { _ in }
    private var configurationGeneration = 0
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
    func fittingContentSize() -> CGSize {
        let fitted = stackView.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
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
        renderedKey = key

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
    let tallyState: TerminalTabTallyState
    private(set) var dotView: UIView?
    private(set) var sourceLabel: UIKitChassisLabel

    private let activate: () -> Void
    private let makeMenu: () -> UIMenu
    private let split: () -> Void
    private let close: () -> Void
    private let canSplit: Bool
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
        sourceLabel = UIKitChassisLabel(
            item.hostName.map { "\(item.title) · \($0)" } ?? item.title,
            size: 10,
            color: item.isActive ? UIKitChassis.signal : UIKitChassis.signal2
        )
        super.init(frame: .zero)

        backgroundColor = item.isActive ? UIKitChassis.bezelHi : UIKitChassis.chassis
        layer.borderWidth = 1
        refreshBorderAndLamp()
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 3))
        isContextMenuInteractionEnabled = true

        isAccessibilityElement = true
        accessibilityTraits = item.isActive ? [.button, .selected] : .button
        accessibilityLabel = "\(item.title) tab\(item.isActive ? ", active" : "")"
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

    override var intrinsicContentSize: CGSize {
        let content = contentStack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(
            width: ceil(content.width + Self.horizontalInset * 2),
            height: ceil(content.height + Self.verticalInset * 2)
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
