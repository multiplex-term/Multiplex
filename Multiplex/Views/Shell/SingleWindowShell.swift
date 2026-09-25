import Observation
import OSLog
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
    var deckControl = ShellDeckControl.back
    var terminalFocusAllowed = false
    /// The device reports a hinge (iPhone Duo).
    var foldable = false
    /// iPhone Duo: the terminal's UMD column, and the deck's action column
    /// while the deck spans the display.
    var sideColumn = ShellSideColumn.none
    var deckActionColumn = ShellSideColumn.none
    var deckHeaderChrome = ShellHeaderChrome.none
    var terminalRailChrome = ShellHeaderChrome.none
    /// The shell has a column to lend a ▤/⌗ panel (iPhone Duo): the deck
    /// rail, a book page, or the laptop console region.
    var columnAvailable = false

    var bareChrome: Bool { SingleWindowShellLayout.chromeIsBare(idiom: .device, foldable: foldable) }
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
    /// The region under a horizontal division (iPhone Duo laptop pose): the
    /// key rail pins to its top edge, the keyboard, composer, panel, or deck
    /// rail fill the rest. nil while the shell is flat or folded as a book.
    var consoleFrame: CGRect?
    /// What each pane's header row clears beyond its safe area: the bare
    /// display corner it owns, and iPhone Duo's inner-portrait status band.
    var deckHeaderChrome = ShellHeaderChrome.none
    var terminalRailChrome = ShellHeaderChrome.none

    /// The expanded shell shows the deck rail beside the terminal.
    var hasDeckColumn: Bool { expanded && deckFrame.width > 0 }
    /// The shell has a column to lend a ▤/⌗ panel (iPhone Duo): the deck
    /// rail, a book page, or the laptop console region.
    var columnAvailable: Bool { hasDeckColumn || consoleFrame != nil }
    var deckPresentation: FleetWall.Presentation {
        expanded || consoleFrame != nil ? .shellRail : .shellCompact
    }
}

