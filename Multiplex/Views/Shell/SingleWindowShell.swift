import Observation
import UIKit
#if os(iOS)
import SwiftTerm
#endif

@MainActor
struct SingleWindowShellDependencies {
    let store: HostStore
    let hub: ConnectionHub
    let themes: ThemeStore
    let workspace: TerminalWorkspace
    let entitlements: EntitlementStore
    let attention: AttentionCenter
    let localNetworkAccess: LocalNetworkAccessMonitor
    let networkChanges: NetworkChangeMonitor
    let externalActions: ExternalActionRouter
    let appLock: AppLockStore
    let bind: BindController
    let openURL: (URL) -> Void
    let sceneWindows: SceneWindowRouting
}

/// Values consumed by the native deck and terminal. One coherent
/// snapshot prevents a rotation or rail animation from briefly giving the
/// terminal its new frame with the old safe-area contract.
struct SingleWindowShellPresentation: Equatable {
    var expanded = false
    var deckPresentation = FleetWall.Presentation.shellCompact
    var deckSafeArea = UIEdgeInsets.zero
    var terminalAvailableWidth: CGFloat = 0
    var terminalSafeArea = UIEdgeInsets.zero
    var railOwnsBottomSafeArea = false
    var deckControlLabel = "‹ DECK"
    var terminalFocusAllowed = false
}

@MainActor
@Observable
final class SingleWindowShellState {
    var terminalRoute: TerminalWindowRoute
    var presentation = SingleWindowShellPresentation()
    var sceneIsActive: Bool
    var reduceMotion: Bool

    init(
        terminalRoute: TerminalWindowRoute,
        sceneIsActive: Bool,
        reduceMotion: Bool
    ) {
        self.terminalRoute = terminalRoute
        self.sceneIsActive = sceneIsActive
        self.reduceMotion = reduceMotion
    }
}

/// Pure result of the shell's UIKit layout pass. Tests can pin every safe-area
/// and breakpoint contract without instantiating FleetWall or a live terminal.
struct SingleWindowShellLayoutMetrics: Equatable {
    var expanded: Bool
    var deckFrame: CGRect
    var terminalFrame: CGRect
    var dividerFrame: CGRect
    var deckAlpha: CGFloat
    var terminalAlpha: CGFloat
    var deckInteractive: Bool
    var terminalInteractive: Bool
    var deckSafeArea: UIEdgeInsets
    var terminalSafeArea: UIEdgeInsets
    var terminalAvailableWidth: CGFloat
    var railOwnsBottomSafeArea: Bool
}

enum SingleWindowShellNativeLayout {
    static func resolve(
        size: CGSize,
        safeArea: UIEdgeInsets,
        verticalSizeClass: UIUserInterfaceSizeClass?,
        deckRailVisible: Bool,
        compactShowsTerminal: Bool,
        compactBackSwipeOffset: CGFloat,
        compactBackSwipeActive: Bool
    ) -> SingleWindowShellLayoutMetrics {
        let fullWidth = max(0, size.width)
        let usableWidth = max(0, fullWidth - safeArea.left - safeArea.right)
        let expanded = SingleWindowShellLayout.isExpanded(width: usableWidth)
        let deckWidth: CGFloat
        if expanded {
            deckWidth = deckRailVisible
                ? min(SingleWindowShellLayout.deckRailWidth + safeArea.left, fullWidth)
                : 0
        } else {
            deckWidth = fullWidth
        }
        let terminalWidth = max(0, fullWidth - (expanded ? deckWidth : 0))
        let contentOriginY = safeArea.top
        let deckHeight = max(0, size.height - safeArea.top)
        let railTakesBottomStrip = verticalSizeClass == .compact
        let terminalHeight = max(
            0,
            size.height - safeArea.top - safeArea.bottom
                + (railTakesBottomStrip ? safeArea.bottom : 0)
        )
        let terminalOriginX = expanded ? deckWidth : 0
        let constrainedSwipe = expanded ? 0 : SingleWindowShellBackSwipe
            .constrainedTranslation(compactBackSwipeOffset, width: fullWidth)
        let terminalX = expanded
            ? deckWidth
            : (compactShowsTerminal ? constrainedSwipe : fullWidth)
        let deckTrailingSafeArea = max(
            0,
            deckWidth - (fullWidth - safeArea.right)
        )
        let terminalLeadingSafeArea = max(0, safeArea.left - terminalOriginX)
        let terminalAvailableWidth = max(
            0,
            terminalWidth - terminalLeadingSafeArea - safeArea.right
        )

        return SingleWindowShellLayoutMetrics(
            expanded: expanded,
            deckFrame: CGRect(
                x: 0,
                y: contentOriginY,
                width: deckWidth,
                height: deckHeight
            ),
            terminalFrame: CGRect(
                x: terminalX,
                y: contentOriginY,
                width: terminalWidth,
                height: terminalHeight
            ),
            dividerFrame: CGRect(
                x: max(0, deckWidth - 1),
                y: contentOriginY,
                width: 1,
                height: deckHeight
            ),
            deckAlpha: expanded || !compactShowsTerminal || compactBackSwipeActive
                ? 1 : 0,
            terminalAlpha: expanded || compactShowsTerminal ? 1 : 0,
            deckInteractive: expanded ? deckRailVisible : !compactShowsTerminal,
            terminalInteractive: expanded || compactShowsTerminal,
            deckSafeArea: UIEdgeInsets(
                top: 0,
                left: safeArea.left,
                bottom: safeArea.bottom,
                right: deckTrailingSafeArea
            ),
            terminalSafeArea: UIEdgeInsets(
                top: 0,
                left: terminalLeadingSafeArea,
                bottom: 0,
                right: safeArea.right
            ),
            terminalAvailableWidth: terminalAvailableWidth,
            railOwnsBottomSafeArea: railTakesBottomStrip
        )
    }
}

