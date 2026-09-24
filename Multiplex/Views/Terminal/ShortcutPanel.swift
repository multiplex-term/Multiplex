import UIKit

/// UIKit implementation of the custom TALLY dropdown shared by the iPad key
/// rail and the visionOS UMD, rendering one backend's `ShortcutPanelContent`
/// (TMUX or HRDR). Commands live in a compact square grid with the human
/// label, command reference, and stock binding; the system Menu row treatment
/// is deliberately not involved.
@MainActor
final class ShortcutPanelViewController: UIViewController {
    nonisolated static let preferredWidth: CGFloat =
        402 + 2 * UIKitChassis.popoverPanelInset
    nonisolated static let confirmationWindow: UInt64 = 2_000_000_000
    /// Long enough for a prefix binding to reach tmux/herdr and change the
    /// active window before the panel re-reads the list.
    nonisolated static let choiceRefreshDelay: UInt64 = 600_000_000

    private let content: ShortcutPanelContent
    private var panelWidth: CGFloat
    private var select: (ShortcutPanelItem) -> Void
    private var selectCoarse: ((ShortcutPanelItem) -> Void)?
    private var rename: ((ShortcutPanelItem, String) -> Void)?
    private var loadChoices: (() async -> [TmuxWindowChoice]?)?
    private var selectChoice: ((TmuxWindowChoice) -> Void)?
    /// The last loaded switch list, kept even when too short to render a
    /// section: the rename field prefills from its active row's name.
    private var latestChoices: [TmuxWindowChoice] = []

    private let panelView: ShortcutPanelRootView
    private let contentStack = UIStackView()
    private let switchSection = UIStackView()
    private var itemButtons: [String: ShortcutItemButton] = [:]
    private var choiceButtons: [ShortcutChoiceButton] = []
    private var choiceLoadTask: Task<Void, Never>?
    private var choiceRefreshTask: Task<Void, Never>?
    private var disarmTask: Task<Void, Never>?
    private var armedItemID: String?
    private var didRequestChoices = false

    init(
        content: ShortcutPanelContent,
        width: CGFloat = ShortcutPanelViewController.preferredWidth,
        select: @escaping (ShortcutPanelItem) -> Void,
        selectCoarse: ((ShortcutPanelItem) -> Void)? = nil,
        rename: ((ShortcutPanelItem, String) -> Void)? = nil,
        loadChoices: (() async -> [TmuxWindowChoice]?)? = nil,
        selectChoice: ((TmuxWindowChoice) -> Void)? = nil
    ) {
        self.content = content
        panelWidth = width
        self.select = select
        self.selectCoarse = selectCoarse
        self.rename = rename
        self.loadChoices = loadChoices
        self.selectChoice = selectChoice
        panelView = ShortcutPanelRootView(width: width)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = panelView.intrinsicContentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = panelView
        buildContent()
        refreshPreferredContentSize()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        requestChoicesIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        disarm()
        choiceLoadTask?.cancel()
        choiceLoadTask = nil
        choiceRefreshTask?.cancel()
        choiceRefreshTask = nil
    }

    /// The view controller owns an intrinsic height so UIKit popovers follow
    /// the grid instead of a tall keyboard-adjusted proposal.
    func fittingContentSize(for width: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        return panelView.fittingSize(for: width ?? panelWidth)
    }