enum SingleWindowShellNativeLayout {
    /// `division` is the active fold region in shell coordinates (nil when
    /// flat): vertical makes a book, horizontal hands the bottom region to
    /// the console (`consoleFrame`).
    static func resolve(
        size: CGSize,
        safeArea: UIEdgeInsets,
        verticalSizeClass: ShellSizeClass,
        horizontalSizeClass: ShellSizeClass = .unspecified,
        idiom: ShellModeDecision.Idiom,
        division: CGRect? = nil,
        deckRailVisible: Bool,
        compactShowsTerminal: Bool,
        compactBackSwipeOffset: CGFloat,
        compactBackSwipeActive: Bool,
        foldable: Bool = false
    ) -> SingleWindowShellLayoutMetrics {
        let fullWidth = max(0, size.width)
        let usableWidth = max(0, fullWidth - safeArea.left - safeArea.right)
        let verticalDivision = division.flatMap { $0.height >= $0.width ? $0 : nil }
        let horizontalDivision = division.flatMap { $0.width > $0.height ? $0 : nil }
        let railWidth = min(SingleWindowShellLayout.deckRailWidth + safeArea.left, fullWidth)
        let expanded: Bool
        if verticalDivision != nil {
            expanded = true
        } else {
            expanded = SingleWindowShellLayout.isExpanded(
                usableWidth: usableWidth,
                terminalAvailableWidthIfExpanded: max(
                    0,
                    fullWidth - railWidth - safeArea.right
                ),
                idiom: idiom
            )
        }
        let deckWidth: CGFloat
        if let verticalDivision {
            deckWidth = max(0, min(verticalDivision.minX, fullWidth))
        } else if expanded {
            deckWidth = deckRailVisible ? railWidth : 0
        } else {
            deckWidth = fullWidth
        }
        let terminalOriginX: CGFloat = if let verticalDivision {
            max(0, min(verticalDivision.maxX, fullWidth))
        } else if expanded {
            deckWidth
        } else {
            0
        }
        let terminalWidth = max(0, fullWidth - terminalOriginX)
        let cornerInset = SingleWindowShellLayout.cornerLeadingInset(
            topSafeArea: safeArea.top,
            leadingSafeArea: safeArea.left,
            idiom: idiom,
            horizontalSizeClass: horizontalSizeClass
        )
        let topPadding = SingleWindowShellLayout.bareTopPadding(
            topSafeArea: safeArea.top,
            idiom: idiom,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        let topBand = SingleWindowShellLayout.topBandHeight(
            topSafeArea: safeArea.top,
            idiom: idiom,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        // The band is the top safe area itself: content starts at 0 and the
        // rail / header live inside the band.
        let contentOriginY = topBand > 0 ? 0 : safeArea.top + topPadding
        let deckHeight = max(0, size.height - contentOriginY)
        let railTakesBottomStrip = verticalSizeClass == .compact
            || SingleWindowShellLayout.railAlwaysTakesBottomStrip(idiom: idiom, foldable: foldable)
        let terminalHeight: CGFloat
        let consoleFrame: CGRect?
        // Laptop pose: the bottom region is the console, and the deck lives
        // there (a column panel takes its place when one is open).
        let consoleShowsDeck = horizontalDivision != nil && compactShowsTerminal && !expanded
        if let horizontalDivision, compactShowsTerminal {
            // Laptop pose: the terminal stops at the fold; the console owns
            // everything below it.
            terminalHeight = max(0, horizontalDivision.minY - contentOriginY)
            consoleFrame = CGRect(
                x: 0,
                y: horizontalDivision.maxY,
                width: fullWidth,
                height: max(0, size.height - horizontalDivision.maxY)
            )
        } else {
            terminalHeight = max(
                0,
                size.height - contentOriginY - safeArea.bottom
                    + (railTakesBottomStrip ? safeArea.bottom : 0)
            )
            consoleFrame = nil
        }
        let constrainedSwipe = expanded ? 0 : SingleWindowShellBackSwipe
            .constrainedTranslation(compactBackSwipeOffset, width: fullWidth)
        let terminalX = expanded
            ? terminalOriginX
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
            deckFrame: (consoleShowsDeck ? consoleFrame : nil) ?? CGRect(
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
                x: verticalDivision?.minX ?? max(0, deckWidth - 1),
                y: contentOriginY,
                width: verticalDivision?.width ?? 1,
                height: deckHeight
            ),
            deckAlpha: expanded || !compactShowsTerminal || compactBackSwipeActive
                || consoleShowsDeck
                ? 1 : 0,
            terminalAlpha: expanded || compactShowsTerminal ? 1 : 0,
            deckInteractive: expanded
                ? (deckRailVisible || verticalDivision != nil)
                : (!compactShowsTerminal || consoleShowsDeck),
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
            railOwnsBottomSafeArea: railTakesBottomStrip,
            consoleFrame: consoleFrame,
            // The console deck sits below the fold, not under the status band.
            deckHeaderChrome: ShellHeaderChrome(
                cornerInset: deckWidth > 0 && (expanded || !compactShowsTerminal) ? cornerInset : 0,
                bandHeight: consoleShowsDeck ? 0 : topBand
            ),
            terminalRailChrome: ShellHeaderChrome(
                cornerInset: terminalX == 0 && (expanded || compactShowsTerminal) ? cornerInset : 0,
                bandHeight: topBand
            )
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

    func presentColumnPanel(_ panel: UIViewController, moveToTab: @escaping () -> Void) {
        controller?.presentColumnPanel(panel, moveToTab: moveToTab)
    }

    func dismissColumnPanel() {
        controller?.dismissColumnPanel()
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
    /// Resolved by `continueAcrossBreakpointIfCrossed` for the `applyLayout`
    /// that follows it, so one layout pass resolves once.
    private var pendingLayoutMetrics: SingleWindowShellLayoutMetrics?

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
    private var layoutCompletion: (() -> Void)?
    private var targetLayoutMetrics: SingleWindowShellLayoutMetrics?
    private var testLayoutInput: (
        size: CGSize,
        safeArea: UIEdgeInsets,
        verticalSizeClass: ShellSizeClass,
        division: CGRect?
    )?
    /// Hinge `partiallyOpen`: drives layout only while the reserved-region
    /// query is empty (the 27.1 simulator).
    private var hingePartiallyOpen = false
    private var hingePresent = false
    private var hingeInteraction: (any UIInteraction)?
    /// iPhone Duo: the ▤/⌗ panel the terminal lent to the shell's column,
    /// and what ‹ DECK runs to send it into a tab.
    private(set) var columnPanel: (controller: UIViewController, moveToTab: () -> Void)?
    #if DEBUG
    /// `MULTIPLEX_AUTO_HIDE_DECK=1`: ◧ HIDE once, for headless captures.
    private var autoHideDeckFired = false
    private func autoHideDeckIfRequested() {
        guard !autoHideDeckFired,
              ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_HIDE_DECK"] == "1",
              currentLayoutMetrics?.expanded == true,
              deckRailVisible
        else { return }
        autoHideDeckFired = true
        showDeck()
    }
    #endif
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        #if os(iOS)
        if #available(iOS 27.1, *),
           traitCollection.verticalBarEdge != previousTraitCollection?.verticalBarEdge {
            shellRootView.setNeedsLayout()
        }
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installHingeObservation()
        #if DEBUG && os(iOS)
        logDuoProbe()
        autoHideDeckIfRequested()
        #endif
        let crossesBreakpoint = continueAcrossBreakpointIfCrossed()
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
        layoutCompletion = nil
        externalCoordinator?.detach()
        externalCoordinator = nil
        #if os(iOS)
        detachBackSwipeRecognizer()
        #endif
        releaseTerminalFocus()
        prepareTerminalForRemoval()
        terminalController.map(unembed)
        terminalController = nil
        (deckController as? DeckWindowViewController)?.prepareForRemoval()
        deckController.map(unembed)
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

    /// Resolves the next layout and carries the shell across the expand
    /// breakpoint before the frames move; the metrics are cached for the
    /// `applyLayout` that follows.
    @discardableResult
    private func continueAcrossBreakpointIfCrossed() -> Bool {
        let next = resolvedLayoutMetrics()
        guard let current = currentLayoutMetrics, current.expanded != next.expanded else {
            pendingLayoutMetrics = next
            return false
        }
        continueAcrossBreakpoint(expanding: next.expanded)
        return true
    }

    /// Crossing to single pane shows the attached terminal (the deck when
    /// nothing is attached); crossing to two panes restores a hidden rail.
    private func continueAcrossBreakpoint(expanding: Bool) {
        if expanding {
            deckRailVisible = true
        } else {
            let hasTabs = !shellState.terminalRoute.tabs.isEmpty
            if compactShowsTerminal != hasTabs {
                resetBackSwipe()
                compactShowsTerminal = hasTabs
                if !hasTabs { releaseTerminalFocus() }
            }
        }
    }

    /// The terminal hands its panel to the column; the deck wall waits
    /// underneath until the panel closes or ‹ DECK sends it into a tab.
    func presentColumnPanel(_ panel: UIViewController, moveToTab: @escaping () -> Void) {
        if let current = columnPanel, current.controller !== panel {
            removeColumnPanel(current.controller)
        }
        columnPanel = (panel, moveToTab)
        if panel.parent !== self {
            embed(panel, in: shellRootView.columnPanelContainer)
        }
        shellRootView.columnPanelPresented = true
        applyLayout(animated: true)
    }

    func dismissColumnPanel() {
        guard let current = columnPanel else { return }
        columnPanel = nil
        removeColumnPanel(current.controller)
        shellRootView.columnPanelPresented = false
        applyLayout(animated: true)
    }

    private func removeColumnPanel(_ panel: UIViewController) {
        guard panel.parent === self else { return }
        unembed(panel)
    }

    func showDeck() {
        if let columnPanel {
            // ‹ DECK over a column panel: the panel becomes a tab and the
            // deck takes its column back (the terminal's render dismisses it).
            columnPanel.moveToTab()
            return
        }
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
        verticalSizeClass: ShellSizeClass = .regular,
        division: CGRect? = nil
    ) {
        loadViewIfNeeded()
        testLayoutInput = (size, safeArea, verticalSizeClass, division)
        shellRootView.frame = CGRect(origin: .zero, size: size)
        continueAcrossBreakpointIfCrossed()
        applyLayout(animated: false)
    }

    // MARK: Child ownership

    /// The panes are pinned by constraints: a frame the spring writes on the
    /// container reaches the pane's own constraint tree in the same pass.
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

    private func mountDeck() {
        guard deckController == nil else { return }
        let controller = deckFactory(shellState, actions)
        deckController = controller
        install(controller, in: shellRootView.deckContainer)
        if let deck = controller as? DeckWindowViewController {
            deck.setAppLocked(appLocked)
            // Deck sheets present from this shell's presenter, so their
            // dismissal is what frees the shell-owned external-action queue.
            deck.presentationDidEnd = { [weak self] in
                self?.externalCoordinator?.presenterDidBecomeAvailable()
            }
        }
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
                unembed(controller)
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
        externalCoordinator?.setAppLocked(locked)
        (deckController as? DeckWindowViewController)?.setAppLocked(locked)
        (terminalController as? TerminalWindowViewController)?.setAppLocked(locked)
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
            verticalSizeClass: ShellSizeClass(traitCollection.verticalSizeClass),
            division: currentDivisionRegion()
        )
        return SingleWindowShellNativeLayout.resolve(
            size: input.size,
            safeArea: input.safeArea,
            verticalSizeClass: input.verticalSizeClass,
            horizontalSizeClass: ShellSizeClass(traitCollection.horizontalSizeClass),
            idiom: .device,
            division: input.division,
            deckRailVisible: deckRailVisible,
            compactShowsTerminal: compactShowsTerminal,
            compactBackSwipeOffset: compactBackSwipeOffset,
            compactBackSwipeActive: compactBackSwipeActive,
            foldable: hingePresent
        )
    }

    /// The fold in shell coordinates, nil when flat: the system's division
    /// region, else the hinge-derived band.
    private func currentDivisionRegion() -> CGRect? {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            if let region = shellRootView.reservedRegions(kind: .division).first {
                return region.frame
            }
        }
        guard hingePartiallyOpen else { return nil }
        return DuoFoldGeometry.syntheticDivision(in: shellRootView.bounds.size)
        #else
        return nil
        #endif
    }

    private func installHingeObservation() {
        #if os(iOS)
        guard hingeInteraction == nil else { return }
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                let folded = update.hinge?.status == .partiallyOpen
                #if DEBUG
                if DuoProbe.enabled {
                    let text = update.hinge.map {
                        "status=\($0.status.rawValue) angle=\($0.angle)"
                    } ?? "hinge=nil"
                    DuoProbe.log.notice("hinge \(text, privacy: .public) folded=\(folded, privacy: .public)")
                }
                #endif
                let present = update.hinge != nil
                if present != hingePresent {
                    hingePresent = present
                    if folded == hingePartiallyOpen { applyLayout(animated: false) }
                }
                guard folded != hingePartiallyOpen else { return }
                hingePartiallyOpen = folded
                applyLayout(animated: true)
            }
            shellRootView.addInteraction(interaction)
            hingeInteraction = interaction
        }
        #endif
    }