/// Weak action proxy shared by the native deck and terminal. It keeps
/// their closures from retaining the native container and gives both sides
/// one routing/focus authority.
@MainActor
final class SingleWindowShellActions {
    weak var controller: SingleWindowShellViewController?

    func openTerminalRoute(_ route: TerminalWindowRoute) {
        controller?.openTerminalRoute(route)
    }

    func revealTab(_ id: UUID) {
        controller?.revealTab(id)
    }

    func showDeck() {
        controller?.showDeck()
    }

    func terminalTabsEmptied() {
        controller?.terminalTabsEmptied()
    }

    func terminalRouteChanged(_ route: TerminalWindowRoute) {
        controller?.replaceTerminalRoute(route)
    }
}

/// UIKit owner of the adaptive shell. Both the full deck lifecycle owner and
/// terminal workspace are native child controllers. UIKit owns geometry,
/// safe-area spending, transitions, focus, the edge gesture, route state,
/// hit testing, and accessibility visibility.
@MainActor
final class SingleWindowShellViewController: UIViewController {
    typealias ChildFactory = (
        SingleWindowShellState,
        SingleWindowShellActions
    ) -> UIViewController
    typealias ExternalCoordinatorFactory = (
        UIViewController,
        TerminalRouteOpener
    ) -> ExternalActionUIKitCoordinator
    typealias ChildUpdater = (
        UIViewController,
        SingleWindowShellState,
        SingleWindowShellActions
    ) -> Void

    nonisolated static let navigationResponse: TimeInterval = 0.3

    private(set) var shellState: SingleWindowShellState
    private(set) var compactShowsTerminal: Bool
    private(set) var terminalFocusReady = true
    private(set) var deckRailVisible = true
    private(set) var compactBackSwipeOffset: CGFloat = 0
    private(set) var compactBackSwipeActive = false
    private(set) var currentLayoutMetrics: SingleWindowShellLayoutMetrics?

