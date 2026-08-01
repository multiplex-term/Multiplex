import UIKit

/// Pure state for the widget ASK form. Keeping normalization and action
/// composition out of the controller makes the native surface a renderer of
/// the same nil / Home / path semantics used by `ExternalAction`.
struct AgentPromptFormState {
    let request: AgentPromptRequest
    var prompt = ""
    var directory: String?
    var model: String

    init(request: AgentPromptRequest) {
        self.request = request
        directory = request.directory ?? request.host.workingDirs.first
        model = request.model ?? ""
    }

    var directoryLabel: String {
        guard let directory, directory != "~" else { return "Home" }
        return directory
    }

    var modelDetail: String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return "Uses \(request.agent.displayName)'s own default model."
        }
        return "Launches as \(request.agent.launchCommand(model: trimmed, initialPrompt: ""))."
    }

    var directoryDetail: String {
        guard !request.host.workingDirs.isEmpty else {
            return "Uses the host's login-shell home directory."
        }
        if let directory, directory != "~" {
            return "Starts in \(directory). Choose Home to use the login shell's default."
        }
        return "Uses the host's login-shell home directory."
    }

    var launchAction: ExternalAction {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let launchModel = model.trimmingCharacters(in: .whitespaces)
        return .openAgent(
            host: .id(request.host.id),
            agent: request.agent,
            prompt: text.isEmpty ? nil : text,
            askForPrompt: false,
            directory: directory,
            setupScript: request.setupScript,
            model: launchModel.isEmpty ? nil : launchModel
        )
    }
}

// MARK: - Native UIKit screen

