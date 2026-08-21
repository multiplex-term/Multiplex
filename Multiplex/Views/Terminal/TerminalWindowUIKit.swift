import Observation
import OSLog
import UIKit
#if DEBUG
import SwiftTerm
#endif

@MainActor
struct TerminalWindowDependencies {
    let store: HostStore
    let hub: ConnectionHub
    let themes: ThemeStore
    let workspace: TerminalWorkspace
    let entitlements: EntitlementStore
}

@MainActor
struct TerminalWindowShellConfiguration {
    var deckControlLabel: String
    var availableWidth: CGFloat
    var contentSafeArea: UIEdgeInsets = .zero
    var railOwnsBottomSafeArea = false
    var showDeck: () -> Void
    var openTerminalRoute: (TerminalWindowRoute) -> Void
    var revealTab: (UUID) -> Void
    var tabsEmptied: () -> Void
    var terminalFocusAllowed: Bool
}

private struct TerminalWindowShellPresentationKey: Equatable {
    var deckControlLabel: String
    var availableWidth: CGFloat
    var contentSafeArea: UIEdgeInsets
    var railOwnsBottomSafeArea: Bool
    var terminalFocusAllowed: Bool

    init?(_ shell: TerminalWindowShellConfiguration?) {
        guard let shell else { return nil }
        deckControlLabel = shell.deckControlLabel
        availableWidth = shell.availableWidth
        contentSafeArea = shell.contentSafeArea
        railOwnsBottomSafeArea = shell.railOwnsBottomSafeArea
        terminalFocusAllowed = shell.terminalFocusAllowed
    }
}

/// The classic scene lays pane controls above the protected bottom strip,
/// then paints that noninteractive strip as a continuation of the surface
/// touching it. SwiftUI did this edge bleed implicitly; UIKit needs the
/// owning surface named explicitly.
@MainActor
enum TerminalWindowBottomSafeAreaFill: Equatable {
    case chassis
    case terminalKeyRail
    case auxiliaryRail

    static func resolve(
        isClassic: Bool,
        activeTab: TerminalRoute?,
        hasActiveTerminalController: Bool
    ) -> Self {
        guard isClassic else { return .chassis }
        if activeTab?.isAuxiliaryPane == true { return .auxiliaryRail }
        return hasActiveTerminalController ? .terminalKeyRail : .chassis
    }

    var color: UIColor {
        switch self {
        case .chassis: UIKitChassis.chassis
        case .terminalKeyRail, .auxiliaryRail: UIKitChassis.bezel
        }
    }
}

/// The classic iPad/Mac terminal window wears the app's own UMD rail instead
/// of a system navigation bar. iPadOS 26+ sizes that bar for system controls —
/// measured 54 pt above a 10 pt scene inset, 64 pt of chrome for TALLY faces
/// only 21 pt tall — and it cannot be shortened: `sizeThatFits` is consulted
/// and ignored, and clamping the frame/bounds only makes UIKit center the
/// shrunken bar inside the band it still reserves (the content inset grew to
/// 74.5 pt). Hiding the bar hands the whole band back, which is what this
/// type's insets then spend deliberately.
///
/// The rail spans the window's full top edge, INCLUDING the scene safe-area
/// strip, and hands the clearance back as the bar's own content inset: the
/// strip is the window's grab region, so chrome may be painted there but no
/// chip may sit in it. A windowed iPadOS scene also floats its
/// close/minimize pill over that corner (measured on iPadOS 27: x 20.5–59.5 pt
/// from the window's leading edge, vertically centred ~29 pt down, drawn with
/// or without a navigation bar), so the rail's content starts clear of it. An
/// iOS app on the Mac wears the Mac's own title bar and has no in-window pill.
enum TerminalClassicRailInsets {
    /// The rail's own side padding, which every clearance below is quoted
    /// inclusive of.
    private static var railPadding: CGFloat { UMDBarRootView.horizontalPadding }

    /// Leading clearance for the iPadOS window-control pill, measured from
    /// the window edge and inclusive of the rail's own 10 pt padding: the
    /// pill ends at 59.5 pt, and the first chip owes it visible daylight.
    static let windowControlsClearance: CGFloat = 72

    /// Trailing clearance for the last chip, likewise inclusive of the rail's
    /// 10 pt padding. The window's rounded corner crowds a chip parked at the
    /// bare padding; the retired navigation bar spent the same daylight
    /// through its own trailing-inset wrapper.
    static let windowEdgeClearance: CGFloat = 26

    /// Chassis above and below the rail's faces — tighter than the shell's
    /// authored 8: this is a title bar, and every point it gives back is a
    /// terminal row.
    static let verticalPadding: CGFloat = 5

    /// Whether the scene actually reaches the display's top chrome. Neither
    /// obvious signal works on iPadOS 26+: the scene's `safeAreaInsets.top`
    /// reports the display's status bar (32 pt) even for a window floating
    /// well below it, `statusBarManager` answers for the display too, and
    /// `isFullScreen` is Mac Catalyst's property — false under iPadOS
    /// windowing even when the window is maximised (all three measured
    /// 2026-08-04). What remains is geometry: only a scene spanning the
    /// display can be under the status bar.
    static func meetsSystemTopChrome(
        sceneSize: CGSize,
        screenSize: CGSize
    ) -> Bool {
        guard screenSize.width > 0, screenSize.height > 0 else { return false }
        // Compare the dimensions unordered: `UIScreen.bounds` does not follow
        // the scene's orientation, so a maximised landscape window is
        // 1376x1032 against a 1032x1376 screen and a naive per-axis compare
        // reports "not spanning" — which paints the rail under the status bar
        // (reported on device, 2026-08-04).
        let scene = (long: max(sceneSize.width, sceneSize.height),
                     short: min(sceneSize.width, sceneSize.height))
        let screen = (long: max(screenSize.width, screenSize.height),
                      short: min(screenSize.width, screenSize.height))
        return scene.long >= screen.long - 1 && scene.short >= screen.short - 1
    }

    /// How much of a window actually sits under the display's status bar —
    /// the only honest answer to "is this window near the system's top
    /// chrome". A window's own frame is scene-relative (origin always
    /// zero), but converting it to the SCREEN's coordinate space reports
    /// where it really is (measured: a floating window at y 217.5 on a
    /// 1376 pt display), which no other API on iOS exposes.
    static func systemTopChromeOverlap(
        windowFrameOnScreen: CGRect,
        statusBarHeight: CGFloat
    ) -> CGFloat {
        max(0, statusBarHeight - windowFrameOnScreen.minY)
    }

    /// The rail spends exactly the band the system's top chrome covers, and
    /// clears the window-control pill only where one is drawn. An iOS app on
    /// the Mac has neither: its scene already sits below a real title bar.
    static func safeArea(
        sceneSafeArea: UIEdgeInsets,
        hostsWindowControls: Bool,
        systemTopChromeOverlap: CGFloat,
        spansDisplay: Bool
    ) -> UIEdgeInsets {
        // A scene spanning the display wears the status bar but hides its
        // pill, so DECK keeps the leading corner there; a floating scene
        // shows the pill wherever it sits, and only owes a top strip when it
        // is parked under the status bar.
        let strip = hostsWindowControls
            ? min(max(0, systemTopChromeOverlap), max(0, sceneSafeArea.top))
            : 0
        let floatsWithPill = hostsWindowControls && !spansDisplay
        return UIEdgeInsets(
            top: strip,
            left: floatsWithPill
                ? max(sceneSafeArea.left, windowControlsClearance - railPadding)
                : sceneSafeArea.left,
            bottom: 0,
            right: max(sceneSafeArea.right, windowEdgeClearance - railPadding)
        )
    }

    /// A windowed iPadOS scene draws the pill; the Mac draws a real title bar
    /// above the scene instead.
    static let deviceHostsWindowControls = !ProcessInfo.processInfo.isiOSAppOnMac
}