    private func applyLayout(
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard isViewLoaded else { return }
        let metrics = pendingLayoutMetrics ?? resolvedLayoutMetrics()
        pendingLayoutMetrics = nil
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

        // Animate only the shell's frame/alpha contract. Forcing
        // `layoutIfNeeded()` on the root here also resolves every pending
        // descendant constraint inside this property animator. A probe tick or
        // second tab can install fresh tile/cell content during that window;
        // UIKit then preserves its zero-origin presentation geometry, piling
        // labels into the corner. Descendants own their ordinary next layout
        // pass, exactly as they did on the working #23 base.
        let changes: () -> Void = { [weak self] in
            self?.shellRootView.apply(metrics)
        }
        // `stopAnimation(true)` retires an animator without running its
        // completions, so an interrupted transition would strand the caller's
        // state cleanup. Carry it to whichever pass finally settles the
        // layout — the interruption coverage SwiftUI's `.removed` completion
        // criteria gave this transition before.
        let pending = layoutCompletion
        layoutCompletion = nil
        let settled: (() -> Void)?
        if pending != nil || completion != nil {
            settled = {
                pending?()
                completion?()
            }
        } else {
            settled = nil
        }
        let shouldAnimate = animated
            && !shellState.reduceMotion
            && shellRootView.window != nil
        guard shouldAnimate else {
            layoutAnimator?.stopAnimation(true)
            layoutAnimator = nil
            changes()
            settled?()
            return
        }

        layoutAnimator?.stopAnimation(true)
        let animator = UIViewPropertyAnimator(
            duration: Self.navigationResponse,
            dampingRatio: 1,
            animations: changes
        )
        layoutAnimator = animator
        layoutCompletion = settled
        animator.addCompletion { [weak self] _ in
            guard let self, self.layoutAnimator === animator else { return }
            self.layoutAnimator = nil
            self.layoutCompletion = nil
            // One settled pass after the spring: a fold moves origin and
            // width together.
            self.terminalController?.view.setNeedsLayout()
            self.deckController?.view.setNeedsLayout()
            settled?()
        }
        animator.startAnimation()
    }

