import UIKit

// MARK: - Adaptive licenses screen

/// Open-source notices rendered as a grouped registry at compact width and a
/// component wall at regular width. Both modes read the same pure catalog.
@MainActor
final class LicensesViewController: UIViewController, AppAppearanceFollowing {
    /// The widest authored license line is 83 mono columns; this width shows
    /// it verbatim beside the component wall's rail and gutters. Narrower
    /// fits fall back to soft wrap.
    static let preferredSheetSize = CGSize(width: 980, height: 1_100)

    enum Presentation {
        case groupedRegistry
        case componentWall
    }

    private enum Filter: CaseIterable {
        case all
        case mit
        case apache
        case bsd
        case vendored

        func includes(_ component: OpenSourceComponent) -> Bool {
            switch self {
            case .all: true
            case .mit: component.family == .mit
            case .apache: component.family == .apache2
            case .bsd: component.family == .bsd
            case .vendored: component.isVendored
            }
        }
    }

    let components: [OpenSourceComponent]
    let footerNote: String

    private(set) var presentation: Presentation?
    private(set) var selectedComponent: OpenSourceComponent?

    var appAppearance = AppAppearance.system {
        didSet {
            applyAppearance()
            if let detail = navigationController?.topViewController
                as? LicenseTextViewController {
                detail.appAppearance = appAppearance
            }
        }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    private var installedRoot: UIView?
    private var activeFilter = Filter.all
    private var filterButtons: [Filter: LicenseFilterChip] = [:]
    private let railStack = UIStackView()
    private weak var detailPane: LicenseTextPaneView?

    init(
        components: [OpenSourceComponent] = LicenseCatalog.components,
        footerNote: String = LicenseCatalog.cleanRoomMoshNote
    ) {
        self.components = components
        self.footerNote = footerNote
        selectedComponent = components.first
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Open Source Licenses"
        view.backgroundColor = GlassPrototype.sheetGround
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel("Open Source Licenses", size: 12)
        #endif
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            let done = UIBarButtonItem(
                title: "Done",
                style: .plain,
                target: self,
                action: #selector(donePressed)
            )
            done.tintColor = UIKitChassis.signal
            done.accessibilityLabel = "Done"
            navigationItem.rightBarButtonItem = done
        }
        rebuildLayout()
        applyAppearance()
    }