/// UIKit owner of one classic terminal scene or the terminal side of the
/// adaptive shell. It owns route reconciliation, child pane lifetimes,
/// source labels, UMD/navigation chrome, helper detection, presentations,
/// focus, probes, and scene lifecycle. The same controller is used for
/// visionOS and iPadOS; only the outer placement of its chrome differs.
@MainActor
final class TerminalWindowViewController: UIViewController,
    UIAdaptivePresentationControllerDelegate
{
    private static let hostProbeInterval: Duration = .seconds(5)
    private static let focusedPaneProbeInterval: Duration = .seconds(1)
    /// A tick of the focused-pane check is skipped while the terminal saw a
    /// keystroke this recently. Detection has no business running between
    /// keystrokes — the pane under the fingers is not changing — and the
    /// probe's exec, parse, and Observation pokes all compete with input
    /// handling on a spatial display where every window stays live. Chips
    /// settle one quiet beat after typing stops; the 5 s wall probe stays
    /// the untouched broad authority.
    private static let typingQuietWindow: Duration = .milliseconds(1500)

    private(set) var route: TerminalWindowRoute
    private var shell: TerminalWindowShellConfiguration?
    private let dependencies: TerminalWindowDependencies
    private let sceneWindows: SceneWindowRouting
    private let routeChanged: (TerminalWindowRoute) -> Void

    private var fontSize: CGFloat
    private var shownAgent: AgentKind?
    private var lastDetectedAgent: AgentKind?
    private var lastObservedActiveTabID: UUID?
    private var activePaneFingerprint: TmuxPaneFingerprint?
    private var creatingTab = false
    private var preparedForRemoval = false
    private var appLocked = false
    #if !os(visionOS)
    /// Last geometry the classic rail was rendered for; see
    /// `layoutNativeChrome`. Both halves matter: the width picks the compact
    /// row, and the insets decide the strip the rail spends.
    private var renderedClassicRailGeometry: ClassicRailGeometry?
    private var windowPositionWatch: Timer?

    private struct ClassicRailGeometry: Equatable {
        var width: CGFloat?
        var safeArea: UIEdgeInsets
    }
    #endif

    private let rootView = TerminalWindowUIKitRootView()
    private let tabStrip = TerminalTabStripView()
    #if os(visionOS)
    private lazy var visionOrnaments = TerminalVisionOrnamentCoordinator(
        tabStrip: tabStrip
    )
    private let visionShellKeyContext = TerminalKeyClusterContext()
    private lazy var visionShellKeyCluster = TerminalKeyClusterGroupView(
        role: .standalone,
        metric: .regular,
        context: visionShellKeyContext
    )
    #endif
    private var paneControllers: [UUID: UIViewController] = [:]
    /// View mounts are cached per host tab so switching away detaches the
    /// panel from the window without cancelling a file load or WebKit page.
    /// `TerminalWorkspace` still owns every auxiliary controller and decides
    /// shutdown; this cache owns presentation only.
    private var sidePanelViewControllers: [UUID: SidePanelViewController] = [:]
    private var mountedSidePanelHostID: UUID?
    private var transientSidePanelWidth: CGFloat?
    private var sidePanelConversionScheduledFor: UUID?
    private var umdController: UIViewController?
    private var helperController: AgentHelperStripViewController?
    /// The active tab's open Talkback composer — one per window, re-pointed
    /// at whichever tab is active; nil while that tab's box is closed.
    private var talkbackController: TalkbackComposerViewController?
    /// Whether opening the box folded the helper strip to its dot (so
    /// closing can unfold it) — the strip stays as the user left it otherwise.
    private var talkbackFoldedHelper = false
    /// The open box's height at this render's width, measured once per
    /// render (before the panes are configured) — never per tab.
    private var renderedTalkbackHeight: CGFloat = 0
    #if !os(visionOS)
    private var lastRenderedKeyboardLocked = false
    #endif
    /// Mirrors the legacy helper's `.id(activeTab.hostID)`: even when two
    /// hosts expose the same agent kind, their editor drafts and command
    /// configuration must never share controller state.
    private var helperHostID: UUID?
    private let passphrasePresenter = SSHKeyPassphrasePromptPresenterViewController()

    private var observationGeneration = 0
    private var hostProbeTask: Task<Void, Never>?
    private var activePaneTask: Task<Void, Never>?
    private var hideAgentTask: Task<Void, Never>?
    private var cloudRefreshTask: Task<Void, Never>?
    private var autoAttachTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    #if DEBUG
    private var debugObservers: [NSObjectProtocol] = []
    #endif

    private var presentedActivationID: String?
    private weak var presentedFeatureController: UIViewController?

    init(
        route: TerminalWindowRoute,
        dependencies: TerminalWindowDependencies,
        sceneWindows: SceneWindowRouting,
        shell: TerminalWindowShellConfiguration? = nil,
        routeChanged: @escaping (TerminalWindowRoute) -> Void = { _ in }
    ) {
        self.route = route
        self.dependencies = dependencies
        self.sceneWindows = sceneWindows
        self.shell = shell
        self.routeChanged = routeChanged
        #if os(visionOS)
        fontSize = 14
        #else
        fontSize = UIDevice.current.userInterfaceIdiom == .phone ? 12 : 14
        #endif
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        hostProbeTask?.cancel()
        activePaneTask?.cancel()
        hideAgentTask?.cancel()
        cloudRefreshTask?.cancel()
        autoAttachTask?.cancel()
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #if DEBUG
        for observer in debugObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    override func loadView() {
        view = rootView
        // A tab drag remains sortable if it strays below the narrow rail. Its
        // local-object marker lets this root target coexist with the pane's real
        // file-upload target without either gesture impersonating the other.
        tabStrip.installDropTarget(on: rootView)
        tabStrip.installDropTarget(on: rootView.tabScrollView)
        // PROTOTYPE(GLASS): the scene root's `TerminalGlassWindowShell`
        // carries the smoked system glass; this silhouette goes clear
        // over it.
        view.backgroundColor = GlassPrototype.enabled
            ? GlassPrototype.clearedChassis : UIKitChassis.chassis
        #if os(visionOS)
        updateVisionOrnamentInstallation()
        #endif
        configurePassphrasePresenter()
        configureLifecycleObservers()
        #if !os(visionOS)
        HardwareKeyboardMonitor.shared.startIfNeeded()
        #endif
        #if DEBUG
        configureDebugObservers()
        #endif
        syncTabs()
        restartActiveTasks()
        observationGeneration &+= 1
        observeAndRender(generation: observationGeneration)
        cloudRefreshTask = Task { [weak store = dependencies.store] in
            await store?.refreshFromCloud()
        }
        dependencies.entitlements.refreshSlashChipMeter()
        #if DEBUG
        autoAttachTask = Task { [weak self] in
            guard let self else { return }
            await DeckScene.autoAttachIfRequested(
                store: dependencies.store,
                workspace: dependencies.workspace,
                openTerminalWindow: { [weak self] route in
                    guard let self else { return }
                    if let shell = self.shell {
                        shell.openTerminalRoute(route)
                    } else {
                        self.sceneWindows.openTerminal(route)
                    }
                }
            )
        }
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        noteActiveSessionOpened()
        restoreActiveTerminalFocusIfOwner()
        presentPendingFeatureIfPossible()
        #if !os(visionOS)
        startWindowPositionWatchIfNeeded()
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if !os(visionOS)
        stopWindowPositionWatch()
        #endif
    }

    #if !os(visionOS)
    /// The rail's insets depend on where the window sits on the display, and
    /// UIKit reports no such thing: a scene's geometry models no origin, so
    /// `didUpdateEffectiveGeometry` covers resizes and screen moves but a
    /// pure DRAG fires nothing at all and the rail keeps a stale inset (user
    /// report: "doesn't always expand or collapse when the window is
    /// moved"). Watching is polling, the deck's way — one rect conversion a
    /// tick, and layout is invalidated only when the answer actually moves.
    private func startWindowPositionWatchIfNeeded() {
        // Only where window position feeds the rail at all: the Mac's scene
        // sits below a real title bar and draws no pill, so its insets do
        // not move with the window.
        guard shell == nil,
              TerminalClassicRailInsets.deviceHostsWindowControls,
              windowPositionWatch == nil
        else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWindowPosition() }
        }
        timer.tolerance = 0.2
        windowPositionWatch = timer
        checkWindowPosition()
    }

    private func stopWindowPositionWatch() {
        windowPositionWatch?.invalidate()
        windowPositionWatch = nil
    }

    private func checkWindowPosition() {
        guard !preparedForRemoval,
              UIApplication.shared.applicationState == .active,
              rootView.window != nil
        else { return }
        // Compare what the rail actually lays out against, not the raw
        // frame: dragging sideways, or anywhere clear of the status bar,
        // moves the window without moving a single inset.
        guard umdSafeArea != renderedClassicRailGeometry?.safeArea else { return }
        rootView.setNeedsLayout()
    }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutNativeChrome()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        layoutNativeChrome()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
            || traitCollection.horizontalSizeClass
                != previousTraitCollection?.horizontalSizeClass
        else { return }
        renderNow()
    }

    func update(
        route: TerminalWindowRoute,
        shell: TerminalWindowShellConfiguration?
    ) {
        let oldActive = self.route.activeTabID
        let routeChangedExternally = self.route != route
        let shellChanged = TerminalWindowShellPresentationKey(self.shell)
            != TerminalWindowShellPresentationKey(shell)
        self.route = route
        self.shell = shell
        guard isViewLoaded else { return }
        guard routeChangedExternally || shellChanged else { return }
        #if os(visionOS)
        updateVisionOrnamentInstallation()
        #endif
        if routeChangedExternally {
            syncTabs()
        }
        if oldActive != route.activeTabID {
            activeTabDidChange(from: oldActive)
        } else {
            restartObservation()
        }
    }

    /// Propagated by the UIKit scene root. Spatial ornaments live outside
    /// that root's disabled content hierarchy, so locking must remove them
    /// explicitly; unlocking reinstalls the same native controllers.
    func setAppLocked(_ locked: Bool) {
        guard appLocked != locked else { return }
        appLocked = locked
        guard isViewLoaded else { return }

        if locked {
            #if os(visionOS)
            visionOrnaments.remove()
            updateVisionShellKeyCluster()
            #endif
        } else {
            #if os(visionOS)
            updateVisionOrnamentInstallation()
            #endif
            renderNow()
        }
    }

    /// Scene/shell teardown. Moved tabs have already left `route`; only tabs
    /// still owned here are real closes and detach their transports.
    func prepareForRemoval() {
        guard !preparedForRemoval else { return }
        preparedForRemoval = true
        observationGeneration &+= 1
        #if !os(visionOS)
        stopWindowPositionWatch()
        #endif
        hostProbeTask?.cancel()
        activePaneTask?.cancel()
        hideAgentTask?.cancel()
        autoAttachTask?.cancel()
        #if os(visionOS)
        visionOrnaments.remove()
        visionShellKeyCluster.update(controller: nil)
        visionShellKeyCluster.removeFromSuperview()
        #endif
        dependencies.workspace.unregisterWindow(id: route.id)
        for tab in route.tabs {
            dependencies.workspace.closeTab(tab.id)
        }
        for controller in paneControllers.values {
            preparePaneForRemoval(controller)
            unmount(controller)
        }
        paneControllers.removeAll()
        for controller in sidePanelViewControllers.values {
            controller.prepareForRemoval()
            if controller.parent === self { unmount(controller) }
        }
        sidePanelViewControllers.removeAll()
        mountedSidePanelHostID = nil
        replaceUMD(with: nil)
        replaceHelper(with: nil)
        passphrasePresenter.update(
            challenge: nil,
            onSubmit: { _, _, _ in },
            onCancel: { _ in }
        )
    }

    // MARK: Derived state

    private var store: HostStore { dependencies.store }
    private var hub: ConnectionHub { dependencies.hub }
    private var themes: ThemeStore { dependencies.themes }
    private var workspace: TerminalWorkspace { dependencies.workspace }
    private var entitlements: EntitlementStore { dependencies.entitlements }

    private var activeTab: TerminalRoute? { route.activeTab }
    private var activeController: TerminalSessionController? {
        activeTab.flatMap { workspace.controller(for: $0.id) }
    }
    private var activeTabHost: Host? {
        activeTab.flatMap { store.host(id: $0.hostID) }
    }
    /// Which remembered width bucket this device uses.
    private var sidePanelPlatform: SidePanelPlatform? {
        #if os(visionOS)
        .visionOS
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : nil
        #endif
    }
    /// How this window presents a panel: the visionOS classic window hangs
    /// it from a trailing ornament; the iPad and the visionOS Shell lay a
    /// card over the pane. nil where no panel is ever admitted (iPhone).
    private var sidePanelStyle: SidePanelPresentationStyle? {
        #if os(visionOS)
        shell == nil ? .visionOrnament : .iPadOverlay
        #else
        sidePanelPlatform == nil ? nil : .iPadOverlay
        #endif
    }
    private var sidePanelEnvironmentOverride: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["MULTIPLEX_SIDE_PANEL"]
        #else
        nil
        #endif
    }
    private func admitsSidePanel(anchor: TerminalRoute) -> Bool {
        guard let style = sidePanelStyle else { return false }
        return SidePanelPolicy.admitsPanel(
            style: style,
            paneWidth: rootView.paneContainer.bounds.width,
            isCompactWidth: traitCollection.horizontalSizeClass == .compact,
            anchorIsTerminal: !anchor.isAuxiliaryPane,
            environmentOverride: sidePanelEnvironmentOverride
        )
    }
    private var terminalFocusAllowed: Bool {
        shell?.terminalFocusAllowed ?? true
    }
    /// The PANE's clearance — terminal, viewport, file viewer, helper strip.
    /// The rail's own insets are `umdSafeArea`: they clear the window-control
    /// pill, which is chrome geometry and must never reach a pane (a leaked
    /// leading inset shoves the terminal off its own window).
    private var contentSafeArea: UIEdgeInsets {
        if let shell { return shell.contentSafeArea }
        #if os(visionOS)
        return .zero
        #else
        // A classic pane now spans the window's own bottom edge, so the
        // home/Stage Manager strip is the pane's to spend. The key rail keeps
        // its faces clear through its own chassis; the auxiliary rails paint
        // through the strip and lift their controls by this inset instead.
        guard isViewLoaded else { return .zero }
        return UIEdgeInsets(
            top: 0,
            left: 0,
            bottom: rootView.safeAreaInsets.bottom,
            right: 0
        )
        #endif
    }

    /// What the rail is asked to clear. The shell hands its panes' insets
    /// straight through; the classic window adds the window-control pill and
    /// window-edge clearance — see `TerminalClassicRailInsets`.
    private var umdSafeArea: UIEdgeInsets {
        if let shell { return shell.contentSafeArea }
        #if os(visionOS)
        return .zero
        #else
        guard isViewLoaded else { return .zero }
        let hostsWindowControls = TerminalClassicRailInsets.deviceHostsWindowControls
        guard let window = rootView.window else { return .zero }
        let screen = window.screen
        return TerminalClassicRailInsets.safeArea(
            sceneSafeArea: rootView.safeAreaInsets,
            hostsWindowControls: hostsWindowControls,
            systemTopChromeOverlap: TerminalClassicRailInsets.systemTopChromeOverlap(
                windowFrameOnScreen: window.convert(
                    window.bounds,
                    to: screen.coordinateSpace
                ),
                statusBarHeight: window.windowScene?.statusBarManager?
                    .statusBarFrame.height ?? 0
            ),
            spansDisplay: TerminalClassicRailInsets.meetsSystemTopChrome(
                sceneSize: window.bounds.size,
                screenSize: screen.bounds.size
            )
        )
        #endif
    }
    private var railOwnsBottomSafeArea: Bool {
        if let shell { return shell.railOwnsBottomSafeArea }
        #if os(visionOS)
        return false
        #else
        // A classic iPad window's key rail is its bottom edge: it spends the
        // home-indicator strip itself rather than floating a backfill band
        // under the row, and buys back its own daylight below the key faces.
        return true
        #endif
    }
    private var showsAgentHelper: Bool {
        shownAgent != nil && activeController?.status == .live
    }
    /// The active tab's Talkback box is open (auxiliary panes have no pane
    /// to talk to).
    private var talkbackOpen: Bool {
        activeTab?.isAuxiliaryPane != true && activeController?.talkbackOpen == true
    }
    /// The width the composer lays out for: the window's on iPad / iPhone
    /// (the shell's available width where the shell insets), the console
    /// clamp on visionOS — content-sized like every ornament slab, capped so
    /// a wide window never grows a window-wide card.
    private var talkbackWidth: CGFloat {
        #if os(visionOS)
        if shell == nil {
            return min(
                620,
                TerminalVisionOrnamentPresentation.consoleClamp(windowWidth: rootView.bounds.width)
            )
        }
        #endif
        return shell?.availableWidth ?? rootView.bounds.width
    }
    /// The eyebrow's telemetry: the tmux/herdr session's attention record for
    /// this tab, or a plain shell's own. Fail-soft — nil says nothing.
    private var activeTabAgentState: PaneAgentState? {
        guard let activeTab else { return nil }
        guard let key = activeTab.sessionKey else {
            return activeController?.directShellAttention
        }
        guard let host = store.host(id: activeTab.hostID) else { return nil }
        return hub.model(for: host).attention[key]
    }
    private var terminalBottomChromeHeight: CGFloat {
        #if os(visionOS)
        0
        #else
        // A collapsed strip is a small dot floating over the terminal's
        // bottom-leading corner; the pane reclaims the docked row. The
        // Talkback card docks below the strip (or its dot) and above the
        // rail, and the pane insets by both.
        let helper = showsAgentHelper && !AgentHelperStripCollapse.shared.isCollapsed
            ? AgentHelperStripViewController.dockedHeight : 0
        return helper + renderedTalkbackHeight
        #endif
    }
    private var mergeSources: [TerminalWorkspace.WindowEntry] {
        shell == nil ? workspace.mergeSources(for: route.id) : []
    }
    private var activeTabHasSession: Bool {
        guard let activeTab else { return false }
        return activeTab.sessionName != nil && store.host(id: activeTab.hostID) != nil
    }
    private var keyPassphraseChallenge: SSHKeyPassphraseChallenge? {
        let activeFirst = activeTab.map { [$0] } ?? []
        for tab in activeFirst + route.tabs.filter({ $0.id != activeTab?.id }) {
            if let challenge = workspace.controller(for: tab.id)?.keyPassphraseChallenge {
                return challenge
            }
        }
        return nil
    }
    private var activeTabKeychainNotice: KeychainLockNotice? {
        guard let activeTab,
              let sessionName = activeTab.sessionName,
              let host = store.host(id: activeTab.hostID),
              activeTab.sessionBackend == host.sessionBackend,
              let notice = hub.model(for: host).keychainNotice,
              notice.sessionNames.contains(sessionName)
        else { return nil }
        return notice
    }
    private var detectedAgent: AgentKind? {
        guard let activeTab else { return nil }
        guard let sessionName = activeTab.sessionName else {
            return activeController?.directShellAgent
        }
        // Any backend this host MONITORS can answer — on a mixed host the
        // probe carries both, and a tab on the secondary deserves its agent
        // chips too. A tab whose backend the host no longer monitors gets
        // nothing rather than a same-named record from the other one.
        guard let host = store.host(id: activeTab.hostID),
              let backend = activeTab.sessionBackend,
              host.monitors(backend)
        else { return nil }
        let model = hub.model(for: host)
        // One expression serves both backends on purpose: a herdr tile IS
        // a whole session, and the probe writes its live focus into the
        // record (active window = focused workspace, active pane = the
        // session's one focus every client mirrors) — so following
        // `activeAgent` follows a workspace switch inside the TUI too.
        return model.sessions(on: backend)
            .first { $0.name == sessionName }?
            .activeAgent
    }
    private var resolvedTerminalTheme: TerminalTheme {
        // Prefer the pinned choice over the live traits: the observation
        // render can run before the scene root writes the new override onto
        // the window, and a trait-derived read in that gap re-applies the
        // OLD appearance's theme (white-on-white text until the trait pass
        // catches up — user-reported as intermittent). Traits remain the
        // source only under SYSTEM, where the device is the authority and
        // `traitCollectionDidChange` re-renders.
        let appearance = themes.appearance.resolvedOverride
            ?? (traitCollection.userInterfaceStyle == .light ? .light : .dark)
        return themes.selected(for: appearance)
    }

    // MARK: Observation

    private func restartObservation() {
        observationGeneration &+= 1
        observeAndRender(generation: observationGeneration)
    }

    private func observeAndRender(generation: Int) {
        guard generation == observationGeneration else { return }
        let snapshot = withObservationTracking {
            // Read every service value that changes this controller's
            // composition. Child controllers observe their own detailed
            // content; these reads only decide which native children/chrome
            // exist and what actions they expose.
            _ = store.hosts
            _ = workspace.windows
            _ = themes.appearance
            _ = resolvedTerminalTheme
            _ = entitlements.isPro
            _ = entitlements.canUseSlashChip
            _ = entitlements.canBrowseAgentHistory
            _ = ConnectionStatsCenter.shared.isCollecting
            _ = activeController?.status
            _ = activeController?.keyboardObstruction
            _ = activeController?.directShellAgent
            _ = activeController?.directShellAttention
            _ = activeController?.pendingLink
            _ = activeController?.pendingPath
            _ = activeController?.talkbackOpen
            // The eyebrow's telemetry matters only while a box is open —
            // otherwise an attention edge on the host is not this window's.
            if talkbackOpen { _ = activeTabAgentState }
            _ = keyPassphraseChallenge
            _ = activeTabKeychainNotice
            #if !os(visionOS)
            _ = KeyboardLock.shared.isLocked
            _ = HardwareKeyboardMonitor.shared.isConnected
            #endif
            var showsFileViewer = false
            for tab in route.tabs {
                if tab.isAuxiliaryPane {
                    _ = workspace.auxiliaryController(for: tab.id)?.tabLabel
                    showsFileViewer = showsFileViewer || tab.isFileViewer
                } else {
                    let panel = workspace.sidePanel(for: tab.id)
                    _ = panel?.tabLabel
                    showsFileViewer = showsFileViewer || panel is FileViewerController
                }
            }
            if let platform = sidePanelPlatform {
                _ = SidePanelWidthStore.shared.width(for: platform)
                if sidePanelStyle == .visionOrnament {
                    _ = SidePanelWidthStore.shared.visionOverhang
                }
            }
            // The rail's A− / A+ readout — a pinch inside the pane (or the
            // same chips in another window) has to reach it.
            if showsFileViewer { _ = FileViewerTextScaleStore.shared.scale }
            return detectedAgent
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAndRender(generation: generation)
            }
        }
        updateShownAgent(from: snapshot)
        #if !os(visionOS)
        if let transition = pendingTalkbackTransition {
            animateTalkbackTransition(transition)
            return
        }
        #endif
        renderNow()
    }

    private func updateShownAgent(from agent: AgentKind?) {
        let activeID = activeTab?.id
        if lastObservedActiveTabID != activeID {
            hideAgentTask?.cancel()
            lastObservedActiveTabID = activeID
            lastDetectedAgent = agent
            shownAgent = agent
            activePaneFingerprint = nil
            return
        }
        guard lastDetectedAgent != agent else { return }
        lastDetectedAgent = agent
        hideAgentTask?.cancel()
        if let agent {
            shownAgent = agent
        } else {
            hideAgentTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(11))
                guard !Task.isCancelled else { return }
                self?.shownAgent = nil
                self?.renderNow()
            }
        }
    }

    private func renderNow() {
        guard isViewLoaded, !preparedForRemoval else { return }
        // Before the panes: their bottom inset reads the composer's height.
        renderTalkback()
        reconcilePaneControllers()
        renderSidePanel()
        renderTabStrip()
        renderUMD()
        renderHelper()
        #if os(visionOS)
        reconcileVisionChromeOwnership()
        updateVisionOrnaments(forceRevision: true)
        #endif
        updatePassphrasePrompt()
        #if os(visionOS)
        rootView.setTabsVisible(shell != nil && route.tabs.count > 1)
        #else
        rootView.setTabsVisible(route.tabs.count > 1)
        #endif
        rootView.setShellMode(shell != nil)
        layoutNativeChrome()
        presentPendingFeatureIfPossible()
        applyAppearanceToPresentedFeature()
    }

    // MARK: Route reconciliation

    private func syncTabs() {
        let orphanedAuxiliaries = route.tabs.filter { tab in
            tab.isAuxiliaryPane && workspace.auxiliaryController(for: tab.id) == nil
        }
        if !orphanedAuxiliaries.isEmpty {
            let ids = Set(orphanedAuxiliaries.map(\.id))
            mutateRoute { route in
                route.tabs.removeAll { ids.contains($0.id) }
                if let active = route.activeTabID, ids.contains(active) {
                    route.activeTabID = route.tabs.first?.id
                }
            }
            return
        }
        if route.tabs.isEmpty {
            workspace.unregisterWindow(id: route.id)
            if let shell {
                shell.tabsEmptied()
            } else {
                sceneWindows.closeCurrentScene()
            }
            return
        }
        for tab in route.tabs where !tab.isAuxiliaryPane {
            _ = workspace.controller(for: tab, store: store)
        }
        workspace.registerWindow(.init(
            id: route.id,
            tabs: route.tabs,
            label: windowLabel,
            reveal: { [weak self] tabID in
                guard let self else { return }
                activate(tabID)
                noteActiveSessionOpened()
                if let shell = self.shell {
                    shell.revealTab(tabID)
                } else {
                    self.workspace.controller(for: tabID)?.revealWindow()
                }
            },
            surrender: { [weak self] in
                guard let self else { return [] }
                let tabs = self.route.tabs
                self.mutateRoute { route in
                    route.tabs = []
                    route.activeTabID = nil
                }
                return tabs
            },
            adopt: { [weak self] tabs in
                self?.mutateRoute { $0.merge(tabs) }
            },
            openFileViewer: { [weak self] hostID, target in
                guard let self,
                      let activeTab,
                      !activeTab.isAuxiliaryPane,
                      activeTab.hostID == hostID
                else { return false }
                openFileViewer(target: target)
                return true
            }
        ))
    }

    private func mutateRoute(_ mutation: (inout TerminalWindowRoute) -> Void) {
        let previousActive = route.activeTabID
        mutation(&route)
        routeChanged(route)
        syncTabs()
        if previousActive != route.activeTabID {
            activeTabDidChange(from: previousActive)
        } else {
            restartObservation()
        }
    }

    /// The one place "the user is now in this session" is known — first
    /// appearance, tab switch, deck/notification reveal.
    private func noteActiveSessionOpened() {
        guard let tab = activeTab, let key = tab.sessionKey else { return }
        store.recordSessionAttach(hostID: tab.hostID, session: key)
    }

    private func activeTabDidChange(from previousTabID: UUID?) {
        noteActiveSessionOpened()
        if activeTab?.isAuxiliaryPane == true {
            if let previousTabID {
                workspace.controller(for: previousTabID)?.releaseFocus()
            }
        } else {
            claimActiveTerminalFocusIfAllowed()
        }
        hideAgentTask?.cancel()
        activePaneFingerprint = nil
        lastObservedActiveTabID = nil
        shownAgent = detectedAgent
        lastDetectedAgent = detectedAgent
        restartActiveTasks()
        restartObservation()
    }

    private var windowLabel: String {
        let names = route.tabs.map(\.displayName).joined(separator: ", ")
        var seen = Set<UUID>()
        let hosts = route.tabs.compactMap { tab -> String? in
            guard seen.insert(tab.hostID).inserted else { return nil }
            return store.host(id: tab.hostID)?.name
        }
        return hosts.isEmpty ? names : "\(names) — \(hosts.joined(separator: ", "))"
    }

    func activate(_ tabID: UUID) {
        guard route.tabs.contains(where: { $0.id == tabID }) else { return }
        mutateRoute { $0.activate(tabID) }
    }

    func closeTab(_ tabID: UUID) {
        if shell != nil { workspace.controller(for: tabID)?.releaseFocus() }
        workspace.closeTab(tabID)
        mutateRoute { $0.removeTab(id: tabID) }
    }

    func splitTab(_ tabID: UUID) {
        guard shell == nil, route.tabs.count > 1 else { return }
        var splitTab: TerminalRoute?
        mutateRoute { splitTab = $0.removeTab(id: tabID) }
        if let splitTab {
            sceneWindows.openTerminal(TerminalWindowRoute(tab: splitTab))
        }
    }

    func reorderTab(_ sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              route.tabs.contains(where: { $0.id == sourceID }),
              route.tabs.contains(where: { $0.id == targetID })
        else { return }
        mutateRoute { $0.moveTab(id: sourceID, to: targetID) }
    }

    private func merge(_ windowID: UUID) {
        mutateRoute { $0.merge(workspace.surrenderTabs(of: windowID)) }
    }

    private func detachActiveTab() {
        guard let activeTab else { return }
        closeTab(activeTab.id)
    }

    private func confirmCloseActiveSession() {
        guard let activeTab,
              let sessionName = activeTab.sessionName,
              let host = store.host(id: activeTab.hostID)
        else { return }
        let message = activeTab.sessionBackend == .herdr
            ? String(localized: """
                Stops “\(sessionName)” on \(host.name), deletes its saved state when \
                herdr allows it, then closes the tab.
                """)
            : String(localized: """
                Kills “\(sessionName)” on \(host.name) and everything running in it, \
                then closes the tab.
                """)
        let alert = UIAlertController(
            title: String(localized: "Close Session"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "Close Session"),
            style: .destructive
        ) { [weak self] _ in
            self?.closeSession(activeTab)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func closeSession(_ tab: TerminalRoute) {
        guard let sessionName = tab.sessionName,
              let backend = tab.sessionBackend,
              let host = store.host(id: tab.hostID)
        else { return }
        let model = hub.model(for: host)
        Task { await model.killSession(named: sessionName, backend: backend) }
        closeTab(tab.id)
    }

    // MARK: New and auxiliary tabs

    func openNewTab(launching agent: AgentKind?) {
        guard !creatingTab,
              let activeTab,
              let host = store.host(id: activeTab.hostID)
        else { return }
        creatingTab = true
        // + TAB means "another one like this": the sibling session is minted
        // on THIS tab's backend, not the host's default, so a herdr tab on a
        // tmux-default mixed host keeps producing herdr siblings. A backend
        // the host no longer monitors falls back to the default.
        let backend = activeTab.sessionBackend
            .flatMap { host.monitors($0) ? $0 : nil }
            ?? host.sessionBackend
        // Only inherit a source session from the namespace the new tab will
        // actually use.
        let source = activeTab.sessionBackend == backend
            ? activeTab.sessionName : nil
        let preferences = NewSessionPreferences()
        let script = preferences.rememberedScript(for: host)
        Task { [weak self] in
            guard let self else { return }
            defer { creatingTab = false }
            let model = hub.model(for: host)
            guard let created = await model.createSession(
                base: agent?.launchCommand ?? source ?? "main",
                backend: backend,
                inDirectoryOf: source,
                applying: host.newSessionTmuxConf,
                running: script?.normalizedBody,
                typing: agent.map {
                    $0.launchCommand(
                        model: preferences.rememberedModel(for: $0),
                        initialPrompt: ""
                    )
                }
            ) else {
                presentNewTabFailure(
                    hostName: host.name, target: .session,
                    reason: model.sessionCreateFailure.map {
                        switch $0 {
                        case .backendMissing(let backend):
                            HostGuide.backendMissingMessage(
                                backend, hostName: host.name)
                        }
                    })
                return
            }
            let tab = TerminalRoute(hostID: host.id, mode: created)
            mutateRoute { route in
                route.tabs.append(tab)
                route.activate(tab.id)
            }
        }
    }

    /// The herdr-only second entry: a tab in the session's focused
    /// workspace, typed into over the control connection. No Multiplex tab
    /// is added — this window is already attached to that session, and its
    /// client is what shows the new tab (herdr focuses it). Runs the
    /// remembered setup script but never an agent: the agent entries mint
    /// sessions, like every backend's leading row.
    func openNewHerdrWorkspaceTab() {
        guard !creatingTab,
              let activeTab,
              case .herdrAttach(let sessionName) = activeTab.mode,
              let host = store.host(id: activeTab.hostID)
        else { return }
        creatingTab = true
        let script = NewSessionPreferences().rememberedScript(for: host)
        Task { [weak self] in
            guard let self else { return }
            defer { creatingTab = false }
            let created = await hub.model(for: host).createHerdrTab(
                inSession: sessionName,
                running: script?.normalizedBody
            )
            if !created {
                presentNewTabFailure(hostName: host.name, target: .herdrWorkspaceTab)
            }
        }
    }

    /// `reason` carries a mint failure the connection is not to blame for
    /// (a host with no herdr installed, say) — pointing at the link there
    /// sends the user to check something that is working.
    private func presentNewTabFailure(
        hostName: String, target: TerminalRoute.NewTabTarget,
        reason: String? = nil
    ) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: target.failureTitle,
            message: reason
                ?? String(localized: "Check the connection to \(hostName) and try again."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    func openFileViewer(
        target: TerminalPathTarget?,
        allowsPanel: Bool = true
    ) {
        guard let activeTab, let host = store.host(id: activeTab.hostID) else { return }
        let anchorID = activeTab.id
        let hostID = activeTab.hostID
        // A live SSH tab answers its own pane cwd below. A mosh tab cannot,
        // so carry the complete session identity into the viewer: its own SSH
        // connection re-asks tmux or herdr before $HOME is considered.
        let anchorSession = activeTab.sessionKey
        Task { [weak self] in
            guard let self else { return }
            // A pressed path anchors to the pane under the finger; the
            // + TAB browse summon (no target) keeps the active pane.
            let cell = target == nil
                ? nil : workspace.controller(for: anchorID)?.pathPressScreenCell
            let cwd = await workspace.controller(for: anchorID)?
                .paneWorkingDirectory(pressedAt: cell)
            guard let anchor = route.tabs.first(where: { $0.id == anchorID }) else { return }
            if allowsPanel, admitsSidePanel(anchor: anchor) {
                workspace.openSidePanel(
                    hostTabID: anchorID,
                    controller: FileViewerController(
                        tabID: UUID(),
                        host: host,
                        startDirectory: cwd,
                        anchorSession: anchorSession,
                        anchorCell: cell,
                        target: target
                    )
                )
                renderNow()
                return
            }

            let tab = TerminalRoute(
                hostID: hostID,
                mode: .fileViewer(path: target?.path ?? cwd ?? "~")
            )
            workspace.openFileViewer(
                tab: tab,
                host: host,
                startDirectory: cwd,
                anchorSession: anchorSession,
                anchorCell: cell,
                target: target
            )
            dock(tab, after: anchorID)
        }
    }

    private func openFileInNewViewerTab(
        _ row: FileTree.Row,
        after sourceTabID: UUID
    ) {
        guard !row.entry.isDirectory,
              let sourceTab = route.tabs.first(where: { $0.id == sourceTabID }),
              sourceTab.isFileViewer,
              let sourceController = workspace.fileViewerController(for: sourceTabID),
              let host = store.host(id: sourceTab.hostID)
        else { return }
        openFileInNewViewerTab(
            row,
            sourceController: sourceController,
            hostID: sourceTab.hostID,
            after: sourceTabID,
            host: host
        )
    }

    private func openFileInNewViewerTab(
        _ row: FileTree.Row,
        sourceController: FileViewerController,
        hostID: UUID,
        after anchorID: UUID,
        host suppliedHost: Host? = nil
    ) {
        guard !row.entry.isDirectory,
              let host = suppliedHost ?? store.host(id: hostID)
        else { return }
        let path = row.entry.path
        // Tree entries are absolute remote paths. Carry that authority into
        // a fresh, in-memory viewer controller, registered before its route
        // enters the tab list like every other auxiliary pane.
        let target = TerminalPathTarget(
            raw: path,
            path: path,
            base: .absolute,
            line: nil
        )
        let tab = TerminalRoute(
            hostID: hostID,
            mode: .fileViewer(path: path)
        )
        workspace.openFileViewer(
            tab: tab,
            host: host,
            startDirectory: FileTree.parent(of: path),
            anchorSession: nil,
            target: target,
            targetPresentation: sourceController.selectionPresentation(for: row)
        )
        dock(tab, after: anchorID)
    }

    func openViewport(_ offer: ViewportOffer) {
        guard let activeTab else { return }
        openViewport(offer, after: activeTab.id, allowsPanel: true)
    }

    private func openViewport(
        _ offer: ViewportOffer,
        after anchorID: UUID,
        allowsPanel: Bool = true
    ) {
        guard let anchor = route.tabs.first(where: { $0.id == anchorID }),
              let host = store.host(id: anchor.hostID)
        else { return }
        if allowsPanel, admitsSidePanel(anchor: anchor) {
            workspace.openSidePanel(
                hostTabID: anchorID,
                controller: ViewportController(tabID: UUID(), offer: offer, host: host)
            )
            renderNow()
            return
        }
        let tab = TerminalRoute(
            hostID: anchor.hostID,
            mode: .viewport(urlString: offer.url.absoluteString)
        )
        workspace.openViewport(tab: tab, offer: offer, host: host)
        dock(tab, after: anchorID)
    }

    private func dock(_ tab: TerminalRoute, after anchorID: UUID) {
        mutateRoute { route in
            if let index = route.tabs.firstIndex(where: { $0.id == anchorID }) {
                route.tabs.insert(tab, at: index + 1)
            } else {
                route.tabs.append(tab)
            }
            route.activate(tab.id)
        }
    }

    // MARK: Focus and probes

    /// Keyboard focus follows the visible tab whatever its transport is
    /// doing. Claiming is what resigns the tab that just went off screen, so
    /// gating this on `.live` would leave a hidden live session first
    /// responder while a connecting/ended pane is on screen — every keystroke
    /// would land invisibly in the session behind it.
    private func claimActiveTerminalFocusIfAllowed() {
        guard terminalFocusAllowed,
              activeTab?.isAuxiliaryPane != true
        else { return }
        activeController?.focusTerminal()
    }

    /// Appearance and scene activation are not user focus requests. Several
    /// Stage Manager / visionOS scenes foreground together, so each surface
    /// may only reassert the app-wide owner selected before suspension.
    private func restoreActiveTerminalFocusIfOwner() {
        guard activeTab?.isAuxiliaryPane != true else { return }
        Self.restoreFocusAfterSurfaceAppearance(
            activeController,
            allowed: terminalFocusAllowed
        )
    }

    /// Named seam for the UIKit focus contract and its two-window test.
    static func restoreFocusAfterSurfaceAppearance(
        _ controller: TerminalSessionController?,
        allowed: Bool
    ) {
        controller?.restoreFocusIfOwner(allowed: allowed)
    }

    private func restartActiveTasks() {
        hostProbeTask?.cancel()
        activePaneTask?.cancel()
        hostProbeTask = Task { [weak self] in await self?.keepHostProbeWarm() }
        activePaneTask = Task { [weak self] in await self?.watchActivePane() }
    }

    private func keepHostProbeWarm() async {
        #if DEBUG
        AgentChipDebugHook.install()
        NewTabDebugHook.install()
        MessageJumpDebugHook.install()
        TerminalLinkDebugHook.install()
        FileViewerDebugHook.install()
        SidePanelDebugHook.install()
        #endif
        guard let hostID = activeTab?.hostID,
              let host = store.host(id: hostID)
        else { return }
        let model = hub.model(for: host)
        while !Task.isCancelled {
            // `permitsWork` resolves the keep-alive switch live, so this
            // task — which outlives a Host Settings save — sees a flip
            // without waiting for a tab change to restart it.
            if BackgroundActivity.shared.permitsWork(for: host) {
                entitlements.refreshSlashChipMeter()
                await model.refreshAndWait(ifStaleFor: 4)
            }
            try? await Task.sleep(for: Self.hostProbeInterval)
        }
    }

    private func watchActivePane() async {
        guard let watchedTab = activeTab,
              !watchedTab.isAuxiliaryPane,
              let host = store.host(id: watchedTab.hostID)
        else {
            activePaneFingerprint = nil
            shownAgent = nil
            renderNow()
            return
        }
        guard let sessionName = watchedTab.sessionName else {
            activePaneFingerprint = nil
            let initialAgent = activeController?.directShellAgent
            if shownAgent != initialAgent {
                shownAgent = initialAgent
                renderNow()
            }
            while !Task.isCancelled {
                if UIApplication.shared.applicationState == .active,
                   let controller = activeController,
                   let view = controller.terminalView,
                   TerminalFocusArbiter.current === view,
                   !view.hasRecentUserInput(within: Self.typingQuietWindow) {
                    await controller.refreshDirectShellAgent(ifStaleFor: 0.8)
                    guard !Task.isCancelled,
                          activeTab?.id == watchedTab.id
                    else { return }
                    let nextAgent = controller.directShellAgent
                    if shownAgent != nextAgent {
                        hideAgentTask?.cancel()
                        shownAgent = nextAgent
                        renderNow()
                    }
                }
                try? await Task.sleep(for: Self.focusedPaneProbeInterval)
            }
            return
        }

        let model = hub.model(for: host)
        // Any backend this host MONITORS can answer, matching `detectedAgent`
        // above — on a mixed host the secondary's tabs get the focused-pane
        // check too. A tab whose backend the host no longer monitors (or a
        // `.shell` tab, which has none) gets nothing rather than a same-named
        // record from the other one.
        guard let backend = watchedTab.sessionBackend, host.monitors(backend) else {
            activePaneFingerprint = nil
            shownAgent = nil
            renderNow()
            return
        }
        let initialAgent = detectedAgent
        let agentChanged = shownAgent != initialAgent
        shownAgent = initialAgent
        activePaneFingerprint = model
            .sessions(on: backend)
            .first(where: { $0.name == sessionName })?
            .activeWindow?
            .activePane?
            .processFingerprint
        if agentChanged { renderNow() }
        await model.refreshAndWait(ifStaleFor: 4)

        if backend == .herdr {
            // The five-second wall probe remains the broad session/attention
            // authority. Between ticks, the one terminal that owns keyboard
            // focus asks `pane current`: herdr's global focused pane identifies
            // the agent now receiving helper-chip input without a full snapshot.
            // Unfocused windows keep following the in-memory wall verdict,
            // avoiding one fast SSH loop per visible spatial window.
            while !Task.isCancelled {
                guard activeTab?.id == watchedTab.id else { return }
                if UIApplication.shared.applicationState == .active,
                   let view = activeController?.terminalView,
                   TerminalFocusArbiter.current === view {
                    // Mid-burst the check waits — and deliberately without
                    // falling to the wall-verdict branch below, so a chip
                    // never swaps under the user's fingers.
                    if !view.hasRecentUserInput(within: Self.typingQuietWindow) {
                        let detection = await model.detectActiveAgent(
                            in: sessionName, backend: backend)
                        guard !Task.isCancelled, activeTab?.id == watchedTab.id else { return }
                        if let detection { apply(detection) }
                    }
                } else if UIApplication.shared.applicationState == .active {
                    let nextAgent = detectedAgent
                    if shownAgent != nextAgent {
                        hideAgentTask?.cancel()
                        shownAgent = nextAgent
                        renderNow()
                    }
                }
                try? await Task.sleep(for: Self.focusedPaneProbeInterval)
            }
            return
        }

        while !Task.isCancelled {
            if UIApplication.shared.applicationState == .active,
               let view = activeController?.terminalView,
               TerminalFocusArbiter.current === view,
               !view.hasRecentUserInput(within: Self.typingQuietWindow) {
                let detection = await model.detectActiveAgent(
                    in: sessionName, backend: backend)
                guard !Task.isCancelled, activeTab?.id == watchedTab.id else { return }
                if let detection { apply(detection) }
            }
            try? await Task.sleep(for: Self.focusedPaneProbeInterval)
        }
    }

    private func apply(_ detection: ActivePaneAgentDetection) {
        let changedPane = activePaneFingerprint != detection.fingerprint
        let previousAgent = shownAgent
        activePaneFingerprint = detection.fingerprint
        hideAgentTask?.cancel()
        if let agent = detection.agent {
            shownAgent = agent
        } else if changedPane || detection.isDefinitive {
            shownAgent = nil
        }
        if previousAgent != shownAgent { renderNow() }
    }

    private func send(
        _ command: AgentCommand,
        via controller: TerminalSessionController
    ) {
        guard !command.consumesSlashChipTaste || entitlements.consumeSlashChip()
        else { return }
        controller.sendInput(command.payload)
        guard command.submitsAfterPause else { return }
        Task {
            try? await Task.sleep(for: AgentCommand.submitDelay)
            controller.sendInput(Data([0x0D]))
        }
    }

    // MARK: Lifecycle

    private func configureLifecycleObservers() {
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self,
                      note.object as? UIScene === viewIfLoaded?.window?.windowScene
                else { return }
                Task { await self.store.refreshFromCloud() }
                self.entitlements.refreshSlashChipMeter()
                self.restoreActiveTerminalFocusIfOwner()
                for tab in self.route.tabs {
                    self.workspace.controller(for: tab.id)?.transportForegrounded()
                }
            }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: .agentHelperStripCollapseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The collapse choice is posted on MainActor. Handle it in this
            // same turn, before the helper's direct fallback render can make
            // the ornament jump to its final intrinsic size without a
            // SwiftUI transaction.
            MainActor.assumeIsolated {
                guard let self,
                      self.isViewLoaded,
                      self.helperController != nil
                else { return }
                self.animateAgentHelperCollapse()
            }
        })
    }

    private func animateAgentHelperCollapse() {
        #if os(visionOS)
        if shell == nil {
            // Classic ornaments are SwiftUI-hosted in their own window. The
            // mirrored collapse value in TerminalVisionOrnamentState drives
            // that host's spring; a UIView animation on `rootView` cannot.
            renderNow()
            return
        }
        #endif
        animateChromeRender()
    }

    /// The chrome band's one motion: the helper strip's fold and the
    /// Talkback card's arrival, departure and growth all run the window's
    /// render inside this spring, so the pane cedes or reclaims its rows in
    /// the same curve as the band. `alongside` rides the block; Reduce
    /// Motion (or a window not yet on screen) cuts straight to the result.
    private typealias ChromeSpring = (duration: TimeInterval, damping: CGFloat)
    private nonisolated static let chromeBandSpring: ChromeSpring = (0.35, 0.85)

    private var animatesChrome: Bool {
        !UIAccessibility.isReduceMotionEnabled && rootView.window != nil
    }

    private func animateChromeRender(
        _ spring: ChromeSpring = chromeBandSpring,
        alongside: @escaping () -> Void = {},
        completion: (() -> Void)? = nil
    ) {
        let changes = { [self] in
            renderNow()
            alongside()
            rootView.layoutIfNeeded()
        }
        guard animatesChrome else {
            changes()
            completion?()
            return
        }
        UIView.animate(
            withDuration: spring.duration,
            delay: 0,
            usingSpringWithDamping: spring.damping,
            initialSpringVelocity: 0,
            animations: changes
        ) { _ in completion?() }
    }

    #if !os(visionOS)
    /// The card's arrival or departure, when the next render will mount or
    /// drop it.
    private enum TalkbackTransition {
        case opening
        case closing
    }

    private var pendingTalkbackTransition: TalkbackTransition? {
        if talkbackOpen, talkbackController == nil { return .opening }
        if !talkbackOpen, talkbackController != nil { return .closing }
        return nil
    }

    /// Opening: the card rises out from behind the rail's edge (its band
    /// clips it, so it never crosses the keys) while the pane cedes its rows;
    /// closing: a snapshot of the card sinks back the same way while the pane
    /// reclaims them.
    private func animateTalkbackTransition(_ transition: TalkbackTransition) {
        guard animatesChrome else {
            renderNow()
            return
        }
        switch transition {
        case .opening:
            // Mount unanimated and park the band at its final frame with the
            // card pushed below it (clipped, so it never crosses the keys);
            // the animated render then insets the pane — the surface lays its
            // constraint out inside the block, so it animates — while the
            // card slides up into the band.
            UIView.performWithoutAnimation {
                renderTalkback()
                let container = rootView.talkbackContainer
                let height = renderedTalkbackHeight
                container.frame = CGRect(
                    x: 0,
                    y: paneChromeBottom - height,
                    width: rootView.bounds.width,
                    height: height
                )
                container.isHidden = false
                if let card = talkbackController?.view {
                    card.frame = container.bounds
                    card.layoutIfNeeded()
                    card.transform = CGAffineTransform(translationX: 0, y: height)
                }
            }
            animateChromeRender(alongside: { [self] in
                talkbackController?.view.transform = .identity
            })
        case .closing:
            // The real card unmounts in the render; a snapshot inside a
            // clipping stand-in at the same frame sinks out of view while the
            // pane takes its rows back.
            let container = rootView.talkbackContainer
            let clip = UIView(frame: container.frame)
            clip.clipsToBounds = true
            clip.isUserInteractionEnabled = false
            if let ghost = container.snapshotView(afterScreenUpdates: false) {
                ghost.frame = clip.bounds
                clip.addSubview(ghost)
                rootView.insertSubview(clip, aboveSubview: container)
            }
            animateChromeRender(alongside: {
                clip.subviews.first?.transform = CGAffineTransform(
                    translationX: 0,
                    y: clip.bounds.height
                )
            }, completion: {
                clip.removeFromSuperview()
            })
        }
    }

    private nonisolated static let chromeGrowthSpring: ChromeSpring = (0.25, 0.9)

    /// A line typed, a chip attached: the card grows upward and the pane
    /// cedes the row in one motion.
    private func animateTalkbackGrowth() {
        animateChromeRender(Self.chromeGrowthSpring)
    }

    /// Where the pane's bottom chrome starts: the rail's top edge, lifted
    /// with it over a docked keyboard.
    private var paneChromeBottom: CGFloat {
        rootView.paneContainer.frame.maxY
            - (activeController?.keyboardObstruction ?? 0)
            - TerminalKeyBar.barHeight(spendsBottomStrip: railOwnsBottomSafeArea)
    }
    #endif

    private func configurePassphrasePresenter() {
        addChild(passphrasePresenter)
        rootView.addSubview(passphrasePresenter.view)
        passphrasePresenter.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            passphrasePresenter.view.widthAnchor.constraint(equalToConstant: 0),
            passphrasePresenter.view.heightAnchor.constraint(equalToConstant: 0),
            passphrasePresenter.view.topAnchor.constraint(equalTo: rootView.topAnchor),
            passphrasePresenter.view.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
        ])
        passphrasePresenter.didMove(toParent: self)
    }

    private func updatePassphrasePrompt() {
        passphrasePresenter.update(
            challenge: keyPassphraseChallenge,
            onSubmit: { [weak self] challenge, passphrase, save in
                self?.acceptKeyPassphrase(
                    challenge,
                    passphrase: passphrase,
                    saveToICloud: save
                )
            },
            onCancel: { _ in }
        )
    }

    private func acceptKeyPassphrase(
        _ challenge: SSHKeyPassphraseChallenge,
        passphrase: String,
        saveToICloud: Bool
    ) {
        SSHKeyPassphraseSession.accept(
            passphrase,
            for: challenge.hostID,
            saveToICloud: saveToICloud
        )
        hub.resumeConnectionsWaitingForKeyPassphrase(hostID: challenge.hostID)
        workspace.resumeConnectionsWaitingForKeyPassphrase(hostID: challenge.hostID)
    }
}

