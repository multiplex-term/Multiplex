import Observation
import UIKit
#if DEBUG
import notify
#endif

enum UMDBarStyle: Equatable {
    /// The visionOS classic window's title row. The terminal key cluster
    /// flanks this controller in the still-transitional scene root.
    case regular
    /// The adaptive single-window shell's slim full-width top rail.
    case shell
}

@MainActor
struct UMDBarConfiguration {
    var controller: TerminalSessionController?
    var title: String
    var mergeSources: [TerminalWorkspace.WindowEntry]
    var showDeck: () -> Void
    var fontDown: () -> Void
    var fontUp: () -> Void
    var newSession: (AgentKind?) -> Void
    /// Runs the herdr-only New Tab in Workspace entry; the row renders
    /// only when `extraNewTabTarget` says the active tab offers it.
    var newHerdrWorkspaceTab: () -> Void
    var openFileViewer: () -> Void
    var merge: (UUID) -> Void
    var detach: () -> Void
    var closeSession: (() -> Void)?
    var keychainTip: (() -> Void)?
    /// Opens the Connection Stats board drilled into this window's host.
    /// nil while the global stats setting is off — the row disappears with
    /// every other entry.
    var showConnectionStats: (() -> Void)?
    /// The herdr-only second `+ TAB` entry, if the active tab offers one —
    /// New Session leads the menu on every backend (see
    /// `TerminalRoute.NewTabTarget`).
    var extraNewTabTarget: TerminalRoute.NewTabTarget?
    /// Which multiplexer owns the shortcut chip (TMUX/HRDR); nil hides it.
    var shortcutBackend: Host.SessionBackend?
    var style: UMDBarStyle
    var deckControlLabel: String
    var availableWidth: CGFloat?
    var contentSafeArea: UIEdgeInsets
    /// Chassis above and below the rail's faces. The shell keeps the
    /// authored 8; the classic window buys terminal rows with a tighter one
    /// (it is a title bar, and it already spends the scene's top strip).
    var contentVerticalPadding: CGFloat = 8
    /// Content width of the pane's own key rail, which carries the TMUX/HRDR
    /// key until it runs out of room. The rail takes that key over exactly
    /// when the key rail drops it — measuring the KEY RAIL, never this rail's
    /// own width, is what keeps the two from drawing it at once (a rail
    /// clearing the window-control pill is ~90 pt narrower than the pane
    /// below it). nil means no key rail exists — visionOS, where the rail is
    /// the only road.
    var keyRailContentWidth: CGFloat?
    /// Floor for the rail's own height, excluding any top strip it spends.
    /// The classic window's title bar matches the key rail at the other end
    /// of the pane; its faces keep their size and centre in the extra room.
    var minimumContentHeight: CGFloat = 0
}

struct UMDBarObservedState: Equatable {
    var status: TerminalSessionController.Status?
    var contactLost: Bool
    var needsYou: Bool
    var keyboardLocked: Bool
    var hardwareKeyboardConnected: Bool
}

private struct UMDBarMergeSourceKey: Equatable {
    var id: UUID
    var label: String
}

private struct UMDBarPresentationKey: Equatable {
    var controllerID: ObjectIdentifier?
    var title: String
    var mergeSources: [UMDBarMergeSourceKey]
    var hasCloseSession: Bool
    var hasKeychainTip: Bool
    var extraNewTabTarget: TerminalRoute.NewTabTarget?
    var shortcutBackend: Host.SessionBackend?
    var style: UMDBarStyle
    var deckControlLabel: String
    var availableWidth: CGFloat?
    var contentSafeArea: UIEdgeInsets
    var contentVerticalPadding: CGFloat
    var keyRailContentWidth: CGFloat?
    var minimumContentHeight: CGFloat

    @MainActor
    init(_ configuration: UMDBarConfiguration) {
        controllerID = configuration.controller.map(ObjectIdentifier.init)
        title = configuration.title
        mergeSources = configuration.mergeSources.map {
            UMDBarMergeSourceKey(id: $0.id, label: $0.label)
        }
        hasCloseSession = configuration.closeSession != nil
        hasKeychainTip = configuration.keychainTip != nil
        extraNewTabTarget = configuration.extraNewTabTarget
        shortcutBackend = configuration.shortcutBackend
        style = configuration.style
        deckControlLabel = configuration.deckControlLabel
        availableWidth = configuration.availableWidth
        contentSafeArea = configuration.contentSafeArea
        contentVerticalPadding = configuration.contentVerticalPadding
        keyRailContentWidth = configuration.keyRailContentWidth
        minimumContentHeight = configuration.minimumContentHeight
    }
}

private struct UMDBarRenderKey: Equatable {
    var presentation: UMDBarPresentationKey
    var observed: UMDBarObservedState
}

enum UMDBarAction: Equatable {
    case showDeck
    case fontDown
    case fontUp
    case newSession(AgentKind?)
    case newHerdrWorkspaceTab
    case openFileViewer
    case merge(UUID)
    case mergeAll
    case detach
    case closeSession
    case toggleKeyboardLock
    case showGuide
    case showConnectionStats
    case attach(FileAttachPicker)
}