    @objc private func donePressed() {
        navigationController?.dismiss(animated: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppearance()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        rebuildLayout()
    }

    /// The wall needs real width for its rail + readable license column, and
    /// sheet widths don't track size class (a visionOS settings sheet is
    /// ~505 pt yet regular) — so the split is decided by measured points.
    private static let componentWallMinWidth: CGFloat = 480

    private var desiredPresentation: Presentation {
        view.bounds.width >= Self.componentWallMinWidth
            ? .componentWall
            : .groupedRegistry
    }

    private func rebuildLayout() {
        let desired = desiredPresentation
        guard presentation != desired || installedRoot == nil else { return }

        installedRoot?.removeFromSuperview()
        detailPane = nil
        filterButtons.removeAll()
        presentation = desired

        let root: UIView
        switch desired {
        case .groupedRegistry:
            root = makeGroupedRegistry()
        case .componentWall:
            root = makeComponentWall()
        }
        installedRoot = root
        view.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false

        switch desired {
        case .groupedRegistry:
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                root.topAnchor.constraint(equalTo: view.topAnchor),
                root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        case .componentWall:
            let safe = view.safeAreaLayoutGuide
            let fillWidth = root.widthAnchor.constraint(
                equalTo: safe.widthAnchor,
                constant: -36
            )
            fillWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                root.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
                root.leadingAnchor.constraint(
                    greaterThanOrEqualTo: safe.leadingAnchor,
                    constant: 18
                ),
                root.trailingAnchor.constraint(
                    lessThanOrEqualTo: safe.trailingAnchor,
                    constant: -18
                ),
                root.topAnchor.constraint(equalTo: safe.topAnchor, constant: 18),
                root.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -18),
                root.widthAnchor.constraint(lessThanOrEqualToConstant: 1_100),
                fillWidth,
            ])
        }
    }

    private func makeGroupedRegistry() -> UIView {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = GlassPrototype.clearedChassis
        scrollView.contentLayoutGuide.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor
        ).isActive = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.addArrangedSubview(makeSummaryStrip())

        for family in LicenseFamily.allCases {
            let familyComponents = components.filter { $0.family == family }
            let rows = familyComponents.map { component in
                LicenseComponentRow(
                    component: component,
                    style: .registry,
                    isSelected: false
                ) { [weak self] in
                    self?.showLicense(component)
                }
            }
            stack.addArrangedSubview(SettingsSectionView(
                title: "\(family.displayName) · \(familyComponents.count)",
                detail: nil,
                rows: rows
            ))
        }
        stack.addArrangedSubview(makeFooterNote())

        scrollView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let fillWidth = stack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -36
        )
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 18
            ),
            stack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -18
            ),
            stack.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 18
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -18
            ),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            fillWidth,
        ])
        return scrollView
    }

    private func makeSummaryStrip() -> UIView {
        let apacheCount = components.filter { $0.family == .apache2 }.count
        let mitCount = components.filter { $0.family == .mit }.count
        let bsdCount = components.filter { $0.family == .bsd }.count
        let badges = [
            SettingsBadgeView("\(components.count) PACKAGES"),
            SettingsBadgeView("APACHE-2.0 \(apacheCount)"),
            SettingsBadgeView("MIT \(mitCount)"),
            SettingsBadgeView("BSD \(bsdCount)"),
        ]
        let stack = UIStackView(arrangedSubviews: badges)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 7

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 28 * Theme.typeScale),
        ])
        return scrollView
    }

    private func makeFooterNote() -> UIView {
        let title = UIKitChassisLabel("Mosh transport", size: 9)
        let detail = licenseLabel(
            footerNote,
            font: UIKitChassis.uiFont(10),
            color: UIKitChassis.signal2
        )
        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.spacing = 5

        let holder = UIKitTallyBorderedView()
        holder.backgroundColor = GlassPrototype.clearedChassis
        holder.tallyBorderColor = UIKitChassis.bezelHi
        holder.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -11),
        ])
        return holder
    }

    private func makeComponentWall() -> UIView {
        let root = UIView()
        root.backgroundColor = GlassPrototype.clearedChassis
        let registry = makeRegistryPane()
        let selected = selectedComponent ?? components[0]
        let detail = LicenseTextPaneView(component: selected)
        detailPane = detail

        root.addSubview(registry)
        root.addSubview(detail)
        registry.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        let proportionalWidth = registry.widthAnchor.constraint(
            equalTo: root.widthAnchor,
            multiplier: 0.34
        )
        proportionalWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            registry.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            registry.topAnchor.constraint(equalTo: root.topAnchor),
            registry.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            registry.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            registry.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            proportionalWidth,
            detail.leadingAnchor.constraint(equalTo: registry.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        reloadRegularContent()
        return root
    }

    private func makeRegistryPane() -> UIView {
        let title = UIKitChassisLabel("Components", size: 10)
        let count = licenseLabel(
            "\(components.count) SHIPPED",
            font: UIKitChassis.monoFont(8, weight: .medium),
            color: UIKitChassis.signal2
        )
        let heading = UIStackView(arrangedSubviews: [title, licenseFlexibleSpacer(), count])
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = 8
        let header = licenseInsetHolder(heading, vertical: 10)
        header.backgroundColor = UIKitChassis.bezel

        let filterStack = UIStackView()
        filterStack.axis = .horizontal
        filterStack.alignment = .center
        filterStack.spacing = 6
        for filter in Filter.allCases {
            let button = LicenseFilterChip(title: filterTitle(filter)) { [weak self] in
                self?.chooseFilter(filter)
            }
            filterButtons[filter] = button
            filterStack.addArrangedSubview(button)
        }
        let filterScroll = UIScrollView()
        filterScroll.showsHorizontalScrollIndicator = false
        filterScroll.alwaysBounceHorizontal = true
        filterScroll.addSubview(filterStack)
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            filterStack.leadingAnchor.constraint(
                equalTo: filterScroll.contentLayoutGuide.leadingAnchor,
                constant: 10
            ),
            filterStack.trailingAnchor.constraint(
                equalTo: filterScroll.contentLayoutGuide.trailingAnchor,
                constant: -10
            ),
            filterStack.topAnchor.constraint(equalTo: filterScroll.contentLayoutGuide.topAnchor),
            filterStack.bottomAnchor.constraint(
                equalTo: filterScroll.contentLayoutGuide.bottomAnchor
            ),
            filterStack.centerYAnchor.constraint(equalTo: filterScroll.frameLayoutGuide.centerYAnchor),
            filterScroll.heightAnchor.constraint(equalToConstant: 46 * Theme.typeScale),
        ])

        railStack.axis = .vertical
        railStack.alignment = .fill
        railStack.spacing = 1
        railStack.backgroundColor = UIKitChassis.bezelHi
        let listScroll = UIScrollView()
        listScroll.alwaysBounceVertical = true
        listScroll.addSubview(railStack)
        railStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            railStack.leadingAnchor.constraint(equalTo: listScroll.contentLayoutGuide.leadingAnchor),
            railStack.trailingAnchor.constraint(
                equalTo: listScroll.contentLayoutGuide.trailingAnchor
            ),
            railStack.topAnchor.constraint(equalTo: listScroll.contentLayoutGuide.topAnchor),
            railStack.bottomAnchor.constraint(equalTo: listScroll.contentLayoutGuide.bottomAnchor),
            railStack.widthAnchor.constraint(equalTo: listScroll.frameLayoutGuide.widthAnchor),
        ])

        let footer = licenseLabel(
            footerNote,
            font: UIKitChassis.uiFont(9),
            color: UIKitChassis.signal2
        )
        let footerHolder = licenseInsetHolder(footer, vertical: 10)
        footerHolder.backgroundColor = UIKitChassis.bezel

        let body = UIStackView(arrangedSubviews: [
            header,
            licenseRule(),
            filterScroll,
            licenseRule(),
            listScroll,
            licenseRule(),
            footerHolder,
        ])
        body.axis = .vertical
        body.spacing = 0

        let pane = UIKitTallyBorderedView()
        pane.backgroundColor = GlassPrototype.clearedChassis
        pane.tallyBorderColor = UIKitChassis.bezelHi
        pane.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            body.topAnchor.constraint(equalTo: pane.topAnchor),
            body.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        return pane
    }

    private func filterTitle(_ filter: Filter) -> String {
        switch filter {
        case .all: "ALL \(components.count)"
        case .mit: "MIT \(components.filter { $0.family == .mit }.count)"
        case .apache: "APACHE \(components.filter { $0.family == .apache2 }.count)"
        case .bsd: "BSD \(components.filter { $0.family == .bsd }.count)"
        case .vendored: "VENDORED \(components.filter(\.isVendored).count)"
        }
    }

    private func chooseFilter(_ filter: Filter) {
        guard activeFilter != filter else { return }
        activeFilter = filter
        if let selectedComponent, !filter.includes(selectedComponent) {
            self.selectedComponent = components.first(where: filter.includes)
        }
        reloadRegularContent()
    }

    private func reloadRegularContent() {
        for view in railStack.arrangedSubviews {
            railStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let visible = components.filter(activeFilter.includes)
        if selectedComponent == nil || !visible.contains(where: {
            $0.name == selectedComponent?.name
        }) {
            selectedComponent = visible.first
        }
        for component in visible {
            railStack.addArrangedSubview(LicenseComponentRow(
                component: component,
                style: .rail,
                isSelected: component.name == selectedComponent?.name
            ) { [weak self] in
                self?.select(component)
            })
        }
        for (filter, button) in filterButtons {
            button.setActive(filter == activeFilter)
        }
        if let selectedComponent {
            detailPane?.setComponent(selectedComponent)
        }
    }

    private func select(_ component: OpenSourceComponent) {
        guard component.name != selectedComponent?.name else { return }
        selectedComponent = component
        reloadRegularContent()
    }

    private func showLicense(_ component: OpenSourceComponent) {
        let controller = LicenseTextViewController(component: component)
        controller.appAppearance = appAppearance
        navigationController?.pushViewController(controller, animated: true)
    }

    private func applyAppearance() {
        applyAppAppearance(
            pinsHostingChrome: navigationController?.viewControllers.first === self
        )
    }
}