// MARK: - Native child composition

extension TerminalWindowViewController {
    private func reconcilePaneControllers() {
        let liveIDs = Set(route.tabs.map(\.id))
        let removedIDs = paneControllers.keys.filter { !liveIDs.contains($0) }
        for id in removedIDs {
            guard let controller = paneControllers.removeValue(forKey: id) else {
                continue
            }
            preparePaneForRemoval(controller)
            unmount(controller)
        }

        for tab in route.tabs {
            let isActive = tab.id == activeTab?.id
            let pane = paneControllers[tab.id] ?? makePaneController(for: tab)
            guard let pane else { continue }
            if paneControllers[tab.id] == nil {
                paneControllers[tab.id] = pane
                mount(pane, in: rootView.paneContainer)
            }
            pane.view.frame = rootView.paneContainer.bounds
            pane.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pane.view.isHidden = !isActive
            pane.view.isUserInteractionEnabled = isActive
            pane.view.accessibilityElementsHidden = !isActive
            updatePaneController(pane, for: tab, isActive: isActive)
        }
    }

    private func renderSidePanel() {
        let desiredHost = activeTab.flatMap { tab in
            tab.isAuxiliaryPane ? nil : tab.id
        }
        // Inactive wrappers stay cached while their workspace controller is
        // alive, so a hidden file keeps loading; a wrapper whose controller
        // closed goes now. The desired host's REPLACED wrapper stays for the
        // crossfade below and is released when it completes.
        for (hostID, cached) in sidePanelViewControllers {
            let live = workspace.sidePanel(for: hostID)
            guard live !== cached.controller, !(hostID == desiredHost && live != nil) else { continue }
            sidePanelViewControllers.removeValue(forKey: hostID)
            cached.prepareForRemoval()
            if cached.parent === self { unmount(cached) }
        }

        guard let hostID = desiredHost,
              let auxiliary = workspace.sidePanel(for: hostID),
              let hostTab = route.tabs.first(where: { $0.id == hostID })
        else {
            unmountCurrentSidePanel()
            return
        }

        let previousForHost = sidePanelViewControllers[hostID]
        let panel: SidePanelViewController
        if let previousForHost, previousForHost.controller === auxiliary {
            panel = previousForHost
        } else {
            panel = makeSidePanelViewController(hostTab: hostTab, controller: auxiliary)
            sidePanelViewControllers[hostID] = panel
        }
        let replaced = previousForHost !== panel ? previousForHost : nil
        panel.setPresented(true)

        if sidePanelStyle == .visionOrnament {
            // The ornament hosts the controller; the strip lays itself out.
            panel.updateWidth(resolvedSidePanelWidth())
            panel.updateOverhang(SidePanelWidthStore.shared.visionOverhang)
            panel.refreshHeader()
            replaced?.prepareForRemoval()
            mountedSidePanelHostID = hostID
            panel.loadViewIfNeeded()
            return
        }

        // In-window: `layoutInWindowSidePanel` frames the container and
        // hands the card its width on every layout pass.
        panel.refreshHeader()
        let oldMounted = mountedSidePanelHostID.flatMap {
            $0 == hostID ? previousForHost : sidePanelViewControllers[$0]
        }
        let changes = { [self] in
            if let oldMounted, oldMounted !== panel, oldMounted.parent === self {
                oldMounted.setPresented(false)
                unmount(oldMounted)
            }
            if panel.parent !== self { mount(panel, in: rootView.sidePanelContainer) }
            panel.view.isHidden = false
            mountedSidePanelHostID = hostID
            rootView.sidePanelContainer.isHidden = false
            layoutInWindowSidePanel()
        }
        if replaced != nil, animatesChrome {
            UIView.transition(
                with: rootView.sidePanelContainer,
                duration: 0.3,
                options: [.transitionCrossDissolve, .allowAnimatedContent],
                animations: changes
            ) { _ in replaced?.prepareForRemoval() }
        } else {
            changes()
            replaced?.prepareForRemoval()
        }
    }

