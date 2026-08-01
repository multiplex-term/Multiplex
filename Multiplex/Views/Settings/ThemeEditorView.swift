import UIKit

// MARK: - Native theme editor

/// Edits a private draft and commits only through Save. Popping the controller
/// leaves the store untouched, matching the former NavigationStack behavior.
@MainActor
final class ThemeEditorViewController: UIViewController, UITextFieldDelegate {
    enum Metrics {
        static let contentMaximumWidth: CGFloat = 680
        static let outerInset: CGFloat = 18
        static let sectionSpacing: CGFloat = 18
    }

    let initialTheme: TerminalTheme
    private(set) var draft: TerminalTheme
    let onSave: (TerminalTheme) -> Void
    var onFinished: (() -> Void)?

    var appAppearance = AppAppearance.system {
        didSet { applyAppearance() }
    }

    private(set) var preview: UIKitThemePreviewView!
    private(set) var nameField = UITextField()
    private(set) var saveItem: UIBarButtonItem!
    private(set) var colorRows: [ThemeEditorColorRow] = []

    private let livePreviewContainer = UIView()
    private let livePreviewStack = UIStackView()
    private let livePreviewName = UILabel()
    private let chassisNavigationTitle = UIKitChassisLabel("", size: 12)
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    init(theme: TerminalTheme, onSave: @escaping (TerminalTheme) -> Void) {
        initialTheme = theme
        draft = theme
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIKitChassis.chassis
        configureNavigation()
        configureLivePreview()
        configureEditor()
        refreshDraftRendering()
        applyAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppearance()
    }

    private func configureNavigation() {
        navigationItem.largeTitleDisplayMode = .never
        saveItem = UIBarButtonItem(
            title: "Save",
            style: .plain,
            target: self,
            action: #selector(savePressed)
        )
        saveItem.tintColor = UIKitChassis.signal
        saveItem.accessibilityLabel = "Save theme"
        navigationItem.rightBarButtonItem = saveItem
    }

    /// The preview remains outside the scrolling editor exactly as before, so
    /// every change stays visible while the color table moves underneath it.
    private func configureLivePreview() {
        livePreviewContainer.backgroundColor = UIKitChassis.chassis
        view.addSubview(livePreviewContainer)
        livePreviewContainer.translatesAutoresizingMaskIntoConstraints = false

        let label = UIKitChassisLabel("Live preview", size: 10)
        livePreviewName.font = UIKitChassis.monoFont(8, weight: .semibold)
        livePreviewName.textColor = UIKitChassis.signal3
        livePreviewName.numberOfLines = 1
        livePreviewName.lineBreakMode = .byTruncatingTail
        livePreviewName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [
            label,
            themeEditorFlexibleSpacer(),
            livePreviewName,
        ])
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = 12