    /// Internal by design: it is the single render path used by the async
    /// loader and by UIKit-focused tests. A single window/workspace has no
    /// useful switch action and therefore earns no section.
    func applyChoices(_ choices: [TmuxWindowChoice]) {
        latestChoices = choices
        choiceButtons = []
        switchSection.arrangedSubviews.forEach {
            switchSection.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        guard choices.count > 1 else {
            switchSection.isHidden = true
            refreshPreferredContentSize()
            return
        }

        let title = UIKitChassisLabel(
            content.switchSectionTitle,
            size: 9,
            color: UIKitChassis.signal2
        )
        title.accessibilityTraits.insert(.header)
        title.accessibilityIdentifier =
            "\(content.switchSectionAccessibilityIdentifier).title"
        switchSection.addArrangedSubview(title)

        let grid = makeChoiceGrid(choices)
        if choices.count > 8 {
            let scrollView = UIScrollView()
            scrollView.backgroundColor = UIKitChassis.bezelHi
            scrollView.showsVerticalScrollIndicator = true
            scrollView.alwaysBounceVertical = false
            scrollView.accessibilityIdentifier =
                "\(content.switchSectionAccessibilityIdentifier).scroll"
            scrollView.addSubview(grid)
            grid.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                grid.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                grid.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                grid.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                grid.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                grid.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
                scrollView.heightAnchor.constraint(equalToConstant: 200),
            ])
            switchSection.addArrangedSubview(scrollView)
        } else {
            switchSection.addArrangedSubview(grid)
        }