/// Native owner of the widget's ASK mode. It mirrors the New Session fields,
/// immediately focuses the optional first prompt, and resubmits the action
/// only when Launch is pressed.
@MainActor
final class AgentPromptSheetViewController: UIViewController, UITextFieldDelegate,
    AppAppearanceFollowing {
    static let contentMaximumWidth: CGFloat = 680
    static let outerInset: CGFloat = 18
    static let sectionSpacing: CGFloat = 18

    var onDismiss: (() -> Void)?
    var appAppearance = AppAppearance.system {
        didSet { applyAppAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    private(set) var contentStack = UIStackView()

    private var form: AgentPromptFormState
    private let submit: (ExternalAction) -> Void
    private let scrollView = UIScrollView()
    private let promptTextView: AgentPromptTextView
    private let promptWell = UIKitTallyBorderedView()
    private let modelField = UITextField()
    private var directoryButton: AgentPromptDirectoryButton?
    private var promptHeightConstraint: NSLayoutConstraint?
    private var requestedInitialFocus = false

    init(
        request: AgentPromptRequest,
        submit: @escaping (ExternalAction) -> Void
    ) {
        form = AgentPromptFormState(request: request)
        self.submit = submit
        promptTextView = AgentPromptTextView(
            placeholder: "What should \(request.agent.displayName) do?"
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = "\(form.request.agent.displayName) on \(form.request.host.name)"
        self.title = title
        view.backgroundColor = GlassPrototype.sheetGround

        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel(title, size: 12)
        #endif
        let cancel = UIBarButtonItem(
            title: "Cancel",
            style: .plain,
            target: self,
            action: #selector(cancelPressed)
        )
        cancel.tintColor = UIKitChassis.signal
        cancel.accessibilityLabel = "Cancel"
        navigationItem.leftBarButtonItem = cancel

        let launch = UIBarButtonItem(
            title: "Launch",
            style: .plain,
            target: self,
            action: #selector(launchPressed)
        )
        launch.tintColor = UIKitChassis.signal
        launch.accessibilityLabel = "Launch"
        navigationItem.rightBarButtonItem = launch

        configureContent()
        applyAppAppearance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !requestedInitialFocus else { return }
        requestedInitialFocus = true
        promptTextView.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePromptHeight()
        // This sheet opens with its prompt already focused, so the inset is
        // what keeps the sections below reachable under a standing keyboard.
        applyKeyboardContentInset(to: scrollView)
    }

    private func configureContent() {
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = GlassPrototype.clearedChassis
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),
        ])

        contentStack.axis = .vertical
        contentStack.spacing = Self.sectionSpacing
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let fillVisibleWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -(Self.outerInset * 2)
        )
        fillVisibleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Self.outerInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Self.outerInset
            ),
            contentStack.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Self.outerInset
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Self.outerInset
            ),
            contentStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: Self.contentMaximumWidth
            ),
            fillVisibleWidth,
        ])

        contentStack.addArrangedSubview(makePromptSection())
        contentStack.addArrangedSubview(makeModelSection())
        contentStack.addArrangedSubview(makeDirectorySection())
    }

    private func makePromptSection() -> UIView {
        promptTextView.accessibilityLabel = "Prompt"
        promptTextView.accessibilityHint =
            "What should \(form.request.agent.displayName) do?"
        promptTextView.accessibilityIdentifier = "agentPrompt.prompt"
        promptTextView.onTextChange = { [weak self] text in
            self?.form.prompt = text
            self?.updatePromptHeight()
        }
        promptTextView.onMetricsChange = { [weak self] in
            self?.updatePromptHeight()
        }

        promptWell.backgroundColor = UIKitChassis.screen
        promptWell.clipsToBounds = true
        promptWell.addSubview(promptTextView)
        promptTextView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            promptTextView.leadingAnchor.constraint(equalTo: promptWell.leadingAnchor),
            promptTextView.trailingAnchor.constraint(equalTo: promptWell.trailingAnchor),
            promptTextView.topAnchor.constraint(equalTo: promptWell.topAnchor),
            promptTextView.bottomAnchor.constraint(equalTo: promptWell.bottomAnchor),
        ])
        let height = promptWell.heightAnchor.constraint(
            equalToConstant: promptTextView.minimumHeight
        )
        height.isActive = true
        promptHeightConstraint = height

        let field = makeField(label: "Prompt", input: promptWell)
        return AgentPromptSectionView(
            title: "First prompt",
            detail: "Sent as \(form.request.agent.displayName)'s launch argument — it starts working on it immediately. Leave empty to open \(form.request.agent.displayName) without a prompt.",
            contentView: field
        )
    }

    private func makeModelSection() -> UIView {
        modelField.text = form.model
        modelField.placeholder = "Agent default"
        modelField.font = UIKitChassis.monoFont(12)
        modelField.textColor = UIKitChassis.signal
        modelField.tintColor = UIKitChassis.signal
        modelField.backgroundColor = .clear
        modelField.borderStyle = .none
        modelField.autocorrectionType = .no
        modelField.autocapitalizationType = .none
        modelField.spellCheckingType = .no
        modelField.smartDashesType = .no
        modelField.smartQuotesType = .no
        modelField.returnKeyType = .done
        modelField.delegate = self
        modelField.accessibilityLabel =
            "Optional model for \(form.request.agent.displayName)"
        modelField.accessibilityIdentifier = "agentPrompt.model"
        modelField.addTarget(self, action: #selector(modelChanged), for: .editingChanged)
        modelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let configured = form.request.host.launchModels(for: form.request.agent)
        var rowSubviews: [UIView] = [modelField]
        if !configured.isEmpty {
            rowSubviews.append(makeModelMenuControl(configured: configured))
        }

        let row = UIStackView(arrangedSubviews: rowSubviews)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8

        let well = UIKitTallyBorderedView()
        well.backgroundColor = UIKitChassis.screen
        well.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: well.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -9),
        ])

        let field = makeField(label: "Model", input: well)
        let section = AgentPromptSectionView(
            title: "Model",
            detail: form.modelDetail,
            contentView: field
        )
        modelSection = section
        return section
    }

    private var modelSection: AgentPromptSectionView?
    private var directorySection: AgentPromptSectionView?

    private func makeDirectorySection() -> UIView {
        let content: UIView
        if form.request.host.workingDirs.isEmpty {
            let startsIn = UILabel()
            startsIn.font = UIKitChassis.uiFont(10, weight: .semibold)
            startsIn.textColor = UIKitChassis.signal2
            startsIn.text = "Starts in"

            let home = UILabel()
            home.font = UIKitChassis.monoFont(10, weight: .medium)
            home.textColor = UIKitChassis.signal
            home.text = "HOME"
            home.setContentHuggingPriority(.required, for: .horizontal)
            home.setContentCompressionResistancePriority(.required, for: .horizontal)

            let row = UIStackView(arrangedSubviews: [startsIn, UIView(), home])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12
            row.isAccessibilityElement = true
            row.accessibilityLabel = "Starts in, Home"
            startsIn.isAccessibilityElement = false
            home.isAccessibilityElement = false
            content = row
        } else {
            let button = AgentPromptDirectoryButton()
            button.setDirectory(form.directoryLabel)
            button.accessibilityLabel = "Starting directory"
            button.accessibilityValue = form.directoryLabel
            button.accessibilityIdentifier = "agentPrompt.directory"
            button.menu = makeDirectoryMenu()
            button.showsMenuAsPrimaryAction = true
            directoryButton = button
            content = makeField(label: "Starts in", input: button)
        }

        let section = AgentPromptSectionView(
            title: "Directory",
            detail: form.directoryDetail,
            contentView: content
        )
        directorySection = section
        return section
    }

    private func makeField(label: String, input: UIView) -> UIView {
        let fieldLabel = UILabel()
        fieldLabel.font = UIKitChassis.uiFont(10, weight: .semibold)
        fieldLabel.textColor = UIKitChassis.signal2
        fieldLabel.text = label

        let stack = UIStackView(arrangedSubviews: [fieldLabel, input])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 7
        return stack
    }

    private func makeModelMenuControl(configured: [String]) -> UIView {
        let button = UIButton(type: .custom)
        button.setImage(
            UIImage(
                systemName: "chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 9 * Theme.typeScale,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        button.tintColor = UIKitChassis.signal2
        button.backgroundColor = GlassPrototype.strataChassis
        button.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        button.accessibilityLabel =
            "Configured models for \(form.request.agent.displayName)"
        button.accessibilityIdentifier = "agentPrompt.modelMenu"
        button.showsMenuAsPrimaryAction = true

        let border = UIKitTallyBorderedView()
        border.backgroundColor = GlassPrototype.clearedChassis
        border.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            border.widthAnchor.constraint(equalToConstant: 25),
            border.heightAnchor.constraint(equalToConstant: 25),
            button.leadingAnchor.constraint(equalTo: border.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: border.trailingAnchor),
            button.topAnchor.constraint(equalTo: border.topAnchor),
            button.bottomAnchor.constraint(equalTo: border.bottomAnchor),
        ])

        var children: [UIMenuElement] = configured.map { candidate in
            UIAction(title: candidate) { [weak self] _ in
                self?.selectModel(candidate)
            }
        }
        let defaultAction = UIAction(title: "Agent default") { [weak self] _ in
            self?.selectModel("")
        }
        children.append(UIMenu(options: .displayInline, children: [defaultAction]))
        button.menu = UIMenu(children: children)
        return border
    }

    private func makeDirectoryMenu() -> UIMenu {
        var children: [UIMenuElement] = form.request.host.workingDirs.map { directory in
            UIAction(title: directory) { [weak self] _ in
                self?.selectDirectory(directory)
            }
        }
        let home = UIAction(title: "Home") { [weak self] _ in
            self?.selectDirectory("~")
        }
        children.append(UIMenu(options: .displayInline, children: [home]))
        return UIMenu(children: children)
    }

    private func selectModel(_ model: String) {
        form.model = model
        modelField.text = model
        modelSection?.setDetail(form.modelDetail)
    }

    private func selectDirectory(_ directory: String) {
        form.directory = directory
        directoryButton?.setDirectory(form.directoryLabel)
        directoryButton?.accessibilityValue = form.directoryLabel
        directorySection?.setDetail(form.directoryDetail)
    }

    private func updatePromptHeight() {
        guard promptTextView.bounds.width > 0 else { return }
        let fitting = promptTextView.sizeThatFits(CGSize(
            width: promptTextView.bounds.width,
            height: .greatestFiniteMagnitude
        )).height
        let height = min(max(fitting, promptTextView.minimumHeight), promptTextView.maximumHeight)
        promptTextView.isScrollEnabled = fitting > promptTextView.maximumHeight
        if abs((promptHeightConstraint?.constant ?? 0) - height) > 0.5 {
            promptHeightConstraint?.constant = height
        }
    }

    @objc private func modelChanged() {
        form.model = modelField.text ?? ""
        modelSection?.setDetail(form.modelDetail)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func cancelPressed() {
        dismissSheet()
    }

    @objc private func launchPressed() {
        submit(form.launchAction)
        dismissSheet()
    }

    private func dismissSheet() {
        if let onDismiss {
            onDismiss()
        } else {
            navigationController?.dismiss(animated: true)
        }
    }
}