    private let workspace: TerminalWorkspace
    private let shellRootView = SingleWindowShellRootView()
    private let actions = SingleWindowShellActions()
    private let deckFactory: ChildFactory
    private let deckUpdater: ChildUpdater?
    private let terminalFactory: ChildFactory
    private let externalCoordinatorFactory: ExternalCoordinatorFactory?
    private let routeChanged: (TerminalWindowRoute) -> Void
    private var lastReportedRoute: TerminalWindowRoute
    private var deckController: UIViewController?
    private var terminalController: UIViewController?
    private var appLocked = false
    private var emptyTerminalView: SingleWindowShellEmptyTerminalView?
    private var externalCoordinator: ExternalActionUIKitCoordinator?
    private var routeObservationGeneration = 0
    private var layoutAnimator: UIViewPropertyAnimator?
    private var targetLayoutMetrics: SingleWindowShellLayoutMetrics?
    private var testLayoutInput: (
        size: CGSize,
        safeArea: UIEdgeInsets,
        verticalSizeClass: UIUserInterfaceSizeClass?
    )?
    #if os(iOS)
    private weak var gestureWindow: UIWindow?
    private weak var initialTouchTerminal: TerminalView?
    private lazy var backSwipeRecognizer: UIScreenEdgePanGestureRecognizer = {
        let recognizer = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleBackSwipe(_:))
        )
        recognizer.edges = .left
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        recognizer.isEnabled = false
        return recognizer
    }()
    #endif

    init(
        workspace: TerminalWorkspace,
        initialRoute: TerminalWindowRoute = TerminalWindowRoute(tabs: []),
        sceneIsActive: Bool = true,
        reduceMotion: Bool = false,
        deckFactory: @escaping ChildFactory,
        deckUpdater: ChildUpdater? = nil,
        terminalFactory: @escaping ChildFactory,
        externalCoordinatorFactory: ExternalCoordinatorFactory? = nil,
        routeChanged: @escaping (TerminalWindowRoute) -> Void = { _ in }
    ) {
        self.workspace = workspace
        shellState = SingleWindowShellState(
            terminalRoute: initialRoute,
            sceneIsActive: sceneIsActive,
            reduceMotion: reduceMotion
        )
        compactShowsTerminal = !initialRoute.tabs.isEmpty
        self.deckFactory = deckFactory
        self.deckUpdater = deckUpdater
        self.terminalFactory = terminalFactory
        self.externalCoordinatorFactory = externalCoordinatorFactory
        self.routeChanged = routeChanged
        lastReportedRoute = initialRoute
        super.init(nibName: nil, bundle: nil)
        actions.controller = self
    }

    /// Framework-neutral production path used by UIKit scene delegates. The
    /// injected factories in the designated initializer remain only as a
    /// focused test seam.
    convenience init(
        dependencies: SingleWindowShellDependencies,
        initialRoute: TerminalWindowRoute = TerminalWindowRoute(tabs: []),
        sceneIsActive: Bool = true,
        reduceMotion: Bool = false,
        routeChanged: @escaping (TerminalWindowRoute) -> Void = { _ in }
    ) {
        self.init(
            workspace: dependencies.workspace,
            initialRoute: initialRoute,
            sceneIsActive: sceneIsActive,
            reduceMotion: reduceMotion,
            deckFactory: { state, actions in
                DeckWindowViewController(
                    configuration: SingleWindowShellViewController
                        .nativeDeckConfiguration(
                            dependencies: dependencies,
                            state: state,
                            actions: actions
                        )
                )
            },
            deckUpdater: { controller, state, actions in
                guard let controller = controller as? DeckWindowViewController else {
                    return
                }
                controller.update(
                    configuration: SingleWindowShellViewController
                        .nativeDeckConfiguration(
                            dependencies: dependencies,
                            state: state,
                            actions: actions
                        )
                )
            },
            terminalFactory: { state, actions in
                TerminalWindowViewController(
                    route: state.terminalRoute,
                    dependencies: TerminalWindowDependencies(
                        store: dependencies.store,
                        hub: dependencies.hub,
                        themes: dependencies.themes,
                        workspace: dependencies.workspace,
                        entitlements: dependencies.entitlements
                    ),
                    sceneWindows: dependencies.sceneWindows,
                    shell: SingleWindowShellViewController
                        .nativeTerminalShellConfiguration(
                        state: state,
                        actions: actions
                    ),
                    routeChanged: actions.terminalRouteChanged
                )
            },
            externalCoordinatorFactory: { presenter, opener in
                ExternalActionUIKitCoordinator(
                    presenter: presenter,
                    store: dependencies.store,
                    hub: dependencies.hub,
                    workspace: dependencies.workspace,
                    router: dependencies.externalActions,
                    themes: dependencies.themes,
                    terminalOpener: opener,
                    sceneWindows: dependencies.sceneWindows
                )
            },
            routeChanged: routeChanged
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    var currentRoute: TerminalWindowRoute { shellState.terminalRoute }

    override func loadView() {
        view = shellRootView
        shellRootView.backgroundColor = UIKitChassis.chassis
        mountDeck()
        updateTerminalSurface()
        observeRoute()

        if let externalCoordinatorFactory {
            let opener = TerminalRouteOpener(
                destination: .shell,
                action: { [weak actions] route in
                    actions?.openTerminalRoute(route)
                }
            )
            externalCoordinator = externalCoordinatorFactory(self, opener)
        }
        applyLayout(animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        externalCoordinator?.attach()
        #if os(iOS)
        attachBackSwipeRecognizer()
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if os(iOS)
        if view.window == nil { detachBackSwipeRecognizer() }
        #endif
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        #if os(iOS)
        if parent != nil { attachBackSwipeRecognizer() }
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let nextExpanded = resolvedLayoutMetrics().expanded
        let crossesBreakpoint = currentLayoutMetrics.map {
            $0.expanded != nextExpanded
        } ?? false
        applyLayout(animated: crossesBreakpoint)
        #if os(iOS)
        attachBackSwipeRecognizer()
        #endif
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyLayout(animated: false)
    }

    /// Scene delegates forward activity through one framework-neutral seam.
    func setSceneActive(_ active: Bool) {
        guard shellState.sceneIsActive != active else { return }
        shellState.sceneIsActive = active
        updateNativeDeckController()
        guard active,
              currentLayoutMetrics?.expanded != true,
              !compactShowsTerminal
        else { return }
        releaseTerminalFocus()
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        guard shellState.reduceMotion != reduceMotion else { return }
        shellState.reduceMotion = reduceMotion
        updateNativeDeckController()
        updateBackSwipeAvailability(
            expanded: currentLayoutMetrics?.expanded ?? false
        )
    }

    func prepareForRemoval() {
        routeObservationGeneration &+= 1
        layoutAnimator?.stopAnimation(true)
        layoutAnimator = nil
        externalCoordinator?.detach()
        externalCoordinator = nil
        #if os(iOS)
        detachBackSwipeRecognizer()
        #endif
        releaseTerminalFocus()
        prepareTerminalForRemoval()
        terminalController?.willMove(toParent: nil)
        terminalController?.view.removeFromSuperview()
        terminalController?.removeFromParent()
        terminalController = nil
        (deckController as? DeckWindowViewController)?.prepareForRemoval()
        deckController?.willMove(toParent: nil)
        deckController?.view.removeFromSuperview()
        deckController?.removeFromParent()
        deckController = nil
        actions.controller = nil
    }

    // MARK: Route and navigation actions

    /// Every incoming window route becomes tabs in this one shell. Grouped
    /// AUTO_ATTACH routes and comma-separated routes retain their order.
    func openTerminalRoute(_ incoming: TerminalWindowRoute) {
        guard !incoming.tabs.isEmpty else { return }
        let isColdStart = shellState.terminalRoute.tabs.isEmpty
        if isColdStart { terminalFocusReady = false }
        resetBackSwipe()

        var route = shellState.terminalRoute
        route.merge(incoming.tabs)
        if let selected = incoming.activeTab?.id ?? incoming.tabs.first?.id {
            route.activate(selected)
        }
        replaceTerminalRoute(route)
        compactShowsTerminal = true
        updateTerminalSurface()
        updateNativeTerminalController()
        applyLayout(animated: true)
        focusAfterNavigation(
            tabID: route.activeTabID,
            deferringColdStart: isColdStart
        )
    }

    /// Workspace press-to-focus calls this instead of opening a duplicate.
    func revealTab(_ tabID: UUID) {
        resetBackSwipe()
        compactShowsTerminal = true
        applyLayout(animated: true)
        focusAfterNavigation(tabID: tabID, deferringColdStart: false)
    }

    func showDeck() {
        if currentLayoutMetrics?.expanded == true {
            deckRailVisible.toggle()
            applyLayout(animated: true)
        } else {
            releaseTerminalFocus()
            resetBackSwipe()
            compactShowsTerminal = false
            terminalFocusReady = true
            applyLayout(animated: true)
        }
    }

    func terminalTabsEmptied() {
        terminalFocusReady = true
        releaseTerminalFocus()
        resetBackSwipe()
        compactShowsTerminal = false
        deckRailVisible = true
        if terminalController is TerminalWindowViewController {
            // The callback originates inside TerminalWindowViewController's
            // empty-route reconciliation. Let that stack unwind before
            // removing and preparing its controller hierarchy.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shellState.terminalRoute.tabs.isEmpty else { return }
                self.updateTerminalSurface()
            }
        } else {
            updateTerminalSurface()
        }
        applyLayout(animated: true)
    }

    func replaceTerminalRoute(_ route: TerminalWindowRoute) {
        guard shellState.terminalRoute != route else { return }
        shellState.terminalRoute = route
        reportRouteChangeIfNeeded()
    }

    func updateBackSwipe(translation: CGFloat, width: CGFloat? = nil) {
        guard !shellState.reduceMotion else { return }
        layoutAnimator?.stopAnimation(true)
        layoutAnimator = nil
        compactBackSwipeActive = true
        compactBackSwipeOffset = SingleWindowShellBackSwipe.constrainedTranslation(
            translation,
            width: width ?? layoutSize.width
        )
        applyLayout(animated: false)
    }

    func finishBackSwipe(
        translation: CGFloat,
        velocity: CGFloat,
        width: CGFloat? = nil
    ) {
        if SingleWindowShellBackSwipe.shouldReturnToDeck(
            translation: translation,
            velocity: velocity,
            width: width ?? layoutSize.width
        ) {
            showDeck()
        } else {
            cancelBackSwipe(animated: true)
        }
    }

    func cancelBackSwipe(animated: Bool) {
        guard compactBackSwipeActive || compactBackSwipeOffset != 0 else { return }
        compactBackSwipeOffset = 0
        applyLayout(animated: animated) { [weak self] in
            guard let self, self.compactBackSwipeOffset == 0 else { return }
            self.compactBackSwipeActive = false
            self.applyLayout(animated: false)
        }
    }

    func resetBackSwipe() {
        compactBackSwipeOffset = 0
        compactBackSwipeActive = false
    }

    /// Focused native tests supply deterministic geometry without a scene or
    /// mutating UIWindow safe-area internals.
    func applyTestLayout(
        size: CGSize,
        safeArea: UIEdgeInsets = .zero,
        verticalSizeClass: UIUserInterfaceSizeClass? = .regular
    ) {
        loadViewIfNeeded()
        testLayoutInput = (size, safeArea, verticalSizeClass)
        shellRootView.frame = CGRect(origin: .zero, size: size)
        applyLayout(animated: false)
    }

    // MARK: Child ownership

    private func mountDeck() {
        guard deckController == nil else { return }
        let controller = deckFactory(shellState, actions)
        deckController = controller
        install(controller, in: shellRootView.deckContainer)
        (controller as? DeckWindowViewController)?.setAppLocked(appLocked)
        updateNativeDeckController()
    }

    private func updateTerminalSurface() {
        let hasTabs = !shellState.terminalRoute.tabs.isEmpty
        if hasTabs {
            emptyTerminalView?.removeFromSuperview()
            emptyTerminalView = nil
            guard terminalController == nil else { return }
            let controller = terminalFactory(shellState, actions)
            terminalController = controller
            install(controller, in: shellRootView.terminalContainer)
            (controller as? TerminalWindowViewController)?.setAppLocked(appLocked)
        } else {
            if let controller = terminalController {
                (controller as? TerminalWindowViewController)?.prepareForRemoval()
                controller.willMove(toParent: nil)
                controller.view.removeFromSuperview()
                controller.removeFromParent()
                terminalController = nil
            }
            guard emptyTerminalView == nil else { return }
            let empty = SingleWindowShellEmptyTerminalView()
            emptyTerminalView = empty
            shellRootView.terminalContainer.addSubview(empty)
            empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(
                    equalTo: shellRootView.terminalContainer.leadingAnchor
                ),
                empty.trailingAnchor.constraint(
                    equalTo: shellRootView.terminalContainer.trailingAnchor
                ),
                empty.topAnchor.constraint(
                    equalTo: shellRootView.terminalContainer.topAnchor
                ),
                empty.bottomAnchor.constraint(
                    equalTo: shellRootView.terminalContainer.bottomAnchor
                ),
            ])
        }
    }

    /// Retains the lock verdict even while the shell is showing only its
    /// deck, so a terminal controller created later cannot briefly install
    /// interactive visionOS chrome behind the veil.
    func setAppLocked(_ locked: Bool) {
        appLocked = locked
        (deckController as? DeckWindowViewController)?.setAppLocked(locked)
        (terminalController as? TerminalWindowViewController)?.setAppLocked(locked)
    }

    private func install(_ controller: UIViewController, in container: UIView) {
        addChild(controller)
        container.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    private func observeRoute(generation: Int? = nil) {
        let generation = generation ?? {
            routeObservationGeneration &+= 1
            return routeObservationGeneration
        }()
        guard generation == routeObservationGeneration else { return }
        _ = withObservationTracking {
            shellState.terminalRoute
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.routeObservationGeneration else { return }
                self.reportRouteChangeIfNeeded()
                self.updateTerminalSurface()
                self.updateNativeDeckController()
                self.updateNativeTerminalController()
                self.applyLayout(animated: true)
                self.observeRoute(generation: generation)
            }
        }
    }

    // MARK: Layout and focus

    private var layoutSize: CGSize {
        testLayoutInput?.size ?? shellRootView.bounds.size
    }

    private func resolvedLayoutMetrics() -> SingleWindowShellLayoutMetrics {
        let input = testLayoutInput ?? (
            size: shellRootView.bounds.size,
            safeArea: shellRootView.safeAreaInsets,
            verticalSizeClass: traitCollection.verticalSizeClass
        )
        return SingleWindowShellNativeLayout.resolve(
            size: input.size,
            safeArea: input.safeArea,
            verticalSizeClass: input.verticalSizeClass,
            deckRailVisible: deckRailVisible,
            compactShowsTerminal: compactShowsTerminal,
            compactBackSwipeOffset: compactBackSwipeOffset,
            compactBackSwipeActive: compactBackSwipeActive
        )
    }

    private func applyLayout(
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard isViewLoaded else { return }
        let metrics = resolvedLayoutMetrics()
        if !animated,
           layoutAnimator?.isRunning == true,
           targetLayoutMetrics == metrics {
            // Direct frame animations can trigger a containment layout pass.
            // Do not let that bookkeeping pass snap the in-flight spring to
            // its endpoint; only genuinely new geometry interrupts it.
            updateChildPresentation(metrics)
            updateBackSwipeAvailability(expanded: metrics.expanded)
            return
        }
        let previousExpanded = currentLayoutMetrics?.expanded
        if previousExpanded != metrics.expanded {
            if metrics.expanded {
                resetBackSwipe()
            } else if !compactShowsTerminal {
                releaseTerminalFocus()
            }
        }
        currentLayoutMetrics = metrics
        targetLayoutMetrics = metrics
        updateChildPresentation(metrics)
        updateBackSwipeAvailability(expanded: metrics.expanded)

        let changes = { [weak self] in
            guard let self else { return }
            self.shellRootView.apply(metrics)
        }
        let shouldAnimate = animated
            && !shellState.reduceMotion
            && shellRootView.window != nil
        guard shouldAnimate else {
            layoutAnimator?.stopAnimation(true)
            layoutAnimator = nil
            changes()
            completion?()
            return
        }

        layoutAnimator?.stopAnimation(true)
        let animator = UIViewPropertyAnimator(
            duration: Self.navigationResponse,
            dampingRatio: 1,
            animations: changes
        )
        layoutAnimator = animator
        animator.addCompletion { [weak self] _ in
            guard let self, self.layoutAnimator === animator else { return }
            self.layoutAnimator = nil
            completion?()
        }
        animator.startAnimation()
    }

    private func updateChildPresentation(_ metrics: SingleWindowShellLayoutMetrics) {
        let presentation = SingleWindowShellPresentation(
            expanded: metrics.expanded,
            deckPresentation: metrics.expanded ? .shellRail : .shellCompact,
            deckSafeArea: metrics.deckSafeArea,
            terminalAvailableWidth: metrics.terminalAvailableWidth,
            terminalSafeArea: metrics.terminalSafeArea,
            railOwnsBottomSafeArea: metrics.railOwnsBottomSafeArea,
            deckControlLabel: metrics.expanded
                ? (deckRailVisible ? "◧ HIDE" : "◧ DECK")
                : "‹ DECK",
            terminalFocusAllowed: (metrics.expanded || compactShowsTerminal)
                && terminalFocusReady
        )
        guard shellState.presentation != presentation else { return }
        shellState.presentation = presentation
        updateNativeDeckController()
        updateNativeTerminalController()
    }

    private func focusAfterNavigation(
        tabID: UUID?,
        deferringColdStart: Bool
    ) {
        guard let tabID else { return }
        let claim: @MainActor () -> Void = { [weak self] in
            guard let self,
                  self.compactShowsTerminal,
                  self.shellState.terminalRoute.activeTabID == tabID
            else { return }
            self.terminalFocusReady = true
            var presentation = self.shellState.presentation
            presentation.terminalFocusAllowed = true
            self.shellState.presentation = presentation
            self.updateNativeTerminalController()
            self.workspace.controller(for: tabID)?.focusTerminal()
        }
        if deferringColdStart {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (
                    self.shellState.reduceMotion
                        ? 0.05 : Self.navigationResponse
                ),
                execute: claim
            )
        } else {
            DispatchQueue.main.async(execute: claim)
        }
    }

    private func releaseTerminalFocus() {
        guard let tabID = shellState.terminalRoute.activeTab?.id else { return }
        workspace.controller(for: tabID)?.releaseFocus()
    }

    private func updateBackSwipeAvailability(expanded: Bool) {
        #if os(iOS)
        let idiom: ShellModeDecision.Idiom = switch UIDevice.current.userInterfaceIdiom {
        case .phone: .phone
        case .pad: .pad
        default: .other
        }
        backSwipeRecognizer.isEnabled = SingleWindowShellBackSwipe.isAvailable(
            idiom: idiom,
            expanded: expanded,
            compactShowsTerminal: compactShowsTerminal
        )
        #endif
    }

    private func updateNativeTerminalController() {
        guard let controller = terminalController as? TerminalWindowViewController else {
            return
        }
        controller.update(
            route: shellState.terminalRoute,
            shell: Self.nativeTerminalShellConfiguration(
                state: shellState,
                actions: actions
            )
        )
    }

    private func updateNativeDeckController() {
        guard let deckController, let deckUpdater else { return }
        deckUpdater(deckController, shellState, actions)
    }

    private func prepareTerminalForRemoval() {
        (terminalController as? TerminalWindowViewController)?.prepareForRemoval()
    }

    private func reportRouteChangeIfNeeded() {
        let route = shellState.terminalRoute
        guard lastReportedRoute != route else { return }
        lastReportedRoute = route
        routeChanged(route)
    }

    static func nativeDeckConfiguration(
        dependencies: SingleWindowShellDependencies,
        state: SingleWindowShellState,
        actions: SingleWindowShellActions
    ) -> DeckWindowConfiguration {
        let presentation = state.presentation
        return DeckWindowConfiguration(
            store: dependencies.store,
            entitlements: dependencies.entitlements,
            hub: dependencies.hub,
            workspace: dependencies.workspace,
            localNetworkAccess: dependencies.localNetworkAccess,
            networkChanges: dependencies.networkChanges,
            bind: dependencies.bind,
            themes: dependencies.themes,
            attention: dependencies.attention,
            appLock: dependencies.appLock,
            externalActions: dependencies.externalActions,
            sceneWindows: dependencies.sceneWindows,
            openURL: dependencies.openURL,
            terminalOpener: TerminalRouteOpener(
                destination: .shell,
                action: actions.openTerminalRoute
            ),
            presentation: presentation.deckPresentation,
            selectedTerminal: state.terminalRoute.activeTab,
            shellSafeArea: presentation.deckSafeArea,
            sceneIsActive: state.sceneIsActive,
            reduceMotion: state.reduceMotion
        )
    }

    static func nativeTerminalShellConfiguration(
        state: SingleWindowShellState,
        actions: SingleWindowShellActions
    ) -> TerminalWindowShellConfiguration {
        let presentation = state.presentation
        return TerminalWindowShellConfiguration(
            deckControlLabel: presentation.deckControlLabel,
            availableWidth: presentation.terminalAvailableWidth,
            contentSafeArea: presentation.terminalSafeArea,
            railOwnsBottomSafeArea: presentation.railOwnsBottomSafeArea,
            showDeck: actions.showDeck,
            openTerminalRoute: actions.openTerminalRoute,
            revealTab: actions.revealTab,
            tabsEmptied: actions.terminalTabsEmptied,
            terminalFocusAllowed: presentation.terminalFocusAllowed
        )
    }
}