        switchSection.isHidden = false
        refreshPreferredContentSize()
    }

    private func buildContent() {
        // PROTOTYPE(GLASS): the popover root's smoke is the one ground —
        // a bezel wash here lightened the panel and crushed contrast.
        panelView.backgroundColor = GlassPrototype.clearedBezel
        panelView.tallyBorderColor = UIKitChassis.bezelHi

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 12
        panelView.install(contentStack: contentStack)

        contentStack.addArrangedSubview(makeHeader())
        for section in content.sections {
            contentStack.addArrangedSubview(makeShortcutSection(section))
        }

        switchSection.axis = .vertical
        switchSection.alignment = .fill
        switchSection.spacing = 6
        switchSection.isHidden = true
        switchSection.accessibilityIdentifier =
            content.switchSectionAccessibilityIdentifier
        contentStack.addArrangedSubview(switchSection)
    }

    private func makeHeader() -> UIView {
        let prefix = UIKitChassisMonoLabel(
            content.prefixLabel,
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal2,
            kern: 0.8
        )
        return TallyPanelHeader.make(title: content.headerTitle, trailing: prefix)
    }

    private func makeShortcutSection(_ section: ShortcutPanelSection) -> UIView {
        let title = UIKitChassisLabel(
            section.title,
            size: 9,
            color: UIKitChassis.signal2
        )
        title.accessibilityTraits.insert(.header)
        title.accessibilityIdentifier = section.accessibilityIdentifier

        let grid: UIView
        if section.usesCompactRow {
            grid = makeCompactRow(section.items)
        } else {
            grid = TallyHairlineGrid.grid(
                section.items.map { item in
                    let button = ShortcutItemButton(item: item)
                    button.addTarget(self, action: #selector(itemPressed(_:)), for: .touchUpInside)
                    itemButtons[item.id] = button
                    return button
                },
                columns: 2
            )
        }

        let stack = UIStackView(arrangedSubviews: [title, grid])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        return stack
    }

    /// One row of equal square symbol buttons — the resize directions. A tap
    /// routes through the same `activate` path as the grid rows; a hold goes
    /// coarse and repeats until release. Both leave the panel up.
    private func makeCompactRow(_ items: [ShortcutPanelItem]) -> UIView {
        TallyHairlineGrid.grid(
            items.map { item in
                let button = ShortcutCompactItemButton(item: item)
                button.onTap = { [weak self] in self?.activate(item) }
                button.onHoldStep = { [weak self] in
                    guard let self else { return }
                    disarm()
                    (selectCoarse ?? select)(item)
                }
                return button
            },
            columns: max(items.count, 1)
        )
    }

    private func makeChoiceGrid(_ choices: [TmuxWindowChoice]) -> UIView {
        choiceButtons = choices.map { choice in
            let button = ShortcutChoiceButton(
                choice: choice,
                noun: content.switchNoun,
                accessibilityPrefix: content.switchChoiceAccessibilityPrefix
            )
            button.addTarget(self, action: #selector(choicePressed(_:)), for: .touchUpInside)
            return button
        }
        return TallyHairlineGrid.grid(choiceButtons, columns: 2)
    }

    @objc private func itemPressed(_ sender: ShortcutItemButton) {
        activate(sender.item)
    }

    /// Switching does not dismiss the panel — the list is a switchboard, and
    /// hopping between windows/workspaces should not cost a reopen. The rows
    /// re-mark ACTIVE in place so the panel keeps telling the truth without a
    /// reload round-trip against the switch that is still in flight.
    @objc private func choicePressed(_ sender: ShortcutChoiceButton) {
        disarm()
        let choice = sender.choice
        for button in choiceButtons {
            button.setActive(button.choice.id == choice.id)
        }
        selectChoice?(choice)
    }

    private func activate(_ item: ShortcutPanelItem) {
        if item.promptsForName {
            disarm()
            return presentRenamePrompt(for: item)
        }
        guard item.requiresDoubleActivation else {
            disarm()
            select(item)
            scheduleChoiceRefreshIfPanelStays(item)
            return
        }

        if armedItemID == item.id {
            disarm()
            select(item)
            scheduleChoiceRefreshIfPanelStays(item)
            return
        }

        disarmTask?.cancel()
        setArmedItemID(item.id)
        disarmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.confirmationWindow)
            guard !Task.isCancelled, self?.armedItemID == item.id else { return }
            self?.setArmedItemID(nil)
            self?.disarmTask = nil
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        disarmTask = nil
        setArmedItemID(nil)
    }

    private func setArmedItemID(_ id: String?) {
        armedItemID = id
        for (candidate, button) in itemButtons {
            button.setArmed(candidate == id)
        }
    }

    /// The rename field, hosted by the panel so both platforms share one
    /// implementation. Prefilled with the active window's name from the
    /// already-loaded switch list; the panel stays up and re-reads the
    /// list once the rename lands.
    private func presentRenamePrompt(for item: ShortcutPanelItem) {
        let alert = UIAlertController(
            title: item.title, message: nil, preferredStyle: .alert
        )
        alert.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        let activeName = latestChoices.first(where: \.isActive)?.name
        alert.addTextField { field in
            field.text = activeName
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        let commit = UIAlertAction(
            title: String(localized: "Rename"), style: .default
        ) { [weak self, weak alert] _ in
            self?.confirmRename(item, to: alert?.textFields?.first?.text ?? "")
        }
        alert.addAction(commit)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    /// The rename field's commit — internal so UIKit-focused tests can
    /// drive it without presenting the alert (a scene-less test panel
    /// cannot present). An all-whitespace name declines like tmux's own
    /// prompt declines an empty one.
    func confirmRename(_ item: ShortcutPanelItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        rename?(item, trimmed)
        scheduleChoiceRefresh()
    }

    /// Next / Previous Window may have moved the very window the switch list
    /// marks ACTIVE while the panel stays up. The command runs remotely, so
    /// re-read the list once it has landed rather than guess the destination.
    /// Rows that stay put (zoom and resize) never pay the round trip.
    private func scheduleChoiceRefreshIfPanelStays(_ item: ShortcutPanelItem) {
        guard item.invalidatesSwitchChoices else { return }
        scheduleChoiceRefresh()
    }

    private func scheduleChoiceRefresh() {
        guard let loadChoices else { return }
        choiceRefreshTask?.cancel()
        choiceRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.choiceRefreshDelay)
            guard !Task.isCancelled else { return }
            let choices = await loadChoices() ?? []
            guard !Task.isCancelled else { return }
            self?.applyChoices(choices)
            self?.choiceRefreshTask = nil
        }
    }

    private func requestChoicesIfNeeded() {
        guard !didRequestChoices, let loadChoices else { return }
        didRequestChoices = true
        choiceLoadTask = Task { @MainActor [weak self] in
            let choices = await loadChoices() ?? []
            guard !Task.isCancelled else { return }
            self?.applyChoices(choices)
            self?.choiceLoadTask = nil
        }
    }

    private func refreshPreferredContentSize() {
        guard isViewLoaded else { return }
        panelView.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let size = panelView.fittingSize(for: panelWidth)
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        parent?.preferredContentSizeDidChange(forChildContentContainer: self)
    }
}

