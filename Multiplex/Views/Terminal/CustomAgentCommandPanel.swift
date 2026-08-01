import Foundation
import Observation
import UIKit

/// Stable, ID-addressed editor state. UIKit text views can deliver a final
/// delegate write while a deleted or reordered row is leaving the hierarchy;
/// resolving that write by ID makes it a safe no-op instead of editing the row
/// that moved into the old array position.
@MainActor
@Observable
final class CustomAgentCommandDrafts {
    private(set) var commands: [CustomAgentCommand]

    init(commands: [CustomAgentCommand]) {
        self.commands = commands
    }

    func command(id: UUID) -> CustomAgentCommand? {
        commands.first(where: { $0.id == id })
    }

    func update(_ updated: CustomAgentCommand, id: UUID) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        var stable = updated
        stable.id = id
        commands[index] = stable
    }

    @discardableResult
    func appendBlank() -> CustomAgentCommand {
        let command = CustomAgentCommand(content: "")
        commands.append(command)
        return command
    }

    func move(id: UUID, offset: Int) {
        guard let source = commands.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard commands.indices.contains(destination) else { return }
        commands.swapAt(source, destination)
    }

    func remove(id: UUID) {
        commands.removeAll { $0.id == id }
    }
}

/// Native TALLY editor for one agent's built-in placement and custom helper
/// commands. The controller owns the complete draft transaction: CANCEL (or
/// an outside popover dismissal) discards it, while DONE normalizes exactly
/// once before handing the result to the host configuration.
@MainActor
final class CustomAgentCommandPanelViewController: UIViewController {
    nonisolated static let preferredWidth: CGFloat = 500
    nonisolated static let maximumEditorHeight: CGFloat = 430
    /// Below the footer legend's own resistance (see `legendRow`), so a
    /// shortened popover spends the scroll viewport before any chrome.
    private static let listHeightPriority = UILayoutPriority(650)

    let agent: AgentKind
    private(set) var panelWidth: CGFloat
    private(set) var drafts: CustomAgentCommandDrafts
    private(set) var builtInPlacementOverrides: [String: AgentCommandPlacement]
    private(set) var isBuiltInExpanded = false

    private var save: (
        [CustomAgentCommand],
        [String: AgentCommandPlacement]
    ) -> Void
    private var cancel: () -> Void

    private let panelView: CustomAgentCommandPanelRootView
    private let rootStack = UIStackView()
    private let listScrollView = UIScrollView()
    private let listStack = UIStackView()
    private var listHeightConstraint: NSLayoutConstraint?
    private var listHeightCeilingConstraint: NSLayoutConstraint?
    private weak var accordionControl: CustomCommandAccordionControl?
    private var rowViews: [UUID: CustomCommandRowView] = [:]
    private var renderedColumnCount = 0
    private var renderedCompactControls: Bool?
    private var rebuildingList = false
    private var listContentExceedsCap = false

    init(
        agent: AgentKind,
        commands: [CustomAgentCommand],
        builtInPlacements: [String: AgentCommandPlacement] = [:],
        width: CGFloat = CustomAgentCommandPanelViewController.preferredWidth,
        save: @escaping (
            [CustomAgentCommand],
            [String: AgentCommandPlacement]
        ) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.agent = agent
        panelWidth = width
        drafts = CustomAgentCommandDrafts(
            commands: commands.isEmpty
                ? [CustomAgentCommand(content: "")]
                : commands
        )
        builtInPlacementOverrides = AgentCommandSet.normalizedPlacementOverrides(
            builtInPlacements,
            for: agent
        )
        self.save = save
        self.cancel = cancel
        panelView = CustomAgentCommandPanelRootView(width: width)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = panelView
        buildView()
        rebuildCommandList()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshListScrollEnabled()
        let columns = builtInColumnCount(for: panelView.bounds.width)
        let compact = usesCompactControls(for: panelView.bounds.width)
        guard !rebuildingList,
              columns != renderedColumnCount || compact != renderedCompactControls
        else { return }
        rebuildCommandList(preservingFocus: true)
    }

    func fittingContentSize(for width: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        let resolvedWidth = width ?? panelWidth
        updateEditorHeight(for: resolvedWidth, notifiesParent: false)
        return panelView.fittingSize(for: resolvedWidth)
    }

    func prepareForRemoval() {
        viewIfLoaded?.endEditing(true)
    }

    // MARK: Testable action boundary