        preview = UIKitThemePreviewView(theme: draft)
        livePreviewStack.axis = .vertical
        livePreviewStack.alignment = .fill
        livePreviewStack.spacing = 10
        livePreviewStack.addArrangedSubview(heading)
        livePreviewStack.addArrangedSubview(preview)
        livePreviewContainer.addSubview(livePreviewStack)
        livePreviewStack.translatesAutoresizingMaskIntoConstraints = false

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        livePreviewContainer.addSubview(divider)
        divider.translatesAutoresizingMaskIntoConstraints = false
        let fillVisibleWidth = livePreviewStack.widthAnchor.constraint(
            equalTo: livePreviewContainer.widthAnchor,
            constant: -(Metrics.outerInset * 2)
        )
        fillVisibleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            livePreviewStack.topAnchor.constraint(
                equalTo: livePreviewContainer.topAnchor,
                constant: Metrics.outerInset
            ),
            livePreviewStack.bottomAnchor.constraint(
                equalTo: livePreviewContainer.bottomAnchor,
                constant: -Metrics.outerInset
            ),
            livePreviewStack.centerXAnchor.constraint(
                equalTo: livePreviewContainer.centerXAnchor
            ),
            livePreviewStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: livePreviewContainer.leadingAnchor,
                constant: Metrics.outerInset
            ),
            livePreviewStack.trailingAnchor.constraint(
                lessThanOrEqualTo: livePreviewContainer.trailingAnchor,
                constant: -Metrics.outerInset
            ),
            livePreviewStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: Metrics.contentMaximumWidth
            ),
            fillVisibleWidth,
            divider.leadingAnchor.constraint(equalTo: livePreviewContainer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: livePreviewContainer.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: livePreviewContainer.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func configureEditor() {
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = UIKitChassis.chassis
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            livePreviewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            livePreviewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            livePreviewContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: livePreviewContainer.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),
        ])

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = Metrics.sectionSpacing
        contentStack.addArrangedSubview(makeIdentitySection())
        contentStack.addArrangedSubview(makeSurfaceSection())
        contentStack.addArrangedSubview(makeANSISection(
            title: "ANSI · Normal",
            detail: "The eight standard colors emitted by terminal programs.",
            range: 0..<8
        ))
        contentStack.addArrangedSubview(makeANSISection(
            title: "ANSI · Bright",
            detail: "The high-intensity variants used for bold and bright output.",
            range: 8..<16
        ))
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let fillVisibleWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -(Metrics.outerInset * 2)
        )
        fillVisibleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Metrics.outerInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Metrics.outerInset
            ),
            contentStack.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Metrics.outerInset
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Metrics.outerInset
            ),
            contentStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: Metrics.contentMaximumWidth
            ),
            fillVisibleWidth,
        ])
    }

    private func makeIdentitySection() -> UIView {
        let fieldLabel = themeEditorLabel(
            "Name",
            font: UIKitChassis.uiFont(10, weight: .semibold),
            color: UIKitChassis.signal2
        )
        nameField.text = draft.name
        nameField.placeholder = "Midnight"
        nameField.font = UIKitChassis.monoFont(12)
        nameField.textColor = UIKitChassis.signal
        nameField.tintColor = UIKitChassis.signal
        nameField.backgroundColor = UIKitChassis.screen
        nameField.borderStyle = .none
        nameField.clearButtonMode = .whileEditing
        nameField.returnKeyType = .done
        nameField.delegate = self
        nameField.accessibilityLabel = "Name"
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        let well = UIKitTallyBorderedView()
        well.tallyBorderColor = UIKitChassis.bezelHi
        well.backgroundColor = UIKitChassis.screen
        well.addSubview(nameField)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -10),
            nameField.topAnchor.constraint(equalTo: well.topAnchor, constant: 9),
            nameField.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -9),
        ])
        let body = UIStackView(arrangedSubviews: [fieldLabel, well])
        body.axis = .vertical
        body.spacing = 7
        return SettingsSectionView(
            title: "Theme identity",
            detail: "Shown in Settings and anywhere this palette is selected.",
            rows: [SettingsInsetRow(contentView: body)]
        )
    }

    private func makeSurfaceSection() -> UIView {
        let rows = [
            makeColorRow(
                label: "Background",
                value: { [weak self] in self?.draft.background ?? ThemeColor(0) },
                initial: initialTheme.background,
                update: { [weak self] color in self?.draft.background = color }
            ),
            makeColorRow(
                label: "Text",
                value: { [weak self] in self?.draft.foreground ?? ThemeColor(0) },
                initial: initialTheme.foreground,
                update: { [weak self] color in self?.draft.foreground = color }
            ),
            makeColorRow(
                label: "Cursor",
                value: { [weak self] in self?.draft.cursor ?? ThemeColor(0) },
                initial: initialTheme.cursor,
                update: { [weak self] color in self?.draft.cursor = color }
            ),
        ]
        return SettingsSectionView(
            title: "Surface",
            detail: "The terminal's canvas, text, and insertion cursor.",
            rows: rows
        )
    }

    private func makeANSISection(
        title: String,
        detail: String,
        range: Range<Int>
    ) -> UIView {
        let rows = range.map { index in
            makeColorRow(
                label: TerminalTheme.ansiNames[index],
                value: { [weak self] in
                    guard let self, self.draft.ansi.indices.contains(index)
                    else { return ThemeColor(0) }
                    return self.draft.ansi[index]
                },
                initial: initialTheme.ansi[index],
                update: { [weak self] color in
                    guard let self, self.draft.ansi.indices.contains(index) else { return }
                    self.draft.ansi[index] = color
                }
            )
        }
        return SettingsSectionView(title: title, detail: detail, rows: rows)
    }

    private func makeColorRow(
        label: String,
        value: @escaping () -> ThemeColor,
        initial: ThemeColor,
        update: @escaping (ThemeColor) -> Void
    ) -> UIView {
        let row = ThemeEditorColorRow(
            label: label,
            color: value(),
            resetIsDisabled: value() == initial,
            colorChanged: { [weak self] color in
                update(color)
                self?.refreshDraftRendering()
            },
            reset: { [weak self] in
                update(initial)
                self?.refreshDraftRendering()
            }
        )
        row.currentColor = value
        row.initialColor = initial
        colorRows.append(row)
        return row
    }

    private func refreshDraftRendering() {
        let displayName = draft.name.isEmpty ? "Theme" : draft.name
        title = displayName
        #if os(visionOS)
        chassisNavigationTitle.setText(displayName)
        navigationItem.titleView = chassisNavigationTitle
        #endif
        livePreviewName.attributedText = NSAttributedString(
            string: draft.name.isEmpty ? "UNTITLED" : draft.name.uppercased(),
            attributes: [
                .font: UIKitChassis.monoFont(8, weight: .semibold),
                .foregroundColor: UIKitChassis.signal3,
                .kern: CGFloat(1),
            ]
        )
        preview?.setTheme(draft)
        let canSave = !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        saveItem?.isEnabled = canSave
        saveItem?.tintColor = canSave ? UIKitChassis.signal : UIKitChassis.signal3
        colorRows.forEach { $0.refresh() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func applyAppearance() {
        let style: UIUserInterfaceStyle
        switch appAppearance.resolvedOverride {
        case nil: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        overrideUserInterfaceStyle = style
        if navigationController?.viewControllers.first === self {
            navigationController?.overrideUserInterfaceStyle = style
            viewIfLoaded?.window?.overrideUserInterfaceStyle = style
        }
        if let navigationBar = navigationController?.navigationBar {
            UIKitChassis.configureSheetNavigationBar(navigationBar)
        }
    }

    @objc private func nameChanged() {
        draft.name = nameField.text ?? ""
        refreshDraftRendering()
    }

    @objc private func savePressed() {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(draft)
        if let onFinished {
            onFinished()
        } else if let navigationController,
                  navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else {
            navigationController?.dismiss(animated: true)
        }
    }
}

// MARK: - Native color row

@MainActor
final class ThemeEditorColorRow: UIView {
    let label: String
    let colorWell = UIColorWell()
    // Matches the original SwiftUI `.buttonStyle(.plain)`: the embedded
    // ChassisBadge owns the visible TALLY ground, not UIButton.
    let resetButton = UIButton(type: .custom)
    private let hexLabel = UILabel()
    private let colorChanged: (ThemeColor) -> Void
    private let reset: () -> Void

    var currentColor: () -> ThemeColor = { ThemeColor(0) }
    var initialColor = ThemeColor(0)

    init(
        label: String,
        color: ThemeColor,
        resetIsDisabled: Bool,
        colorChanged: @escaping (ThemeColor) -> Void,
        reset: @escaping () -> Void
    ) {
        self.label = label
        self.colorChanged = colorChanged
        self.reset = reset
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.chassis

        let titleLabel = themeEditorLabel(
            label,
            font: UIKitChassis.uiFont(11, weight: .medium),
            color: UIKitChassis.signal
        )
        hexLabel.font = UIKitChassis.monoFont(9, weight: .medium)
        hexLabel.textColor = UIKitChassis.signal3
        hexLabel.numberOfLines = 1
        let identity = UIStackView(arrangedSubviews: [titleLabel, hexLabel])
        identity.axis = .vertical
        identity.spacing = 3

        colorWell.supportsAlpha = false
        colorWell.title = label
        colorWell.selectedColor = UIColor(color)
        colorWell.accessibilityLabel = label
        colorWell.addTarget(self, action: #selector(colorWellChanged), for: .valueChanged)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            colorWell.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            colorWell.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])

        resetButton.backgroundColor = .clear
        resetButton.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )
        resetButton.accessibilityLabel = "Reset \(label)"
        resetButton.addTarget(self, action: #selector(resetPressed), for: .touchUpInside)
        let resetBadge = SettingsBadgeView("", systemImage: "arrow.counterclockwise")
        resetBadge.isAccessibilityElement = false
        resetBadge.isUserInteractionEnabled = false
        resetButton.addSubview(resetBadge)
        resetBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resetBadge.centerXAnchor.constraint(equalTo: resetButton.centerXAnchor),
            resetBadge.centerYAnchor.constraint(equalTo: resetButton.centerYAnchor),
        ])
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resetButton.widthAnchor.constraint(equalToConstant: 36),
            resetButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        let row = UIStackView(arrangedSubviews: [
            identity,
            themeEditorFlexibleSpacer(),
            colorWell,
            resetButton,
        ])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        resetButton.isEnabled = !resetIsDisabled
        resetButton.alpha = resetIsDisabled ? 0.35 : 1
        hexLabel.text = color.hexString
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func refresh() {
        let color = currentColor()
        colorWell.selectedColor = UIColor(color)
        hexLabel.text = color.hexString
        let disabled = color == initialColor
        resetButton.isEnabled = !disabled
        resetButton.alpha = disabled ? 0.35 : 1
    }

    @objc private func colorWellChanged() {
        guard let selectedColor = colorWell.selectedColor,
              let color = ThemeColor(uiColor: selectedColor, traits: traitCollection)
        else { return }
        colorChanged(color)
    }

    @objc private func resetPressed() {
        reset()
    }
}

private extension ThemeColor {
    init?(uiColor: UIColor, traits: UITraitCollection) {
        let resolved = uiColor.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        else { return nil }
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (value * 255).rounded())))
        }
        self.init(red: byte(red), green: byte(green), blue: byte(blue))
    }
}

@MainActor
private func themeEditorFlexibleSpacer() -> UIView {
    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return spacer
}

@MainActor
private func themeEditorLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = 0
    return label
}