/// Equal-width cells over the 1 pt bezel hairline — the one grid treatment
/// every TALLY panel uses, whether two columns of full rows, one compact
/// row, or the Key Commands grid.
@MainActor
enum TallyHairlineGrid {
    static func grid(_ cells: [UIView], columns: Int) -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.alignment = .fill
        grid.spacing = 1
        grid.backgroundColor = UIKitChassis.bezelHi
        for offset in stride(from: 0, to: cells.count, by: columns) {
            let rowCells = (offset..<offset + columns).map { index -> UIView in
                guard cells.indices.contains(index) else {
                    let filler = UIView()
                    filler.backgroundColor = UIKitChassis.bezelHi
                    filler.isAccessibilityElement = false
                    return filler
                }
                return cells[index]
            }
            grid.addArrangedSubview(row(rowCells))
        }
        return grid
    }

    static func row(_ cells: [UIView]) -> UIView {
        let row = UIStackView(arrangedSubviews: cells)
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fillEqually
        row.spacing = 1
        row.backgroundColor = UIKitChassis.bezelHi
        return row
    }
}

/// A panel's title row: compressed-caps title with the header trait, a
/// spacer, and a trailing readout at the first baseline.
@MainActor
enum TallyPanelHeader {
    static func make(
        title: String,
        trailing: UIView,
        titleIdentifier: String? = nil
    ) -> UIView {
        let titleLabel = UIKitChassisLabel(title, size: 13)
        titleLabel.accessibilityTraits.insert(.header)
        titleLabel.accessibilityIdentifier = titleIdentifier
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [titleLabel, spacer, trailing])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 16

        let container = UIView()
        container.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}

/// Press feedback for the panel's rows: the pressed ground lands at once and
/// fades away. A tap raises and clears the highlight inside one run loop, so
/// clearing it outright drew no frame and only a long press ever looked
/// pressed — the fade starts from the colour the touch already set, which is
/// what makes a quick tap visible.
private let shortcutPressFadeDuration: TimeInterval = 0.25

/// Shared press chassis for every control in a TALLY panel — the shortcut
/// panel's rows and the Key Commands panel's cells and segment cells: the
/// square hover shape, the press wiring, and the fade above. Subclasses
/// supply only their content and, where state changes it, the resting ground.
@MainActor
class ShortcutPressControl: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        addTarget(self, action: #selector(tap), for: .touchDown)
        addTarget(
            self,
            action: #selector(beginPress),
            for: [.touchDown, .touchDragEnter]
        )
        addTarget(
            self,
            action: #selector(endPress),
            for: [.touchCancel, .touchDragExit, .touchUpInside, .touchUpOutside]
        )
        refreshBackground()
    }

    @objc private func tap() {
        TerminalKeyHaptics.keyPress(on: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    // PROTOTYPE(GLASS): rest on strata over the popover's smoke, never
    // opaque chassis.
    var restingBackgroundColor: UIColor { GlassPrototype.strataChassis }

    override var isHighlighted: Bool {
        didSet { refreshBackground(animated: !isHighlighted) }
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    func refreshBackground(animated: Bool = false) {
        let ground = isHighlighted ? UIKitChassis.bezelHi : restingBackgroundColor
        guard animated else { return backgroundColor = ground }
        UIView.animate(withDuration: shortcutPressFadeDuration) {
            self.backgroundColor = ground
        }
    }

    @objc private func beginPress() { isHighlighted = true }
    @objc private func endPress() { isHighlighted = false }
}

/// The measuring, scrolling root every popover-hosted TALLY panel stands on
/// (shortcut panel, Key Commands): its intrinsic size is the content stack
/// measured at `width`, and a panel that changes width (Key Commands' two
/// tabs) sets it and re-measures.
@MainActor
final class ShortcutPanelRootView: UIKitTallyBorderedView {
    var width: CGFloat {
        didSet { invalidateIntrinsicContentSize() }
    }
    private let scrollView = UIScrollView()
    private weak var contentStack: UIStackView?

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
    }

    /// The content lives in a scroll view: `preferredContentSize` asks for
    /// the full grid, but an iPhone popover clamps tall content to the
    /// screen (the herdr set plus a workspace grid overflows one), and a
    /// clamped panel must scroll — never clip rows mid-face.
    func install(contentStack: UIStackView) {
        self.contentStack = contentStack
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = true
        #if !os(visionOS)
        scrollView.keyboardDismissMode = .interactive
        #endif
        addSubview(scrollView)
        scrollView.addSubview(contentStack)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let inset = UIKitChassis.popoverPanelInset
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: inset),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -inset),
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor, constant: inset),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -inset),
            contentStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * inset),
        ])
    }

    override var intrinsicContentSize: CGSize {
        fittingSize(for: width)
    }

    func fittingSize(for proposedWidth: CGFloat) -> CGSize {
        let insets = 2 * UIKitChassis.popoverPanelInset
        guard let contentStack else { return CGSize(width: proposedWidth, height: insets) }
        let contentWidth = max(0, proposedWidth - insets)
        let measured = contentStack.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: proposedWidth, height: ceil(measured.height + insets))
    }
}