/// Native under-monitor display. It owns every chip, menu, tally, adaptive
/// compact decision, attachment presenter, and tmux popover; SwiftUI only
/// mounts this controller until the surrounding terminal scene migrates.
@MainActor
final class UMDBarViewController: UIViewController,
    UIPopoverPresentationControllerDelegate
{
    private var configuration: UMDBarConfiguration
    private let rootView = UMDBarRootView()
    private(set) var fileAttachController: FileAttachMenuViewController
    private weak var shortcutPopoverController: ShortcutPanelViewController?
    private weak var shortcutButtonView: UMDBarButton?
    private weak var guideNavigationController: UINavigationController?
    private weak var guideFocusController: TerminalSessionController?
    private var resumesFocusAfterShortcutPanel = false
    private var resumesFocusAfterGuide = false
    #if DEBUG
    private var debugObservers: [NSObjectProtocol] = []
    #endif
    private var observationGeneration = 0
    private var renderedKey: UMDBarRenderKey?
    private var currentObservedState = UMDBarObservedState(
        status: nil,
        contactLost: false,
        needsYou: false,
        keyboardLocked: false,
        hardwareKeyboardConnected: false
    )

    init(configuration: UMDBarConfiguration) {
        self.configuration = configuration
        fileAttachController = FileAttachMenuViewController(
            controller: configuration.controller
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = rootView
        #if !os(visionOS)
        HardwareKeyboardMonitor.shared.startIfNeeded()
        #endif
        addChild(fileAttachController)
        rootView.parkFileAttachView(fileAttachController.view)
        fileAttachController.didMove(toParent: self)
        #if DEBUG
        installDebugObservers()
        #endif
        renderAndObserve()
    }

    func update(configuration: UMDBarConfiguration) {
        let previousKey = UMDBarPresentationKey(self.configuration)
        self.configuration = configuration
        let nextKey = UMDBarPresentationKey(configuration)
        guard previousKey != nextKey else { return }
        fileAttachController.update(controller: configuration.controller)
        guard isViewLoaded else { return }
        observationGeneration &+= 1
        renderAndObserve(generation: observationGeneration)
    }

    func fittingContentSize(for proposedWidth: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        return rootView.fittingSize(
            proposedWidth: proposedWidth ?? configuration.availableWidth
        )
    }

    func prepareForRemoval() {
        observationGeneration &+= 1
        shortcutPopoverController?.dismiss(animated: false)
        shortcutPopoverController = nil
        resumeFocusAfterShortcutPresentationIfNeeded()
        guideNavigationController?.dismiss(animated: false)
        guideNavigationController = nil
        resumeFocusAfterGuidePresentationIfNeeded()
        #if DEBUG
        for observer in debugObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        debugObservers.removeAll()
        #endif
    }

    /// One action router backs direct controls and every UIMenu item, making
    /// the native menu surface testable without duplicating callback logic.
    func perform(_ action: UMDBarAction) {
        switch action {
        case .showDeck:
            configuration.showDeck()
        case .fontDown:
            configuration.fontDown()
        case .fontUp:
            configuration.fontUp()
        case .newSession(let agent):
            configuration.newSession(agent)
        case .newHerdrWorkspaceTab:
            configuration.newHerdrWorkspaceTab()
        case .openFileViewer:
            configuration.openFileViewer()
        case .merge(let id):
            configuration.merge(id)
        case .mergeAll:
            for source in configuration.mergeSources {
                configuration.merge(source.id)
            }
        case .detach:
            configuration.detach()
        case .closeSession:
            configuration.closeSession?()
        case .toggleKeyboardLock:
            #if !os(visionOS)
            configuration.controller?.toggleKeyboardLock()
            #endif
        case .showGuide:
            showGuide()
        case .showConnectionStats:
            configuration.showConnectionStats?()
        case .attach(let picker):
            fileAttachController.request(
                picker,
                target: configuration.controller
            )
        }
    }

    /// UIKit-focused tests can paint each coherent service snapshot without
    /// mutating the controller's private(set) transport state.
    func applyObservedState(_ state: UMDBarObservedState) {
        currentObservedState = state
        render(state)
    }

    private func renderAndObserve(generation: Int? = nil) {
        let generation = generation ?? {
            observationGeneration &+= 1
            return observationGeneration
        }()
        guard generation == observationGeneration else { return }

        let state = withObservationTracking {
            UMDBarObservedState(
                status: configuration.controller?.status,
                contactLost: configuration.controller?.contactLost ?? false,
                needsYou: {
                    if case .needsYou = configuration.controller?.directShellAttention {
                        return true
                    }
                    return false
                }(),
                keyboardLocked: KeyboardLock.shared.isLocked,
                hardwareKeyboardConnected: {
                    #if os(visionOS)
                    false
                    #else
                    HardwareKeyboardMonitor.shared.isConnected
                    #endif
                }()
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.renderAndObserve(generation: generation)
            }
        }
        currentObservedState = state
        render(state)
    }

    private func render(_ state: UMDBarObservedState) {
        let key = UMDBarRenderKey(
            presentation: UMDBarPresentationKey(configuration),
            observed: state
        )
        guard renderedKey != key else { return }
        renderedKey = key
        fileAttachController.parkAttachButton()

        let content: UIView
        switch configuration.style {
        case .regular:
            content = makeRegularRow(state: state)
        case .shell:
            content = makeShellContent(state: state)
        }
        rootView.apply(
            content: content,
            style: configuration.style,
            availableWidth: configuration.availableWidth,
            safeArea: configuration.contentSafeArea,
            verticalPadding: configuration.contentVerticalPadding,
            minimumHeight: configuration.minimumContentHeight
        )
        view.setNeedsLayout()
        view.layoutIfNeeded()
        preferredContentSize = fittingContentSize()
    }

    private func makeRegularRow(state: UMDBarObservedState) -> UIView {
        var views: [UIView] = [
            actionButton(
                caption: "DECK",
                identifier: "umd.deck",
                accessibilityLabel: "Deck",
                action: .showDeck
            ),
            divider(),
            titleLabel(size: 12),
            statusCluster(state),
            divider(),
            actionButton(
                caption: "A−",
                identifier: "umd.fontDown",
                accessibilityLabel: "A−",
                action: .fontDown
            ),
            actionButton(
                caption: "A+",
                identifier: "umd.fontUp",
                accessibilityLabel: "A+",
                action: .fontUp
            ),
            newTabButton(),
        ]

        views.append(fileAttachController.takeAttachButton())
        if let backend = configuration.shortcutBackend {
            views.append(shortcutButton(backend))
        }
        if !configuration.mergeSources.isEmpty {
            views.append(mergeButton())
        }
        views.append(guideButton())
        if let overflow = overflowButtonIfNeeded(displacesDirectActions: false) {
            views.append(overflow)
        }
        views.append(divider())
        views.append(detachButton())

        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        row.accessibilityIdentifier = "umd.regular"
        return row
    }

    private func makeShellContent(state: UMDBarObservedState) -> UIView {
        let wide = makeShellRow(state: state, showsDirectActions: true)
        let idealWidth = wide.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        ).width + 20
        let available = configuration.availableWidth ?? .greatestFiniteMagnitude

        if idealWidth <= available {
            wide.accessibilityIdentifier = "umd.shell.wide"
            return wide
        }

        fileAttachController.parkAttachButton()
        let compact = makeShellRow(state: state, showsDirectActions: false)
        compact.accessibilityIdentifier = "umd.shell.compact"
        return compact
    }

    private func makeShellRow(
        state: UMDBarObservedState,
        showsDirectActions: Bool
    ) -> UIStackView {
        let deck = actionButton(
            caption: configuration.deckControlLabel,
            identifier: "umd.deck",
            accessibilityLabel: configuration.deckControlLabel.capitalized,
            action: .showDeck
        )
        deck.setContentHuggingPriority(.required, for: .horizontal)
        deck.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = titleLabel(size: 11)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let status = statusCluster(state)
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true

        var views: [UIView] = [deck, title, status, spacer]
        if showsDirectActions {
            views.append(actionButton(
                caption: "A−",
                identifier: "umd.fontDown",
                accessibilityLabel: "A−",
                action: .fontDown
            ))
            views.append(actionButton(
                caption: "A+",
                identifier: "umd.fontUp",
                accessibilityLabel: "A+",
                action: .fontUp
            ))
            views.append(newTabButton())
            views.append(fileAttachController.takeAttachButton())
            if let backend = configuration.shortcutBackend,
               showsTopBarShortcut(state: state) {
                views.append(shortcutButton(backend))
            }
            // MERGE is a window-level road and belongs beside DETACH; the
            // wide row is the only place it fits (the overflow carries it
            // only when it displaces the direct actions).
            if !configuration.mergeSources.isEmpty {
                views.append(mergeButton())
            }
            views.append(guideButton())
            if let overflow = overflowButtonIfNeeded(
                displacesDirectActions: false
            ) {
                views.append(overflow)
            }
            views.append(detachButton())
        } else {
            if let overflow = overflowButtonIfNeeded(
                displacesDirectActions: true
            ) {
                views.append(overflow)
            }
            if let backend = configuration.shortcutBackend,
               showsTopBarShortcut(state: state) {
                views.append(shortcutButton(backend))
            }
        }

        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 9
        return row
    }

    /// TMUX/HRDR names one road, and exactly one rail may draw it. The pane's
    /// key rail owns it wherever it fits — so the top bar asks about the KEY
    /// RAIL's width, not its own (measuring its own is how a wide iPhone
    /// landscape rail drew a second chip above the one already on the key
    /// rail). Only where no key rail exists (visionOS) does the bar own it
    /// outright.
    private func showsTopBarShortcut(state: UMDBarObservedState) -> Bool {
        guard configuration.shortcutBackend != nil else { return false }
        guard let keyRailWidth = configuration.keyRailContentWidth else { return true }
        return SingleWindowShellLayout.showsTopBarTmuxShortcut(
            availableWidth: keyRailWidth,
            supportsTmuxShortcuts: true,
            keyBarIncludesReturnKey: state.keyboardLocked || keyRailAlwaysShowsReturn
        )
    }

    /// `TerminalKeyBar` gives every iPad a RET key, which is what moves its
    /// shortcut cutoff to the wider tier.
    private var keyRailAlwaysShowsReturn: Bool {
        #if os(visionOS)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    private func titleLabel(size: CGFloat) -> UIKitChassisLabel {
        let label = UIKitChassisLabel(configuration.title, size: size)
        label.accessibilityIdentifier = "umd.title"
        return label
    }

    private func divider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18),
        ])
        divider.isAccessibilityElement = false
        return divider
    }

    private func actionButton(
        caption: String,
        systemImage: String? = nil,
        prominent: Bool = false,
        identifier: String,
        accessibilityLabel: String,
        action: UMDBarAction
    ) -> UMDBarButton {
        let button = UMDBarButton(
            caption: caption,
            systemImage: systemImage,
            prominent: prominent,
            accessibilityLabel: accessibilityLabel
        )
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { [weak self] _ in self?.perform(action) }, for: .touchUpInside)
        return button
    }

    private func menuButton(
        caption: String,
        systemImage: String? = nil,
        prominent: Bool = false,
        identifier: String,
        accessibilityLabel: String,
        menu: UIMenu
    ) -> UMDBarButton {
        let button = UMDBarButton(
            caption: caption,
            systemImage: systemImage,
            prominent: prominent,
            accessibilityLabel: accessibilityLabel
        )
        button.accessibilityIdentifier = identifier
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func newTabButton() -> UMDBarButton {
        menuButton(
            caption: "TAB",
            systemImage: "plus",
            identifier: "umd.newTab",
            accessibilityLabel: TerminalRoute.NewTabTarget
                .controlAccessibilityLabel(offering: configuration.extraNewTabTarget),
            menu: makeNewTabMenu()
        )
    }

    private func mergeButton() -> UMDBarButton {
        menuButton(
            caption: "MERGE",
            identifier: "umd.merge",
            accessibilityLabel: "Merge another window into this one",
            menu: makeMergeMenu(titled: false)
        )
    }

    /// GUIDE is a direct chip wherever the rail has room; only the compact
    /// row — which displaces every direct action — carries it in the `⋯`.
    private func guideButton() -> UMDBarButton {
        actionButton(
            caption: "GUIDE",
            identifier: "umd.guide",
            accessibilityLabel: "Guide",
            action: .showGuide
        )
    }

    private func detachButton() -> UMDBarButton {
        guard configuration.closeSession != nil else {
            return actionButton(
                caption: "DETACH",
                prominent: true,
                identifier: "umd.detach",
                accessibilityLabel: "Detach",
                action: .detach
            )
        }
        return menuButton(
            caption: "DETACH",
            prominent: true,
            identifier: "umd.detach",
            accessibilityLabel: "Detach or close the session",
            menu: makeDetachMenu()
        )
    }

    private func overflowButtonIfNeeded(
        displacesDirectActions: Bool
    ) -> UMDBarButton? {
        let menu = makeOverflowMenu(
            displacesDirectActions: displacesDirectActions
        )
        guard !menu.children.isEmpty else { return nil }
        return menuButton(
            caption: "",
            systemImage: "ellipsis",
            identifier: "umd.overflow",
            accessibilityLabel: "Terminal actions",
            menu: menu
        )
    }

    /// The identifier names the chip's slot, not its occupant — tests and
    /// hooks address "umd.tmux" for either backend's shortcut chip.
    private func shortcutButton(_ backend: Host.SessionBackend) -> UMDBarButton {
        let button = UMDBarButton(
            caption: backend == .herdr ? "HRDR" : "TMUX",
            systemImage: "command",
            prominent: false,
            accessibilityLabel: backend == .herdr
                ? "Show herdr shortcuts"
                : "Show tmux shortcuts"
        )
        button.accessibilityIdentifier = "umd.tmux"
        button.isEnabled = currentObservedState.status == .live
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            self.showShortcutPanel(from: button)
        }, for: .touchUpInside)
        shortcutButtonView = button
        return button
    }

    private func statusCluster(_ state: UMDBarObservedState) -> UIView {
        var views: [UIView] = []
        if configuration.controller?.host.useMosh == true {
            let mosh = UMDStateBadgeView(
                caption: "MOSH",
                accessibilityLabel: "Connects over mosh"
            )
            mosh.accessibilityIdentifier = "umd.status.mosh"
            views.append(mosh)
        }

        switch state.status {
        case .live:
            let lamp = state.contactLost
                ? UIKitTallyLamp(caption: "NO LINK", color: TallyPalette.caution)
                : UIKitTallyLamp(caption: "LIVE", color: TallyPalette.tally)
            lamp.accessibilityIdentifier = state.contactLost
                ? "umd.status.noLink" : "umd.status.live"
            views.append(lamp)
        case .connecting:
            let lamp = UIKitTallyLamp(caption: "LINK", color: TallyPalette.caution)
            lamp.accessibilityIdentifier = "umd.status.link"
            views.append(lamp)
        case .ended:
            let lamp = UIKitTallyLamp(caption: "ENDED", color: TallyPalette.signal3)
            lamp.accessibilityIdentifier = "umd.status.ended"
            views.append(lamp)
        case nil:
            break
        }

        if configuration.keychainTip != nil {
            let lamp = UIKitTallyLamp(
                caption: "KEYCHAIN LOCKED",
                color: TallyPalette.caution
            )
            let button = UMDLampButton(
                lamp: lamp,
                accessibilityLabel: "The Mac's keychain is locked, so Claude Code shows signed out",
                accessibilityHint: "Shows how to unlock the keychain",
                action: { [weak self] in self?.configuration.keychainTip?() }
            )
            button.accessibilityIdentifier = "umd.status.keychain"
            views.append(button)
        }

        if state.needsYou {
            let lamp = UIKitTallyLamp(
                caption: "NEEDS YOU",
                color: TallyPalette.caution
            )
            lamp.accessibilityIdentifier = "umd.status.needsYou"
            views.append(lamp)
        }

        let cluster = UIStackView(arrangedSubviews: views)
        cluster.axis = .horizontal
        cluster.alignment = .center
        cluster.spacing = 8
        cluster.accessibilityIdentifier = "umd.status"
        return cluster
    }

    private func makeNewTabMenu() -> UIMenu {
        var sessionActions: [UIMenuElement] = [
            menuAction(
                title: TerminalRoute.NewTabTarget.session.menuTitle,
                identifier: "umd.newTab.session",
                action: .newSession(nil)
            ),
        ]
        sessionActions.append(contentsOf: AgentKind.allCases.map { agent in
            menuAction(
                title: agent.displayName,
                identifier: "umd.newTab.agent.\(agent.rawValue)",
                action: .newSession(agent)
            )
        })
        if configuration.extraNewTabTarget == .herdrWorkspaceTab {
            // Its own section: the row is remote-level — it adds a tab
            // inside the herdr client, never a Multiplex tab.
            sessionActions.append(UIMenu(
                title: "",
                options: .displayInline,
                children: [
                    menuAction(
                        title: TerminalRoute.NewTabTarget.herdrWorkspaceTab.menuTitle,
                        identifier: "umd.newTab.herdrWorkspaceTab",
                        action: .newHerdrWorkspaceTab
                    ),
                ]
            ))
        }
        let file = UIMenu(
            title: "",
            options: .displayInline,
            children: [
                menuAction(
                    title: "File Viewer",
                    identifier: "umd.newTab.fileViewer",
                    action: .openFileViewer
                ),
            ]
        )
        sessionActions.append(file)
        return UIMenu(children: sessionActions)
    }

    private func makeMergeMenu(titled: Bool) -> UIMenu {
        var children: [UIMenuElement] = configuration.mergeSources.map { source in
            menuAction(
                title: source.label,
                image: UIImage(systemName: "macwindow"),
                identifier: "umd.merge.\(source.id.uuidString)",
                action: .merge(source.id)
            )
        }
        if configuration.mergeSources.count > 1 {
            children.append(UIMenu(
                title: "",
                options: .displayInline,
                children: [
                    menuAction(
                        title: "Merge All Windows",
                        image: UIImage(systemName: "rectangle.stack"),
                        identifier: "umd.mergeAll",
                        action: .mergeAll
                    ),
                ]
            ))
        }
        return UIMenu(title: titled ? "Merge Window" : "", children: children)
    }

    private func makeDetachMenu() -> UIMenu {
        UIMenu(children: [
            menuAction(
                title: "Detach",
                identifier: "umd.detach.action",
                action: .detach
            ),
            menuAction(
                title: "Close Session",
                identifier: "umd.closeSession",
                attributes: .destructive,
                action: .closeSession
            ),
        ])
    }

    private func makeOverflowMenu(displacesDirectActions: Bool) -> UIMenu {
        var children: [UIMenuElement] = []
        #if !os(visionOS)
        let offersKeyboardLock = currentObservedState.keyboardLocked
            || !currentObservedState.hardwareKeyboardConnected
        if configuration.controller != nil, offersKeyboardLock {
            children.append(menuAction(
                title: currentObservedState.keyboardLocked
                    ? "Unlock Keyboard" : "Lock Keyboard Closed",
                image: UIImage(
                    systemName: currentObservedState.keyboardLocked
                        ? "lock.open" : "lock"
                ),
                identifier: "umd.keyboardLock",
                action: .toggleKeyboardLock
            ))
        }
        #endif
        if configuration.showConnectionStats != nil {
            children.append(menuAction(
                title: "Connection Stats…",
                image: UIImage(systemName: "waveform.path.ecg"),
                identifier: "umd.connectionStats",
                action: .showConnectionStats
            ))
        }
        if displacesDirectActions {
            // The wide rows carry GUIDE as its own chip; it rides the menu
            // only where the direct actions have been displaced.
            children.append(menuAction(
                title: "Guide",
                image: UIImage(systemName: "questionmark.circle"),
                identifier: "umd.guide.action",
                action: .showGuide
            ))
            children.append(UIMenu(
                title: "Text Size",
                options: .displayInline,
                children: [
                    menuAction(
                        title: "Smaller Text",
                        identifier: "umd.fontDown.action",
                        action: .fontDown
                    ),
                    menuAction(
                        title: "Larger Text",
                        identifier: "umd.fontUp.action",
                        action: .fontUp
                    ),
                ]
            ))
            children.append(UIMenu(title: "New Tab", children: makeNewTabMenu().children))
            if FileAttachAvailability.canOffer(for: configuration.controller) {
                children.append(makeFileAttachMenu())
            }
            if !configuration.mergeSources.isEmpty {
                children.append(makeMergeMenu(titled: true))
            }
            var closingActions: [UIMenuElement] = [
                menuAction(
                    title: "Detach",
                    identifier: "umd.detach.action",
                    action: .detach
                ),
            ]
            if configuration.closeSession != nil {
                closingActions.append(menuAction(
                    title: "Close Session",
                    identifier: "umd.closeSession",
                    attributes: .destructive,
                    action: .closeSession
                ))
            }
            children.append(UIMenu(
                title: "",
                options: .displayInline,
                children: closingActions
            ))
        }
        return UIMenu(children: children)
    }

    private func makeFileAttachMenu() -> UIMenu {
        let enabled = currentObservedState.status == .live
        var actions: [UIMenuElement] = []
        #if !os(visionOS)
        actions.append(menuAction(
            title: "Camera…",
            image: UIImage(systemName: "camera"),
            identifier: "umd.attach.camera",
            attributes: enabled && FileAttachAvailability.cameraAvailable
                ? [] : .disabled,
            action: .attach(.camera)
        ))
        #endif
        actions.append(menuAction(
            title: "Photo Library…",
            image: UIImage(systemName: "photo.on.rectangle"),
            identifier: "umd.attach.photos",
            attributes: enabled ? [] : .disabled,
            action: .attach(.photoLibrary)
        ))
        actions.append(menuAction(
            title: "Files…",
            image: UIImage(systemName: "folder"),
            identifier: "umd.attach.files",
            attributes: enabled ? [] : .disabled,
            action: .attach(.files)
        ))
        return UIMenu(
            title: "Send File…",
            image: UIImage(systemName: "paperclip"),
            children: actions
        )
    }

    private func menuAction(
        title: String,
        image: UIImage? = nil,
        identifier: String,
        attributes: UIMenuElement.Attributes = [],
        action: UMDBarAction
    ) -> UIAction {
        UIAction(
            title: title,
            image: image,
            identifier: UIAction.Identifier(identifier),
            attributes: attributes
        ) { [weak self] _ in
            self?.perform(action)
        }
    }

    private func showGuide() {
        guard guideNavigationController == nil,
              shortcutPopoverController == nil,
              presentedViewController == nil
        else { return }

        resumesFocusAfterGuide =
            configuration.controller?.suspendFocusForPresentation() == true
        guideFocusController = resumesFocusAfterGuide ? configuration.controller : nil
        let guide = TerminalGuideViewController(context: TerminalGuideContext(
            platform: terminalGuidePlatform,
            backendIsHerdr: configuration.shortcutBackend == .herdr
        ))
        guide.followAppAppearance(nil, presentedFrom: self)
        let navigation = UINavigationController(rootViewController: guide)
        navigation.navigationBar.prefersLargeTitles = false
        navigation.view.backgroundColor = GlassPrototype.clearedChassis
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        navigation.modalPresentationStyle = .formSheet
        guide.onDone = { [weak self, weak navigation] in
            navigation?.dismiss(animated: true) {
                self?.finishGuidePresentation()
            }
        }
        guideNavigationController = navigation
        navigation.presentationController?.delegate = self
        present(navigation, animated: true)
        guide.refreshDynamicTextColorsAfterTraitPropagation()
    }

    private var terminalGuidePlatform: TerminalGuideContext.Platform {
        #if os(visionOS)
        .vision
        #else
        UIDevice.current.userInterfaceIdiom == .phone ? .phone : .pad
        #endif
    }

    private func showShortcutPanel(from source: UIView) {
        guard shortcutPopoverController == nil,
              let content = ShortcutPanelContent.content(
                for: configuration.shortcutBackend
              ),
              configuration.controller?.status == .live
        else { return }

        if configuration.style == .shell {
            resumesFocusAfterShortcutPanel =
                configuration.controller?.suspendFocusForPresentation() == true
        }

        let panelWidth = min(
            ShortcutPanelViewController.preferredWidth,
            max(
                280,
                (configuration.availableWidth
                    ?? ShortcutPanelViewController.preferredWidth + 24) - 24
            )
        )
        let panel = ShortcutPanelViewController(
            content: content,
            width: panelWidth,
            select: { [weak self] item in
                guard let self else { return }
                if !item.keepsPanelOpen {
                    self.shortcutPopoverController?.dismiss(animated: true) {
                        self.resumeFocusAfterShortcutPresentationIfNeeded()
                    }
                }
                self.configuration.controller?.performPanelShortcut(item)
            },
            // A held resize row repeats coarse steps; the panel stays up
            // throughout, so no dismissal decision rides along.
            selectCoarse: { [weak self] item in
                self?.configuration.controller?.performPanelShortcutCoarse(item)
            },
            rename: { [weak self] item, name in
                self?.configuration.controller?.performPanelRename(item, to: name)
            },
            loadChoices: { [weak controller = configuration.controller] in
                await controller?.loadShortcutSwitchChoices()
            },
            // Switching leaves the panel up: the list is a switchboard, and
            // hopping workspaces should not cost a reopen. Focus resumes
            // when the panel is actually dismissed.
            selectChoice: { [weak self] choice in
                self?.configuration.controller?.selectShortcutSwitchChoice(choice)
            }
        )
        shortcutPopoverController = panel
        panel.modalPresentationStyle = .popover
        // visionOS hosts this popover in a window of its own; carry the
        // ornament mount's appearance override across or a pinned LIGHT
        // presents a dark panel. Inert wherever inheritance already works.
        panel.overrideUserInterfaceStyle = inheritedInterfaceStyleOverride
        panel.loadViewIfNeeded()
        // PROTOTYPE(GLASS): mirror the glass selection across the popover's
        // window like the style above, and ground the panel in smoke over
        // the popover's own platter.
        panel.view.traitOverrides[GlassAppearanceTrait.self] =
            view.traitCollection[GlassAppearanceTrait.self]
        panel.view.backgroundColor = GlassPrototype.popoverGround(
            fallback: TallyPalette.bezel
        )
        panel.preferredContentSize = panel.fittingContentSize()

        if let popover = panel.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
            popover.permittedArrowDirections = configuration.style == .regular
                ? .down : .up
            #if !os(visionOS)
            popover.backgroundColor = UIKitChassis.bezel
            #endif
            popover.delegate = self
        }
        present(panel, animated: true)
        // Labels built before the window attach can retain ink resolved
        // against the wrong traits (the visionOS retained-ink defect);
        // re-resolve once trait delivery has settled.
        panel.refreshDynamicTextColorsAfterTraitPropagation()
    }

    func presentationControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) {
        if let navigation = presentationController.presentedViewController
            as? UINavigationController,
           navigation.viewControllers.first is TerminalGuideViewController {
            finishGuidePresentation()
            return
        }
        shortcutPopoverController = nil
        resumeFocusAfterShortcutPresentationIfNeeded()
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

    private func resumeFocusAfterShortcutPresentationIfNeeded() {
        guard resumesFocusAfterShortcutPanel else { return }
        resumesFocusAfterShortcutPanel = false
        configuration.controller?.resumeFocusAfterPresentation()
    }

    private func finishGuidePresentation() {
        guideNavigationController = nil
        resumeFocusAfterGuidePresentationIfNeeded()
    }

    private func resumeFocusAfterGuidePresentationIfNeeded() {
        let controller = guideFocusController
        guideFocusController = nil
        guard resumesFocusAfterGuide else { return }
        resumesFocusAfterGuide = false
        controller?.resumeFocusAfterPresentation()
    }

    #if DEBUG
    private func installDebugObservers() {
        TerminalGuideDebugHook.install()
        debugObservers.append(NotificationCenter.default.addObserver(
            forName: .multiplexDebugTerminalGuide,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let terminalView = self.configuration.controller?.terminalView,
                      TerminalFocusArbiter.current === terminalView
                else { return }
                self.showGuide()
            }
        })

        #if os(visionOS)
        // The iPad key rail owns the other spelling of this hook; visionOS
        // opens the focused window's UMD shortcut panel directly.
        UMDTmuxShortcutsDebugHook.install()
        debugObservers.append(NotificationCenter.default.addObserver(
            forName: .multiplexDebugUMDTmuxShortcuts,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let terminalView = self.configuration.controller?.terminalView,
                      TerminalFocusArbiter.current === terminalView,
                      let button = self.shortcutButtonView
                else { return }
                self.showShortcutPanel(from: button)
            }
        })
        #endif
    }
    #endif
}