    private func makeSidePanelViewController(
        hostTab: TerminalRoute,
        controller: any AuxiliaryPaneController
    ) -> SidePanelViewController {
        let hostTabID = hostTab.id
        let hostID = hostTab.hostID
        // The row is UIKit inside the hosted controller: a rail change only
        // refreshes it, never the window's ornaments.
        let refreshHeader: () -> Void = { [weak self] in
            self?.sidePanelViewControllers[hostTabID]?.refreshHeader()
        }
        let pane: UIViewController
        if let viewport = controller as? ViewportController {
            pane = ViewportPaneViewController(
                controller: viewport,
                contentSafeArea: .zero,
                showsInWindowRail: false,
                ornamentRailDidChange: refreshHeader,
                borrowKeyboard: { [weak self] field in
                    let terminal = self?.workspace.controller(for: hostTabID)?.terminalView
                    TerminalFocusArbiter.lend(terminal, to: field)
                },
                close: { [weak self] in
                    self?.closeSidePanel(hostTabID: hostTabID)
                }
            )
        } else if let fileViewer = controller as? FileViewerController {
            pane = FileViewerPaneViewController(
                controller: fileViewer,
                contentSafeArea: .zero,
                isActive: true,
                showsInWindowRail: false,
                ornamentRailDidChange: refreshHeader,
                openInNewTab: { [weak self, weak fileViewer] row in
                    guard let fileViewer else { return }
                    self?.openFileInNewViewerTab(
                        row,
                        sourceController: fileViewer,
                        hostID: hostID,
                        after: hostTabID
                    )
                },
                openViewport: { [weak self] offer in
                    self?.openViewport(
                        offer,
                        after: hostTabID,
                        allowsPanel: false
                    )
                },
                close: { [weak self] in
                    self?.closeSidePanel(hostTabID: hostTabID)
                }
            )
        } else {
            preconditionFailure("Unsupported side-panel controller")
        }

        let style = sidePanelStyle ?? .iPadOverlay
        let panel = SidePanelViewController(
            controller: controller,
            paneController: pane,
            presentationStyle: style,
            width: resolvedSidePanelWidth(),
            overhang: style == .visionOrnament
                ? SidePanelWidthStore.shared.visionOverhang : 0,
            split: { [weak self] in
                self?.splitSidePanelToTab(hostTabID: hostTabID)
            },
            close: { [weak self] in
                self?.closeSidePanel(hostTabID: hostTabID)
            },
            resize: { [weak self] width, overhang, phase in
                self?.sidePanelDidResize(
                    width: width,
                    overhang: overhang,
                    phase: phase,
                    hostTabID: hostTabID
                )
            }
        )
        #if os(visionOS)
        if style == .visionOrnament {
            panel.onCardFrameChange = { [weak self] frame in
                self?.visionOrnaments.state.setSidePanelCardFrame(frame)
            }
        }
        #endif
        return panel
    }