@MainActor
private final class ShortcutItemButton: ShortcutPressControl {
    let item: ShortcutPanelItem

    private let titleLabel = UIKitChassisMonoLabel()
    private let commandLabel = UIKitChassisMonoLabel()
    private let bindingLabel = UIKitChassisMonoLabel()
    private let bindingBorder = UIKitTallyBorderedView()
    private var isArmed = false

    init(item: ShortcutPanelItem) {
        self.item = item
        super.init(frame: .zero)
        minimumHeight(48)
        accessibilityIdentifier = item.accessibilityIdentifier

        titleLabel.configure(
            item.title.uppercased(),
            font: UIKitChassis.compressedLabelFont(10),
            color: UIKitChassis.signal,
            kern: 0.8
        )
        commandLabel.configure(
            item.command,
            font: UIKitChassis.monoFont(8),
            color: UIKitChassis.signal2
        )
        commandLabel.lineBreakMode = .byTruncatingTail

        let labels = UIStackView(arrangedSubviews: [titleLabel, commandLabel])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bindingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        bindingLabel.setContentHuggingPriority(.required, for: .horizontal)
        bindingBorder.addSubview(bindingLabel)
        bindingLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bindingLabel.leadingAnchor.constraint(equalTo: bindingBorder.leadingAnchor, constant: 6),
            bindingLabel.trailingAnchor.constraint(equalTo: bindingBorder.trailingAnchor, constant: -6),
            bindingLabel.topAnchor.constraint(equalTo: bindingBorder.topAnchor, constant: 4),
            bindingLabel.bottomAnchor.constraint(equalTo: bindingBorder.bottomAnchor, constant: -4),
        ])

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [labels, spacer, bindingBorder])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setArmed(false)
    }

    func setArmed(_ armed: Bool) {
        isArmed = armed
        commandLabel.setText(
            armed ? String(localized: "press again to close") : item.command
        )
        bindingLabel.configure(
            armed ? "AGAIN" : item.bindingLabel,
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal2
        )
        layer.borderWidth = armed ? 1 : 0
        refreshBorder()
        accessibilityLabel = Self.accessibilityLabel(for: item, isArmed: armed)
        refreshBackground()
    }

    // Arming swaps the strata resting ground for the raised bezel.
    override var restingBackgroundColor: UIColor {
        isArmed ? UIKitChassis.bezelHi : super.restingBackgroundColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshBorder()
    }

    private static func accessibilityLabel(
        for item: ShortcutPanelItem,
        isArmed: Bool
    ) -> String {
        if isArmed {
            return String(localized: "\(item.title), press again to close")
        }
        if item.requiresDoubleActivation {
            return String(localized: "\(item.title), \(item.command), press twice to confirm")
        }
        return "\(item.title), \(item.command), \(item.bindingLabel)"
    }

    private func refreshBorder() {
        layer.borderColor = UIKitChassis.signal2.resolvedColor(with: traitCollection).cgColor
    }
}

