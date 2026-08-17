import Observation
import UIKit
#if DEBUG
import notify

extension Notification.Name {
    static let multiplexDebugConnectionStats =
        Notification.Name("multiplex.debug.connstats")
}

/// Headless-verification hook: no tap route exists on the visionOS sim
/// (simctl has none; idb died under Xcode 27), so
/// `xcrun simctl spawn <udid> notifyutil -p app.multiplexterm.multiplex.debug.connstats`
/// opens the Connection Stats board through the exact request the deck's
/// STATS chip makes — gates included. Process-level installer with a latch,
/// like every other notify hook, so scene churn can never double-register.
@MainActor
enum ConnectionStatsDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.connstats", &token, .main
        ) { _ in
            NotificationCenter.default.post(
                name: .multiplexDebugConnectionStats, object: nil
            )
        }
    }
}
#endif

/// Tracks the live deck window's scene plus one-shot state that must not
/// repeat per window. The data-driven scene identity prevents new duplicates;
/// this registry removes any second deck restored from legacy or raced
/// relaunch state.
@MainActor
enum DeckScene {
    private static var sessions = SingletonSceneRegistry<UISceneSession, String>()
    static var autoAttachFired = false

    static func register(_ newSession: UISceneSession) {
        guard sessions.register(
            newSession,
            id: newSession.persistentIdentifier
        ) == .duplicate else { return }

        UIApplication.shared.requestSceneSessionDestruction(
            newSession,
            options: nil
        )
    }