// MARK: - Compact detail

@MainActor
final class LicenseTextViewController: UIViewController, AppAppearanceFollowing {
    let component: OpenSourceComponent
    var appAppearance = AppAppearance.system {
        didSet { applyAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    private let pane: LicenseTextPaneView

    init(component: OpenSourceComponent) {
        self.component = component
        pane = LicenseTextPaneView(component: component)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = component.name
        view.backgroundColor = GlassPrototype.sheetGround
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel(component.name, size: 12)
        #endif

        view.addSubview(pane)
        pane.translatesAutoresizingMaskIntoConstraints = false
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 14),
            pane.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -14),
            pane.topAnchor.constraint(equalTo: safe.topAnchor, constant: 14),
            pane.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -14),
        ])
        applyAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppearance()
    }

    private func applyAppearance() {
        applyAppAppearance(
            pinsHostingChrome: navigationController?.viewControllers.first === self
        )
    }
}

// MARK: - Component rows

@MainActor
private final class LicenseComponentRow: UIControl {
    enum Style {
        case registry
        case rail
    }

    private let style: Style
    private let selectionBar = UIView()
    private var rowIsSelected: Bool

    init(
        component: OpenSourceComponent,
        style: Style,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.style = style
        rowIsSelected = isSelected
        super.init(frame: .zero)
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = component.name
        accessibilityValue = "Version \(component.version), "
            + component.family.displayName
            + (component.isVendored ? ", vendored" : "")
        addAction(UIAction { _ in action() }, for: .touchUpInside)

        let name = licenseLabel(
            component.name,
            font: UIKitChassis.monoFont(
                style == .registry ? 11 : 10,
                weight: .semibold
            ),
            color: UIKitChassis.signal
        )
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingMiddle
        let metadataText = style == .registry
            ? component.version
            : "\(component.version) · \(component.family.displayName)"
        let metadata = licenseLabel(
            metadataText,
            font: UIKitChassis.monoFont(8, weight: .medium),
            color: UIKitChassis.signal2
        )
        metadata.numberOfLines = 1
        let identity = UIStackView(arrangedSubviews: [name, metadata])
        identity.axis = .vertical
        identity.spacing = 3
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = UIStackView(arrangedSubviews: [identity, licenseFlexibleSpacer()])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 9
        if component.isVendored {
            content.addArrangedSubview(SettingsBadgeView("VENDORED"))
        }
        if style == .registry {
            let chevron = UIImageView(image: UIImage(
                systemName: "chevron.right",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 9 * Theme.typeScale,
                    weight: .semibold
                )
            ))
            chevron.tintColor = UIKitChassis.signal2
            chevron.contentMode = .scaleAspectFit
            chevron.isAccessibilityElement = false
            content.addArrangedSubview(chevron)
        }
        content.isUserInteractionEnabled = false
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        let verticalInset: CGFloat = style == .registry ? 11 : 8
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: style == .registry ? 54 : 46
            ),
        ])

        selectionBar.backgroundColor = UIKitChassis.signal
        selectionBar.isHidden = style != .rail || !isSelected
        addSubview(selectionBar)
        selectionBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            selectionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionBar.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            selectionBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            selectionBar.widthAnchor.constraint(equalToConstant: 2),
        ])
        refreshSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isHighlighted: Bool {
        didSet { refreshSelection() }
    }

    private func refreshSelection() {
        if isHighlighted {
            backgroundColor = UIKitChassis.bezelHi
        } else if style == .rail, rowIsSelected {
            backgroundColor = UIKitChassis.bezel
        } else {
            backgroundColor = GlassPrototype.strataChassis
        }
        selectionBar.isHidden = style != .rail || !rowIsSelected
        if rowIsSelected {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }
}