    private func updateChildPresentation(_ metrics: SingleWindowShellLayoutMetrics) {
        // Orientation comes from the display, not a pane: a laptop-pose pane
        // is landscape-shaped on a portrait display.
        let sideColumn = ShellSideColumn.resolve(
            traits: traitCollection,
            isLandscape: shellRootView.bounds.width > shellRootView.bounds.height,
            foldable: hingePresent,
            leadingSafeArea: metrics.deckSafeArea.left,
            trailingSafeArea: metrics.deckSafeArea.right
        )
        let presentation = SingleWindowShellPresentation(
            expanded: metrics.expanded,
            deckPresentation: metrics.deckPresentation,
            deckSafeArea: metrics.deckSafeArea,
            terminalAvailableWidth: metrics.terminalAvailableWidth,
            terminalSafeArea: metrics.terminalSafeArea,
            railOwnsBottomSafeArea: metrics.railOwnsBottomSafeArea,
            deckControl: metrics.expanded && columnPanel == nil
                ? (deckRailVisible ? .hide : .show)
                : .back,
            terminalFocusAllowed: (metrics.expanded || compactShowsTerminal)
                && terminalFocusReady,
            foldable: hingePresent,
            sideColumn: sideColumn,
            deckActionColumn: SingleWindowShellLayout.deckActionColumn(
                sideColumn: sideColumn,
                deckSpansShell: metrics.deckPresentation == .shellCompact
            ),
            deckHeaderChrome: metrics.deckHeaderChrome,
            terminalRailChrome: metrics.terminalRailChrome,
            columnAvailable: metrics.columnAvailable
        )
        if let panel = columnPanel?.controller as? SidePanelViewController {
            panel.updateWidth(metrics.deckFrame.width)
            panel.updateHeaderCornerInset(metrics.deckHeaderChrome.cornerInset)
        }
        guard shellState.presentation != presentation else { return }
        shellState.presentation = presentation
        shellRootView.bareChrome = presentation.bareChrome
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

    #if DEBUG && os(iOS)
    /// `MULTIPLEX_DUO_PROBE=1`: the geometry the Duo rules read, once per change.
    private var lastDuoProbe = ""
    private func logDuoProbe() {
        guard DuoProbe.enabled, let probeView = viewIfLoaded else { return }
        var edge = "n/a"
        var division = "n/a"
        var occlusion = "n/a"
        if #available(iOS 27.1, *) {
            edge = String(describing: traitCollection.verticalBarEdge.rawValue)
            let describe: (UIView.ReservedRegion) -> String = {
                "\($0.frame) active=\($0.isActive) margins=\($0.margins)"
            }
            division = probeView.reservedRegions(kind: .division, options: .includeInactive)
                .map(describe).joined(separator: " | ")
            occlusion = probeView.reservedRegions(kind: .occlusion, options: .includeInactive)
                .map(describe).joined(separator: " | ")
            if let window = probeView.window {
                division += " win:" + window.reservedRegions(kind: .division, options: .includeInactive)
                    .map(describe).joined(separator: " | ")
                occlusion += " win:" + window.reservedRegions(kind: .occlusion, options: .includeInactive)
                    .map(describe).joined(separator: " | ")
            }
        }
        let scene = probeView.window?.windowScene
        let orientation = scene?.effectiveGeometry.interfaceOrientation.rawValue ?? -1
        let screen = scene?.screen.bounds.size ?? .zero
        let line = "bounds=\(probeView.bounds.size) safe=\(probeView.safeAreaInsets) "
            + "h=\(traitCollection.horizontalSizeClass.rawValue) v=\(traitCollection.verticalSizeClass.rawValue) "
            + "idiom=\(traitCollection.userInterfaceIdiom.rawValue) edge=\(edge) orient=\(orientation) "
            + "screen=\(screen) hingeFolded=\(hingePartiallyOpen) "
            + "division=[\(division)] occlusion=[\(occlusion)]"
        guard line != lastDuoProbe else { return }
        lastDuoProbe = line
        DuoProbe.log.notice("\(line, privacy: .public)")
        // Regions can settle after the pass that resized us: re-read once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.logDuoProbe()
        }
    }
    #endif

    private func updateBackSwipeAvailability(expanded: Bool) {
        #if os(iOS)
        backSwipeRecognizer.isEnabled = SingleWindowShellBackSwipe.isAvailable(
            idiom: .device,
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
            headerChrome: presentation.deckHeaderChrome,
            actionColumn: presentation.deckActionColumn,
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
            deckControl: presentation.deckControl,
            availableWidth: presentation.terminalAvailableWidth,
            contentSafeArea: presentation.terminalSafeArea,
            railChrome: presentation.terminalRailChrome,
            railOwnsBottomSafeArea: presentation.railOwnsBottomSafeArea,
            columnAvailable: presentation.columnAvailable,
            bareChrome: presentation.bareChrome,
            sideColumn: presentation.sideColumn,
            presentColumnPanel: actions.presentColumnPanel,
            dismissColumnPanel: actions.dismissColumnPanel,
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
        // The recognizer lives on the window and cancels touches in view, so
        // everything sitting inside the left grab region is its to steal —
        // including the tab strip's leading cells and the UMD's own ‹ DECK
        // control, which a press with a few points of rightward drift then
        // never reaches. Those two are app chrome with their own actions, so
        // the edge gesture declines them outright; over the terminal pane it
        // keeps its first refusal on horizontal movement.
        if isShellChromeTouch(touch.view) {
            initialTouchTerminal = nil
            return false
        }
        initialTouchTerminal = terminalView(containing: touch.view)
        return initialTouchTerminal?.hasActiveSelection != true
    }

    /// Walks up from the touched view: a cell is nested several levels inside
    /// its strip, and a UMD control inside its bar's stacks.
    private func isShellChromeTouch(_ view: UIView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if current is TerminalTabStripView
                || current is TerminalTabScrollView
                || current is UMDBarRootView
                || current is ViewportUMDRootView {
                return true
            }
            candidate = current.superview
        }
        return false
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
    /// iPhone Duo: the ▤/⌗ panel in the deck's column, over the deck wall.
    let columnPanelContainer = UIView()
    var columnPanelPresented = false
    /// Bare chrome: the backfill bands above and below the terminal wear the
    /// pane's ground, not the bezel.
    var bareChrome = false {
        didSet {
            guard bareChrome != oldValue else { return }
            let ground = bareChrome ? UIKitChassis.screen : UIKitChassis.bezel
            terminalTopBackfill.backgroundColor = ground
            terminalBottomBackfill.backgroundColor = ground
        }
    }
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
        columnPanelContainer.accessibilityIdentifier = "singleWindowShell.columnPanel"
        columnPanelContainer.backgroundColor = UIKitChassis.chassis
        columnPanelContainer.clipsToBounds = true
        columnPanelContainer.isHidden = true
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
            columnPanelContainer,
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
        let columnShowsPanel = columnPanelPresented && metrics.deckFrame.width > 0
        columnPanelContainer.frame = metrics.deckFrame
        columnPanelContainer.isHidden = !columnShowsPanel
        columnPanelContainer.alpha = metrics.deckAlpha
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
        // The home-strip backfill, unless the console owns the bottom.
        let backfillHeight = metrics.railOwnsBottomSafeArea || metrics.consoleFrame != nil
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
        // A hairline between panes; the fold's own band reads as chassis.
        divider.backgroundColor = metrics.dividerFrame.width > 1
            ? UIKitChassis.chassis
            : UIKitChassis.bezelHi
        deckContainer.alpha = columnShowsPanel ? 0 : metrics.deckAlpha
        terminalContainer.alpha = metrics.terminalAlpha
        deckContainer.isUserInteractionEnabled = metrics.deckInteractive && !columnShowsPanel
        terminalContainer.isUserInteractionEnabled = metrics.terminalInteractive
        deckContainer.accessibilityElementsHidden = !metrics.deckInteractive || columnShowsPanel
        terminalContainer.accessibilityElementsHidden = !metrics.terminalInteractive
        divider.isHidden = !metrics.hasDeckColumn
        bringSubviewToFront(terminalContainer)
        bringSubviewToFront(columnPanelContainer)
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
            String(localized: "No terminal selected"),
            size: 13,
            color: UIKitChassis.signal3
        )
        title.accessibilityIdentifier = "singleWindowShell.emptyTitle"
        let detail = UILabel()
        detail.text = String(localized: "Choose a session from the deck to attach it here.")
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
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
