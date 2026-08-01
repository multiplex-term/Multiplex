import UIKit

/// UIKit implementation of the custom TALLY dropdown shared by the iPad key
/// rail and the visionOS UMD. Commands live in a compact square grid with the
/// human label, tmux command, and stock binding; the system Menu row treatment
/// is deliberately not involved.
@MainActor
final class TmuxShortcutPanelViewController: UIViewController {
    nonisolated static let preferredWidth: CGFloat = 430
    nonisolated static let confirmationWindow: UInt64 = 2_000_000_000

    private var panelWidth: CGFloat
    private var select: (TmuxShortcut) -> Void
    private var loadWindows: (() async -> [TmuxWindowChoice]?)?
    private var selectWindow: ((TmuxWindowChoice) -> Void)?

    private let panelView: TmuxShortcutPanelRootView
    private let contentStack = UIStackView()
    private let windowSection = UIStackView()
    private var shortcutButtons: [TmuxShortcut: TmuxShortcutButton] = [:]
    private var windowLoadTask: Task<Void, Never>?
    private var disarmTask: Task<Void, Never>?
    private var armedShortcut: TmuxShortcut?
    private var didRequestWindows = false

    init(
        width: CGFloat = TmuxShortcutPanelViewController.preferredWidth,
        select: @escaping (TmuxShortcut) -> Void,
        loadWindows: (() async -> [TmuxWindowChoice]?)? = nil,
        selectWindow: ((TmuxWindowChoice) -> Void)? = nil
    ) {
        panelWidth = width
        self.select = select
        self.loadWindows = loadWindows
        self.selectWindow = selectWindow
        panelView = TmuxShortcutPanelRootView(width: width)
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
        requestWindowsIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        disarm()
        windowLoadTask?.cancel()
        windowLoadTask = nil
    }

    /// The view controller owns an intrinsic height so UIKit popovers follow
    /// the grid instead of a tall keyboard-adjusted proposal.
    func fittingContentSize(for width: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        return panelView.fittingSize(for: width ?? panelWidth)
    }