    private func unmountCurrentSidePanel() {
        if sidePanelStyle == .visionOrnament {
            if let hostID = mountedSidePanelHostID {
                sidePanelViewControllers[hostID]?.setPresented(false)
            }
            mountedSidePanelHostID = nil
            return
        }
        guard let hostID = mountedSidePanelHostID else {
            rootView.sidePanelContainer.isHidden = true
            return
        }
        if let panel = sidePanelViewControllers[hostID], panel.parent === self {
            panel.setPresented(false)
            unmount(panel)
        }
        mountedSidePanelHostID = nil
        rootView.sidePanelContainer.isHidden = true
    }

    /// The remembered width as this window can show it: an overlay clamps
    /// to its pane here; the ornament's card clamps itself to the strip.
    private func resolvedSidePanelWidth() -> CGFloat {
        guard let platform = sidePanelPlatform, let style = sidePanelStyle else { return 0 }
        if let transientSidePanelWidth { return transientSidePanelWidth }
        let stored = SidePanelWidthStore.shared.width(for: platform)
        switch style {
        case .iPadOverlay:
            return SidePanelWidth.clamped(stored, paneWidth: rootView.paneContainer.bounds.width)
        case .visionOrnament:
            return stored
        }
    }

    private func sidePanelDidResize(
        width: CGFloat,
        overhang: CGFloat,
        phase: SidePanelResizePhase,
        hostTabID: UUID
    ) {
        guard mountedSidePanelHostID == hostTabID,
              let panel = sidePanelViewControllers[hostTabID]
        else { return }
        switch panel.presentationStyle {
        case .visionOrnament:
            // The strip laid itself out live; only the release persists.
            guard phase == .ended else { return }
            SidePanelWidthStore.shared.setVisionGeometry(width: width, overhang: overhang)
            renderNow()
        case .iPadOverlay:
            // Only the overlay moves per tick; the rest of the chrome waits
            // for the release's render.
            let clamped = SidePanelWidth.clamped(
                width,
                paneWidth: rootView.paneContainer.bounds.width
            )
            transientSidePanelWidth = clamped
            layoutInWindowSidePanel()
            guard phase == .ended else { return }
            if let platform = sidePanelPlatform {
                SidePanelWidthStore.shared.setWidth(clamped, for: platform)
            }
            transientSidePanelWidth = nil
            renderNow()
        }
    }

    func closeSidePanel(hostTabID: UUID) {
        workspace.closeSidePanel(hostTabID: hostTabID)
        renderNow()
    }

    func splitSidePanelToTab(hostTabID: UUID) {
        guard let hostTab = route.tabs.first(where: { $0.id == hostTabID }),
              !hostTab.isAuxiliaryPane,
              let controller = workspace.detachSidePanel(hostTabID: hostTabID)
        else { return }

        let auxiliaryTab = TerminalRoute(hostID: hostTab.hostID, mode: controller.routeMode)
        // Register first: `dock` mutates the route synchronously and
        // `syncTabs` strips controller-less auxiliaries by design.
        workspace.adoptAuxiliary(controller, tabID: auxiliaryTab.id)
        dock(auxiliaryTab, after: hostTabID)
    }

    private var showsInWindowAuxiliaryRail: Bool {
        #if os(visionOS)
        shell != nil
        #else
        true
        #endif
    }

    private func auxiliaryOrnamentDidChange() {
        #if os(visionOS)
        guard shell == nil, !appLocked, isViewLoaded else { return }
        // Pane observation may fire while UIKit is loading that pane inside
        // reconciliation. Move ornament reconciliation to the next main turn
        // rather than re-entering the child graph mid-mount.
        Task { @MainActor [weak self] in
            guard let self, self.shell == nil, !self.appLocked else { return }
            self.renderUMD()
            self.updateVisionOrnaments(forceRevision: true)
        }
        #endif
    }

    private func makePaneController(for tab: TerminalRoute) -> UIViewController? {
        if tab.isViewport {
            guard let viewport = workspace.viewportController(for: tab.id) else { return nil }
            return ViewportPaneViewController(
                controller: viewport,
                contentSafeArea: contentSafeArea,
                showsInWindowRail: showsInWindowAuxiliaryRail,
                ornamentRailDidChange: { [weak self] in
                    self?.auxiliaryOrnamentDidChange()
                },
                close: { [weak self] in self?.closeTab(tab.id) }
            )
        }
        if tab.isFileViewer {
            guard let fileViewer = workspace.fileViewerController(for: tab.id) else { return nil }
            return FileViewerPaneViewController(
                controller: fileViewer,
                contentSafeArea: contentSafeArea,
                isActive: tab.id == activeTab?.id,
                showsInWindowRail: showsInWindowAuxiliaryRail,
                ornamentRailDidChange: { [weak self] in
                    self?.auxiliaryOrnamentDidChange()
                },
                openInNewTab: { [weak self] row in
                    self?.openFileInNewViewerTab(row, after: tab.id)
                },
                openViewport: { [weak self] offer in
                    self?.openViewport(offer, after: tab.id, allowsPanel: false)
                },
                close: { [weak self] in self?.closeTab(tab.id) }
            )
        }
        return TerminalPaneViewController(configuration: paneConfiguration(
            for: tab,
            isActive: tab.id == activeTab?.id
        ))
    }

    private func updatePaneController(
        _ pane: UIViewController,
        for tab: TerminalRoute,
        isActive: Bool
    ) {
        if let terminal = pane as? TerminalPaneViewController {
            terminal.update(configuration: paneConfiguration(for: tab, isActive: isActive))
        } else if let viewport = pane as? ViewportPaneViewController {
            viewport.update(
                contentSafeArea: contentSafeArea,
                close: { [weak self] in self?.closeTab(tab.id) },
                ornamentRailDidChange: { [weak self] in
                    self?.auxiliaryOrnamentDidChange()
                }
            )
        } else if let fileViewer = pane as? FileViewerPaneViewController {
            fileViewer.update(
                contentSafeArea: contentSafeArea,
                isActive: isActive,
                openInNewTab: { [weak self] row in
                    self?.openFileInNewViewerTab(row, after: tab.id)
                },
                openViewport: { [weak self] offer in
                    self?.openViewport(offer, after: tab.id, allowsPanel: false)
                },
                close: { [weak self] in self?.closeTab(tab.id) },
                ornamentRailDidChange: { [weak self] in
                    self?.auxiliaryOrnamentDidChange()
                }
            )
        }
    }

    private func paneConfiguration(
        for tab: TerminalRoute,
        isActive: Bool
    ) -> TerminalPaneConfiguration {
        TerminalPaneConfiguration(
            controller: workspace.controller(for: tab.id),
            hostExists: store.host(id: tab.hostID) != nil,
            fontSize: fontSize,
            theme: resolvedTerminalTheme,
            bottomChromeHeight: terminalBottomChromeHeight,
            contentSafeArea: contentSafeArea,
            railOwnsBottomSafeArea: railOwnsBottomSafeArea,
            isActive: isActive,
            focusAllowed: terminalFocusAllowed,
            keyCommandPlan: keyCommandPlan,
            close: { [weak self] in self?.closeTab(tab.id) }
        )
    }

    /// The hold-CTRL panel's tier: the free cap with the paywall as its
    /// route, or the full cap once Pro. `entitlements.isPro` is in this
    /// controller's observation set, so a purchase re-renders every pane
    /// (and, on visionOS, the cluster contexts) with the lifted plan.
    private var keyCommandPlan: KeyCommandPlan {
        KeyCommandPlan(
            limit: entitlements.keyCommandLimit,
            upgrade: entitlements.isPro ? nil : { [weak self] in self?.presentPaywall() }
        )
    }

    private func preparePaneForRemoval(_ pane: UIViewController) {
        (pane as? TerminalPaneViewController)?.prepareForRemoval()
        (pane as? ViewportPaneViewController)?.prepareForRemoval()
        (pane as? FileViewerPaneViewController)?.prepareForRemoval()
    }

    private func mount(_ controller: UIViewController, in container: UIView) {
        addChild(controller)
        container.addSubview(controller.view)
        controller.view.frame = container.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.didMove(toParent: self)
    }