    #if DEBUG
    /// Launch automation is shared by deck and terminal roots. iPadOS may
    /// restore a terminal scene without constructing the deck, so keeping
    /// this only on `DeckWindowViewController` makes real-device verification
    /// silently skip its requested attach.
    static func autoAttachIfRequested(
        store: HostStore,
        workspace: TerminalWorkspace,
        openTerminalWindow: (TerminalWindowRoute) -> Void
    ) async {
        guard !autoAttachFired,
              let list = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_ATTACH"],
              !list.isEmpty else { return }
        autoAttachFired = true
        try? await Task.sleep(for: .seconds(5))
        let host: Host?
        if let name = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_ATTACH_HOST"] {
            host = store.hosts.first(where: { $0.name == name })
        } else {
            host = store.hosts.first
        }
        guard let host else { return }
        var firstTabID: UUID?
        for entry in list.split(separator: ",") {
            let tabs = entry.split(separator: "+").map { name in
                TerminalRoute(
                    hostID: host.id,
                    mode: .attach(host: host, sessionName: String(name))
                )
            }
            guard !tabs.isEmpty else { continue }
            if firstTabID == nil { firstTabID = tabs.first?.id }
            openTerminalWindow(TerminalWindowRoute(tabs: tabs))
            try? await Task.sleep(for: .seconds(1))
        }
        if ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_TMUX_COPY"] == "1",
           let tabID = firstTabID {
            for _ in 0..<100 {
                if workspace.controller(for: tabID)?
                    .debugSendTmuxShortcutThroughTerminal(.copyMode) == true {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if let closeTarget = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_TMUX_CLOSE"],
           let shortcut: TmuxShortcut = switch closeTarget {
           case "pane": .closePane
           case "window": .closeWindow
           default: nil
           },
           let tabID = firstTabID {
            for _ in 0..<100 {
                if let controller = workspace.controller(for: tabID),
                   controller.status == .live {
                    controller.performTmuxShortcut(shortcut)
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_MERGE"] == "1" {
            try? await Task.sleep(for: .seconds(8))
            workspace.mergeAllWindows()
        }
        if let dropPath = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_DROP"],
           let tabID = firstTabID {
            try? await Task.sleep(for: .seconds(8))
            if let controller = workspace.controller(for: tabID),
               let data = FileManager.default.contents(atPath: dropPath) {
                controller.deliverDrop([DroppedFile(
                    name: (dropPath as NSString).lastPathComponent,
                    data: data
                )])
            }
        }
    }
    #endif
}

// MARK: - Native configuration

/// The side effects whose lifetime used to be implicit in SwiftUI `.task`
/// modifiers. Keeping them behind one native driver makes ownership explicit
/// and gives lifecycle tests a deterministic seam that never opens sockets,
/// touches Keychain, or starts StoreKit work.
@MainActor
struct DeckWindowLifecycleDriver {
    var attachBind: () -> Void
    var rotatePendingBindKeys: () async -> Void
    var refreshHostsFromCloud: () async -> Void
    var publishWidgetState: ([Host], [UUID: SessionKey]) -> Void
    var checkLocalNetwork: ([Host]) -> Void
    var suspendLocalNetwork: () -> Void
    var beginNetworkChanges: () -> Void
    var suspendNetworkChanges: () -> Void
    var reconnectAfterNetworkChange: () -> Void
    var beginBindDiscovery: () -> Void
    var endBindDiscovery: () -> Void
    var flushSnapshots: () -> Void

    static func live(
        store: HostStore,
        entitlements: EntitlementStore,
        hub: ConnectionHub,
        localNetworkAccess: LocalNetworkAccessMonitor,
        networkChanges: NetworkChangeMonitor,
        bind: BindController
    ) -> Self {
        Self(
            attachBind: { bind.attach(store: store, entitlements: entitlements) },
            rotatePendingBindKeys: { await bind.rotatePendingKeysIfNeeded() },
            refreshHostsFromCloud: { await store.refreshFromCloud() },
            publishWidgetState: { hub.publishWidgetState(hosts: $0, recentSessions: $1) },
            checkLocalNetwork: { localNetworkAccess.check(hosts: $0) },
            suspendLocalNetwork: { localNetworkAccess.suspend() },
            beginNetworkChanges: { networkChanges.begin() },
            suspendNetworkChanges: { networkChanges.suspend() },
            reconnectAfterNetworkChange: { hub.reconnectAfterNetworkChange() },
            beginBindDiscovery: { bind.beginDiscovery() },
            endBindDiscovery: { bind.endDiscovery() },
            flushSnapshots: { hub.flushSnapshots() }
        )
    }
}

/// Complete native dependency/value snapshot for one deck owner. It contains
/// no SwiftUI-only environment actions or scene-phase types, so UISceneDelegate
/// and the native single-window shell can construct it directly.
@MainActor
struct DeckWindowConfiguration {
    let store: HostStore
    let entitlements: EntitlementStore
    let hub: ConnectionHub
    let workspace: TerminalWorkspace
    let localNetworkAccess: LocalNetworkAccessMonitor
    let networkChanges: NetworkChangeMonitor
    let bind: BindController
    let themes: ThemeStore
    let attention: AttentionCenter
    let appLock: AppLockStore
    let externalActions: ExternalActionRouter
    let sceneWindows: SceneWindowRouting
    var openURL: (URL) -> Void
    var terminalOpener: TerminalRouteOpener
    var presentation: FleetWall.Presentation = .standard
    var selectedTerminal: TerminalRoute?
    var shellSafeArea = UIEdgeInsets.zero
    var sceneIsActive: Bool
    var reduceMotion: Bool
    var lifecycleDriver: DeckWindowLifecycleDriver

    init(
        store: HostStore,
        entitlements: EntitlementStore,
        hub: ConnectionHub,
        workspace: TerminalWorkspace,
        localNetworkAccess: LocalNetworkAccessMonitor,
        networkChanges: NetworkChangeMonitor,
        bind: BindController,
        themes: ThemeStore,
        attention: AttentionCenter,
        appLock: AppLockStore,
        externalActions: ExternalActionRouter,
        sceneWindows: SceneWindowRouting,
        openURL: @escaping (URL) -> Void,
        terminalOpener: TerminalRouteOpener,
        presentation: FleetWall.Presentation = .standard,
        selectedTerminal: TerminalRoute? = nil,
        shellSafeArea: UIEdgeInsets = .zero,
        sceneIsActive: Bool,
        reduceMotion: Bool,
        lifecycleDriver: DeckWindowLifecycleDriver? = nil
    ) {
        self.store = store
        self.entitlements = entitlements
        self.hub = hub
        self.workspace = workspace
        self.localNetworkAccess = localNetworkAccess
        self.networkChanges = networkChanges
        self.bind = bind
        self.themes = themes
        self.attention = attention
        self.appLock = appLock
        self.externalActions = externalActions
        self.sceneWindows = sceneWindows
        self.openURL = openURL
        self.terminalOpener = terminalOpener
        self.presentation = presentation
        self.selectedTerminal = selectedTerminal
        self.shellSafeArea = shellSafeArea
        self.sceneIsActive = sceneIsActive
        self.reduceMotion = reduceMotion
        self.lifecycleDriver = lifecycleDriver ?? .live(
            store: store,
            entitlements: entitlements,
            hub: hub,
            localNetworkAccess: localNetworkAccess,
            networkChanges: networkChanges,
            bind: bind
        )
    }
}

// MARK: - Native deck owner

@MainActor
final class DeckWindowViewController: UIViewController {
    enum PresentationKind: Equatable {
        case addHost
        case editHost(UUID)
        case settings
        case faq
        case whatsNew
        case releaseLog
        case paywall
        case connectionStats(UUID?)
        case localNetworkAlert
    }

    private enum PresentationRequest: Equatable {
        case addHost
        case editHost(Host)
        case settings
        case faq
        case whatsNew
        case releaseLog
        case paywall
        case connectionStats(Host?)
        case localNetworkAlert

        var kind: PresentationKind {
            switch self {
            case .addHost: .addHost
            case .editHost(let host): .editHost(host.id)
            case .settings: .settings
            case .faq: .faq
            case .whatsNew: .whatsNew
            case .releaseLog: .releaseLog
            case .paywall: .paywall
            case .connectionStats(let host): .connectionStats(host?.id)
            case .localNetworkAlert: .localNetworkAlert
            }
        }
    }

    private struct ObservedState: Equatable {
        let hosts: [Host]
        let recentSessions: [UUID: SessionKey]
        let wantsBindSurface: Bool
        let bindSurfaceOpen: Bool
        let enrollmentInFlight: Bool
        let reconnectRevision: Int
        let denialRevision: Int
        let localNetworkDenied: Bool
    }

    private struct LocalNetworkCheckIdentity: Equatable {
        let hosts: [Host]
        let active: Bool
    }

    private struct BindBrowseIdentity: Equatable {
        let surface: Bool
        let inFlight: Bool
        let active: Bool

        var wantsBrowsing: Bool { active && (surface || inFlight) }
    }

    private var configuration: DeckWindowConfiguration
    private(set) lazy var wallController = FleetWallContainerViewController(
        configuration: makeWallConfiguration()
    )
    private let presentationDelegate = DeckWindowPresentationDelegate()
    private weak var ownedPresentation: UIViewController?
    private weak var activeAddHostController: AddHostViewController?
    private var pendingPresentations: [PresentationRequest] = []
    private(set) var activePresentationKind: PresentationKind?
    private(set) var lifecycleStarted = false
    private var lifecycleStopped = false
    private var appLocked = false
    private var deferredPresentationSupersession = false
    private var observationGeneration = 0
    private var latestObservedState: ObservedState?
    private var lastPublishedWidgetInput: (hosts: [Host], recentSessions: [UUID: SessionKey])?
    private var localNetworkCheckIdentity: LocalNetworkCheckIdentity?
    private var bindBrowseIdentity: BindBrowseIdentity?
    private var networkMonitorActive: Bool?
    private var lastReconnectRevision: Int?
    private var lastDenialRevision: Int?
    private var lastSceneActive: Bool?
    private var lifecycleTasks: [Task<Void, Never>] = []
    private var cloudRefreshTask: Task<Void, Never>?
    private var externalActionCoordinator: ExternalActionUIKitCoordinator?
    private var releaseNotesChecked = false
    /// Device-local, so each device is owed the notes on its own update. Tests
    /// substitute a scratch `UserDefaults` suite.
    var releaseNotesStore = ReleaseNotesStore()
    #if DEBUG
    private var debugAutomationStarted = false
    #endif

    var pendingPresentationKinds: [PresentationKind] {
        pendingPresentations.map(\.kind)
    }

    /// The adaptive shell owns the external-action coordinator, so a nested
    /// deck builds none of its own (its opener destination is `.shell`). Its
    /// sheets still occupy the shell's presenter, so the owner hears every
    /// deck dismissal here and drains the queue the classic path drains
    /// through `externalActionCoordinator` in `finishPresentation`.
    var presentationDidEnd: (() -> Void)?

    var sceneIsActive: Bool { configuration.sceneIsActive }
    var isPreparedForRemoval: Bool { lifecycleStopped }

    init(configuration: DeckWindowConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        presentationDelegate.owner = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let root = DeckSceneRegistrationView()
        // PROTOTYPE(GLASS): the scene root paints the smoke; this layer clears.
        root.backgroundColor =
            GlassPrototype.enabled ? GlassPrototype.clearedChassis : UIKitChassis.chassis
        root.sceneConnected = { [weak self] session in
            DeckScene.register(session)
            self?.externalActionCoordinator?.presenterDidBecomeAvailable()
            self?.presentNextIfPossible()
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installWall()
        #if DEBUG
        ConnectionStatsDebugHook.install()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(debugOpenConnectionStats),
            name: .multiplexDebugConnectionStats,
            object: nil
        )
        #endif
    }

    #if DEBUG
    @objc private func debugOpenConnectionStats() {
        // Focus the FIRST host so the drill-in cluster is provable
        // headlessly too — the fleet level renders around it either way,
        // and strips can't be tapped from the CLI.
        requestConnectionStats(focusing: configuration.store.hosts.first)
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let session = view.window?.windowScene?.session {
            DeckScene.register(session)
        }
        startLifecycleIfNeeded()
        presentReleaseNotesIfDue()
        presentNextIfPossible()
        externalActionCoordinator?.presenterDidBecomeAvailable()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The shell's deck pane can be on screen at zero width; this is where
        // it becomes presentable again after the terminal collapses.
        presentReleaseNotesIfDue()
    }

    deinit {
        lifecycleTasks.forEach { $0.cancel() }
        cloudRefreshTask?.cancel()
    }

    /// One update seam for classic scenes and the adaptive shell. Dependency
    /// references are expected to remain app-lifetime stable, but replacing
    /// them still re-arms Observation and the wall coherently.
    func update(configuration: DeckWindowConfiguration) {
        let previousConfiguration = self.configuration
        let dependenciesChanged = self.configuration.store !== configuration.store
            || self.configuration.entitlements !== configuration.entitlements
            || self.configuration.hub !== configuration.hub
            || self.configuration.workspace !== configuration.workspace
            || self.configuration.localNetworkAccess !== configuration.localNetworkAccess
            || self.configuration.networkChanges !== configuration.networkChanges
            || self.configuration.bind !== configuration.bind
            || self.configuration.themes !== configuration.themes
            || self.configuration.attention !== configuration.attention
            || self.configuration.appLock !== configuration.appLock
            || self.configuration.externalActions !== configuration.externalActions
        let destinationChanged = self.configuration.terminalOpener.destination
            != configuration.terminalOpener.destination
        let activeChanged = self.configuration.sceneIsActive != configuration.sceneIsActive
        self.configuration = configuration

        if isViewLoaded {
            wallController.update(configuration: makeWallConfiguration())
        }
        guard lifecycleStarted, !lifecycleStopped else { return }
        if dependenciesChanged {
            restartLifecycleServices(previous: previousConfiguration)
        } else if activeChanged {
            sceneActivityChanged()
        }
        if destinationChanged || dependenciesChanged {
            configureExternalActionCoordinator(replacingExisting: true)
        }
    }

    func setSceneActive(_ active: Bool) {
        guard configuration.sceneIsActive != active else { return }
        var updated = configuration
        updated.sceneIsActive = active
        update(configuration: updated)
    }

    /// The scene-level shield preserves any presentation already on screen;
    /// new deck-owned or external-action UI waits underneath until unlock so
    /// no UIKit presentation can race above the privacy boundary.
    func setAppLocked(_ locked: Bool) {
        guard appLocked != locked else { return }
        appLocked = locked
        externalActionCoordinator?.setAppLocked(locked)
        if !locked {
            if deferredPresentationSupersession,
               activePresentationKind != nil {
                deferredPresentationSupersession = false
                dismissActivePresentation()
            } else {
                deferredPresentationSupersession = false
                presentNextIfPossible()
            }
            externalActionCoordinator?.presenterDidBecomeAvailable()
        }
    }

    /// Explicit teardown for UISceneDelegate/shell removal. It cancels every
    /// task and network watcher the old SwiftUI `.task` lifetimes owned.
    func prepareForRemoval() {
        guard !lifecycleStopped else { return }
        lifecycleStopped = true
        observationGeneration += 1
        lifecycleTasks.forEach { $0.cancel() }
        lifecycleTasks.removeAll()
        cloudRefreshTask?.cancel()
        cloudRefreshTask = nil
        configuration.lifecycleDriver.suspendLocalNetwork()
        configuration.lifecycleDriver.suspendNetworkChanges()
        configuration.lifecycleDriver.endBindDiscovery()
        configuration.lifecycleDriver.flushSnapshots()
        externalActionCoordinator?.detach()
        externalActionCoordinator = nil
        activeAddHostController?.prepareForRemoval()
        if let ownedPresentation, ownedPresentation.presentingViewController != nil {
            ownedPresentation.dismiss(animated: false)
        }
        self.ownedPresentation = nil
        activePresentationKind = nil
        pendingPresentations.removeAll()
        deferredPresentationSupersession = false
    }

    private func installWall() {
        addChild(wallController)
        view.addSubview(wallController.view)
        wallController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wallController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wallController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wallController.view.topAnchor.constraint(equalTo: view.topAnchor),
            wallController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        wallController.didMove(toParent: self)
    }

    private func makeWallConfiguration() -> FleetWallConfiguration {
        FleetWallConfiguration(
            store: configuration.store,
            hub: configuration.hub,
            networkChanges: configuration.networkChanges,
            workspace: configuration.workspace,
            themes: configuration.themes,
            terminalOpener: configuration.terminalOpener,
            presentation: configuration.presentation,
            selectedTerminal: configuration.selectedTerminal,
            shellSafeArea: configuration.shellSafeArea,
            reduceMotion: configuration.reduceMotion,
            sceneIsActive: configuration.sceneIsActive,
            addHost: { [weak self] in self?.requestAddHost() },
            editHost: { [weak self] host in self?.requestEditHost(host) },
            openSettings: { [weak self] in self?.requestSettings() },
            openFAQ: { [weak self] in self?.requestFAQ() },
            openStats: { [weak self] host in
                self?.requestConnectionStats(focusing: host)
            }
        )
    }

    // MARK: Lifecycle / Observation

    private func startLifecycleIfNeeded() {
        guard !lifecycleStarted else { return }
        lifecycleStarted = true
        lifecycleStopped = false
        lastSceneActive = configuration.sceneIsActive
        configuration.lifecycleDriver.attachBind()
        configureExternalActionCoordinator(replacingExisting: false)
        observeState()
        startInitialLifecycleTasks()
        #if DEBUG
        startDebugAutomationIfNeeded()
        #endif
    }

    private func startInitialLifecycleTasks() {
        lifecycleTasks.append(Task { [weak self] in
            guard let self else { return }
            await self.configuration.lifecycleDriver.rotatePendingBindKeys()
        })
        refreshHostsFromCloud()
    }

    /// Every foreground refreshes, and the scene reports one for each system
    /// alert, app-switcher peek, and Control Center pull. One replaceable
    /// handle keeps that from retaining a finished task per activation for
    /// the life of the deck.
    private func refreshHostsFromCloud() {
        cloudRefreshTask?.cancel()
        cloudRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.configuration.lifecycleDriver.refreshHostsFromCloud()
        }
    }

    private func restartLifecycleServices(previous: DeckWindowConfiguration) {
        previous.lifecycleDriver.suspendLocalNetwork()
        previous.lifecycleDriver.suspendNetworkChanges()
        previous.lifecycleDriver.endBindDiscovery()
        lifecycleTasks.forEach { $0.cancel() }
        lifecycleTasks.removeAll()

        resetLifecycleTracking()
        lastSceneActive = configuration.sceneIsActive
        configuration.lifecycleDriver.attachBind()
        observeState()
        startInitialLifecycleTasks()
    }

    private func resetLifecycleTracking() {
        lastPublishedWidgetInput = nil
        localNetworkCheckIdentity = nil
        bindBrowseIdentity = nil
        networkMonitorActive = nil
        lastReconnectRevision = nil
        lastDenialRevision = nil
    }

    private func observeState() {
        guard lifecycleStarted, !lifecycleStopped else { return }
        observationGeneration += 1
        let generation = observationGeneration
        let snapshot = withObservationTracking {
            ObservedState(
                hosts: configuration.store.hosts,
                recentSessions: configuration.store.recentSessions,
                wantsBindSurface: configuration.bind.wantsBindSurface,
                bindSurfaceOpen: configuration.bind.bindSurfaceOpen,
                enrollmentInFlight: configuration.bind.enrollmentInFlight,
                reconnectRevision: configuration.networkChanges.reconnectRevision,
                denialRevision: configuration.localNetworkAccess.denialRevision,
                localNetworkDenied: configuration.localNetworkAccess.isDenied
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.observationGeneration == generation,
                      !self.lifecycleStopped
                else { return }
                self.observeState()
            }
        }
        latestObservedState = snapshot
        process(snapshot)
    }

    private func process(_ state: ObservedState) {
        guard lifecycleStarted, !lifecycleStopped else { return }

        if lastPublishedWidgetInput?.hosts != state.hosts
            || lastPublishedWidgetInput?.recentSessions != state.recentSessions {
            lastPublishedWidgetInput = (state.hosts, state.recentSessions)
            configuration.lifecycleDriver.publishWidgetState(state.hosts, state.recentSessions)
        }

        let localIdentity = LocalNetworkCheckIdentity(
            hosts: state.hosts,
            active: configuration.sceneIsActive
        )
        if localNetworkCheckIdentity != localIdentity {
            localNetworkCheckIdentity = localIdentity
            if localIdentity.active {
                configuration.lifecycleDriver.checkLocalNetwork(
                    state.hosts.filter(\.isEnabled)
                )
            } else {
                configuration.lifecycleDriver.suspendLocalNetwork()
            }
        }

        let browseIdentity = BindBrowseIdentity(
            surface: state.bindSurfaceOpen,
            inFlight: state.enrollmentInFlight,
            active: configuration.sceneIsActive
        )
        if bindBrowseIdentity != browseIdentity {
            bindBrowseIdentity = browseIdentity
            if browseIdentity.wantsBrowsing {
                configuration.lifecycleDriver.beginBindDiscovery()
            } else {
                configuration.lifecycleDriver.endBindDiscovery()
            }
        }

        if networkMonitorActive != configuration.sceneIsActive {
            networkMonitorActive = configuration.sceneIsActive
            if configuration.sceneIsActive {
                configuration.lifecycleDriver.beginNetworkChanges()
            } else {
                configuration.lifecycleDriver.suspendNetworkChanges()
            }
        }

        if let lastReconnectRevision,
           lastReconnectRevision != state.reconnectRevision,
           configuration.sceneIsActive {
            configuration.lifecycleDriver.reconnectAfterNetworkChange()
        }
        lastReconnectRevision = state.reconnectRevision

        if let lastDenialRevision,
           lastDenialRevision != state.denialRevision,
           state.denialRevision > 0,
           configuration.sceneIsActive {
            requestPresentation(.localNetworkAlert)
        }
        lastDenialRevision = state.denialRevision
        if !state.localNetworkDenied {
            clearLocalNetworkPresentation()
        }

        if state.wantsBindSurface {
            presentBindSurfaceIfRequested()
        }
    }

    private func sceneActivityChanged() {
        let active = configuration.sceneIsActive
        defer { lastSceneActive = active }
        guard lastSceneActive != active else { return }
        if active {
            refreshHostsFromCloud()
        } else {
            configuration.lifecycleDriver.flushSnapshots()
        }
        if let latestObservedState { process(latestObservedState) }
    }

    private func configureExternalActionCoordinator(replacingExisting: Bool) {
        if replacingExisting {
            externalActionCoordinator?.detach()
            externalActionCoordinator = nil
        }
        guard externalActionCoordinator == nil,
              configuration.terminalOpener.destination == .window
        else { return }
        let coordinator = ExternalActionUIKitCoordinator(
            presenter: self,
            store: configuration.store,
            hub: configuration.hub,
            workspace: configuration.workspace,
            router: configuration.externalActions,
            themes: configuration.themes,
            terminalOpener: configuration.terminalOpener,
            sceneWindows: configuration.sceneWindows
        )
        coordinator.presentationDidEnd = { [weak self] in self?.presentNextIfPossible() }
        externalActionCoordinator = coordinator
        coordinator.setAppLocked(appLocked)
        coordinator.attach()
    }

    // MARK: Deck-owned presentations

    func requestAddHost() {
        if configuration.entitlements.canAddHost(
            existingHostCount: configuration.store.hosts.count
        ) {
            requestPresentation(.addHost)
        } else {
            requestPresentation(.paywall)
        }
    }

    func requestEditHost(_ host: Host) {
        requestPresentation(.editHost(host))
    }

    func requestSettings() {
        requestPresentation(.settings)
    }

    func requestFAQ() {
        requestPresentation(.faq)
    }

    func requestReleaseLog() {
        requestPresentation(.releaseLog)
    }

    /// The Connection Stats board. The chip and every other entry are hidden
    /// while the setting is off, so the guard is belt-and-braces; the Pro
    /// gate routes free users to the paywall — the visible-but-locked idiom.
    func requestConnectionStats(focusing host: Host? = nil) {
        guard ConnectionStatsCenter.shared.isCollecting else { return }
        if configuration.entitlements.canViewConnectionStats {
            requestPresentation(.connectionStats(host))
        } else {
            requestPresentation(.paywall)
        }
    }

    /// Whether this launch owes the reader the release notes, asked once the
    /// deck is genuinely presentable.
    ///
    /// Two guards beyond the gate itself. **Width**: the compact shell clips
    /// its deck pane to zero while a terminal is expanded, and that pane is
    /// the wrong presenter (the same trap the external-action alert routes
    /// around) — a later layout pass retries. **Pending external actions**: a
    /// launch carrying a widget deep link asked for something specific, so
    /// the card waits for a launch that did not. Whether a window exists yet
    /// is deliberately NOT asked here: that is `presentNextIfPossible`'s
    /// guard, and a queued request is exactly what it is for.
    private func presentReleaseNotesIfDue() {
        guard !releaseNotesChecked,
              lifecycleStarted,
              !lifecycleStopped,
              view.bounds.width > 0,
              !configuration.externalActions.hasPendingActions
        else { return }
        releaseNotesChecked = true
        switch ReleaseNotesGate.decide(
            lastSeen: releaseNotesStore.lastSeenVersion,
            current: ReleaseNotes.version,
            // The locally cached host list is what separates "updated from a
            // version that stamped nothing" from "installed today".
            installHasPriorUse: !configuration.store.hosts.isEmpty
        ) {
        case .show:
            requestPresentation(.whatsNew)
        case .stampSilently:
            releaseNotesStore.markSeen(ReleaseNotes.version)
        case .nothing:
            break
        }
    }

    private func requestPresentation(
        _ request: PresentationRequest,
        supersedingCurrent: Bool = false
    ) {
        guard !lifecycleStopped else { return }
        if activePresentationKind == request.kind { return }
        if !pendingPresentations.contains(where: { $0.kind == request.kind }) {
            if supersedingCurrent {
                pendingPresentations.insert(request, at: 0)
            } else {
                pendingPresentations.append(request)
            }
        }
        if supersedingCurrent, activePresentationKind != nil {
            if appLocked {
                deferredPresentationSupersession = true
            } else {
                dismissActivePresentation()
            }
        } else {
            presentNextIfPossible()
        }
    }

    private func presentNextIfPossible() {
        guard !lifecycleStopped,
              !appLocked,
              activePresentationKind == nil,
              ownedPresentation == nil,
              presentedViewController == nil,
              viewIfLoaded?.window != nil,
              !pendingPresentations.isEmpty
        else { return }
        let request = pendingPresentations.removeFirst()
        switch request {
        case .addHost:
            presentAddHost(editing: nil)
        case .editHost(let host):
            presentAddHost(editing: host)
        case .settings:
            presentSettings()
        case .faq:
            presentFAQ()
        case .whatsNew:
            presentWhatsNew()
        case .releaseLog:
            presentReleaseLog()
        case .paywall:
            presentPaywall()
        case .connectionStats(let host):
            presentConnectionStats(focusing: host)
        case .localNetworkAlert:
            presentLocalNetworkAlert()
        }
    }

    private func presentAddHost(editing host: Host?) {
        let controller = AddHostViewController(
            store: configuration.store,
            entitlements: configuration.entitlements,
            bind: configuration.bind,
            editing: host
        )
        controller.followAppAppearance(configuration.themes)
        controller.onDismiss = { [weak self] in self?.dismissActivePresentation() }
        controller.onPresentationDismissed = { [weak self] in
            self?.presentationEndedExternally()
        }
        let navigation = makeNavigation(root: controller)
        activeAddHostController = controller
        beginPresentation(
            navigation,
            kind: host.map { .editHost($0.id) } ?? .addHost,
            usesOwnerDelegate: false
        )
    }

    private func presentSettings() {
        let controller = SettingsViewController(
            themes: configuration.themes,
            entitlements: configuration.entitlements,
            attention: configuration.attention,
            appLock: configuration.appLock
        )
        controller.onDone = { [weak self] in self?.dismissActivePresentation() }
        controller.openPrivacyPolicy = { [weak self] url in self?.configuration.openURL(url) }
        let navigation = makeNavigation(root: controller)
        beginPresentation(navigation, kind: .settings, usesOwnerDelegate: true)
    }

    private func presentFAQ() {
        let controller = FAQViewController()
        controller.followAppAppearance(configuration.themes)
        controller.onDone = { [weak self] in self?.dismissActivePresentation() }
        let navigation = makeNavigation(root: controller)
        beginPresentation(navigation, kind: .faq, usesOwnerDelegate: true)
    }

    /// The launch card carries its own DONE, so it is presented bare — a
    /// navigation bar above four rows would be chrome for nothing.
    private func presentWhatsNew() {
        let controller = WhatsNewViewController()
        controller.followAppAppearance(configuration.themes)
        controller.onDone = { [weak self] in self?.dismissActivePresentation() }
        // FULL NOTES *replaces* the card rather than stacking a second sheet
        // on it: one sheet at a time is the deck's discipline, and a reader
        // who asked for the record should land back on the wall when done.
        controller.onFullNotes = { [weak self] in
            self?.requestPresentation(.releaseLog, supersedingCurrent: true)
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            controller.modalPresentationStyle = .formSheet
        }
        beginPresentation(controller, kind: .whatsNew, usesOwnerDelegate: true)
        releaseNotesStore.markSeen(ReleaseNotes.version)
    }

    private func presentReleaseLog() {
        let controller = ReleaseLogViewController()
        controller.followAppAppearance(configuration.themes)
        controller.onDone = { [weak self] in self?.dismissActivePresentation() }
        let navigation = makeNavigation(root: controller)
        navigation.preferredContentSize = ReleaseLogViewController.preferredSheetSize
        if UIDevice.current.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .formSheet
        }
        beginPresentation(navigation, kind: .releaseLog, usesOwnerDelegate: true)
    }

    private func presentPaywall() {
        let controller = ProPaywallViewController(entitlements: configuration.entitlements)
        controller.followAppAppearance(configuration.themes)
        controller.onDone = { [weak self] in self?.dismissActivePresentation() }
        let navigation = makeNavigation(root: controller)
        beginPresentation(navigation, kind: .paywall, usesOwnerDelegate: true)
    }

    private func presentConnectionStats(focusing host: Host?) {
        let controller = ConnectionStatsViewController(
            store: configuration.store,
            focusedHostID: host?.id
        )
        controller.followAppAppearance(configuration.themes)
        controller.onDone = { [weak self] in self?.dismissActivePresentation() }
        let navigation = makeNavigation(root: controller)
        navigation.preferredContentSize = ConnectionStatsViewController.preferredSheetSize
        if UIDevice.current.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .formSheet
        }
        beginPresentation(
            navigation,
            kind: .connectionStats(host?.id),
            usesOwnerDelegate: true
        )
    }

    private func makeNavigation(root: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: root)
        navigation.navigationBar.prefersLargeTitles = false
        // The child controller owns the one sheetGround smoke layer. This
        // container sits behind it, so another smoke layer makes translucent
        // forms — most visibly Host Settings — read as opaque DARK.
        navigation.view.backgroundColor = GlassPrototype.clearedChassis
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        return navigation
    }

