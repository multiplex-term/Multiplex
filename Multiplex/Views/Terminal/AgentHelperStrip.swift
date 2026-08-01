import Observation
import UIKit
#if DEBUG
import notify
#endif

@MainActor
struct AgentHelperStripConfiguration {
    var agent: AgentKind
    var canShowCommands: Bool
    var builtInPlacements: [String: AgentCommandPlacement]
    var customCommands: [CustomAgentCommand]
    var historyController: TerminalSessionController?
    var historyLocked: Bool
    var floating: Bool
    var floatingMaximumWidth: CGFloat?
    var contentSafeArea: UIEdgeInsets
    var send: (AgentCommand) -> Void
    var saveCommandConfiguration: (
        [CustomAgentCommand],
        [String: AgentCommandPlacement]
    ) -> Void
    var openPaywall: () -> Void
    var isFocusOwner: () -> Bool
}

enum AgentHelperStripAction: Equatable {
    case send(AgentCommand)
    case openPaywall
    case customize
    case history
}

/// Native quick-command bezel for the CLI agent detected in the attached
/// tmux pane. UIKit owns its horizontal command rail, MORE menu, HISTORY and
/// command-editor popovers, accessibility, live observation, and sizing.
@MainActor
final class AgentHelperStripViewController: UIViewController,
    UIPopoverPresentationControllerDelegate
{
    /// Callbacks and controller references are read from `configuration` when
    /// used. Only values that change the rendered hierarchy, menu, or layout
    /// belong here, so routine parent updates keep popover anchors stable.
    private struct RenderKey: Equatable {
        let agent: AgentKind
        let canShowCommands: Bool
        let builtInPlacements: [String: AgentCommandPlacement]
        let customCommands: [CustomAgentCommand]
        let historyAvailable: Bool
        let floating: Bool
        let floatingMaximumWidth: CGFloat
        let safeAreaLeft: CGFloat
        let safeAreaRight: CGFloat
    }

    /// What the live Observation registration is armed against. Everything
    /// else a configuration carries is read at render time, so only a move
    /// here needs a fresh — and uncancellable — tracking.
    private struct ObservationKey: Equatable {
        let agent: AgentKind
        let historyController: ObjectIdentifier?
    }

    nonisolated static let dockedHeight: CGFloat = 48
    nonisolated static let chipHeight: CGFloat = 22
    nonisolated static let maximumFloatingWidth: CGFloat = 760
    nonisolated static let floatingEdgeClearance: CGFloat = 60

    private(set) var configuration: AgentHelperStripConfiguration
    private let rootView = AgentHelperStripRootView()
    private weak var moreButton: AgentHelperStripButton?
    private weak var historyButton: AgentHelperStripButton?
    private weak var customPanelController: CustomAgentCommandPanelViewController?
    private weak var historyPanelController: AgentHistoryPanelViewController?
    private var observationGeneration = 0
    private var observedKey: ObservationKey?
    private var renderedKey: RenderKey?
    private(set) var historyAvailable = false
    #if DEBUG
    private var debugObservers: [NSObjectProtocol] = []
    #endif

    init(configuration: AgentHelperStripConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = rootView
        #if DEBUG
        installDebugObservers()
        #endif
        renderAndObserve()
    }

    func update(configuration: AgentHelperStripConfiguration) {
        let changedAgent = self.configuration.agent != configuration.agent
        self.configuration = configuration
        if changedAgent {
            dismissOpenPanels(animated: false)
        }
        guard isViewLoaded else { return }
        // A tracking is one-shot and cannot be cancelled, while the parent
        // re-renders on every probe tick — re-arming here stranded one dead
        // registration per render on a controller whose status stays `.live`
        // for hours. The live one still speaks for an unchanged identity, so
        // routine updates only re-render.
        guard observationKey != observedKey else {
            renderIfNeeded(available: historyAvailable)
            return
        }
        observationGeneration &+= 1
        renderAndObserve(generation: observationGeneration)
    }

    func fittingContentSize(for proposedWidth: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        return rootView.fittingSize(proposedWidth: proposedWidth)
    }

    func prepareForRemoval() {
        observationGeneration &+= 1
        // The bump retires the live chain, so a later update must re-arm.
        observedKey = nil
        dismissOpenPanels(animated: false)
        #if DEBUG
        for observer in debugObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        debugObservers.removeAll()
        #endif
    }

    /// One action seam backs direct chips, menu actions, lock routing, and
    /// focused UIKit tests.
    func perform(_ action: AgentHelperStripAction) {
        switch action {
        case .send(let command):
            configuration.send(command)
        case .openPaywall:
            configuration.openPaywall()
        case .customize:
            scheduleCustomCommandEditor()
        case .history:
            guard historyAvailable else { return }
            if configuration.historyLocked {
                configuration.openPaywall()
            } else {
                presentHistory()
            }
        }
    }

    var barBuiltInCommands: [AgentCommand] {
        AgentCommandSet.commands(
            in: .bar,
            for: configuration.agent,
            placementOverrides: configuration.builtInPlacements
        )
    }

    var moreBuiltInCommands: [AgentCommand] {
        AgentCommandSet.commands(
            in: .more,
            for: configuration.agent,
            placementOverrides: configuration.builtInPlacements
        )
    }

    var barCustomCommands: [CustomAgentCommand] {
        configuration.customCommands.filter { $0.barLabel != nil }
    }

    var moreCustomCommands: [CustomAgentCommand] {
        configuration.customCommands.filter { $0.barLabel == nil }
    }

    func makeMoreMenu() -> UIMenu {
        var groups: [UIMenuElement] = []
        let builtIns = moreBuiltInCommands.map { command in
            UIAction(title: command.label) { [weak self] _ in
                self?.perform(.send(command))
            }
        }
        if !builtIns.isEmpty {
            groups.append(UIMenu(options: .displayInline, children: builtIns))
        }

        let customs = moreCustomCommands.map { command in
            UIAction(title: command.menuLabel) { [weak self] _ in
                self?.perform(.send(command.agentCommand))
            }
        }
        if !customs.isEmpty {
            groups.append(UIMenu(
                title: "Custom",
                options: .displayInline,
                children: customs
            ))
        }

        let customize = UIAction(
            title: "Customize Commands…",
            image: UIImage(systemName: "slider.horizontal.3")
        ) { [weak self] _ in
            self?.perform(.customize)
        }
        groups.append(UIMenu(options: .displayInline, children: [customize]))
        return UIMenu(children: groups)
    }

    /// Injectable observation boundary for focused native tests. Production
    /// continuously derives this value from the @Observable session.
    func applyHistoryAvailability(_ available: Bool) {
        historyAvailable = available
        renderIfNeeded(available: available)
    }

    private var observationKey: ObservationKey {
        ObservationKey(
            agent: configuration.agent,
            historyController: configuration.historyController
                .map(ObjectIdentifier.init)
        )
    }

    private func renderAndObserve(generation: Int? = nil) {
        let generation = generation ?? {
            observationGeneration &+= 1
            return observationGeneration
        }()
        guard generation == observationGeneration else { return }
        observedKey = observationKey

        let available = withObservationTracking {
            configuration.agent == .claudeCode
                && configuration.historyController?.canOfferAgentHistory == true
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.renderAndObserve(generation: generation)
            }
        }
        historyAvailable = available
        renderIfNeeded(available: available)
    }

    private func renderIfNeeded(available: Bool) {
        let key = RenderKey(
            agent: configuration.agent,
            canShowCommands: configuration.canShowCommands,
            builtInPlacements: configuration.builtInPlacements,
            customCommands: configuration.customCommands,
            historyAvailable: available,
            floating: configuration.floating,
            floatingMaximumWidth: configuration.floatingMaximumWidth
                ?? Self.maximumFloatingWidth,
            safeAreaLeft: configuration.contentSafeArea.left,
            safeAreaRight: configuration.contentSafeArea.right
        )
        guard key != renderedKey else { return }
        renderedKey = key
        render(available: available)
    }

    private func render(available: Bool) {
        moreButton = nil
        historyButton = nil

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10

        let agent = UIKitChassisLabel(
            configuration.agent.displayName,
            size: 10,
            color: UIKitChassis.signal2
        )
        agent.accessibilityIdentifier = "agentHelpers.agent"
        agent.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(agent)

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 14),
        ])
        row.addArrangedSubview(divider)

        if configuration.canShowCommands {
            row.addArrangedSubview(makeCommandRail(historyAvailable: available))
        } else {
            let pro = AgentHelperStripButton(
                caption: "✳ AGENT HELPERS · PRO",
                prominent: true,
                accessibilityLabel: "Agent helpers Pro",
                action: { [weak self] in self?.perform(.openPaywall) }
            )
            pro.accessibilityIdentifier = "agentHelpers.pro"
            let detail = UILabel()
            detail.text = "Free daily command taps return tomorrow"
            detail.font = UIKitChassis.monoFont(8, weight: .medium)
            detail.textColor = UIKitChassis.signal3
            detail.numberOfLines = 1
            detail.lineBreakMode = .byTruncatingTail
            let locked = UIStackView(arrangedSubviews: [pro, detail])
            locked.axis = .vertical
            locked.alignment = .leading
            locked.spacing = 3
            row.addArrangedSubview(locked)
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
        }

        rootView.apply(
            content: row,
            floating: configuration.floating,
            floatingMaximumWidth: configuration.floatingMaximumWidth
                ?? Self.maximumFloatingWidth,
            safeArea: configuration.contentSafeArea
        )
        rootView.setNeedsLayout()
        rootView.layoutIfNeeded()
        preferredContentSize = fittingContentSize()
    }

    private func makeCommandRail(historyAvailable: Bool) -> UIView {
        let rail = UIStackView()
        rail.axis = .horizontal
        rail.alignment = .center
        rail.spacing = 6

        let scroll = AgentHelperCommandScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.clipsToBounds = true
        scroll.accessibilityIdentifier = "agentHelpers.commandScroll"
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: Self.chipHeight).isActive = true

        let commands = UIStackView()
        commands.axis = .horizontal
        commands.alignment = .center
        commands.spacing = 6
        scroll.addSubview(commands)
        commands.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            commands.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            commands.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            commands.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            commands.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            commands.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        for command in barCustomCommands {
            let button = AgentHelperStripButton(
                caption: command.barLabel ?? command.menuLabel,
                color: TallyPalette.customCommand,
                accessibilityLabel: "Custom command \(command.menuLabel), \(command.autoSubmit ? "auto submit" : "type only")",
                action: { [weak self] in self?.perform(.send(command.agentCommand)) }
            )
            button.accessibilityIdentifier = "agentHelpers.custom.\(command.id.uuidString)"
            commands.addArrangedSubview(button)
        }
        for command in barBuiltInCommands {
            let button = AgentHelperStripButton(
                caption: command.label,
                accessibilityLabel: command.label.capitalized,
                action: { [weak self] in self?.perform(.send(command)) }
            )
            button.accessibilityIdentifier = "agentHelpers.command.\(command.id)"
            commands.addArrangedSubview(button)
        }
        rail.addArrangedSubview(scroll)

        let more = AgentHelperStripButton(
            caption: "MORE",
            accessibilityLabel: "More \(configuration.agent.displayName) commands"
        )
        more.accessibilityIdentifier = "agentHelpers.more"
        more.menu = makeMoreMenu()
        more.showsMenuAsPrimaryAction = true
        more.setContentHuggingPriority(.required, for: .horizontal)
        more.setContentCompressionResistancePriority(.required, for: .horizontal)
        moreButton = more
        rail.addArrangedSubview(more)

        if historyAvailable {
            let history = AgentHelperStripButton(
                caption: "HIST",
                accessibilityLabel: "Message history for \(configuration.agent.displayName)",
                action: { [weak self] in self?.perform(.history) }
            )
            history.accessibilityIdentifier = "agentHelpers.history"
            history.setContentHuggingPriority(.required, for: .horizontal)
            history.setContentCompressionResistancePriority(.required, for: .horizontal)
            historyButton = history
            rail.addArrangedSubview(history)
        }
        return rail
    }

    // MARK: Native presentation

    private func scheduleCustomCommandEditor() {
        guard customPanelController == nil else { return }
        // MORE is still completing its menu-selection transaction here.
        DispatchQueue.main.async { [weak self] in
            self?.presentCustomCommandEditor()
        }
    }

    private func presentCustomCommandEditor() {
        guard customPanelController == nil,
              let anchor = moreButton,
              anchor.window != nil
        else { return }
        let sceneWidth = anchor.window?.bounds.width ?? view.bounds.width
        let width = min(
            CustomAgentCommandPanelViewController.preferredWidth,
            max(280, sceneWidth - 24)
        )
        let panel = CustomAgentCommandPanelViewController(
            agent: configuration.agent,
            commands: configuration.customCommands,
            builtInPlacements: configuration.builtInPlacements,
            width: width,
            save: { [weak self] commands, placements in
                guard let self else { return }
                self.configuration.saveCommandConfiguration(commands, placements)
                self.dismissCustomPanel(animated: true)
            },
            cancel: { [weak self] in
                self?.dismissCustomPanel(animated: true)
            }
        )
        customPanelController = panel
        panel.modalPresentationStyle = .popover
        panel.view.backgroundColor = UIKitChassis.bezel
        panel.preferredContentSize = panel.fittingContentSize()
        configurePopover(panel, sourceView: anchor)
        present(panel, animated: true)
    }

    private func presentHistory() {
        guard historyPanelController == nil,
              let controller = configuration.historyController,
              let anchor = historyButton,
              anchor.window != nil
        else { return }
        let sceneWidth = anchor.window?.bounds.width ?? view.bounds.width
        let width = min(
            AgentHistoryPanelViewController.preferredWidth,
            max(280, sceneWidth - 24)
        )
        let panel = AgentHistoryPanelViewController(
            agent: configuration.agent,
            controller: controller,
            width: width,
            dismiss: { [weak self] in
                self?.dismissHistoryPanel(animated: true)
            }
        )
        historyPanelController = panel
        panel.modalPresentationStyle = .popover
        panel.view.backgroundColor = UIKitChassis.bezel
        panel.preferredContentSize = panel.fittingContentSize()
        configurePopover(panel, sourceView: anchor)
        present(panel, animated: true)
    }

    private func configurePopover(_ panel: UIViewController, sourceView: UIView) {
        guard let popover = panel.popoverPresentationController else { return }
        popover.sourceView = sourceView
        popover.sourceRect = sourceView.bounds
        popover.permittedArrowDirections = .down
        #if !os(visionOS)
        popover.backgroundColor = UIKitChassis.bezel
        #endif
        popover.delegate = self
    }

    private func dismissCustomPanel(animated: Bool) {
        guard let panel = customPanelController else { return }
        customPanelController = nil
        panel.prepareForRemoval()
        panel.dismiss(animated: animated)
    }

    private func dismissHistoryPanel(animated: Bool) {
        guard let panel = historyPanelController else { return }
        historyPanelController = nil
        panel.prepareForRemoval()
        panel.dismiss(animated: animated)
    }

    private func dismissOpenPanels(animated: Bool) {
        dismissCustomPanel(animated: animated)
        dismissHistoryPanel(animated: animated)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        let presented = presentationController.presentedViewController
        if presented === customPanelController {
            customPanelController?.prepareForRemoval()
            customPanelController = nil
        } else if presented === historyPanelController {
            historyPanelController?.prepareForRemoval()
            historyPanelController = nil
        }
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController
    ) -> UIModalPresentationStyle {
        .none
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }

    #if DEBUG
    private func installDebugObservers() {
        CustomCommandsDebugHook.install()
        AgentHistoryDebugHook.install()

        debugObservers.append(NotificationCenter.default.addObserver(
            forName: .multiplexDebugCustomCommands,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.configuration.isFocusOwner() else { return }
                self.perform(.customize)
            }
        })
        debugObservers.append(NotificationCenter.default.addObserver(
            forName: .multiplexDebugAgentHistory,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.configuration.isFocusOwner(),
                      self.configuration.agent == .claudeCode,
                      self.historyAvailable,
                      !self.configuration.historyLocked
                else { return }
                self.perform(.history)
            }
        })
    }
    #endif
}