    private func unmount(_ controller: UIViewController) {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func renderTabStrip() {
        tabStrip.apply(
            items: tabItems,
            allowsSplit: shell == nil,
            activate: { [weak self] in self?.activate($0) },
            split: { [weak self] in self?.splitTab($0) },
            close: { [weak self] in self?.closeTab($0) },
            reorder: { [weak self] source, target in
                self?.reorderTab(source, to: target)
            }
        )
        #if os(visionOS)
        guard shell != nil else {
            visionOrnaments.state.topHostView.refreshFittingSize()
            return
        }
        #endif
        if tabStrip.superview !== rootView.tabScrollView {
            tabStrip.removeFromSuperview()
            rootView.tabScrollView.addSubview(tabStrip)
        }
        // Geometry belongs to `layoutNativeChrome`, which measures the strip
        // on every layout pass anyway: sizing it only here left a pass that
        // changed the fitting size without a render with a stale strip width
        // — cells compressed into each other, and the overflow past that
        // width stopped hit-testing entirely.
        rootView.setNeedsLayout()
    }

    private var tabItems: [TerminalTabStrip.Item] {
        let multiHost = Set(route.tabs.map(\.hostID)).count > 1
        return route.tabs.map { tab in
            TerminalTabStrip.Item(
                id: tab.id,
                title: tabTitle(for: tab),
                hostName: multiHost ? store.host(id: tab.hostID)?.name : nil,
                controller: workspace.controller(for: tab.id),
                isActive: tab.id == activeTab?.id,
                isAuxiliary: tab.isAuxiliaryPane,
                hasSidePanel: !tab.isAuxiliaryPane
                    && workspace.sidePanel(for: tab.id) != nil
            )
        }
    }

    private func tabTitle(for tab: TerminalRoute) -> String {
        if tab.isAuxiliaryPane,
           let auxiliary = workspace.auxiliaryController(for: tab.id) {
            return auxiliary.tabLabel
        }
        return tab.displayName
    }

    private var windowTitle: String {
        guard let activeTab else { return String(localized: "Terminal") }
        let hostName = store.host(id: activeTab.hostID)?.name
        let title = tabTitle(for: activeTab)
        return hostName.map { "\(title) — \($0)" } ?? title
    }

    private var umdTitle: String {
        guard let activeTab else { return windowTitle }
        let hostName = store.host(id: activeTab.hostID)?.name
        let title = tabTitle(for: activeTab)
        return hostName.map { "\(title) · \($0)" } ?? title
    }

    private var auxiliaryCloseLabel: String {
        activeTab?.isFileViewer == true
            ? String(localized: "Close file viewer")
            : String(localized: "Close viewport")
    }

    /// The herdr-only second `+ TAB` entry the active tab offers — the one
    /// place the menu row, the control's label, and the failure alert read
    /// it from. The leading entry is New Session on every backend.
    private var extraNewTabTarget: TerminalRoute.NewTabTarget? {
        activeTab?.extraNewTabTarget
    }

    /// Everything the rail's geometry turns on, resolved once. Three facts
    /// (which row, how much chassis, who owns the shortcut key) all follow
    /// from one question — is this the classic window's own title bar? —
    /// and deriving them separately is how they drift apart.
    private struct RailProfile {
        var style: UMDBarStyle
        var auxiliaryStyle: ViewportUMDStyle
        /// Chassis above and below the faces, a floor once `minimumHeight`
        /// applies.
        var verticalPadding: CGFloat
        /// The title bar matches the key rail at the pane's other end.
        var minimumHeight: CGFloat
        /// Whether the pane below this rail wears a `TerminalKeyBar`. Where
        /// one exists it owns the TMUX/HRDR key until its own width drops it,
        /// and the rail measures THAT width before drawing the key itself.
        var hasKeyRail: Bool

        /// visionOS classic windows wear the `.regular` row inside an
        /// ornament; every other terminal surface — the adaptive shell and,
        /// since the system navigation bar was retired, the classic
        /// iPad/Mac window — wears the slim rail.
        static let ornament = RailProfile(
            style: .regular,
            auxiliaryStyle: .regular,
            verticalPadding: 8,
            minimumHeight: 0,
            hasKeyRail: false
        )

        static let shell = RailProfile(
            style: .shell,
            auxiliaryStyle: .shell,
            verticalPadding: 8,
            minimumHeight: 0,
            hasKeyRail: true
        )

        #if !os(visionOS)
        /// `TerminalKeyBar` is iPad/iPhone-only, and so is this profile.
        static let titleBar = RailProfile(
            style: .shell,
            auxiliaryStyle: .shell,
            verticalPadding: TerminalClassicRailInsets.verticalPadding,
            minimumHeight: TerminalKeyBar.barHeight,
            hasKeyRail: true
        )
        #endif
    }

    private var railProfile: RailProfile {
        guard shell == nil else { return .shell }
        #if os(visionOS)
        return .ornament
        #else
        return .titleBar
        #endif
    }

    /// The pane's clearance and the rail's, side by side. They must never be
    /// the same value on a classic window: the rail clears the window-control
    /// pill, and that inset reaching a pane shoves the terminal and key rail
    /// off their own window (regression, 2026-08-04).
    var paneAndRailInsetsForTesting: (pane: UIEdgeInsets, rail: UIEdgeInsets) {
        (contentSafeArea, umdSafeArea)
    }

    /// What the rail may measure against: the window minus the clearance it
    /// hands back. The shell computes its own; the classic window derives one
    /// so the rail can still choose its compact row in a narrow Stage Manager
    /// window (a nil width reads as unlimited and would pin it wide).
    private var umdAvailableWidth: CGFloat? {
        if let shell { return shell.availableWidth }
        #if os(visionOS)
        return nil
        #else
        guard isViewLoaded else { return nil }
        return railWidth(clearing: umdSafeArea)
        #endif
    }

    #if !os(visionOS)
    private func railWidth(clearing insets: UIEdgeInsets) -> CGFloat {
        max(0, rootView.bounds.width - insets.left - insets.right)
    }
    #endif

    /// The content width of the pane's key rail — the width its TMUX/HRDR key
    /// must fit in, and the only honest input to "may the rail above draw one
    /// too". Never the rail's own available width: the classic window's rail
    /// clears the window-control pill and is ~90 pt narrower than the pane
    /// below it. nil where no key rail exists, so the rail owns the key.
    private func keyRailContentWidth(profile: RailProfile) -> CGFloat? {
        #if os(visionOS)
        return nil
        #else
        guard profile.hasKeyRail else { return nil }
        if let shell { return shell.availableWidth }
        // Unmeasurable yet reads as roomy: the key rail keeps its own key
        // until a real width says otherwise.
        guard isViewLoaded else { return .greatestFiniteMagnitude }
        let insets = contentSafeArea
        return max(
            0,
            rootView.paneContainer.bounds.width - insets.left - insets.right
        )
        #endif
    }

    /// The reading size a ▤ tab's rail exposes. A ⌗ viewport tab gets none —
    /// a web page carries its own zoom.
    private var auxiliaryTextScale: ViewportUMDConfiguration.TextScale? {
        guard activeTab?.isFileViewer == true else { return nil }
        let store = FileViewerTextScaleStore.shared
        return ViewportUMDConfiguration.TextScale(
            scale: store.scale,
            canDecrease: store.canStep(by: -1),
            canIncrease: store.canStep(by: 1),
            step: { store.step(by: $0) },
            reset: { store.set(FileViewerTextScale.default) }
        )
    }

    private func renderUMD() {
        let profile = railProfile
        if activeTab?.isAuxiliaryPane == true {
            let activePane = activeTab.flatMap { paneControllers[$0.id] }
            let fileViewer = (activePane as? FileViewerPaneViewController)?
                .ornamentConfiguration
            let viewport = (activePane as? ViewportPaneViewController)?
                .ornamentConfiguration
            let configuration = ViewportUMDConfiguration(
                title: umdTitle,
                mergeSources: mergeSources,
                showDeck: { [weak self] in self?.showDeck() },
                merge: { [weak self] in self?.merge($0) },
                close: { [weak self] in
                    guard let id = self?.activeTab?.id else { return }
                    self?.closeTab(id)
                },
                style: profile.auxiliaryStyle,
                deckControlLabel: shell?.deckControlLabel ?? "DECK",
                contentSafeArea: umdSafeArea,
                contentVerticalPadding: profile.verticalPadding,
                minimumContentHeight: profile.minimumHeight,
                closeAccessibilityLabel: auxiliaryCloseLabel,
                textScale: auxiliaryTextScale,
                fileViewer: fileViewer,
                viewport: viewport
            )
            #if os(visionOS)
            if profile.auxiliaryStyle == .regular, viewport != nil {
                if let controller = umdController as? ViewportSwitchboardViewController {
                    controller.update(configuration: configuration)
                } else {
                    replaceUMD(with: ViewportSwitchboardViewController(
                        configuration: configuration
                    ))
                }
                return
            }
            #endif
            if let controller = umdController as? ViewportUMDViewController {
                controller.update(configuration: configuration)
            } else {
                replaceUMD(with: ViewportUMDViewController(configuration: configuration))
            }
            return
        }

        let configuration = UMDBarConfiguration(
            controller: activeController,
            title: umdTitle,
            mergeSources: mergeSources,
            showDeck: { [weak self] in self?.showDeck() },
            fontDown: { [weak self] in self?.changeFont(by: -1) },
            fontUp: { [weak self] in self?.changeFont(by: 1) },
            newSession: { [weak self] in self?.openNewTab(launching: $0) },
            newHerdrWorkspaceTab: { [weak self] in self?.openNewHerdrWorkspaceTab() },
            openFileViewer: { [weak self] in
                self?.openFileViewer(target: nil, allowsPanel: false)
            },
            merge: { [weak self] in self?.merge($0) },
            detach: { [weak self] in self?.detachActiveTab() },
            closeSession: activeTabHasSession
                ? { [weak self] in self?.confirmCloseActiveSession() } : nil,
            keychainTip: activeTabKeychainNotice != nil
                ? { [weak self] in self?.presentKeychainTip() } : nil,
            showConnectionStats: ConnectionStatsCenter.shared.isCollecting
                ? { [weak self] in self?.presentConnectionStats() } : nil,
            extraNewTabTarget: extraNewTabTarget,
            shortcutBackend: activeTab?.sessionBackend,
            style: profile.style,
            deckControlLabel: shell?.deckControlLabel ?? "DECK",
            availableWidth: umdAvailableWidth,
            contentSafeArea: umdSafeArea,
            contentVerticalPadding: profile.verticalPadding,
            keyRailContentWidth: keyRailContentWidth(profile: profile),
            minimumContentHeight: profile.minimumHeight
        )
        if let controller = umdController as? UMDBarViewController {
            controller.update(configuration: configuration)
        } else {
            replaceUMD(with: UMDBarViewController(configuration: configuration))
        }
    }

    private func replaceUMD(with replacement: UIViewController?) {
        guard umdController !== replacement else { return }
        if let existing = umdController {
            (existing as? UMDBarViewController)?.prepareForRemoval()
            #if os(visionOS)
            if shell != nil { unmount(existing) }
            #else
            unmount(existing)
            #endif
        }
        umdController = replacement
        guard let replacement else { return }
        #if os(visionOS)
        guard shell != nil else { return }
        #endif
        addChild(replacement)
        rootView.umdContainer.addSubview(replacement.view)
        replacement.view.frame = rootView.umdContainer.bounds
        replacement.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        replacement.didMove(toParent: self)
    }

    private func renderHelper() {
        guard let activeTab,
              let agent = shownAgent,
              let controller = activeController,
              controller.status == .live
        else {
            replaceHelper(with: nil)
            return
        }
        let commandConfiguration = store.agentCommandConfiguration(for: activeTab.hostID)
        let configuration = AgentHelperStripConfiguration(
            agent: agent,
            canShowCommands: entitlements.isPro || entitlements.canUseSlashChip,
            builtInPlacements: commandConfiguration.builtInPlacements(for: agent),
            customCommands: commandConfiguration.commands(for: agent),
            historyController: controller,
            historyLocked: !entitlements.canBrowseAgentHistory,
            floating: {
                #if os(visionOS)
                true
                #else
                false
                #endif
            }(),
            floatingMaximumWidth: {
                #if os(visionOS)
                visionFloatingHelperMaximumWidth
                #else
                nil
                #endif
            }(),
            contentSafeArea: {
                #if os(visionOS)
                .zero
                #else
                contentSafeArea
                #endif
            }(),
            send: { [weak self, weak controller] command in
                guard let self, let controller else { return }
                send(command, via: controller)
            },
            saveCommandConfiguration: { [weak self] commands, placements in
                self?.store.replaceAgentCommandConfiguration(
                    commands,
                    builtInPlacements: placements,
                    for: agent,
                    hostID: activeTab.hostID
                )
            },
            openPaywall: { [weak self] in self?.presentPaywall() },
            isFocusOwner: { [weak controller] in
                guard let terminalView = controller?.terminalView else { return false }
                return TerminalFocusArbiter.current === terminalView
            }
        )
        if let helperController,
           Self.canReuseAgentHelper(
               currentHostID: helperHostID,
               nextHostID: activeTab.hostID
           ) {
            helperController.update(configuration: configuration)
        } else {
            replaceHelper(with: AgentHelperStripViewController(configuration: configuration))
            helperHostID = activeTab.hostID
        }
    }

    static func canReuseAgentHelper(
        currentHostID: UUID?,
        nextHostID: UUID
    ) -> Bool {
        currentHostID == nextHostID
    }

    private func replaceHelper(with replacement: AgentHelperStripViewController?) {
        guard helperController !== replacement else { return }
        if let helperController {
            helperController.prepareForRemoval()
            #if os(visionOS)
            if shell != nil { unmount(helperController) }
            #else
            unmount(helperController)
            #endif
        }
        helperController = replacement
        helperHostID = nil
        guard let replacement else { return }
        #if os(visionOS)
        guard shell != nil else { return }
        #endif
        addChild(replacement)
        rootView.helperContainer.addSubview(replacement.view)
        replacement.didMove(toParent: self)
    }

    /// The Talkback composer follows the active tab's draft: mounted while
    /// that tab's box is open (docked above the rail on iPad / iPhone, its
    /// own slab under the visionOS console), dropped when it closes or the
    /// active tab has no box. Opening folds the helper strip to its dot;
    /// closing unfolds it if this window folded it. Runs first in a render:
    /// the panes' bottom inset reads the height it measures.
    private func renderTalkback() {
        #if !os(visionOS)
        // Locking the keyboard closes every message box in this window: the
        // box exists to type, and the lock says "no keyboard". A box opened
        // while locked is the user's word that they want to type again —
        // the lock releases (without the terminal summon that would race the
        // field's own focus) before the box mounts.
        let locked = KeyboardLock.shared.isLocked
        if locked, !lastRenderedKeyboardLocked {
            for tab in route.tabs {
                workspace.controller(for: tab.id)?.setTalkbackOpen(false)
            }
        }
        lastRenderedKeyboardLocked = locked
        #endif
        guard talkbackOpen, let controller = activeController else {
            if let existing = talkbackController {
                // Hand the keyboard to the pane BEFORE the box goes, so it
                // changes hands instead of dropping and rising again.
                if existing.fieldHasKeyboard,
                   let terminal = existing.configuration.controller.terminalView {
                    TerminalFocusArbiter.resumeAfterPresentation(terminal)
                }
                existing.prepareForRemoval()
                // visionOS mounts the composer in the bottom ornament, never
                // in-window (the shell there is a test-only configuration).
                #if !os(visionOS)
                unmount(existing)
                #endif
                talkbackController = nil
                unfoldHelperAfterTalkback()
            }
            renderedTalkbackHeight = 0
            return
        }
        let configuration = TalkbackComposerConfiguration(
            controller: controller,
            presentation: TalkbackComposerPresentation(
                targetLabel: umdTitle,
                agent: shownAgent,
                agentState: activeTabAgentState,
                compactPreviews: UIDevice.current.userInterfaceIdiom == .phone,
                floating: {
                    #if os(visionOS)
                    shell == nil
                    #else
                    false
                    #endif
                }(),
                availableWidth: talkbackWidth,
                contentSafeArea: {
                    #if os(visionOS)
                    .zero
                    #else
                    contentSafeArea
                    #endif
                }()
            ),
            close: { [weak controller] in controller?.setTalkbackOpen(false) },
            focusTerminal: { [weak controller] in
                guard let terminal = controller?.terminalView else { return }
                TerminalFocusArbiter.claim(terminal)
            }
        )
        if let talkbackController {
            talkbackController.update(configuration: configuration)
        } else {
            #if !os(visionOS)
            if KeyboardLock.shared.isLocked, let terminal = controller.terminalView {
                TerminalFocusArbiter.unlock(terminal, summoning: false)
            }
            #endif
            let composer = TalkbackComposerViewController(configuration: configuration)
            composer.onContentSizeChange = { [weak self] in
                // Reported from the composer's own layout pass; re-inset the
                // pane on the next turn rather than inside that pass — with
                // the card and the pane moving together where it is docked.
                Task { @MainActor [weak self] in
                    #if os(visionOS)
                    self?.renderNow()
                    #else
                    self?.animateTalkbackGrowth()
                    #endif
                }
            }
            talkbackController = composer
            #if !os(visionOS)
            mountTalkback(composer)
            #endif
            foldHelperForTalkback()
        }
        #if os(visionOS)
        renderedTalkbackHeight = 0
        #else
        renderedTalkbackHeight = talkbackController?.fittingContentSize().height ?? 0
        #endif
    }

    #if !os(visionOS)
    private func mountTalkback(_ composer: TalkbackComposerViewController) {
        addChild(composer)
        rootView.talkbackContainer.addSubview(composer.view)
        composer.view.frame = rootView.talkbackContainer.bounds
        composer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        composer.didMove(toParent: self)
    }
    #endif

    /// The strip's chips are one tap away on the dot; the rows they cost are
    /// the pane's while a message is being written. Deferred a turn: the
    /// collapse posts app-wide and every window re-renders on it, and this
    /// runs inside a render.
    private func foldHelperForTalkback() {
        guard !AgentHelperStripCollapse.shared.isCollapsed else { return }
        talkbackFoldedHelper = true
        DispatchQueue.main.async {
            AgentHelperStripCollapse.shared.setCollapsed(true)
        }
    }

    private func unfoldHelperAfterTalkback() {
        guard talkbackFoldedHelper else { return }
        talkbackFoldedHelper = false
        // Only if the user left it folded meanwhile — an expanded strip is
        // their choice, not this window's to undo.
        guard AgentHelperStripCollapse.shared.isCollapsed else { return }
        DispatchQueue.main.async {
            AgentHelperStripCollapse.shared.setCollapsed(false)
        }
    }

    private func changeFont(by delta: CGFloat) {
        fontSize = min(32, max(9, fontSize + delta))
        renderNow()
    }

    private func showDeck() {
        if let shell {
            shell.showDeck()
        } else {
            sceneWindows.openDeck()
        }
    }
}

// MARK: - Layout and classic iPad navigation chrome

extension TerminalWindowViewController {
    #if os(visionOS)
    private func updateVisionOrnamentInstallation() {
        if shell == nil && !appLocked {
            visionOrnaments.install(on: self)
        } else {
            visionOrnaments.remove()
        }
    }

    private func updateVisionOrnaments(forceRevision: Bool = false) {
        guard shell == nil, !appLocked else { return }
        visionOrnaments.state.keyClusterContext.keyCommandPlan = keyCommandPlan
        let sidePanel = mountedSidePanelHostID.flatMap {
            sidePanelViewControllers[$0]
        }
        visionOrnaments.update(
            tabCount: route.tabs.count,
            isAuxiliary: activeTab?.isAuxiliaryPane == true,
            activeTerminalController: activeController,
            umdController: umdController,
            helperController: helperController,
            talkbackController: talkbackController,
            sidePanelController: sidePanel,
            windowWidth: rootView.bounds.width,
            windowHeight: rootView.bounds.height,
            interfaceStyle: themes.appearance.interfaceStyle,
            forceRevision: forceRevision
        )
    }

    private var visionFloatingHelperMaximumWidth: CGFloat {
        if let shell {
            return max(1, shell.availableWidth - 24)
        }
        return min(
            AgentHelperStripViewController.maximumFloatingWidth,
            max(
                1,
                rootView.bounds.width
                    - AgentHelperStripViewController.floatingEdgeClearance * 2
            )
        )
    }