    func resolvedPlacement(for command: AgentCommand) -> AgentCommandPlacement {
        AgentCommandSet.resolvedPlacement(
            for: command.id,
            kind: agent,
            placementOverrides: builtInPlacementOverrides
        ) ?? .more
    }

    func setBuiltInPlacement(
        _ placement: AgentCommandPlacement,
        for command: AgentCommand
    ) {
        guard let stock = AgentCommandSet.defaultPlacement(
            for: command.id,
            kind: agent
        ) else { return }
        if placement == stock {
            builtInPlacementOverrides.removeValue(forKey: command.id)
        } else {
            builtInPlacementOverrides[command.id] = placement
        }
    }

    func toggleBuiltInCommands() {
        isBuiltInExpanded.toggle()
        let changes: () -> Void = { [weak self] in
            self?.rebuildCommandList(preservingFocus: true)
        }
        if UIAccessibility.isReduceMotionEnabled {
            changes()
        } else {
            UIView.transition(
                with: listScrollView,
                duration: 0.3,
                options: [.transitionCrossDissolve, .allowAnimatedContent],
                animations: changes
            )
        }
    }

    @discardableResult
    func addCommand(focus: Bool = true) -> CustomAgentCommand {
        let command = drafts.appendBlank()
        rebuildCommandList()
        if focus {
            DispatchQueue.main.async { [weak self] in
                self?.rowViews[command.id]?.focusEditor()
            }
        }
        return command
    }

    func moveCommand(id: UUID, offset: Int) {
        guard drafts.command(id: id) != nil else { return }
        drafts.move(id: id, offset: offset)
        rebuildCommandList(preservingFocus: true)
    }

    func deleteCommand(id: UUID) {
        // Only the deleted row hands back its editor. Another row being typed
        // into keeps the keyboard and its caret across the rebuild, and because
        // focus is restored by command UUID it can never land on whichever row
        // slid into the deleted one's position.
        rowViews[id]?.resignEditor()
        drafts.remove(id: id)
        rebuildCommandList(preservingFocus: true)
    }

    func updateCommand(_ command: CustomAgentCommand) {
        drafts.update(command, id: command.id)
    }

    func saveDrafts() {
        save(
            CustomAgentCommand.normalized(drafts.commands),
            AgentCommandSet.normalizedPlacementOverrides(
                builtInPlacementOverrides,
                for: agent
            )
        )
    }

    func cancelDrafts() {
        cancel()
    }

    // MARK: Construction

    private func buildView() {
        panelView.backgroundColor = UIKitChassis.bezel
        panelView.tallyBorderColor = UIKitChassis.bezelHi

        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 0
        panelView.install(rootStack: rootStack)

        rootStack.addArrangedSubview(makeHeader())
        rootStack.addArrangedSubview(divider())
        rootStack.addArrangedSubview(makeCommandList())
        rootStack.addArrangedSubview(divider())
        rootStack.addArrangedSubview(makeFooter())
    }

    private func makeHeader() -> UIView {
        let title = UIKitChassisLabel("COMMAND SETUP", size: 13)
        title.accessibilityTraits.insert(.header)
        title.accessibilityIdentifier = "customCommands.title"
        let agentLabel = UIKitChassisLabel(
            agent.displayName,
            size: 9,
            color: TallyPalette.customCommand
        )
        agentLabel.accessibilityIdentifier = "customCommands.agent"
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [title, spacer, agentLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 12

        let description = UILabel()
        description.text = "Place each built-in in Bar or More. Custom content may span "
            + "many lines; turn Submit off to leave it ready to edit."
        description.font = UIKitChassis.uiFont(11)
        description.textColor = UIKitChassis.signal2
        description.numberOfLines = 0
        description.accessibilityIdentifier = "customCommands.description"

        let stack = UIStackView(arrangedSubviews: [titleRow, description])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 20,
            leading: 14,
            bottom: 14,
            trailing: 14
        )
        return stack
    }