// MARK: - Filter chips

@MainActor
private final class LicenseFilterChip: UIControl {
    private let titleLabel = UILabel()
    private let sourceTitle: String
    private let action: () -> Void
    private var active = false

    init(title: String, action: @escaping () -> Void) {
        sourceTitle = title
        self.action = action
        super.init(frame: .zero)
        layer.borderWidth = 1
        layer.cornerRadius = 2
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        addTarget(self, action: #selector(pressed), for: .touchUpInside)

        titleLabel.numberOfLines = 1
        titleLabel.isAccessibilityElement = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.68 : 1 }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refresh()
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        refresh()
    }

    @objc private func pressed() {
        action()
    }

    private func refresh() {
        backgroundColor = active ? UIKitChassis.bezel : GlassPrototype.strataChassis
        layer.borderColor = (active ? UIKitChassis.signal2 : UIKitChassis.bezelHi)
            .resolvedColor(with: traitCollection)
            .cgColor
        titleLabel.attributedText = NSAttributedString(
            string: sourceTitle,
            attributes: [
                .font: UIKitChassis.monoFont(8, weight: .semibold),
                .kern: CGFloat(0.8),
                .foregroundColor: (active ? UIKitChassis.signal : UIKitChassis.signal2)
                    .resolvedColor(with: traitCollection),
            ]
        )
        accessibilityValue = active ? "Selected" : "Not selected"
        if active {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }
}

// MARK: - License screen pane

@MainActor
private final class LicenseTextPaneView: UIKitTallyBorderedView {
    private var component: OpenSourceComponent
    private let metadataLabel = UILabel()
    private let copyrightLabel = UILabel()
    private let vendorLabel = UILabel()
    private let vendoredBadge = SettingsBadgeView("VENDORED")
    private let textView = UITextView()
    private lazy var copyChip = UIKitChassisChip(
        "COPY",
        systemImage: "doc.on.doc",
        accessibilityLabel: "Copy license text"
    ) { [weak self] in
        self?.copyLicense()
    }