/// A mutable-detail wrapper around the shared native TALLY section. The
/// model and directory descriptions change in place so editing never replaces
/// the focused field or collapses an open menu.
@MainActor
private final class AgentPromptSectionView: UIView {
    private let detailLabel = UILabel()

    init(title: String, detail: String, contentView: UIView) {
        super.init(frame: .zero)

        let section = UIKitTallyFormSectionView(
            title: title,
            detail: nil,
            contentView: contentView
        )
        detailLabel.font = UIKitChassis.uiFont(10)
        detailLabel.textColor = UIKitChassis.signal2
        detailLabel.numberOfLines = 0
        detailLabel.text = detail

        let detailContainer = UIView()
        detailContainer.addSubview(detailLabel)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -2),
            detailLabel.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])

        let stack = UIStackView(arrangedSubviews: [section, detailContainer])
        stack.axis = .vertical
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setDetail(_ detail: String) {
        detailLabel.text = detail
    }
}

@MainActor
private final class AgentPromptTextView: UITextView, UITextViewDelegate {
    var onTextChange: ((String) -> Void)?
    var onMetricsChange: (() -> Void)?

    var minimumHeight: CGFloat { ceil((font?.lineHeight ?? 0) * 3 + 18) }
    var maximumHeight: CGFloat { ceil((font?.lineHeight ?? 0) * 8 + 18) }