// MARK: - Native strip components

@MainActor
private final class AgentHelperStripRootView: UIKitTallyBorderedView {
    private weak var content: UIView?
    private let topRule = UIView()
    private var floating = false
    private var floatingMaximumWidth = AgentHelperStripViewController.maximumFloatingWidth
    private var safeAreaInsetsForContent = UIEdgeInsets.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        topRule.backgroundColor = UIKitChassis.bezelHi
        topRule.isUserInteractionEnabled = false
        addSubview(topRule)
        topRule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: topAnchor),
            topRule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(
        content: UIView,
        floating: Bool,
        floatingMaximumWidth: CGFloat,
        safeArea: UIEdgeInsets
    ) {
        self.content?.removeFromSuperview()
        self.content = content
        self.floating = floating
        self.floatingMaximumWidth = floatingMaximumWidth
        safeAreaInsetsForContent = safeArea
        backgroundColor = UIKitChassis.bezel
        layer.cornerRadius = floating ? 12 : 0
        layer.cornerCurve = .continuous
        layer.borderWidth = floating ? 1 : 0
        tallyBorderColor = UIKitChassis.bezelHi
        topRule.isHidden = floating

        addSubview(content)
        bringSubviewToFront(topRule)
        content.translatesAutoresizingMaskIntoConstraints = false
        if floating {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                content.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            ])
        } else {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: 12 + safeArea.left
                ),
                content.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -(12 + safeArea.right)
                ),
                content.centerYAnchor.constraint(equalTo: centerYAnchor),
                content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 1),
            ])
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        fittingSize(proposedWidth: nil)
    }

    func fittingSize(proposedWidth: CGFloat?) -> CGSize {
        guard let content else {
            return CGSize(
                width: proposedWidth ?? UIView.noIntrinsicMetric,
                height: floating ? 0 : AgentHelperStripViewController.dockedHeight
            )
        }
        let horizontalInsets: CGFloat = floating
            ? 32
            : 24 + safeAreaInsetsForContent.left + safeAreaInsetsForContent.right
        let maximum = floating ? floatingMaximumWidth : (proposedWidth ?? .greatestFiniteMagnitude)
        let available = max(1, min(proposedWidth ?? maximum, maximum) - horizontalInsets)
        let measured = content.systemLayoutSizeFitting(
            CGSize(width: available, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: proposedWidth == nil ? .fittingSizeLevel : .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if floating {
            let width = min(
                floatingMaximumWidth,
                proposedWidth ?? ceil(measured.width + horizontalInsets)
            )
            return CGSize(width: width, height: ceil(measured.height + 10))
        }
        return CGSize(
            width: proposedWidth ?? ceil(measured.width + horizontalInsets),
            height: AgentHelperStripViewController.dockedHeight
        )
    }
}

/// The command rail's scroller. Same contract as the tab rail's: a scroll
/// view delays content touches by 150 ms and drops them if the finger drifts
/// during that window, so an overflowing chip row loses ordinary presses.
/// Track at once, and keep drag-to-scroll from a chip by answering the cancel
/// question for controls, whose UIKit default (false) would otherwise pin the
/// rail once touches are undelayed.
@MainActor
final class AgentHelperCommandScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIButton { return true }
        return super.touchesShouldCancel(in: view)
    }
}