    private func makeCommandList() -> UIView {
        listScrollView.backgroundColor = UIKitChassis.bezelHi
        listScrollView.alwaysBounceVertical = false
        listScrollView.showsVerticalScrollIndicator = true
        listScrollView.accessibilityIdentifier = "customCommands.scroll"

        listStack.axis = .vertical
        listStack.alignment = .fill
        listStack.spacing = 1
        listStack.accessibilityIdentifier = "customCommands.list"

        listScrollView.addSubview(listStack)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(
                equalTo: listScrollView.contentLayoutGuide.leadingAnchor,
                constant: 12
            ),
            listStack.trailingAnchor.constraint(
                equalTo: listScrollView.contentLayoutGuide.trailingAnchor,
                constant: -12
            ),
            listStack.topAnchor.constraint(
                equalTo: listScrollView.contentLayoutGuide.topAnchor,
                constant: 12
            ),
            listStack.bottomAnchor.constraint(
                equalTo: listScrollView.contentLayoutGuide.bottomAnchor,
                constant: -12
            ),
            listStack.widthAnchor.constraint(
                equalTo: listScrollView.frameLayoutGuide.widthAnchor,
                constant: -24
            ),
        ])
        // The viewport's height is a ceiling that must hold and a resting
        // height that may give way. UIKit shortens an anchored popover above a
        // docked keyboard, and the SwiftUI panel this replaced spelled the same
        // rule `.frame(minHeight: 0, idealHeight:, maxHeight:)`: only the list
        // contracts, so the header and the ADD/CANCEL/DONE footer stay on
        // screen instead of being clipped out of reach.
        let ceiling = listScrollView.heightAnchor.constraint(
            lessThanOrEqualToConstant: 0
        )
        ceiling.identifier = "customCommands.listHeightCeiling"
        ceiling.isActive = true
        listHeightCeilingConstraint = ceiling
        // Contracting stops at zero: past that the legend gives way, never the
        // stack's arithmetic.
        listScrollView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 0
        ).isActive = true
        let height = listScrollView.heightAnchor.constraint(equalToConstant: 0)
        height.identifier = "customCommands.listHeight"
        height.priority = Self.listHeightPriority
        height.isActive = true
        listHeightConstraint = height
        return listScrollView
    }

    private func makeFooter() -> UIView {
        let legend = UIStackView(arrangedSubviews: [
            legendRow(
                color: TallyPalette.customCommand,
                text: "Built-ins and custom commands each live in Bar or More; custom Bar labels keep 9 characters."
            ),
            legendRow(
                color: UIKitChassis.signal3,
                text: "Shared keeps one editable command synchronized across Claude Code, Codex, and Pi."
            ),
        ])
        legend.axis = .vertical
        legend.alignment = .fill
        legend.spacing = 6

        let add = UIKitChassisChip(
            "ADD COMMAND",
            systemImage: "plus",
            accessibilityLabel: "Add command",
            action: { [weak self] in self?.addCommand() }
        )
        add.accessibilityIdentifier = "customCommands.add"
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cancel = UIKitChassisChip(
            "CANCEL",
            accessibilityLabel: "Cancel",
            action: { [weak self] in self?.cancelDrafts() }
        )
        cancel.accessibilityIdentifier = "customCommands.cancel"
        let done = UIKitChassisChip(
            "DONE",
            prominent: true,
            accessibilityLabel: "Done",
            action: { [weak self] in self?.saveDrafts() }
        )
        done.accessibilityIdentifier = "customCommands.done"
        for chip in [add, cancel, done] {
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let actions = UIStackView(arrangedSubviews: [add, spacer, cancel, done])
        actions.axis = .horizontal
        actions.alignment = .center
        actions.spacing = 8

        let stack = UIStackView(arrangedSubviews: [legend, actions])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 14,
            leading: 14,
            bottom: 14,
            trailing: 14
        )
        return stack
    }

    private func legendRow(color: UIColor, text: String) -> UIView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        dot.isAccessibilityElement = false

        let label = UILabel()
        label.text = text
        label.font = UIKitChassis.monoFont(8, weight: .medium)
        label.textColor = UIKitChassis.signal2
        label.numberOfLines = 0
        // Above the list viewport's resting height, below required: the legend
        // is the last thing in the panel to give way, and a required floor here
        // would make a popover shorter than the whole panel unsatisfiable.
        label.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)

        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func divider() -> UIView {
        let view = UIView()
        view.backgroundColor = UIKitChassis.bezelHi
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    // MARK: Dynamic list

    private func rebuildCommandList(preservingFocus: Bool = false) {
        guard isViewLoaded, !rebuildingList else { return }
        rebuildingList = true
        defer { rebuildingList = false }

        let focused: (id: UUID, selection: NSRange)? = preservingFocus
            ? rowViews.first(where: { $0.value.isEditing })
                .map { (id: $0.key, selection: $0.value.editorSelection) }
            : nil
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowViews.removeAll()

        let accordion = CustomCommandAccordionControl(
            itemCount: AgentCommandSet.all(for: agent).count,
            expanded: isBuiltInExpanded,
            action: { [weak self] in self?.toggleBuiltInCommands() }
        )
        accordionControl = accordion
        listStack.addArrangedSubview(accordion)

        let width = panelView.bounds.width > 0 ? panelView.bounds.width : panelWidth
        let columns = builtInColumnCount(for: width)
        renderedColumnCount = columns
        if isBuiltInExpanded {
            appendBuiltInGrid(columns: columns)
        }

        listStack.addArrangedSubview(
            CustomCommandSectionHeader(title: "CUSTOM", detail: "ORDERED")
        )

        let compact = usesCompactControls(for: width)
        renderedCompactControls = compact
        for (index, command) in drafts.commands.enumerated() {
            let row = CustomCommandRowView(
                command: command,
                index: index,
                commandCount: drafts.commands.count,
                compactControls: compact,
                changed: { [weak self] command in
                    self?.drafts.update(command, id: command.id)
                    self?.refreshPreferredContentSize()
                },
                move: { [weak self] id, offset in
                    self?.moveCommand(id: id, offset: offset)
                },
                delete: { [weak self] id in
                    self?.deleteCommand(id: id)
                },
                heightChanged: { [weak self] in
                    self?.refreshPreferredContentSize()
                }
            )
            rowViews[command.id] = row
            listStack.addArrangedSubview(row)
        }

        if drafts.commands.isEmpty {
            let empty = UIKitChassisLabel(
                "NO CUSTOM COMMANDS",
                size: 10,
                color: UIKitChassis.signal3
            )
            empty.textAlignment = .center
            empty.backgroundColor = UIKitChassis.chassis
            empty.accessibilityIdentifier = "customCommands.empty"
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
            listStack.addArrangedSubview(empty)
        }

        listStack.layoutIfNeeded()
        refreshPreferredContentSize()
        if let focused {
            DispatchQueue.main.async { [weak self] in
                self?.rowViews[focused.id]?.focusEditor(selection: focused.selection)
            }
        }
    }

    private func appendBuiltInGrid(columns: Int) {
        let commands = AgentCommandSet.all(for: agent)
        var index = 0
        while index < commands.count {
            let slice = Array(commands[index..<min(index + columns, commands.count)])
            let rows = slice.map { command in
                CustomBuiltInCommandRow(
                    command: command,
                    placement: resolvedPlacement(for: command),
                    changed: { [weak self] placement in
                        self?.setBuiltInPlacement(placement, for: command)
                    }
                )
            }
            if rows.count == 1 || columns == 1 {
                listStack.addArrangedSubview(rows[0])
            } else {
                let row = UIStackView(arrangedSubviews: rows)
                row.axis = .horizontal
                row.alignment = .fill
                row.distribution = .fillEqually
                row.spacing = 1
                listStack.addArrangedSubview(row)
            }
            index += columns
        }
    }

    private func builtInColumnCount(for width: CGFloat) -> Int {
        max(0, width - 24) >= 421 ? 2 : 1
    }

    private func usesCompactControls(for width: CGFloat) -> Bool {
        width < 455
    }

    private func updateEditorHeight(
        for width: CGFloat,
        notifiesParent: Bool
    ) {
        guard isViewLoaded else { return }
        let contentWidth = max(1, width - 24)
        listStack.setNeedsLayout()
        listStack.layoutIfNeeded()
        let measured = listStack.systemLayoutSizeFitting(
            CGSize(
                width: contentWidth,
                height: UIView.layoutFittingCompressedSize.height
            ),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height + 24
        let estimate = CGFloat(max(1, drafts.commands.count)) * 102 + 60
        let resolved = min(
            Self.maximumEditorHeight,
            ceil(measured > 24 ? measured : estimate)
        )
        listHeightConstraint?.constant = resolved
        listHeightCeilingConstraint?.constant = resolved
        listContentExceedsCap = measured > Self.maximumEditorHeight
        panelView.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        refreshListScrollEnabled()

        let size = panelView.fittingSize(for: width)
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        if notifiesParent {
            parent?.preferredContentSizeDidChange(forChildContentContainer: self)
        }
    }

    /// The resting height is what the content wants; the frame is what the
    /// popover was given. A contracted viewport has to scroll even when the
    /// content would otherwise have fit.
    private func refreshListScrollEnabled() {
        let contracted = listScrollView.bounds.height + 0.5
            < listScrollView.contentSize.height
        listScrollView.isScrollEnabled = listContentExceedsCap || contracted
    }

    private func refreshPreferredContentSize() {
        updateEditorHeight(for: panelWidth, notifiesParent: true)
    }
}

// MARK: - Native editor components

@MainActor
private final class CustomAgentCommandPanelRootView: UIKitTallyBorderedView {
    private var width: CGFloat
    private weak var rootStack: UIStackView?

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func install(rootStack: UIStackView) {
        self.rootStack = rootStack
        addSubview(rootStack)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var intrinsicContentSize: CGSize {
        fittingSize(for: width)
    }

    func fittingSize(for proposedWidth: CGFloat) -> CGSize {
        guard let rootStack else { return CGSize(width: proposedWidth, height: 0) }
        let measured = rootStack.systemLayoutSizeFitting(
            CGSize(
                width: proposedWidth,
                height: UIView.layoutFittingCompressedSize.height
            ),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: proposedWidth, height: ceil(measured.height))
    }
}

@MainActor
private final class CustomCommandAccordionControl: UIControl {
    private let chevron = UIImageView()
    private let detail = UIKitChassisLabel("", size: 8, color: UIKitChassis.signal3)
    private let action: () -> Void
    private var expanded: Bool

    init(itemCount: Int, expanded: Bool, action: @escaping () -> Void) {
        self.expanded = expanded
        self.action = action
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        accessibilityIdentifier = "customCommands.builtInAccordion"
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Built-in commands"
        accessibilityHint = "Shows placement controls for built-in commands"
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        #if os(visionOS)
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        #endif

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 9 * Theme.typeScale,
                weight: .bold
            )
        )
        chevron.tintColor = UIKitChassis.signal2
        chevron.contentMode = .center
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let title = UIKitChassisLabel("BUILT-IN", size: 9)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setText("\(itemCount) ITEMS · BAR / MORE")
        let row = UIStackView(arrangedSubviews: [chevron, title, spacer, detail])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func pressed() {
        action()
    }

    private func updateState() {
        accessibilityValue = expanded ? "Expanded" : "Collapsed"
        chevron.transform = expanded
            ? CGAffineTransform(rotationAngle: .pi / 2)
            : .identity
    }
}

@MainActor
private final class CustomCommandSectionHeader: UIView {
    init(title: String, detail: String) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        let titleLabel = UIKitChassisLabel(title, size: 9)
        titleLabel.accessibilityTraits.insert(.header)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let detailLabel = UIKitChassisLabel(detail, size: 8, color: UIKitChassis.signal3)
        let row = UIStackView(arrangedSubviews: [titleLabel, spacer, detailLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
private final class CustomBuiltInCommandRow: UIView {
    init(
        command: AgentCommand,
        placement: AgentCommandPlacement,
        changed: @escaping (AgentCommandPlacement) -> Void
    ) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.chassis
        accessibilityIdentifier = "customCommands.builtIn.\(command.id)"

        let label = UILabel()
        label.text = command.label
        label.font = UIKitChassis.monoFont(10, weight: .semibold)
        label.textColor = UIKitChassis.signal2
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        let choice = CustomCommandPlacementChoice(
            selection: placement,
            changed: changed
        )
        choice.accessibilityIdentifier = "customCommands.placement.\(command.id)"
        choice.translatesAutoresizingMaskIntoConstraints = false
        choice.widthAnchor.constraint(equalToConstant: 112).isActive = true

        let row = UIStackView(arrangedSubviews: [label, choice])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

enum CustomCommandChoiceMetrics {
    static let height: CGFloat = 34
    static let seam: CGFloat = 1
    static let selectionAnimationDuration: TimeInterval = 0.14
}

@MainActor
private final class CustomCommandPlacementChoice: UIView {
    private var selection: AgentCommandPlacement
    private let changed: (AgentCommandPlacement) -> Void
    private var segments: [AgentCommandPlacement: CustomCommandChoiceSegment] = [:]

    init(
        selection: AgentCommandPlacement,
        changed: @escaping (AgentCommandPlacement) -> Void
    ) {
        self.selection = selection
        self.changed = changed
        super.init(frame: .zero)
        isAccessibilityElement = false
        backgroundColor = UIKitChassis.bezelHi

        let bar = CustomCommandChoiceSegment(label: "BAR")
        let more = CustomCommandChoiceSegment(label: "MORE")
        segments = [.bar: bar, .more: more]
        bar.addAction(UIAction { [weak self] _ in self?.select(.bar) }, for: .touchUpInside)
        more.addAction(UIAction { [weak self] _ in self?.select(.more) }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [bar, more])
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fillEqually
        row.spacing = CustomCommandChoiceMetrics.seam
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: CustomCommandChoiceMetrics.height),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    private func select(_ placement: AgentCommandPlacement) {
        guard selection != placement else { return }
        selection = placement
        render(animated: true)
        changed(placement)
    }

    private func render(animated: Bool = false) {
        let changes = { [self] in
            for (placement, segment) in segments {
                segment.setSelected(placement == selection)
            }
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.animate(
            withDuration: CustomCommandChoiceMetrics.selectionAnimationDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
            animations: changes
        )
    }
}

@MainActor
private final class CustomCommandChoiceSegment: UIControl {
    private let label: UIKitChassisLabel

    init(label: String) {
        self.label = UIKitChassisLabel(
            label,
            size: 9,
            color: UIKitChassis.signal2
        )
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = label.capitalized
        layer.borderWidth = 1
        #if os(visionOS)
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        #endif
        addSubview(self.label)
        self.label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.label.centerXAnchor.constraint(equalTo: centerXAnchor),
            self.label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setSelected(_ selected: Bool) {
        backgroundColor = selected ? UIKitChassis.bezelHi : UIKitChassis.chassis
        layer.borderColor = (selected ? UIKitChassis.signal2 : UIKitChassis.bezelHi)
            .resolvedColor(with: traitCollection).cgColor
        label.setInk(selected ? UIKitChassis.signal : UIKitChassis.signal2)
        if selected {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        setSelected(accessibilityTraits.contains(.selected))
    }
}

@MainActor
private final class CustomCommandRowView: UIView, UITextViewDelegate {
    private(set) var command: CustomAgentCommand
    private let changed: (CustomAgentCommand) -> Void
    private let heightChanged: () -> Void
    private let editor = CustomCommandTextView()
    private let placementLabel = UIKitChassisLabel(
        "",
        size: 8,
        color: UIKitChassis.signal3
    )
    private var textHeightConstraint: NSLayoutConstraint?

    var isEditing: Bool { editor.isFirstResponder }

    init(
        command: CustomAgentCommand,
        index: Int,
        commandCount: Int,
        compactControls: Bool,
        changed: @escaping (CustomAgentCommand) -> Void,
        move: @escaping (UUID, Int) -> Void,
        delete: @escaping (UUID) -> Void,
        heightChanged: @escaping () -> Void
    ) {
        self.command = command
        self.changed = changed
        self.heightChanged = heightChanged
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.chassis
        accessibilityIdentifier = "customCommands.row.\(command.id.uuidString)"

        let number = UILabel()
        number.text = String(format: "%02d", index + 1)
        number.font = UIKitChassis.monoFont(9, weight: .semibold)
        number.textColor = UIKitChassis.signal3
        number.textAlignment = .left
        number.translatesAutoresizingMaskIntoConstraints = false
        number.widthAnchor.constraint(equalToConstant: 18).isActive = true

        editor.text = command.content
        editor.font = UIKitChassis.monoFont(11)
        editor.textColor = UIKitChassis.signal
        editor.backgroundColor = UIKitChassis.screen
        editor.tintColor = UIKitChassis.signal
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.smartDashesType = .no
        editor.smartQuotesType = .no
        editor.smartInsertDeleteType = .no
        editor.delegate = self
        editor.accessibilityLabel = "Command content"
        editor.accessibilityIdentifier = "customCommands.content.\(command.id.uuidString)"
        editor.layer.borderWidth = 1
        editor.layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
        let textHeight = editor.heightAnchor.constraint(
            equalToConstant: editor.requiredHeight()
        )
        textHeight.isActive = true
        textHeightConstraint = textHeight

        let firstLine = UIStackView(arrangedSubviews: [number, editor])
        firstLine.axis = .horizontal
        firstLine.alignment = .top
        firstLine.spacing = 10

        let switches = UIStackView(arrangedSubviews: [
            makeSwitch(
                label: "SUBMIT",
                accessibilityLabel: "Auto Submit",
                value: command.autoSubmit,
                keyPath: \.autoSubmit
            ),
            makeSwitch(
                label: "BAR",
                accessibilityLabel: "Show in Bar",
                value: command.showInBar,
                keyPath: \.showInBar
            ),
            makeSwitch(
                label: "SHARED",
                accessibilityLabel: "Shared across Claude Code, Codex, and Pi",
                value: command.shared,
                keyPath: \.shared
            ),
        ])
        switches.axis = .horizontal
        switches.alignment = .center
        switches.spacing = 8
        switches.setContentHuggingPriority(.required, for: .horizontal)

        let up = CustomCommandRowActionButton(
            systemImage: "arrow.up",
            accessibilityLabel: "Move command up",
            enabled: index > 0,
            action: { move(command.id, -1) }
        )
        up.accessibilityIdentifier = "customCommands.moveUp.\(command.id.uuidString)"
        let down = CustomCommandRowActionButton(
            systemImage: "arrow.down",
            accessibilityLabel: "Move command down",
            enabled: index < commandCount - 1,
            action: { move(command.id, 1) }
        )
        down.accessibilityIdentifier = "customCommands.moveDown.\(command.id.uuidString)"
        let trash = CustomCommandRowActionButton(
            systemImage: "trash",
            accessibilityLabel: "Delete command",
            enabled: true,
            action: { delete(command.id) }
        )
        trash.accessibilityIdentifier = "customCommands.delete.\(command.id.uuidString)"
        let actions = UIStackView(arrangedSubviews: [up, down, trash])
        actions.axis = .horizontal
        actions.alignment = .center
        actions.spacing = 8
        actions.setContentHuggingPriority(.required, for: .horizontal)

        refreshPlacementLabel()
        placementLabel.setContentHuggingPriority(.required, for: .horizontal)
        let controls: UIView
        if compactControls {
            let lowerSpacer = UIView()
            lowerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let lower = UIStackView(arrangedSubviews: [
                placementLabel, lowerSpacer, actions,
            ])
            lower.axis = .horizontal
            lower.alignment = .center
            lower.spacing = 8
            let stack = UIStackView(arrangedSubviews: [switches, lower])
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            lower.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            controls = stack
        } else {
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = UIStackView(arrangedSubviews: [
                switches, spacer, placementLabel, actions,
            ])
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            controls = stack
        }

        let controlInset = UIView()
        controlInset.addSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: controlInset.leadingAnchor, constant: 28),
            controls.trailingAnchor.constraint(equalTo: controlInset.trailingAnchor),
            controls.topAnchor.constraint(equalTo: controlInset.topAnchor),
            controls.bottomAnchor.constraint(equalTo: controlInset.bottomAnchor),
        ])

        let content = UIStackView(arrangedSubviews: [firstLine, controlInset])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 9
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        editor.updatePlaceholderVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    var editorSelection: NSRange { editor.selectedRange }

    func focusEditor(selection: NSRange? = nil) {
        editor.becomeFirstResponder()
        guard let selection,
              selection.location + selection.length <= (editor.text as NSString).length
        else { return }
        editor.selectedRange = selection
    }

    func resignEditor() {
        editor.resignFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        command.content = textView.text
        editor.updatePlaceholderVisibility()
        changed(command)
        refreshPlacementLabel()
        refreshTextHeight()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        editor.updatePlaceholderVisibility()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        editor.updatePlaceholderVisibility()
    }

    private func makeSwitch(
        label: String,
        accessibilityLabel: String,
        value: Bool,
        keyPath: WritableKeyPath<CustomAgentCommand, Bool>
    ) -> UIView {
        CustomCommandSwitch(
            label: label,
            accessibilityLabel: accessibilityLabel,
            isOn: value,
            changed: { [weak self] value in
                guard let self else { return }
                self.command[keyPath: keyPath] = value
                self.changed(self.command)
                self.refreshPlacementLabel()
            }
        )
    }

    private func refreshPlacementLabel() {
        let barLabel = command.barLabel
        let text = switch (command.shared, command.showInBar) {
        case (true, true): "ALL · \(barLabel ?? "EMPTY")"
        case (true, false): "ALL · MORE"
        case (false, true): "BAR · \(barLabel ?? "EMPTY")"
        case (false, false): "MORE"
        }
        placementLabel.setText(text)
        placementLabel.setInk(
            command.showInBar ? TallyPalette.customCommand : UIKitChassis.signal3
        )
    }

    private func refreshTextHeight() {
        let height = editor.requiredHeight()
        guard textHeightConstraint?.constant != height else { return }
        textHeightConstraint?.constant = height
        heightChanged()
    }
}

@MainActor
private final class CustomCommandTextView: UITextView {
    private let placeholderLabel = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textContainerInset = UIEdgeInsets(top: 9, left: 5, bottom: 9, right: 5)
        self.textContainer.lineFragmentPadding = 4
        isScrollEnabled = false

        placeholderLabel.text = "Command content"
        placeholderLabel.font = UIKitChassis.monoFont(11)
        placeholderLabel.textColor = UIKitChassis.signal3
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func requiredHeight() -> CGFloat {
        let lineHeight = font?.lineHeight ?? UIKitChassis.monoFont(11).lineHeight
        let minimum = ceil(lineHeight * 2 + 18)
        let maximum = ceil(lineHeight * 5 + 18)
        let fitting = sizeThatFits(CGSize(width: max(bounds.width, 260), height: .greatestFiniteMagnitude))
        let height = min(max(ceil(fitting.height), minimum), maximum)
        isScrollEnabled = fitting.height > maximum
        return height
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The controller remeasures on delegate changes; layout handles the
        // first pass when the final row width becomes known.
        let needed = requiredHeight()
        if let height = constraints.first(where: {
            $0.firstAttribute == .height && $0.relation == .equal
        }), abs(height.constant - needed) >= 0.5 {
            height.constant = needed
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
    }
}

@MainActor
private final class CustomCommandSwitch: UIControl {
    private let track = CustomCommandSwitchTrack()
    private let caption: UIKitChassisLabel
    private var isOn: Bool
    private let changed: (Bool) -> Void

    init(
        label: String,
        accessibilityLabel: String,
        isOn: Bool,
        changed: @escaping (Bool) -> Void
    ) {
        self.isOn = isOn
        self.changed = changed
        caption = UIKitChassisLabel(
            label,
            size: 8,
            color: isOn ? UIKitChassis.signal : UIKitChassis.signal2
        )
        super.init(frame: .zero)
        isAccessibilityElement = true
        // The SwiftUI row was a real `Toggle`; `.toggleButton` is UIKit's
        // equivalent identity, so the switch rotor and the spoken On/Off
        // state survive the port.
        accessibilityTraits = [.button, .toggleButton]
        self.accessibilityLabel = accessibilityLabel
        accessibilityIdentifier = "customCommands.switch.\(label.lowercased())"
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        #if os(visionOS)
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        #endif

        let row = UIStackView(arrangedSubviews: [track, caption])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 7
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func pressed() {
        isOn.toggle()
        render(animated: true)
        changed(isOn)
    }

    private func render(animated: Bool = false) {
        track.setOn(isOn, animated: animated)
        caption.setInk(isOn ? UIKitChassis.signal : UIKitChassis.signal2)
        accessibilityValue = isOn ? "On" : "Off"
        if isOn {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }
}

@MainActor
private final class CustomCommandSwitchTrack: UIKitTallyBorderedView {
    private let thumb = UIView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 14),
        ])
        thumb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumb)
        leading = thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3)
        trailing = thumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 8),
            thumb.heightAnchor.constraint(equalToConstant: 8),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading,
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setOn(_ on: Bool, animated: Bool = false) {
        leading.isActive = false
        trailing.isActive = false
        (on ? trailing : leading).isActive = true
        let apply = {
            self.backgroundColor = on ? UIKitChassis.bezelHi : UIKitChassis.screen
            self.thumb.backgroundColor = on ? UIKitChassis.signal : UIKitChassis.signal3
            self.tallyBorderColor = on ? UIKitChassis.signal2 : UIKitChassis.bezelHi
            // The swapped constraint only moves the thumb inside an animation
            // transaction if the layout pass runs there too.
            self.layoutIfNeeded()
        }
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.animate(
            withDuration: CustomCommandChoiceMetrics.selectionAnimationDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState],
            animations: apply
        )
    }
}

@MainActor
private final class CustomCommandRowActionButton: UIButton {
    private let action: () -> Void

    init(
        systemImage: String,
        accessibilityLabel: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) {
        self.action = action
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.chassis
        layer.borderWidth = 1
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
        setImage(
            UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 9 * Theme.typeScale,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        tintColor = enabled ? UIKitChassis.signal2 : UIKitChassis.signal3
        isEnabled = enabled
        self.accessibilityLabel = accessibilityLabel
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 25),
            heightAnchor.constraint(equalToConstant: 23),
        ])
        #if os(visionOS)
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func pressed() {
        action()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
    }
}