    private func beginPresentation(
        _ controller: UIViewController,
        kind: PresentationKind,
        usesOwnerDelegate: Bool
    ) {
        ownedPresentation = controller
        activePresentationKind = kind
        present(controller, animated: true) { [weak self, weak controller] in
            guard let self, let controller else { return }
            if usesOwnerDelegate {
                controller.presentationController?.delegate = self.presentationDelegate
            }
        }
    }

    private func presentLocalNetworkAlert() {
        let alert = UIAlertController(
            title: "Local Network Access Is Off",
            message: "Multiplex can’t reach SSH hosts on your local network. Turn on Local Network access in Settings.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { [weak self] _ in
            guard let self,
                  let url = URL(string: UIApplication.openSettingsURLString)
            else { return }
            self.configuration.openURL(url)
            self.alertActionEndedPresentation()
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in
            self?.alertActionEndedPresentation()
        })
        ownedPresentation = alert
        activePresentationKind = .localNetworkAlert
        present(alert, animated: true)
    }

    private func clearLocalNetworkPresentation() {
        pendingPresentations.removeAll { $0.kind == .localNetworkAlert }
        guard activePresentationKind == .localNetworkAlert else { return }
        dismissActivePresentation()
    }

    private func dismissActivePresentation() {
        guard let presentation = ownedPresentation else {
            presentationEndedExternally()
            return
        }
        activeAddHostController?.prepareForRemoval()
        presentation.dismiss(animated: true) { [weak self] in
            self?.finishPresentation()
        }
    }

    fileprivate func presentationEndedExternally() {
        finishPresentation()
    }

    private func alertActionEndedPresentation() {
        finishPresentation()
    }

    private func finishPresentation() {
        guard activePresentationKind != nil || ownedPresentation != nil else { return }
        activeAddHostController = nil
        ownedPresentation = nil
        activePresentationKind = nil
        schedulePresentationRetry()
        externalActionCoordinator?.presenterDidBecomeAvailable()
        presentationDidEnd?()
    }

    private func schedulePresentationRetry() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<8 where self.presentedViewController != nil {
                try? await Task.sleep(for: .milliseconds(25))
            }
            self.presentNextIfPossible()
        }
    }

    private func presentBindSurfaceIfRequested() {
        guard configuration.bind.wantsBindSurface else { return }
        configuration.bind.wantsBindSurface = false
        let supersedesEdit: Bool
        if case .some(.editHost) = activePresentationKind {
            supersedesEdit = true
        } else {
            supersedesEdit = false
        }
        requestPresentation(.addHost, supersedingCurrent: supersedesEdit)
    }

    // MARK: DEBUG automation

    #if DEBUG
    private func startDebugAutomationIfNeeded() {
        guard !debugAutomationStarted else { return }
        debugAutomationStarted = true

        lifecycleTasks.append(Task { [weak self] in
            await self?.configuration.bind.runDebugAutomationIfRequested()
        })
        presentPaywallForReviewCaptureIfRequested()
        presentSettingsForVerificationIfRequested()
        presentFAQForVerificationIfRequested()
        presentReleaseNotesForVerificationIfRequested()
        presentAddHostForVerificationIfRequested()
        lifecycleTasks.append(Task { [weak self] in
            await self?.presentHostSettingsForVerificationIfRequested()
        })
        lifecycleTasks.append(Task { [weak self] in
            guard let self else { return }
            await DeckScene.autoAttachIfRequested(
                store: self.configuration.store,
                workspace: self.configuration.workspace,
                openTerminalWindow: { [weak self] route in
                    self?.configuration.terminalOpener(route)
                }
            )
        })
    }

    private func presentSettingsForVerificationIfRequested() {
        guard let request = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_SETTINGS"],
              ["1", "theme", "licenses"].contains(request) else { return }
        requestPresentation(.settings)
    }

    private func presentAddHostForVerificationIfRequested() {
        guard AddHostAutoOpen.requested != nil else { return }
        requestPresentation(.addHost)
    }

    private func presentFAQForVerificationIfRequested() {
        guard ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_FAQ"] == "1"
        else { return }
        requestPresentation(.faq)
    }

    /// Opens either release-notes screen for layout capture. The launch gate
    /// itself is unreachable headlessly — it fires only for an install that
    /// carries a PREVIOUS version's defaults — so this is the layout road and
    /// `DeckWindowUIKitTests` pins the gate. The card still stamps itself seen
    /// when it presents; Settings ▸ About is the way back to it.
    private func presentReleaseNotesForVerificationIfRequested() {
        switch ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_WHATS_NEW"] {
        case "1": requestPresentation(.whatsNew)
        case "log": requestPresentation(.releaseLog)
        default: return
        }
    }

    private func presentHostSettingsForVerificationIfRequested() async {
        guard ["1", "models", "backend", "directories"].contains(
            ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_HOST_SETTINGS"]
        ) else { return }
        for _ in 0..<50 {
            if let host = configuration.store.hosts.first {
                requestPresentation(.editHost(host))
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func presentPaywallForReviewCaptureIfRequested() {
        guard ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_PAYWALL"] == "1"
        else { return }
        configuration.entitlements.prepareDebugPaywallPreview()
        requestPresentation(.paywall)
    }
    #endif
}

@MainActor
private final class DeckSceneRegistrationView: UIView {
    var sceneConnected: ((UISceneSession) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let session = window?.windowScene?.session {
            sceneConnected?(session)
        }
    }
}

@MainActor
private final class DeckWindowPresentationDelegate: NSObject,
    UIAdaptivePresentationControllerDelegate
{
    weak var owner: DeckWindowViewController?

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        owner?.presentationEndedExternally()
    }
}