#if DEBUG
extension Notification.Name {
    static let multiplexDebugTerminalGuide = Notification.Name(
        "MultiplexDebugTerminalGuide"
    )

    #if os(visionOS)
    static let multiplexDebugUMDTmuxShortcuts = Notification.Name(
        "MultiplexDebugUMDTmuxShortcuts"
    )
    #endif
}

@MainActor
private enum TerminalGuideDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.guide", &token, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugTerminalGuide,
                object: nil
            )
        }
    }
}

#if os(visionOS)
@MainActor
private enum UMDTmuxShortcutsDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxshortcuts", &token, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugUMDTmuxShortcuts,
                object: nil
            )
        }
    }
}
#endif
#endif

@MainActor
final class UMDBarRootView: UIView {
    /// Chassis between the rail's faces and the window's side edges. Callers
    /// that reserve a wider corner (the classic title bar clearing the
    /// window-control pill) express it as clearance INCLUDING this.
    static let horizontalPadding: CGFloat = 10

    private let contentContainer = UIView()
    private let presenterParking = UIView()
    private let bottomRule = UIView()
    private weak var contentView: UIView?
    private var style = UMDBarStyle.regular
    private var availableWidth: CGFloat?
    private var safeArea = UIEdgeInsets.zero
    private var verticalPadding: CGFloat = 8
    private var minimumHeight: CGFloat = 0
    private var containerEdgeConstraints: [NSLayoutConstraint] = []
    private var contentEdgeConstraints: [NSLayoutConstraint] = []
    private var parkingConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.bezel
        presenterParking.clipsToBounds = true
        addSubview(contentContainer)
        addSubview(presenterParking)
        addSubview(bottomRule)
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        presenterParking.translatesAutoresizingMaskIntoConstraints = false
        bottomRule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            presenterParking.leadingAnchor.constraint(equalTo: leadingAnchor),
            presenterParking.topAnchor.constraint(equalTo: topAnchor),
            presenterParking.widthAnchor.constraint(equalToConstant: 0),
            presenterParking.heightAnchor.constraint(equalToConstant: 0),
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: 1),
        ])
        bottomRule.backgroundColor = UIKitChassis.bezelHi
        layer.borderWidth = 1
        refreshBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func parkFileAttachView(_ view: UIView) {
        NSLayoutConstraint.deactivate(parkingConstraints)
        parkingConstraints.removeAll()
        if let stack = view.superview as? UIStackView {
            stack.removeArrangedSubview(view)
        }
        view.removeFromSuperview()
        presenterParking.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        parkingConstraints = [
            view.leadingAnchor.constraint(equalTo: presenterParking.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: presenterParking.trailingAnchor),
            view.topAnchor.constraint(equalTo: presenterParking.topAnchor),
            view.bottomAnchor.constraint(equalTo: presenterParking.bottomAnchor),
        ]
        NSLayoutConstraint.activate(parkingConstraints)
    }

    func apply(
        content: UIView,
        style: UMDBarStyle,
        availableWidth: CGFloat?,
        safeArea: UIEdgeInsets,
        verticalPadding: CGFloat = 8,
        minimumHeight: CGFloat = 0
    ) {
        NSLayoutConstraint.deactivate(containerEdgeConstraints)
        NSLayoutConstraint.deactivate(contentEdgeConstraints)
        containerEdgeConstraints.removeAll()
        contentEdgeConstraints.removeAll()
        contentView?.removeFromSuperview()
        self.style = style
        self.availableWidth = availableWidth
        self.safeArea = safeArea
        self.verticalPadding = verticalPadding
        self.minimumHeight = minimumHeight
        contentView = content
        contentContainer.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false

        switch style {
        case .regular:
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            layer.borderWidth = 1
            clipsToBounds = false
            bottomRule.isHidden = true
            containerEdgeConstraints = [
                contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
                contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
                contentContainer.topAnchor.constraint(equalTo: topAnchor, constant: 11),
                contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            ]
        case .shell:
            layer.cornerRadius = 0
            layer.borderWidth = 0
            clipsToBounds = false
            bottomRule.isHidden = false
            containerEdgeConstraints = [
                contentContainer.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: Self.horizontalPadding + safeArea.left
                ),
                contentContainer.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -(Self.horizontalPadding + safeArea.right)
                ),
                // The classic window's rail spans the scene's top safe strip
                // so the chassis reaches the window edge, and hands the
                // clearance back here — no chip may sit in the window's grab
                // region. The shell always passes top: 0 (it spends its own
                // safe areas before this controller sees them).
                // The padding is a floor, not the geometry: a rail asked to
                // match the key bar's height keeps its faces the same size
                // and centres them in the room below whatever strip it
                // spends.
                contentContainer.topAnchor.constraint(
                    greaterThanOrEqualTo: topAnchor,
                    constant: verticalPadding + safeArea.top
                ),
                contentContainer.bottomAnchor.constraint(
                    lessThanOrEqualTo: bottomAnchor,
                    constant: -verticalPadding
                ),
                contentContainer.centerYAnchor.constraint(
                    equalTo: centerYAnchor,
                    constant: safeArea.top / 2
                ),
            ]
        }
        NSLayoutConstraint.activate(containerEdgeConstraints)
        contentEdgeConstraints = [
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(contentEdgeConstraints)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        fittingSize(proposedWidth: availableWidth)
    }

    func fittingSize(proposedWidth: CGFloat?) -> CGSize {
        guard let contentView else { return .zero }
        let horizontalInset: CGFloat
        switch style {
        case .regular:
            horizontalInset = 36
        case .shell:
            // `availableWidth` already excludes the shell's side safe areas.
            // The real frame is wider and spends those insets in `apply`.
            horizontalInset = Self.horizontalPadding * 2
        }
        let targetWidth = proposedWidth.map { max(0, $0 - horizontalInset) }
            ?? UIView.layoutFittingCompressedSize.width
        let horizontalPriority: UILayoutPriority = proposedWidth == nil
            ? .fittingSizeLevel : .required
        let contentSize = contentView.systemLayoutSizeFitting(
            CGSize(
                width: targetWidth,
                height: UIView.layoutFittingCompressedSize.height
            ),
            withHorizontalFittingPriority: horizontalPriority,
            verticalFittingPriority: .fittingSizeLevel
        )
        let width = proposedWidth ?? ceil(contentSize.width + horizontalInset)
        // The shell style also carries whatever top strip it was asked to
        // span (classic window: the scene's own safe area; shell: zero).
        if style == .regular {
            return CGSize(width: width, height: ceil(contentSize.height + 22))
        }
        let body = max(minimumHeight, contentSize.height + verticalPadding * 2)
        return CGSize(width: width, height: ceil(body + safeArea.top))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshBorder()
    }

    private func refreshBorder() {
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
    }
}