    private func refreshVisionHelperWidthIfNeeded() {
        guard let helperController,
              helperController.configuration.floatingMaximumWidth
                != visionFloatingHelperMaximumWidth
        else { return }
        renderHelper()
    }

    /// A route never changes classic/shell ownership in production on
    /// visionOS, but keeping the transfer exact makes controller updates and
    /// focused tests safe. A dismantling ornament may still hold a stale
    /// reference; its host only detaches children it still owns.
    private func reconcileVisionChromeOwnership() {
        guard shell != nil else {
            updateVisionShellKeyCluster()
            return
        }
        mountVisionShellChrome(umdController, in: rootView.umdContainer)
        mountVisionShellChrome(helperController, in: rootView.helperContainer)
        updateVisionShellKeyCluster()
    }

    private func updateVisionShellKeyCluster() {
        let visible = shell != nil
            && !appLocked
            && activeTab?.isAuxiliaryPane != true
        guard visible else {
            visionShellKeyCluster.update(controller: nil)
            visionShellKeyCluster.removeFromSuperview()
            return
        }
        if visionShellKeyCluster.superview !== rootView {
            visionShellKeyCluster.removeFromSuperview()
            rootView.addSubview(visionShellKeyCluster)
        }
        visionShellKeyContext.keyCommandPlan = keyCommandPlan
        visionShellKeyCluster.update(controller: activeController)
        visionShellKeyCluster.isHidden = false
    }

    private func mountVisionShellChrome(
        _ controller: UIViewController?,
        in container: UIView
    ) {
        guard let controller else { return }
        if controller.parent !== self {
            if controller.parent != nil {
                controller.willMove(toParent: nil)
                controller.view.removeFromSuperview()
                controller.removeFromParent()
            }
            addChild(controller)
            container.addSubview(controller.view)
            controller.didMove(toParent: self)
        } else if controller.view.superview !== container {
            controller.view.removeFromSuperview()
            container.addSubview(controller.view)
        }
        controller.view.frame = container.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    var visionOrnamentPresentationForTesting: TerminalVisionOrnamentPresentation {
        visionOrnaments.state.presentation
    }

    var visionOrnamentTabStripForTesting: TerminalTabStripView {
        tabStrip
    }

    var visionOrnamentRevisionForTesting: Int {
        visionOrnaments.state.revision
    }

    var visionSidePanelControllerForTesting: SidePanelViewController? {
        visionOrnaments.state.sidePanelController
    }

    var visionSidePanelSizeForTesting: CGSize {
        visionOrnaments.state.sidePanelSize
    }

    var visionShellKeyClusterForTesting: TerminalKeyClusterGroupView {
        visionShellKeyCluster
    }
    #endif

    private func layoutNativeChrome() {
        guard isViewLoaded else { return }
        let bounds = rootView.bounds

        #if os(visionOS)
        if shell == nil {
            refreshVisionHelperWidthIfNeeded()
            rootView.paneContainer.frame = bounds
            rootView.sidePanelContainer.frame = .zero
            rootView.sidePanelContainer.isHidden = true
            rootView.tabScrollView.frame = .zero
            rootView.umdContainer.frame = .zero
            rootView.helperContainer.frame = .zero
            rootView.helperContainer.isHidden = true
            rootView.talkbackContainer.frame = .zero
            rootView.talkbackContainer.isHidden = true
            for pane in paneControllers.values {
                pane.view.frame = rootView.paneContainer.bounds
            }
            updateVisionOrnaments()
            return
        }
        #endif
        // Every stage now spends the bottom strip itself: the key rail is the
        // window's bottom edge and keeps its faces clear of the home/Stage
        // Manager region through its own chassis, so reserving the strip here
        // would only park a dead band under the row (the pane still learns
        // the fact through `railOwnsBottomSafeArea`, which is what keeps the
        // keyboard measurement honest).
        let contentBounds = TerminalWindowUIKitRootView.contentBounds(
            in: bounds,
            reservesBottomSafeArea: shell == nil && !railOwnsBottomSafeArea,
            safeAreaInsets: rootView.safeAreaInsets
        )
        #if !os(visionOS)
        // The classic rail's compact/wide choice and its measured height both
        // ride the width this pass just resolved. Re-render only when that
        // width actually moves — `renderUMD` allocates a configuration, and
        // layout runs far more often than the window resizes.
        if shell == nil {
            // One resolve per pass: the insets are a window→screen
            // conversion plus a status-bar query, and the width is derived
            // from them.
            let insets = umdSafeArea
            let geometry = ClassicRailGeometry(
                width: railWidth(clearing: insets),
                safeArea: insets
            )
            if renderedClassicRailGeometry != geometry {
                renderedClassicRailGeometry = geometry
                renderUMD()
            }
        }
        #endif
        let tabsFitting = tabStrip.fittingContentSize()
        let tabsHeight: CGFloat = route.tabs.count > 1
            ? tabsFitting.height
                + TerminalWindowUIKitRootView.tabRailVerticalInset * 2
            : 0
        let umdHeight: CGFloat = {
            guard let umdController else { return 0 }
            if let controller = umdController as? UMDBarViewController {
                return controller.fittingContentSize(
                    for: shell?.availableWidth ?? bounds.width
                ).height
            }
            return umdController.view.systemLayoutSizeFitting(
                CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }()

        if shell != nil {
            rootView.umdContainer.frame = CGRect(
                x: 0, y: 0, width: bounds.width, height: umdHeight
            )
            rootView.tabScrollView.frame = CGRect(
                x: 0, y: umdHeight, width: bounds.width, height: tabsHeight
            )
            rootView.paneContainer.frame = CGRect(
                x: 0,
                y: umdHeight + tabsHeight,
                width: contentBounds.width,
                height: max(0, contentBounds.height - umdHeight - tabsHeight)
            )
        } else {
            // The classic window's rail is app-owned chrome pinned to the
            // window's top edge: it spends the scene's top safe strip itself
            // (`contentSafeArea` hands that clearance to the bar's content),
            // so nothing below it needs to inset again. The previous system
            // navigation bar overlaid this band instead and cost 64 pt for a
            // 21 pt row — see `TerminalClassicRailInsets`.
            rootView.umdContainer.frame = CGRect(
                x: 0, y: 0, width: bounds.width, height: umdHeight
            )
            rootView.tabScrollView.frame = CGRect(
                x: 0, y: umdHeight, width: contentBounds.width, height: tabsHeight
            )
            rootView.paneContainer.frame = CGRect(
                x: 0,
                y: umdHeight + tabsHeight,
                width: contentBounds.width,
                height: max(0, contentBounds.height - umdHeight - tabsHeight)
            )
        }
        // One measurement per pass owns the rail's height, the strip's frame,
        // and the scroller's content size together, so they can never disagree
        // about how wide the tabs are.
        if tabStrip.superview === rootView.tabScrollView {
            let verticalInset = TerminalWindowUIKitRootView.tabRailVerticalInset
            tabStrip.frame = CGRect(
                x: TerminalWindowUIKitRootView.tabRailHorizontalInset,
                y: verticalInset,
                width: max(tabsFitting.width, 1),
                height: tabsFitting.height
            )
            rootView.tabScrollView.contentSize = CGSize(
                width: tabStrip.frame.maxX
                    + TerminalWindowUIKitRootView.tabRailHorizontalInset,
                height: tabsFitting.height + verticalInset * 2
            )
        }
        rootView.setBottomSafeAreaBackfill(
            frame: CGRect(
                x: contentBounds.minX,
                y: contentBounds.maxY,
                width: contentBounds.width,
                height: max(0, bounds.maxY - contentBounds.maxY)
            ),
            fill: TerminalWindowBottomSafeAreaFill.resolve(
                isClassic: shell == nil,
                activeTab: activeTab,
                hasActiveTerminalController: activeController != nil
            )
        )
        umdController?.view.frame = rootView.umdContainer.bounds

        // The pane's bottom chrome stacks upward from the key rail (lifted
        // with it over a docked keyboard): the Talkback card first, then the
        // helper strip — docked or its dot. One cursor places both.
        #if !os(visionOS)
        var chromeBottom = paneChromeBottom
        let composerHeight = renderedTalkbackHeight
        if let talkbackController, composerHeight > 0 {
            chromeBottom -= composerHeight
            rootView.talkbackContainer.frame = CGRect(
                x: 0,
                y: max(rootView.paneContainer.frame.minY, chromeBottom),
                width: bounds.width,
                height: composerHeight
            )
            talkbackController.view.frame = rootView.talkbackContainer.bounds
            rootView.talkbackContainer.isHidden = false
        } else {
            rootView.talkbackContainer.frame = .zero
            rootView.talkbackContainer.isHidden = true
        }
        #endif

        if let helperController {
            #if !os(visionOS)
            if AgentHelperStripCollapse.shared.isCollapsed {
                let dotSize = helperController.fittingContentSize()
                rootView.helperContainer.frame = CGRect(
                    x: rootView.paneContainer.frame.minX + 10 + contentSafeArea.left,
                    y: max(
                        rootView.paneContainer.frame.minY,
                        chromeBottom - dotSize.height - 8
                    ),
                    width: dotSize.width,
                    height: dotSize.height
                )
            } else {
                rootView.helperContainer.frame = CGRect(
                    x: 0,
                    y: max(
                        rootView.paneContainer.frame.minY,
                        chromeBottom - AgentHelperStripViewController.dockedHeight
                    ),
                    width: bounds.width,
                    height: AgentHelperStripViewController.dockedHeight
                )
            }
            #else
            if shell != nil,
               !appLocked,
               activeTab?.isAuxiliaryPane != true,
               visionShellKeyCluster.superview === rootView {
                let available = max(
                    1,
                    min(
                        shell?.availableWidth ?? rootView.paneContainer.bounds.width,
                        rootView.paneContainer.bounds.width
                    ) - 24
                )
                let keySize = visionShellKeyCluster.fittingSize(
                    maximumWidth: available
                )
                visionShellKeyCluster.frame = CGRect(
                    x: rootView.paneContainer.frame.midX - keySize.width / 2,
                    y: rootView.paneContainer.frame.maxY - 10 - keySize.height,
                    width: keySize.width,
                    height: keySize.height
                )
                let measured = helperController.fittingContentSize(
                    for: available
                )
                let helperSize = CGSize(
                    width: min(available, measured.width),
                    height: measured.height
                )
                // Collapsed, the dot parks at the pane's leading edge rather
                // than centering over the key cluster.
                let helperX = AgentHelperStripCollapse.shared.isCollapsed
                    ? rootView.paneContainer.frame.minX + 12
                    : rootView.paneContainer.frame.midX - helperSize.width / 2
                rootView.helperContainer.frame = CGRect(
                    x: helperX,
                    y: visionShellKeyCluster.frame.minY - 8 - helperSize.height,
                    width: helperSize.width,
                    height: helperSize.height
                )
            } else {
                rootView.helperContainer.frame = .zero
            }
            #endif
            helperController.view.frame = rootView.helperContainer.bounds
            rootView.helperContainer.isHidden = false
        } else {
            rootView.helperContainer.frame = .zero
            rootView.helperContainer.isHidden = true
        }
        #if os(visionOS)
        if shell != nil,
           !appLocked,
           activeTab?.isAuxiliaryPane != true,
           visionShellKeyCluster.superview === rootView,
           helperController == nil {
            let available = max(
                1,
                min(
                    shell?.availableWidth ?? rootView.paneContainer.bounds.width,
                    rootView.paneContainer.bounds.width
                ) - 24
            )
            let keySize = visionShellKeyCluster.fittingSize(
                maximumWidth: available
            )
            visionShellKeyCluster.frame = CGRect(
                x: rootView.paneContainer.frame.midX - keySize.width / 2,
                y: rootView.paneContainer.frame.maxY - 10 - keySize.height,
                width: keySize.width,
                height: keySize.height
            )
        } else if visionShellKeyCluster.superview == nil {
            visionShellKeyCluster.frame = .zero
        }
        #endif
        for pane in paneControllers.values {
            pane.view.frame = rootView.paneContainer.bounds
        }
        layoutInWindowSidePanel()
    }

    private func layoutInWindowSidePanel() {
        guard let hostTabID = mountedSidePanelHostID,
              let panel = sidePanelViewControllers[hostTabID],
              panel.parent === self
        else {
            rootView.sidePanelContainer.frame = .zero
            rootView.sidePanelContainer.isHidden = true
            return
        }

        // A pane that shrank below the overlay's floor (Stage Manager) moves
        // the panel into a tab instead.
        if let hostTab = route.tabs.first(where: { $0.id == hostTabID }),
           !admitsSidePanel(anchor: hostTab) {
            scheduleSidePanelConversion(hostTabID: hostTabID)
        }

        let pane = rootView.paneContainer.frame
        let width = resolvedSidePanelWidth()
        let bottom: CGFloat = {
            #if os(visionOS)
            pane.maxY - (workspace.controller(for: hostTabID)?.keyboardObstruction ?? 0)
            #else
            // `paneContainer` owns both screen and key rail. The authored
            // SIDECAR rectangle is the screen portion of that pane: use the
            // same obstruction-lifted rail seam as Talkback so the full-width
            // keys remain visible and interactive beneath the overlay.
            paneChromeBottom
            #endif
        }()
        let frame = SidePanelWidth.overlayContainerFrame(
            pane: pane,
            bottom: bottom,
            width: width,
            leadingOverhang: panel.leadingOverhang
        )
        rootView.sidePanelContainer.frame = frame
        rootView.sidePanelContainer.isHidden = frame.isEmpty
        panel.view.frame = rootView.sidePanelContainer.bounds
        panel.updateWidth(width)
    }

    private func scheduleSidePanelConversion(hostTabID: UUID) {
        guard sidePanelConversionScheduledFor != hostTabID else { return }
        sidePanelConversionScheduledFor = hostTabID
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if sidePanelConversionScheduledFor == hostTabID {
                    sidePanelConversionScheduledFor = nil
                }
            }
            guard workspace.sidePanel(for: hostTabID) != nil,
                  let hostTab = route.tabs.first(where: { $0.id == hostTabID }),
                  !admitsSidePanel(anchor: hostTab)
            else { return }
            splitSidePanelToTab(hostTabID: hostTabID)
        }
    }
}

// MARK: - Native presentations

extension TerminalWindowViewController {
    private func presentPendingFeatureIfPossible() {
        guard !appLocked,
              isViewLoaded,
              view.window != nil,
              presentedViewController == nil,
              passphrasePresenter.presentedViewController == nil,
              presentedFeatureController == nil,
              let controller = activeController
        else { return }

        if let link = controller.pendingLink {
            let featureID = "link:\(activeTab?.id.uuidString ?? ""):" + link.id
            guard featureID != presentedActivationID else { return }
            presentedActivationID = featureID
            let sheet = TerminalLinkSheetViewController(
                link: link,
                viewportOffer: { [weak self] link in
                    ViewportOffer.make(for: link, host: self?.activeTabHost)
                },
                onOpen: { [weak controller] in controller?.openConfirmedLink($0) },
                onCopy: { [weak controller] in controller?.copyConfirmedTarget($0) },
                onOpenViewport: { [weak self] in self?.openViewport($0) }
            )
            sheet.onDismiss = { [weak self, weak controller] in
                controller?.dismissPendingLink()
                self?.dismissPresentedFeature()
            }
            presentFeature(sheet)
            return
        }

        if let target = controller.pendingPath {
            let featureID = "path:\(activeTab?.id.uuidString ?? ""):" + target.id
            guard featureID != presentedActivationID else { return }
            presentedActivationID = featureID
            let sheet = TerminalFilePathSheetViewController(
                target: target,
                hostName: activeTabHost?.name ?? String(localized: "the host"),
                onView: { [weak self] in self?.openFileViewer(target: $0) },
                onCopy: { [weak controller] in controller?.copyConfirmedTarget($0) }
            )
            sheet.onDismiss = { [weak self, weak controller] in
                controller?.dismissPendingPath()
                self?.dismissPresentedFeature()
            }
            presentFeature(sheet)
        }
    }