    private let placeholderLabel = UILabel()

    init(placeholder: String) {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        font = UIKitChassis.monoFont(12)
        textColor = UIKitChassis.signal
        tintColor = UIKitChassis.signal
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = false
        #if os(iOS)
        keyboardDismissMode = .none
        #endif

        placeholderLabel.font = UIKitChassis.monoFont(12)
        placeholderLabel.textColor = UIKitChassis.signal3
        placeholderLabel.text = placeholder
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(
                equalTo: frameLayoutGuide.leadingAnchor,
                constant: 10
            ),
            placeholderLabel.trailingAnchor.constraint(
                equalTo: frameLayoutGuide.trailingAnchor,
                constant: -10
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: frameLayoutGuide.topAnchor,
                constant: 9
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        onMetricsChange?()
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        onTextChange?(textView.text)
    }
}

@MainActor
private final class AgentPromptDirectoryButton: UIButton {
    private let directoryLabel = UILabel()

    init() {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.screen
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))

        directoryLabel.font = UIKitChassis.monoFont(12)
        directoryLabel.textColor = UIKitChassis.signal
        directoryLabel.numberOfLines = 1
        directoryLabel.lineBreakMode = .byTruncatingTail
        directoryLabel.isAccessibilityElement = false

        let chevron = UIImageView(image: UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 9 * Theme.typeScale,
                weight: .semibold
            )
        ))
        chevron.tintColor = UIKitChassis.signal2
        chevron.contentMode = .scaleAspectFit
        chevron.isAccessibilityElement = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [directoryLabel, UIView(), chevron])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])

        let border = UIKitTallyBorderedView()
        border.isUserInteractionEnabled = false
        insertSubview(border, at: 0)
        border.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setDirectory(_ directory: String) {
        directoryLabel.text = directory
    }
}
