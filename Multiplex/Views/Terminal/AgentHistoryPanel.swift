import Observation
import UIKit

/// Native HISTORY surface for the focused pane's past user prompts. Rows peek
/// the full session-file text—including content the agent TUI truncates—and,
/// where supported, JUMP scrolls the live Claude transcript to that message.
@MainActor
final class AgentHistoryPanelViewController: UIViewController {
    nonisolated static let preferredWidth: CGFloat =
        352 + 2 * UIKitChassis.popoverPanelInset
    nonisolated static let maximumListHeight: CGFloat = 420

    typealias HistoryStatus = TerminalSessionController.AgentHistoryStatus

    private let agent: AgentKind
    private var panelWidth: CGFloat
    private let historyStatus: () -> HistoryStatus?
    private let openHistory: (AgentKind) -> Void
    private let closeHistory: () -> Void
    private let startHistoryJump: (AgentUserMessage) -> Void
    private var dismiss: () -> Void

    private let panelView: AgentHistoryPanelRootView
    private let rootStack = UIStackView()
    private let contentContainer = UIView()
    private var currentContent: UIView?
    private var expandedOrdinal: Int?
    private var messageRows: [Int: AgentHistoryMessageRowView] = [:]
    private weak var listScrollView: UIScrollView?
    private weak var listStack: UIStackView?
    private var observesHistory = false
    private var observationGeneration = 0

    convenience init(
        agent: AgentKind,
        controller: TerminalSessionController,
        width: CGFloat = AgentHistoryPanelViewController.preferredWidth,
        dismiss: @escaping () -> Void
    ) {
        self.init(
            agent: agent,
            width: width,
            historyStatus: { [weak controller] in controller?.agentHistory },
            openHistory: { [weak controller] agent in
                controller?.openAgentHistory(for: agent)
            },
            closeHistory: { [weak controller] in
                controller?.closeAgentHistory()
            },
            startHistoryJump: { [weak controller] message in
                controller?.startHistoryJump(to: message)
            },
            dismiss: dismiss
        )
    }

    /// Injectable observation boundary keeps the UIKit behavior directly
    /// testable while production still reads the controller's @Observable
    /// property and routes actions back to that same controller.
    init(
        agent: AgentKind,
        width: CGFloat = AgentHistoryPanelViewController.preferredWidth,
        historyStatus: @escaping () -> HistoryStatus?,
        openHistory: @escaping (AgentKind) -> Void,
        closeHistory: @escaping () -> Void,
        startHistoryJump: @escaping (AgentUserMessage) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.agent = agent
        panelWidth = width
        self.historyStatus = historyStatus
        self.openHistory = openHistory
        self.closeHistory = closeHistory
        self.startHistoryJump = startHistoryJump
        self.dismiss = dismiss
        panelView = AgentHistoryPanelRootView(width: width)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = panelView.intrinsicContentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = panelView
        buildView()
        render(historyStatus())
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observationGeneration &+= 1
        observesHistory = true
        openHistory(agent)
        observeHistory(generation: observationGeneration)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopObservingAndClose()
    }

    func fittingContentSize(for width: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        return panelView.fittingSize(for: width ?? panelWidth)
    }

    /// The observation callback and focused UIKit tests share one rendering
    /// seam. This does not mutate the controller; it only paints a coherent
    /// snapshot already owned by the service.
    func applyHistoryStatus(_ status: HistoryStatus?) {
        render(status)
    }

    func prepareForRemoval() {
        stopObservingAndClose()
    }

    private func buildView() {
        // PROTOTYPE(GLASS): the popover root's smoke is the one ground —
        // a bezel wash here lightened the panel and crushed contrast.
        panelView.backgroundColor = GlassPrototype.clearedBezel

        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 0
        panelView.install(rootStack: rootStack)

        rootStack.addArrangedSubview(makeHeader())
        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rootStack.addArrangedSubview(divider)
        rootStack.addArrangedSubview(contentContainer)
    }

    private func makeHeader() -> UIView {
        let history = UIKitChassisLabel("HISTORY", size: 11)
        history.accessibilityTraits.insert(.header)
        let agentLabel = UIKitChassisLabel(
            agent.displayName,
            size: 9,
            color: UIKitChassis.signal3
        )
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 12).isActive = true