/// Native spelling of the 22-point ChassisBadge button. Its ink can be the
/// warmer custom-command neutral, and UIButton supplies primary-action menus.
@MainActor
private final class AgentHelperStripButton: UIButton {
    private let caption: String
    private let ink: UIColor
    private let prominent: Bool
    private var storedAction: (() -> Void)?

    init(
        caption: String,
        color: UIColor? = nil,
        prominent: Bool = false,
        accessibilityLabel: String,
        action: (() -> Void)? = nil
    ) {
        self.caption = caption
        ink = color ?? UIKitChassis.signal2
        self.prominent = prominent
        storedAction = action
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.strataChassis
        layer.borderWidth = 1
        contentEdgeInsets = UIEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        titleLabel?.numberOfLines = 1
        self.accessibilityLabel = accessibilityLabel
        accessibilityTraits = .button
        if storedAction != nil {
            addTarget(self, action: #selector(pressed), for: .touchUpInside)
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: AgentHelperStripViewController.chipHeight)
            .isActive = true
        #if os(visionOS)
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        #endif
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func pressed() {
        storedAction?()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshAppearance()
    }

    private func refreshAppearance() {
        layer.borderColor = (prominent ? UIKitChassis.signal2 : UIKitChassis.bezelHi)
            .resolvedColor(with: traitCollection).cgColor
        setAttributedTitle(
            NSAttributedString(
                string: caption,
                attributes: [
                    .font: UIKitChassis.monoFont(9, weight: .semibold),
                    .kern: 1.1,
                    .foregroundColor: (prominent ? UIKitChassis.signal : ink)
                        .resolvedColor(with: traitCollection),
                ]
            ),
            for: .normal
        )
    }
}

#if DEBUG
extension Notification.Name {
    static let multiplexDebugAgentChip = Notification.Name("MultiplexDebugAgentChip")
    static let multiplexDebugCustomCommands = Notification.Name(
        "MultiplexDebugCustomCommands"
    )
    static let multiplexDebugAgentHistory = Notification.Name(
        "MultiplexDebugAgentHistory"
    )
}

/// Opens the focused terminal's HISTORY panel for layout capture and
/// headless checks. The strip's focus-owner guard keeps one Darwin
/// notification from presenting panels in several scenes.
@MainActor
enum AgentHistoryDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.msghistory", &token, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugAgentHistory,
                object: nil
            )
        }
    }
}

/// Opens the focused terminal's real Command Setup editor for layout capture.
@MainActor
enum CustomCommandsDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.customcommands", &token, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugCustomCommands,
                object: nil
            )
        }
    }
}

/// Headless-verification hook for the first focused slash chip.
@MainActor
enum AgentChipDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.agentchip", &token, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugAgentChip, object: nil)
        }
    }
}

#endif