@MainActor
final class UMDBarButton: UIButton {
    private let contentStack = UIStackView()
    private let symbolView = UIImageView()
    private let captionLabel = UILabel()
    private let prominent: Bool

    init(
        caption: String,
        systemImage: String? = nil,
        prominent: Bool,
        accessibilityLabel: String
    ) {
        self.prominent = prominent
        super.init(frame: .zero)
        self.accessibilityLabel = accessibilityLabel
        backgroundColor = GlassPrototype.strataChassis
        layer.borderWidth = 1
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 5
        contentStack.isUserInteractionEnabled = false
        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        if let systemImage {
            symbolView.image = UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 9 * Theme.typeScale,
                    weight: .semibold
                )
            )
            symbolView.contentMode = .scaleAspectFit
            contentStack.addArrangedSubview(symbolView)
            NSLayoutConstraint.activate([
                symbolView.widthAnchor.constraint(equalToConstant: 10 * Theme.typeScale),
                symbolView.heightAnchor.constraint(equalToConstant: 10 * Theme.typeScale),
            ])
        }
        if !caption.isEmpty {
            contentStack.addArrangedSubview(captionLabel)
        }
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        refreshColors(caption: caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var intrinsicContentSize: CGSize {
        let content = contentStack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        return CGSize(
            width: ceil(content.width + 18),
            height: ceil(content.height + 10)
        )
    }

    override var isHighlighted: Bool {
        // PROTOTYPE(GLASS): rest on strataChassis — the ground the init
        // chose — or the first press permanently flips the chip opaque on
        // the glass bar (user report: "press TMUX breaks the button").
        didSet {
            backgroundColor = isHighlighted
                ? UIKitChassis.bezelHi : GlassPrototype.strataChassis
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshColors(caption: captionLabel.attributedText?.string ?? "")
    }

    private func refreshColors(caption: String) {
        let ink = prominent ? UIKitChassis.signal : UIKitChassis.signal2
        layer.borderColor = (prominent ? UIKitChassis.signal2 : UIKitChassis.bezelHi)
            .resolvedColor(with: traitCollection).cgColor
        symbolView.tintColor = ink
        captionLabel.attributedText = NSAttributedString(
            string: caption,
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: ink.resolvedColor(with: traitCollection),
            ]
        )
    }
}

@MainActor
private final class UMDStateBadgeView: UIKitTallyBorderedView {
    private let captionLabel = UILabel()
    private let caption: String

    init(caption: String, accessibilityLabel: String) {
        self.caption = caption
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.strataChassis
        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityLabel
        addSubview(captionLabel)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        refreshCaption()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshCaption()
    }

    private func refreshCaption() {
        captionLabel.attributedText = NSAttributedString(
            string: caption,
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: UIKitChassis.signal2
                    .resolvedColor(with: traitCollection),
            ]
        )
    }
}

@MainActor
private final class UMDLampButton: UIControl {
    private let action: () -> Void

    init(
        lamp: UIKitTallyLamp,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) {
        self.action = action
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        lamp.isAccessibilityElement = false
        addSubview(lamp)
        lamp.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor),
            lamp.trailingAnchor.constraint(equalTo: trailingAnchor),
            lamp.topAnchor.constraint(equalTo: topAnchor),
            lamp.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func accessibilityActivate() -> Bool {
        action()
        return true
    }

    @objc private func pressed() {
        action()
    }
}