/// A square compact-row button showing just its item's symbol face; the
/// title, command, and stock chord travel through the accessibility label
/// the way the full rows compose theirs.
///
/// A tap fires `onTap`; keeping the press down goes coarse — `onHoldStep`
/// after the hold delay, then again every repeat interval until release —
/// so a big resize is one held press, not twenty taps. A press that held
/// swallows its release: the finger lifting off a repeat must not append
/// one more fine step.
@MainActor
private final class ShortcutCompactItemButton: ShortcutPressControl {
    nonisolated static let holdDelay: UInt64 = 500_000_000
    nonisolated static let holdRepeatInterval: UInt64 = 500_000_000

    var onTap: () -> Void = {}
    var onHoldStep: () -> Void = {}

    private var holdTask: Task<Void, Never>?
    private var didHold = false

    init(item: ShortcutPanelItem) {
        super.init(frame: .zero)
        minimumHeight(40)
        accessibilityIdentifier = item.accessibilityIdentifier
        accessibilityLabel = "\(item.title), \(item.command), \(item.bindingLabel)"
        accessibilityHint = String(
            localized: "Hold for \(TmuxShortcut.coarseResizeCells)-cell steps, repeating until release."
        )

        let face = UIImageView(
            image: item.symbolName.flatMap(UIImage.init(systemName:))
        )
        face.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 13 * Theme.typeScale, weight: .semibold
        )
        face.tintColor = UIKitChassis.signal
        face.isAccessibilityElement = false
        addSubview(face)
        face.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            face.centerXAnchor.constraint(equalTo: centerXAnchor),
            face.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Mirrors the base press events: a drag back in re-arms the hold the
        // way it re-lights the pressed ground.
        addTarget(
            self,
            action: #selector(beginHold),
            for: [.touchDown, .touchDragEnter]
        )
        addTarget(self, action: #selector(lift), for: .touchUpInside)
        addTarget(
            self,
            action: #selector(cancelHold),
            for: [.touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    @objc private func beginHold() {
        didHold = false
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.holdDelay)
            while !Task.isCancelled {
                guard let self else { return }
                didHold = true
                onHoldStep()
                try? await Task.sleep(nanoseconds: Self.holdRepeatInterval)
            }
        }
    }

    @objc private func lift() {
        cancelHoldTask()
        if didHold {
            didHold = false
        } else {
            onTap()
        }
    }

    @objc private func cancelHold() {
        cancelHoldTask()
        didHold = false
    }

    private func cancelHoldTask() {
        holdTask?.cancel()
        holdTask = nil
    }
}

@MainActor
private final class ShortcutChoiceButton: ShortcutPressControl {
    private(set) var choice: TmuxWindowChoice

    private let noun: String
    private let activeLabel: UIKitChassisMonoLabel

    init(choice: TmuxWindowChoice, noun: String, accessibilityPrefix: String) {
        self.choice = choice
        self.noun = noun
        // Built for every row, hidden while inactive: the panel stays open
        // across a switch, so the marker has to move without a rebuild.
        activeLabel = UIKitChassisMonoLabel(
            "ACTIVE",
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal2
        )
        super.init(frame: .zero)
        minimumHeight(40)
        accessibilityIdentifier = accessibilityPrefix + choice.tmuxID

        let index = UIKitChassisMonoLabel(
            "\(choice.index)",
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal2
        )
        index.setContentHuggingPriority(.required, for: .horizontal)
        let name = UIKitChassisMonoLabel(
            choice.name.uppercased(),
            font: UIKitChassis.compressedLabelFont(10),
            color: UIKitChassis.signal,
            kern: 0.8
        )
        name.lineBreakMode = .byTruncatingTail

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [index, name, spacer, activeLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setActive(choice.isActive)
    }

    func setActive(_ active: Bool) {
        choice.isActive = active
        activeLabel.isHidden = !active
        accessibilityLabel = active
            ? String(localized: "\(noun.capitalized) \(choice.index), \(choice.name), current \(noun)")
            : String(localized: "Switch to \(noun) \(choice.index), \(choice.name)")
    }
}

@MainActor
private extension UIView {
    func minimumHeight(_ height: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
    }
}