        let close = UIKitChassisChip(
            "CLOSE",
            accessibilityLabel: "Close",
            action: { [weak self] in self?.dismiss() }
        )
        close.accessibilityIdentifier = "agentHistory.close"
        close.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [history, agentLabel, spacer, close])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8

        let container = UIView()
        container.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        let inset = UIKitChassis.popoverPanelInset
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    private func observeHistory(generation: Int) {
        guard observesHistory, generation == observationGeneration else { return }
        let status = withObservationTracking {
            historyStatus()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeHistory(generation: generation)
            }
        }
        render(status)
    }

    private func stopObservingAndClose() {
        guard observesHistory else { return }
        observesHistory = false
        observationGeneration &+= 1
        closeHistory()
    }

    private func render(_ status: HistoryStatus?) {
        messageRows.removeAll()
        listScrollView = nil
        listStack = nil

        let content: UIView
        switch status {
        case nil, .loading:
            let spinner = UIActivityIndicatorView(style: .medium)
            // An unstyled indicator resolves to the system gray and ignores the
            // window tint, so the TALLY ink must be assigned directly — the same
            // token every other busy indicator in the app uses.
            spinner.color = UIKitChassis.signal2
            spinner.startAnimating()
            spinner.accessibilityLabel = "Reading session file"
            let label = UIKitChassisLabel(
                "READING SESSION FILE",
                size: 9,
                color: UIKitChassis.signal3
            )
            content = makeStatusRow([spinner, label])

        case .unavailable(let reason):
            let marker = UIView()
            marker.backgroundColor = UIKitChassis.signal3
            marker.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                marker.widthAnchor.constraint(equalToConstant: 5),
                marker.heightAnchor.constraint(equalToConstant: 5),
            ])
            marker.isAccessibilityElement = false
            let label = UIKitChassisLabel(
                reason,
                size: 9,
                color: UIKitChassis.signal3
            )
            content = makeStatusRow([marker, label])

        case .loaded(_, let messages, let jumpAvailable):
            if messages.isEmpty {
                content = makeStatusRow([
                    UIKitChassisLabel(
                        "NO MESSAGES YET",
                        size: 9,
                        color: UIKitChassis.signal3
                    ),
                ])
            } else {
                content = makeMessageList(
                    messages: messages,
                    jumpAvailable: jumpAvailable
                )
            }
        }

        replaceContent(with: content)
        refreshListAndPreferredSize()
    }

    private func makeStatusRow(_ views: [UIView]) -> UIView {
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.alignment = .center
        row.justifyContentInCenter()
        row.spacing = 10
        row.accessibilityIdentifier = "agentHistory.status"
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 72).isActive = true
        return row
    }

    private func makeMessageList(
        messages: [AgentUserMessage],
        jumpAvailable: Bool
    ) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.accessibilityIdentifier = "agentHistory.list"

        for message in messages.reversed() {
            let row = AgentHistoryMessageRowView(
                message: message,
                expanded: expandedOrdinal == message.ordinal,
                availableWidth: panelWidth - 2 * UIKitChassis.popoverPanelInset,
                showsJump: jumpAvailable && message.reachable,
                toggle: { [weak self] ordinal in
                    self?.toggleMessage(ordinal)
                },
                jump: { [weak self] message in
                    guard let self else { return }
                    self.startHistoryJump(message)
                    self.dismiss()
                }
            )
            messageRows[message.ordinal] = row
            stack.addArrangedSubview(row)

            let divider = UIView()
            divider.backgroundColor = UIKitChassis.bezelHi.withAlphaComponent(0.6)
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(divider)
        }

        let scroll = UIScrollView()
        scroll.backgroundColor = .clear
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = true
        scroll.accessibilityIdentifier = "agentHistory.scroll"
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        let height = scroll.heightAnchor.constraint(equalToConstant: 44)
        height.identifier = "agentHistory.listHeight"
        height.isActive = true

        listScrollView = scroll
        listStack = stack
        return scroll
    }

    private func replaceContent(with content: UIView) {
        currentContent?.removeFromSuperview()
        currentContent = content
        contentContainer.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func toggleMessage(_ ordinal: Int) {
        expandedOrdinal = expandedOrdinal == ordinal ? nil : ordinal
        for (candidate, row) in messageRows {
            row.setExpanded(candidate == expandedOrdinal)
        }
        refreshListAndPreferredSize()
    }

    private func refreshListAndPreferredSize() {
        view.setNeedsLayout()
        view.layoutIfNeeded()

        if let scroll = listScrollView, let stack = listStack {
            let listWidth = max(0, panelWidth)
            let measured = stack.systemLayoutSizeFitting(
                CGSize(width: listWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            let height = min(max(ceil(measured), 44), Self.maximumListHeight)
            scroll.constraints.first {
                $0.identifier == "agentHistory.listHeight"
            }?.constant = height
            scroll.isScrollEnabled = measured > Self.maximumListHeight
        }

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
private final class AgentHistoryPanelRootView: UIView {
    /// visionOS's rounded platter mask crowds the last row, so the list gets
    /// a footer clearance there; iPad's square frame keeps the flush bottom.
    #if os(visionOS)
    private static let footerClearance: CGFloat = 10
    #else
    private static let footerClearance: CGFloat = 0
    #endif

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
            rootStack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Self.footerClearance
            ),
        ])
    }

    override var intrinsicContentSize: CGSize {
        fittingSize(for: width)
    }

    func fittingSize(for proposedWidth: CGFloat) -> CGSize {
        guard let rootStack else { return CGSize(width: proposedWidth, height: 0) }
        let measured = rootStack.systemLayoutSizeFitting(
            CGSize(width: proposedWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(
            width: proposedWidth,
            height: ceil(measured.height) + Self.footerClearance
        )
    }
}

@MainActor
private final class AgentHistoryMessageRowView: UIView {
    private let message: AgentUserMessage
    private let messageControl = UIControl()
    private let textStack = UIStackView()
    private var availableWidth: CGFloat
    private var expanded: Bool
    private let toggle: (Int) -> Void

    init(
        message: AgentUserMessage,
        expanded: Bool,
        availableWidth: CGFloat,
        showsJump: Bool,
        toggle: @escaping (Int) -> Void,
        jump: @escaping (AgentUserMessage) -> Void
    ) {
        self.message = message
        self.expanded = expanded
        self.availableWidth = availableWidth
        self.toggle = toggle
        super.init(frame: .zero)
        accessibilityIdentifier = "agentHistory.row.\(message.ordinal)"

        messageControl.isAccessibilityElement = true
        messageControl.accessibilityTraits = .button
        messageControl.accessibilityIdentifier = "agentHistory.message.\(message.ordinal)"
        messageControl.addTarget(self, action: #selector(togglePressed), for: .touchUpInside)
        #if os(visionOS)
        messageControl.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )
        #endif

        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 4
        textStack.isUserInteractionEnabled = true
        messageControl.addSubview(textStack)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: messageControl.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: messageControl.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: messageControl.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: messageControl.bottomAnchor),
        ])

        var rowViews: [UIView] = [messageControl]
        if showsJump {
            let jumpButton = UIKitChassisChip(
                "JUMP",
                accessibilityLabel: "Scroll the terminal back to this message",
                action: { jump(message) }
            )
            jumpButton.accessibilityIdentifier = "agentHistory.jump.\(message.ordinal)"
            jumpButton.setContentHuggingPriority(.required, for: .horizontal)
            jumpButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            rowViews.append(jumpButton)
        }

        let row = UIStackView(arrangedSubviews: rowViews)
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        let inset = UIKitChassis.popoverPanelInset
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        messageControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        messageControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        renderText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setExpanded(_ expanded: Bool) {
        guard self.expanded != expanded else { return }
        self.expanded = expanded
        renderText()
    }

    private func renderText() {
        textStack.arrangedSubviews.forEach {
            textStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        messageControl.accessibilityLabel = expanded
            ? "Collapse message"
            : "Expand message"

        if expanded {
            let fullText = AgentHistorySelectableTextView(text: message.text)
            fullText.accessibilityIdentifier = "agentHistory.fullText.\(message.ordinal)"
            let tap = UITapGestureRecognizer(target: self, action: #selector(togglePressed))
            tap.cancelsTouchesInView = false
            fullText.addGestureRecognizer(tap)

            if message.text.count > 900 {
                fullText.isScrollEnabled = true
                let textWidth = max(1, availableWidth - 28)
                let measured = fullText.sizeThatFits(CGSize(
                    width: textWidth,
                    height: .greatestFiniteMagnitude
                )).height
                fullText.heightAnchor.constraint(
                    equalToConstant: min(ceil(measured), 220)
                ).isActive = true
            } else {
                fullText.isScrollEnabled = false
            }
            textStack.addArrangedSubview(fullText)
        } else {
            let preview = AgentHistoryTextLabel(
                message.firstLine,
                font: UIKitChassis.monoFont(11),
                color: UIKitChassis.signal
            )
            preview.numberOfLines = 2
            preview.lineBreakMode = .byTruncatingTail
            textStack.addArrangedSubview(preview)
        }

        if let stamp = Self.timestampLabel(message.timestamp) {
            let timestamp = AgentHistoryTextLabel(
                stamp,
                font: UIKitChassis.monoFont(8, weight: .medium),
                color: UIKitChassis.signal3
            )
            textStack.addArrangedSubview(timestamp)
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @objc private func togglePressed() {
        toggle(message.ordinal)
    }

    private static func timestampLabel(_ date: Date?) -> String? {
        guard let date else { return nil }
        return stampFormatter.localizedString(for: date, relativeTo: Date())
            .uppercased()
    }

    private static let stampFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

@MainActor
private final class AgentHistorySelectableTextView: UITextView {
    init(text: String) {
        super.init(frame: .zero, textContainer: nil)
        self.text = text
        font = UIKitChassis.monoFont(11)
        textColor = UIKitChassis.signal
        backgroundColor = .clear
        isEditable = false
        isSelectable = true
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        contentInset = .zero
        showsVerticalScrollIndicator = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
private final class AgentHistoryTextLabel: UILabel {
    private let sourceColor: UIColor

    init(_ text: String, font: UIFont, color: UIColor) {
        sourceColor = color
        super.init(frame: .zero)
        self.text = text
        self.font = font
        textColor = color
        numberOfLines = 1
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        textColor = sourceColor
    }
}

@MainActor
private extension UIStackView {
    /// A status row is centered without introducing an extra wrapper whose
    /// intrinsic width could compete with the panel's fixed width.
    func justifyContentInCenter() {
        let leading = UIView()
        let trailing = UIView()
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
        insertArrangedSubview(leading, at: 0)
        addArrangedSubview(trailing)
        // Both guides must be in this stack's view hierarchy before UIKit
        // can activate their cross-view equality constraint. Activating it
        // first raises an NSGenericException in every status-row render.
        leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true
    }
}