    private func presentFeature(_ content: UIViewController) {
        let navigation = UINavigationController(rootViewController: content)
        navigation.navigationBar.prefersLargeTitles = false
        navigation.view.backgroundColor = GlassPrototype.sheetGround
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        navigation.presentationController?.delegate = self
        presentedFeatureController = navigation
        applyAppearanceToPresentedFeature()
        present(navigation, animated: true)
        navigation.presentationController?.delegate = self
    }

    /// The link and path sheets carry no appearance property of their own, so
    /// the stack they are hosted in wears the choice for them. `renderNow`
    /// re-runs this on every appearance change (the observation reads
    /// `themes.appearance`), which is what keeps an open sheet in step.
    private func applyAppearanceToPresentedFeature() {
        guard let presented = presentedFeatureController else { return }
        let style = themes.appearance.interfaceStyle
        guard presented.overrideUserInterfaceStyle != style else { return }
        presented.overrideUserInterfaceStyle = style
    }

    private func dismissPresentedFeature() {
        guard let presentedFeatureController else {
            presentedActivationID = nil
            restartObservation()
            return
        }
        presentedFeatureController.dismiss(animated: true) { [weak self] in
            self?.presentedFeatureController = nil
            self?.presentedActivationID = nil
            self?.restartObservation()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        activeController?.dismissPendingLink()
        activeController?.dismissPendingPath()
        presentedFeatureController = nil
        presentedActivationID = nil
        restartObservation()
    }

    private func presentPaywall() {
        guard !appLocked, presentedViewController == nil else { return }
        let paywall = ProPaywallViewController(entitlements: entitlements)
        paywall.followAppAppearance(themes)
        let navigation = UINavigationController(rootViewController: paywall)
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        paywall.onDone = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }

    /// The terminal window's road to the stats board: pre-drilled into this
    /// window's host, paywall for free users — the same gate the deck runs.
    private func presentConnectionStats() {
        guard !appLocked,
              presentedViewController == nil,
              ConnectionStatsCenter.shared.isCollecting,
              let activeTab
        else { return }
        guard entitlements.canViewConnectionStats else {
            presentPaywall()
            return
        }
        let sheet = ConnectionStatsViewController(
            store: store,
            focusedHostID: activeTab.hostID
        )
        sheet.followAppAppearance(themes)
        let navigation = UINavigationController(rootViewController: sheet)
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        navigation.preferredContentSize = ConnectionStatsViewController.preferredSheetSize
        if UIDevice.current.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .formSheet
        }
        sheet.onDone = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }

    private func presentKeychainTip() {
        guard !appLocked,
              presentedViewController == nil,
              let activeTab,
              let host = store.host(id: activeTab.hostID),
              let notice = activeTabKeychainNotice
        else { return }
        let guide = KeychainUnlockViewController(
            host: host,
            sessionNames: notice.sessionNames
        )
        guide.followAppAppearance(themes)
        let navigation = UINavigationController(rootViewController: guide)
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        guide.onDone = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }
}

// MARK: - DEBUG automation

#if DEBUG
extension TerminalWindowViewController {
    private func configureDebugObservers() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
            debugObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in Task { @MainActor in action() } })
        }
        observe(.multiplexDebugAgentChip) { [weak self] in self?.debugTapFirstSlashChip() }
        observe(.multiplexDebugNewTab) { [weak self] in self?.debugNewTab() }
        observe(.multiplexDebugHerdrTab) { [weak self] in self?.debugNewHerdrTab() }
        observe(.multiplexDebugMessageJump) { [weak self] in self?.debugJumpToOldestMessage() }
        observe(.multiplexDebugMessageJumpBack) { [weak self] in
            guard let self, ownsFocusedTerminal else { return }
            activeController?.finishHistoryJump()
        }
        observe(.multiplexDebugLink) { [weak self] in self?.debugActivateFirstLink() }
        observe(.multiplexDebugLinkOpen) { [weak self] in
            guard let self, ownsFocusedTerminal else { return }
            activeController?.openPendingLink()
        }
        observe(.multiplexDebugViewportOpen) { [weak self] in
            self?.debugOpenViewportForPendingLink()
        }
        observe(.multiplexDebugFileViewer) { [weak self] in self?.debugOpenFileViewer() }
        observe(.multiplexDebugPathView) { [weak self] in self?.debugViewPendingPath() }
        observe(.multiplexDebugSidePanelSplit) { [weak self] in
            self?.debugSplitSidePanel()
        }
        observe(.multiplexDebugSidePanelClose) { [weak self] in
            self?.debugCloseSidePanel()
        }
        observe(.multiplexDebugSidePanelWidth) { [weak self] in
            self?.debugCycleSidePanelWidth()
        }
        observe(.multiplexDebugFileViewerRepoDiff) { [weak self] in
            guard let self,
                  let activeTab,
                  activeTab.isFileViewer,
                  let fileViewer = workspace.fileViewerController(for: activeTab.id)
            else { return }
            Task { await fileViewer.showRepoDiff() }
        }
        observe(.multiplexDebugLinkRegions) { [weak self] in self?.debugLogLinkRegions() }
        // Talkback: the talk key for the focused terminal (the composer's
        // own type/send hooks install with the composer).
        TalkbackDebugHook.install()
        observe(.multiplexDebugTalkbackToggle) { [weak self] in
            guard let self, ownsFocusedTerminal else { return }
            activeController?.toggleTalkback()
        }
    }

    private var ownsFocusedTerminal: Bool {
        guard let view = activeController?.terminalView else { return false }
        return TerminalFocusArbiter.current === view
    }

    private func debugTapFirstSlashChip() {
        guard ownsFocusedTerminal,
              let controller = activeController,
              let activeTab,
              let agent = shownAgent,
              entitlements.isPro || entitlements.canUseSlashChip,
              controller.status == .live,
              let command = AgentCommandSet.commands(
                in: .bar,
                for: agent,
                placementOverrides: store.agentCommandConfiguration(
                    for: activeTab.hostID
                ).builtInPlacements(for: agent)
              ).first(where: { $0.label.hasPrefix("/") })
        else { return }
        send(command, via: controller)
    }

    private func debugActivateFirstLink() {
        guard ownsFocusedTerminal, let view = activeController?.terminalView else { return }
        let terminal = view.getTerminal()
        for row in 0..<terminal.rows {
            var col = 0
            while col < terminal.cols {
                // Same seam-carrying lookup the long-press route uses, so
                // this hook proves the wrapped-glue cut headlessly too.
                guard let result = terminal.linkWithRowTexts(
                    at: .screen(Position(col: col, row: row)),
                    mode: .explicitAndImplicit
                ) else {
                    col += 1
                    continue
                }
                if activeController?.activateLink(
                    result.text, rowFragments: result.rowTexts
                ) == true { return }
                // A declined match must not stall the scan on its own
                // cells — step past the whole match's worth of columns
                // rather than re-resolving each one.
                col += max(1, result.text.count)
            }
        }
    }

    private func debugNewTab() {
        guard ownsFocusedTerminal else { return }
        openNewTab(launching: nil)
    }

    private func debugNewHerdrTab() {
        guard ownsFocusedTerminal else { return }
        openNewHerdrWorkspaceTab()
    }

    private func debugOpenViewportForPendingLink() {
        guard ownsFocusedTerminal,
              let controller = activeController,
              let link = controller.pendingLink,
              let offer = ViewportOffer.make(for: link, host: activeTabHost)
        else { return }
        controller.dismissPendingLink()
        openViewport(offer)
        // The chip's own road ends with the sheet going away; the model
        // clear above leaves the presented sheet standing otherwise.
        dismissPresentedFeature()
    }

    private func debugOpenFileViewer() {
        guard ownsFocusedTerminal else { return }
        openFileViewer(target: nil, allowsPanel: false)
    }

    private func debugViewPendingPath() {
        guard ownsFocusedTerminal,
              let controller = activeController,
              let target = controller.pendingPath
        else { return }
        controller.dismissPendingPath()
        openFileViewer(target: target)
        dismissPresentedFeature()
    }

    /// The active terminal's open panel, while this window owns the focused
    /// terminal — what the DEBUG panel hooks act on.
    private var debugSidePanelHostTabID: UUID? {
        guard ownsFocusedTerminal,
              let hostTabID = activeTab?.id,
              workspace.sidePanel(for: hostTabID) != nil
        else { return nil }
        return hostTabID
    }

    private func debugSplitSidePanel() {
        guard let hostTabID = debugSidePanelHostTabID else { return }
        splitSidePanelToTab(hostTabID: hostTabID)
    }

    private func debugCloseSidePanel() {
        guard let hostTabID = debugSidePanelHostTabID else { return }
        closeSidePanel(hostTabID: hostTabID)
    }

    private func debugCycleSidePanelWidth() {
        guard debugSidePanelHostTabID != nil, let platform = sidePanelPlatform else { return }
        let store = SidePanelWidthStore.shared
        switch platform {
        case .iPad:
            store.setWidth(store.width(for: .iPad) < 460 ? 560 : 360, for: .iPad)
        case .visionOS:
            let width = store.width(for: .visionOS)
            let next = SidePanelWidth.visionWidthCycle.first { $0 > width }
                ?? SidePanelWidth.visionWidthCycle[0]
            store.setWidth(next, for: .visionOS)
        }
        transientSidePanelWidth = nil
        renderNow()
    }

    private func debugLogLinkRegions() {
        guard ownsFocusedTerminal, let view = activeController?.terminalView else { return }
        let logger = Logger(
            subsystem: "app.multiplexterm.multiplex",
            category: "links"
        )
        let regions = view.visibleLinkRegions()
            .filter { TerminalLink.resolve($0.target) != nil }
        logger.debug("link-regions count=\(regions.count, privacy: .public)")
        for region in regions {
            logger.debug(
                "link-region target=\(region.target, privacy: .public) rects=\(String(describing: region.rects), privacy: .public)"
            )
        }
    }

    private func debugJumpToOldestMessage() {
        guard ownsFocusedTerminal,
              let controller = activeController,
              let agent = shownAgent
        else { return }
        Task {
            controller.openAgentHistory(for: agent)
            for _ in 0..<60 {
                if case .loaded = controller.agentHistory { break }
                if case .unavailable = controller.agentHistory { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard case .loaded(_, let messages, true) = controller.agentHistory,
                  let oldest = messages.first(where: \.reachable)
            else { return }
            controller.startHistoryJump(to: oldest)
            controller.closeAgentHistory()
        }
    }
}
#endif

/// The tab rail's scroller. A `UIScrollView` delays content touches by 150 ms
/// and discards them outright if the finger drifts during that window, so once
/// the tabs overflow the rail a perfectly ordinary press never reached the
/// cell — the "tabs feel dead" report. Track immediately instead, and let a
/// genuine pre-lift drag that starts on a cell still scroll the strip. Keep
/// that cancellation explicit so the cell's tap/context/drag interactions do
/// not pin an overflowing strip in place under an ordinary swipe.
@MainActor
final class TerminalTabScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is TerminalTabCell { return true }
        return super.touchesShouldCancel(in: view)
    }
}

@MainActor
final class TerminalWindowUIKitRootView: UIView {
    static let tabRailHorizontalInset: CGFloat = 12
    static let tabRailVerticalInset: CGFloat = 6

    let paneContainer = UIView()
    /// iPad/Shell SIDECAR mount: a sibling over the pane, deliberately not
    /// part of its layout or SwiftTerm's size proposal.
    let sidePanelContainer = UIView()
    let tabScrollView = TerminalTabScrollView()
    let umdContainer = UIView()
    let helperContainer = UIView()
    /// The Talkback card's band on iPad / iPhone (and the visionOS shell):
    /// docked between the pane's chrome and its key rail.
    let talkbackContainer = UIView()
    private let bottomSafeAreaBackfill = UIView()
    private let tabDivider = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // PROTOTYPE(GLASS): the scene root's glass shell carries the
        // window's smoke; chrome goes clear over it, and the terminal
        // surface itself carries the screen pane (theme-tinted) — a pane
        // ground here would double-tint it. Geometry is untouched: the
        // 24pt bordered silhouette and compact gutter are the shipping
        // ones (user direction 2026-08-02).
        backgroundColor = GlassPrototype.enabled
            ? GlassPrototype.clearedChassis : UIKitChassis.chassis
        paneContainer.backgroundColor =
            GlassPrototype.enabled ? GlassPrototype.clearedScreen : UIKitChassis.screen
        tabScrollView.backgroundColor =
            GlassPrototype.enabled ? GlassPrototype.clearedChassis : UIKitChassis.chassis
        tabScrollView.showsHorizontalScrollIndicator = false
        tabDivider.backgroundColor = UIKitChassis.bezelHi
        umdContainer.backgroundColor = .clear
        helperContainer.backgroundColor = .clear
        sidePanelContainer.backgroundColor = .clear
        sidePanelContainer.clipsToBounds = false
        sidePanelContainer.isHidden = true
        talkbackContainer.backgroundColor = .clear
        talkbackContainer.clipsToBounds = true
        bottomSafeAreaBackfill.backgroundColor = UIKitChassis.bezel
        bottomSafeAreaBackfill.isUserInteractionEnabled = false
        bottomSafeAreaBackfill.isAccessibilityElement = false
        bottomSafeAreaBackfill.accessibilityIdentifier =
            "terminalWindow.bottomSafeAreaBackfill"

        addSubview(paneContainer)
        addSubview(tabScrollView)
        addSubview(tabDivider)
        addSubview(umdContainer)
        addSubview(sidePanelContainer)
        addSubview(talkbackContainer)
        addSubview(helperContainer)
        addSubview(bottomSafeAreaBackfill)
        paneContainer.accessibilityIdentifier = "terminalWindow.panes"
        sidePanelContainer.accessibilityIdentifier = "terminalWindow.sidePanel"
        tabScrollView.accessibilityIdentifier = "terminalWindow.tabs"
        umdContainer.accessibilityIdentifier = "terminalWindow.umd"
        helperContainer.accessibilityIdentifier = "terminalWindow.helpers"
        talkbackContainer.accessibilityIdentifier = "terminalWindow.talkback"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        tabDivider.frame = CGRect(
            x: tabScrollView.frame.minX,
            y: max(tabScrollView.frame.minY, tabScrollView.frame.maxY - 1),
            width: tabScrollView.frame.width,
            height: tabScrollView.isHidden ? 0 : 1
        )
    }

    func setTabsVisible(_ visible: Bool) {
        tabScrollView.isHidden = !visible
        tabDivider.isHidden = !visible
    }

    static func contentBounds(
        in bounds: CGRect,
        reservesBottomSafeArea: Bool,
        safeAreaInsets: UIEdgeInsets
    ) -> CGRect {
        guard reservesBottomSafeArea else { return bounds }
        var result = bounds
        result.size.height = max(0, bounds.height - safeAreaInsets.bottom)
        return result
    }

    func setBottomSafeAreaBackfill(
        frame: CGRect,
        fill: TerminalWindowBottomSafeAreaFill
    ) {
        bottomSafeAreaBackfill.frame = frame
        bottomSafeAreaBackfill.backgroundColor = fill.color
        bottomSafeAreaBackfill.isHidden = frame.height <= 0
        bringSubviewToFront(bottomSafeAreaBackfill)
    }

    func setShellMode(_ shell: Bool) {
        layer.cornerRadius = shell ? 0 : {
            #if os(visionOS)
            24
            #else
            0
            #endif
        }()
        clipsToBounds = true
        layer.borderWidth = shell ? 0 : {
            #if os(visionOS)
            1
            #else
            0
            #endif
        }()
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
    }
}