// MARK: - UIKit edge-back gesture

#if os(iOS)
extension SingleWindowShellViewController: UIGestureRecognizerDelegate {
    private func attachBackSwipeRecognizer() {
        guard gestureWindow !== view.window else { return }
        detachBackSwipeRecognizer()
        guard let window = view.window else { return }
        window.addGestureRecognizer(backSwipeRecognizer)
        gestureWindow = window
    }

    private func detachBackSwipeRecognizer() {
        gestureWindow?.removeGestureRecognizer(backSwipeRecognizer)
        gestureWindow = nil
        initialTouchTerminal = nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === backSwipeRecognizer,
              backSwipeRecognizer.isEnabled
        else { return false }
        initialTouchTerminal = terminalView(containing: touch.view)
        return initialTouchTerminal?.hasActiveSelection != true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === backSwipeRecognizer,
              backSwipeRecognizer.isEnabled,
              let pan = gestureRecognizer as? UIPanGestureRecognizer
        else { return false }
        let velocity = pan.velocity(in: pan.view)
        return SingleWindowShellBackSwipe.shouldBegin(
            horizontalVelocity: velocity.x,
            verticalVelocity: velocity.y,
            hasActiveTextSelection: initialTouchTerminal?.hasActiveSelection == true
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === backSwipeRecognizer
            && otherGestureRecognizer is UIPanGestureRecognizer
    }

    private func terminalView(containing view: UIView?) -> TerminalView? {
        var candidate = view
        while let current = candidate {
            if let terminal = current as? TerminalView { return terminal }
            candidate = current.superview
        }
        return nil
    }

    @objc private func handleBackSwipe(_ recognizer: UIPanGestureRecognizer) {
        let translation = max(0, recognizer.translation(in: recognizer.view).x)
        switch recognizer.state {
        case .began, .changed:
            updateBackSwipe(translation: translation)
        case .ended:
            finishBackSwipe(
                translation: translation,
                velocity: recognizer.velocity(in: recognizer.view).x
            )
            initialTouchTerminal = nil
        case .cancelled, .failed:
            cancelBackSwipe(animated: true)
            initialTouchTerminal = nil
        default:
            break
        }
    }
}
#endif

// MARK: - Native root views

@MainActor
final class SingleWindowShellRootView: UIView {
    let deckContainer = UIView()
    /// The terminal's legacy bezel paint ignored the top safe area while the
    /// themed pane began below it. Keep this stage-owned band moving with the
    /// terminal during compact back navigation instead of exposing chassis.
    let terminalTopBackfill = UIView()
    /// The pre-migration terminal surface painted the protected bottom band
    /// as rail bezel while the terminal theme covered only ordinary bounds.
    /// Keep that paint separate from the pane so SwiftTerm remains flush and
    /// the home-indicator tail does not fall through to chassis gray.
    let terminalBottomBackfill = UIView()
    let terminalContainer = UIView()
    let divider = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "singleWindowShell.root"
        backgroundColor = UIKitChassis.chassis
        deckContainer.accessibilityIdentifier = "singleWindowShell.deck"
        terminalTopBackfill.accessibilityIdentifier =
            "singleWindowShell.terminalTopBackfill"
        terminalTopBackfill.backgroundColor = UIKitChassis.bezel
        terminalTopBackfill.isUserInteractionEnabled = false
        terminalTopBackfill.isAccessibilityElement = false
        terminalBottomBackfill.accessibilityIdentifier =
            "singleWindowShell.terminalBottomBackfill"
        terminalBottomBackfill.backgroundColor = UIKitChassis.bezel
        terminalBottomBackfill.isUserInteractionEnabled = false
        terminalBottomBackfill.isAccessibilityElement = false
        terminalContainer.accessibilityIdentifier = "singleWindowShell.terminal"
        divider.accessibilityIdentifier = "singleWindowShell.divider"
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.isUserInteractionEnabled = false
        divider.isAccessibilityElement = false
        for child in [
            deckContainer,
            terminalTopBackfill,
            terminalBottomBackfill,
            terminalContainer,
            divider,
        ] {
            addSubview(child)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ metrics: SingleWindowShellLayoutMetrics) {
        deckContainer.frame = metrics.deckFrame
        terminalContainer.frame = metrics.terminalFrame
        let topBackfillHeight = max(0, metrics.terminalFrame.minY)
        terminalTopBackfill.frame = CGRect(
            x: metrics.terminalFrame.minX,
            y: 0,
            width: metrics.terminalFrame.width,
            height: topBackfillHeight
        )
        terminalTopBackfill.alpha = metrics.terminalAlpha
        terminalTopBackfill.isHidden = topBackfillHeight == 0
        let backfillHeight = metrics.railOwnsBottomSafeArea
            ? 0
            : max(0, bounds.height - metrics.terminalFrame.maxY)
        terminalBottomBackfill.frame = CGRect(
            x: metrics.terminalFrame.minX,
            y: metrics.terminalFrame.maxY,
            width: metrics.terminalFrame.width,
            height: backfillHeight
        )
        terminalBottomBackfill.alpha = metrics.terminalAlpha
        // Alpha and x-position animate with the terminal. Hiding merely
        // because the destination alpha is zero would pop this band away at
        // the start of a terminal-to-deck transition.
        terminalBottomBackfill.isHidden = backfillHeight == 0
        divider.frame = metrics.dividerFrame
        deckContainer.alpha = metrics.deckAlpha
        terminalContainer.alpha = metrics.terminalAlpha
        deckContainer.isUserInteractionEnabled = metrics.deckInteractive
        terminalContainer.isUserInteractionEnabled = metrics.terminalInteractive
        deckContainer.accessibilityElementsHidden = !metrics.deckInteractive
        terminalContainer.accessibilityElementsHidden = !metrics.terminalInteractive
        divider.isHidden = !(metrics.expanded && metrics.deckFrame.width > 0)
        bringSubviewToFront(terminalContainer)
        bringSubviewToFront(divider)
    }
}

@MainActor
final class SingleWindowShellEmptyTerminalView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "singleWindowShell.emptyTerminal"
        backgroundColor = UIKitChassis.screen

        let title = UIKitChassisLabel(
            "No terminal selected",
            size: 13,
            color: UIKitChassis.signal3
        )
        title.accessibilityIdentifier = "singleWindowShell.emptyTitle"
        let detail = UILabel()
        detail.text = "Choose a session from the deck to attach it here."
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = UIKitChassis.signal2
        detail.textAlignment = .center
        detail.numberOfLines = 0
        detail.accessibilityIdentifier = "singleWindowShell.emptyDetail"

        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}