    /// Internal by design: it is the single render path used by the async
    /// loader and by UIKit-focused tests. A single window has no useful switch
    /// action and therefore earns no section.
    func applyWindows(_ windows: [TmuxWindowChoice]) {
        windowSection.arrangedSubviews.forEach {
            windowSection.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        guard windows.count > 1 else {
            windowSection.isHidden = true
            refreshPreferredContentSize()
            return
        }

        let title = UIKitChassisLabel(
            "Switch Window",
            size: 9,
            color: UIKitChassis.signal2
        )
        title.accessibilityTraits.insert(.header)
        title.accessibilityIdentifier = "tmuxWindowSection.title"
        windowSection.addArrangedSubview(title)

        let grid = makeWindowGrid(windows)
        if windows.count > 8 {
            let scrollView = UIScrollView()
            scrollView.backgroundColor = UIKitChassis.bezelHi
            scrollView.showsVerticalScrollIndicator = true
            scrollView.alwaysBounceVertical = false
            scrollView.accessibilityIdentifier = "tmuxWindowSection.scroll"
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
            windowSection.addArrangedSubview(scrollView)
        } else {
            windowSection.addArrangedSubview(grid)
        }

        windowSection.isHidden = false
        refreshPreferredContentSize()
    }

    private func buildContent() {
        panelView.backgroundColor = UIKitChassis.bezel
        panelView.tallyBorderColor = UIKitChassis.bezelHi

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 12
        panelView.install(contentStack: contentStack)

        contentStack.addArrangedSubview(makeHeader())
        for group in TmuxShortcut.Group.allCases {
            contentStack.addArrangedSubview(makeShortcutSection(group))
        }

        windowSection.axis = .vertical
        windowSection.alignment = .fill
        windowSection.spacing = 6
        windowSection.isHidden = true
        windowSection.accessibilityIdentifier = "tmuxWindowSection"
        contentStack.addArrangedSubview(windowSection)
    }

    private func makeHeader() -> UIView {
        let title = UIKitChassisLabel("TMUX SHORTCUTS", size: 13)
        title.accessibilityTraits.insert(.header)
        let prefix = TmuxPanelLabel(
            "DEFAULT PREFIX  ⌃B",
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal2,
            kern: 0.8
        )
        prefix.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [title, spacer, prefix])
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

    private func makeShortcutSection(_ group: TmuxShortcut.Group) -> UIView {
        let title = UIKitChassisLabel(
            group.rawValue,
            size: 9,
            color: UIKitChassis.signal2
        )
        title.accessibilityTraits.insert(.header)
        title.accessibilityIdentifier = "tmuxGroup.\(group.rawValue)"

        let shortcuts = TmuxShortcut.shortcuts(in: group)
        let grid = makeTwoColumnGrid(shortcuts.map { shortcut in
            let button = TmuxShortcutButton(shortcut: shortcut)
            button.addTarget(self, action: #selector(shortcutPressed(_:)), for: .touchUpInside)
            shortcutButtons[shortcut] = button
            return button
        })

        let section = UIStackView(arrangedSubviews: [title, grid])
        section.axis = .vertical
        section.alignment = .fill
        section.spacing = 6
        return section
    }

    private func makeWindowGrid(_ windows: [TmuxWindowChoice]) -> UIView {
        makeTwoColumnGrid(windows.map { window in
            let button = TmuxWindowButton(window: window)
            button.addTarget(self, action: #selector(windowPressed(_:)), for: .touchUpInside)
            return button
        })
    }

    private func makeTwoColumnGrid(_ controls: [UIControl]) -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.alignment = .fill
        grid.spacing = 1
        grid.backgroundColor = UIKitChassis.bezelHi

        for offset in stride(from: 0, to: controls.count, by: 2) {
            let first = controls[offset]
            let second: UIView
            if controls.indices.contains(offset + 1) {
                second = controls[offset + 1]
            } else {
                second = UIView()
                second.backgroundColor = UIKitChassis.bezelHi
                second.isAccessibilityElement = false
            }

            let row = UIStackView(arrangedSubviews: [first, second])
            row.axis = .horizontal
            row.alignment = .fill
            row.distribution = .fillEqually
            row.spacing = 1
            grid.addArrangedSubview(row)
        }
        return grid
    }

    @objc private func shortcutPressed(_ sender: TmuxShortcutButton) {
        activate(sender.shortcut)
    }

    @objc private func windowPressed(_ sender: TmuxWindowButton) {
        disarm()
        selectWindow?(sender.windowChoice)
    }

    private func activate(_ shortcut: TmuxShortcut) {
        guard shortcut.requiresDoubleActivation else {
            disarm()
            select(shortcut)
            return
        }

        if armedShortcut == shortcut {
            disarm()
            select(shortcut)
            return
        }

        disarmTask?.cancel()
        setArmedShortcut(shortcut)
        disarmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.confirmationWindow)
            guard !Task.isCancelled, self?.armedShortcut == shortcut else { return }
            self?.setArmedShortcut(nil)
            self?.disarmTask = nil
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        disarmTask = nil
        setArmedShortcut(nil)
    }

    private func setArmedShortcut(_ shortcut: TmuxShortcut?) {
        armedShortcut = shortcut
        for (candidate, button) in shortcutButtons {
            button.setArmed(candidate == shortcut)
        }
    }

    private func requestWindowsIfNeeded() {
        guard !didRequestWindows, let loadWindows else { return }
        didRequestWindows = true
        windowLoadTask = Task { @MainActor [weak self] in
            let windows = await loadWindows() ?? []
            guard !Task.isCancelled else { return }
            self?.applyWindows(windows)
            self?.windowLoadTask = nil
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

@MainActor
private final class TmuxShortcutPanelRootView: UIKitTallyBorderedView {
    private var width: CGFloat
    private weak var contentStack: UIStackView?

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
    }

    func install(contentStack: UIStackView) {
        self.contentStack = contentStack
        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    override var intrinsicContentSize: CGSize {
        fittingSize(for: width)
    }

    func fittingSize(for proposedWidth: CGFloat) -> CGSize {
        guard let contentStack else { return CGSize(width: proposedWidth, height: 28) }
        let contentWidth = max(0, proposedWidth - 28)
        let measured = contentStack.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: proposedWidth, height: ceil(measured.height + 28))
    }
}

@MainActor
private final class TmuxShortcutButton: UIControl {
    let shortcut: TmuxShortcut

    private let titleLabel = TmuxPanelLabel()
    private let commandLabel = TmuxPanelLabel()
    private let bindingLabel = TmuxPanelLabel()
    private let bindingBorder = UIKitTallyBorderedView()
    private var isArmed = false

    init(shortcut: TmuxShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        minimumHeight(48)
        accessibilityIdentifier = "tmuxShortcut.\(shortcut.rawValue)"
        isAccessibilityElement = true
        accessibilityTraits = .button
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))

        titleLabel.configure(
            shortcut.title.uppercased(),
            font: UIKitChassis.compressedLabelFont(10),
            color: UIKitChassis.signal,
            kern: 0.8
        )
        commandLabel.configure(
            shortcut.command,
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
        setArmed(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setArmed(_ armed: Bool) {
        isArmed = armed
        commandLabel.setText(armed ? "press again to close" : shortcut.command)
        bindingLabel.configure(
            armed ? "AGAIN" : shortcut.bindingLabel,
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal2
        )
        layer.borderWidth = armed ? 1 : 0
        refreshBorder()
        accessibilityLabel = Self.accessibilityLabel(for: shortcut, isArmed: armed)
        refreshBackground()
    }

    override var isHighlighted: Bool {
        didSet { refreshBackground() }
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshBorder()
    }

    private static func accessibilityLabel(
        for shortcut: TmuxShortcut,
        isArmed: Bool
    ) -> String {
        if isArmed {
            return "\(shortcut.title), press again to close"
        }
        if shortcut.requiresDoubleActivation {
            return "\(shortcut.title), \(shortcut.command), press twice to confirm"
        }
        return "\(shortcut.title), \(shortcut.command), \(shortcut.bindingLabel)"
    }

    @objc private func beginPress() {
        isHighlighted = true
    }

    @objc private func endPress() {
        isHighlighted = false
    }

    private func refreshBackground() {
        backgroundColor = isArmed || isHighlighted
            ? UIKitChassis.bezelHi
            : UIKitChassis.chassis
    }

    private func refreshBorder() {
        layer.borderColor = UIKitChassis.signal2.resolvedColor(with: traitCollection).cgColor
    }
}

@MainActor
private final class TmuxWindowButton: UIControl {
    let windowChoice: TmuxWindowChoice

    init(window: TmuxWindowChoice) {
        windowChoice = window
        super.init(frame: .zero)
        minimumHeight(40)
        accessibilityIdentifier = "tmuxWindow.\(window.tmuxID)"
        isAccessibilityElement = true
        accessibilityTraits = .button
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        accessibilityLabel = window.isActive
            ? "Window \(window.index), \(window.name), current window"
            : "Switch to window \(window.index), \(window.name)"

        let index = TmuxPanelLabel(
            "\(window.index)",
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal2
        )
        index.setContentHuggingPriority(.required, for: .horizontal)
        let name = TmuxPanelLabel(
            window.name.uppercased(),
            font: UIKitChassis.compressedLabelFont(10),
            color: UIKitChassis.signal,
            kern: 0.8
        )
        name.lineBreakMode = .byTruncatingTail

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var content: [UIView] = [index, name, spacer]
        if window.isActive {
            let active = TmuxPanelLabel(
                "ACTIVE",
                font: UIKitChassis.monoFont(9, weight: .semibold),
                color: UIKitChassis.signal2
            )
            active.setContentCompressionResistancePriority(.required, for: .horizontal)
            content.append(active)
        }

        let row = UIStackView(arrangedSubviews: content)
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isHighlighted: Bool {
        didSet { refreshBackground() }
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    @objc private func beginPress() {
        isHighlighted = true
    }

    @objc private func endPress() {
        isHighlighted = false
    }

    private func refreshBackground() {
        backgroundColor = isHighlighted ? UIKitChassis.bezelHi : UIKitChassis.chassis
    }
}

@MainActor
private final class TmuxPanelLabel: UILabel {
    private var sourceText = ""
    private var sourceFont = UIFont.systemFont(ofSize: 10)
    private var sourceColor = UIKitChassis.signal
    private var kern: CGFloat?

    convenience init(
        _ text: String,
        font: UIFont,
        color: UIColor,
        kern: CGFloat? = nil
    ) {
        self.init(frame: .zero)
        configure(text, font: font, color: color, kern: kern)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 1
        lineBreakMode = .byClipping
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(
        _ text: String,
        font: UIFont,
        color: UIColor,
        kern: CGFloat? = nil
    ) {
        sourceText = text
        sourceFont = font
        sourceColor = color
        self.kern = kern
        refreshAttributedText()
    }

    func setText(_ text: String) {
        sourceText = text
        refreshAttributedText()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshAttributedText()
    }

    private func refreshAttributedText() {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: sourceFont,
            .foregroundColor: sourceColor.resolvedColor(with: traitCollection),
        ]
        if let kern { attributes[.kern] = kern }
        attributedText = NSAttributedString(string: sourceText, attributes: attributes)
    }
}

@MainActor
private extension UIView {
    func minimumHeight(_ height: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
    }
}