    init(component: OpenSourceComponent) {
        self.component = component
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.screen
        tallyBorderColor = UIKitChassis.bezelHi
        configure()
        setComponent(component)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setComponent(_ component: OpenSourceComponent) {
        self.component = component
        metadataLabel.text = screenHeader(for: component)
        copyrightLabel.text = component.copyrightHolder
        vendorLabel.text = component.vendorNote
        vendorLabel.isHidden = component.vendorNote == nil
        vendoredBadge.isHidden = !component.isVendored
        textView.text = component.licenseText
        textView.accessibilityLabel = "\(component.name) license text"
        copyChip.accessibilityLabel = "Copy \(component.name) license text"
        textView.setContentOffset(.zero, animated: false)
    }

    private func configure() {
        metadataLabel.font = UIKitChassis.monoFont(10, weight: .semibold)
        metadataLabel.textColor = UIKitChassis.signal
        metadataLabel.numberOfLines = 1
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyrightLabel.font = UIKitChassis.monoFont(8, weight: .medium)
        copyrightLabel.textColor = UIKitChassis.signal2
        copyrightLabel.numberOfLines = 0
        vendorLabel.font = UIKitChassis.monoFont(8, weight: .medium)
        vendorLabel.textColor = UIKitChassis.signal3
        vendorLabel.numberOfLines = 0

        let topLine = UIStackView(arrangedSubviews: [
            metadataLabel,
            licenseFlexibleSpacer(),
            vendoredBadge,
            copyChip,
        ])
        topLine.axis = .horizontal
        topLine.alignment = .center
        topLine.spacing = 8
        let headerStack = UIStackView(arrangedSubviews: [
            topLine,
            copyrightLabel,
            vendorLabel,
        ])
        headerStack.axis = .vertical
        headerStack.spacing = 5
        let header = licenseInsetHolder(headerStack, horizontal: 12, vertical: 10)
        header.backgroundColor = UIKitChassis.bezel

        textView.backgroundColor = UIKitChassis.screen
        textView.textColor = UIKitChassis.signal
        textView.tintColor = UIKitChassis.signal2
        textView.font = UIKitChassis.monoFont(11)
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 18, right: 14)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityTraits = .staticText

        let stack = UIStackView(arrangedSubviews: [header, licenseRule(), textView])
        stack.axis = .vertical
        stack.spacing = 0
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func screenHeader(for component: OpenSourceComponent) -> String {
        var fields = [
            component.name.uppercased(),
            component.version,
            component.family.displayName.uppercased(),
        ]
        if let vendorNote = component.vendorNote {
            let revision = vendorNote.components(separatedBy: " · ").first { field in
                field.lowercased().hasPrefix("rev ")
            }
            if let revision {
                fields.append(revision.uppercased())
            }
        }
        return fields.joined(separator: " · ")
    }

    private func copyLicense() {
        UIPasteboard.general.string = component.licenseText
        UIAccessibility.post(notification: .announcement, argument: "License copied")
    }
}

// MARK: - Small layout helpers

@MainActor
private func licenseLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = 0
    return label
}

@MainActor
private func licenseFlexibleSpacer() -> UIView {
    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return spacer
}

@MainActor
private func licenseRule() -> UIView {
    let rule = UIView()
    rule.backgroundColor = UIKitChassis.bezelHi
    rule.translatesAutoresizingMaskIntoConstraints = false
    rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return rule
}

@MainActor
private func licenseInsetHolder(
    _ content: UIView,
    horizontal: CGFloat = 12,
    vertical: CGFloat
) -> UIView {
    let holder = UIView()
    holder.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: horizontal),
        content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -horizontal),
        content.topAnchor.constraint(equalTo: holder.topAnchor, constant: vertical),
        content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -vertical),
    ])
    return holder
}
