import OSLog
import UIKit

/// UIKit owns the process and every window scene. SwiftUI remains linked in
/// the main app only for visionOS's `UIHostingOrnament` API, whose public
/// surface requires a SwiftUI `View`; no app screen is rooted in SwiftUI.
@main
@MainActor
final class MultiplexApplicationDelegate: UIResponder, UIApplicationDelegate {
    let runtime = AppRuntime()
    private let sceneLog = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "scene"
    )

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(adoptPersistedSwiftUIScene(_:)),
            name: UIScene.willConnectNotification,
            object: nil
        )
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Multiplex Window",
            sessionRole: connectingSceneSession.role
        )
        configuration.sceneClass = UIWindowScene.self
        configuration.delegateClass = MultiplexSceneDelegate.self
        return configuration
    }

    /// SwiftUI's scene configuration is serialized into each UISceneSession.
    /// An in-place upgrade therefore reconnects the old AppSceneDelegate even
    /// though this executable now has a UIKit entry point. UIKit exposes the
    /// live scene delegate as mutable, so adopt that already-restored scene at
    /// its connection notification instead of destroying the sole foreground
    /// session (which can terminate the process before a replacement opens).
    @objc
    private func adoptPersistedSwiftUIScene(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        let session = scene.session
        let configuredName = session.configuration.delegateClass.map {
            NSStringFromClass($0)
        }
        let liveName = scene.delegate.map { NSStringFromClass(type(of: $0)) }
        guard UIKitLegacySceneMigrationPolicy.requiresAdoption(
            nativeDelegateClassName: NSStringFromClass(MultiplexSceneDelegate.self),
            configuredDelegateClassName: configuredName,
            liveDelegateClassName: liveName
        ) else { return }

        let nativeDelegate = MultiplexSceneDelegate()
        scene.delegate = nativeDelegate
        // Mount immediately from the session's own persisted state. This
        // notification can arrive either side of the serialized delegate's
        // `willConnect`, and deferring a turn leaves the sole foreground scene
        // inert meanwhile. When UIKit does reach this delegate afterwards, the
        // `connectedSession` guard keeps the mount single and hands that
        // callback's connection options — the cold-launch widget tap, URL, or
        // Shortcut — to `adoptLateConnectionOptions` instead of dropping them.
        nativeDelegate.connectPersistedLegacySceneIfNeeded(scene)
        sceneLog.notice(
            "Adopted persisted SwiftUI scene \(session.persistentIdentifier, privacy: .public) into UIKit"
        )
    }
}

/// One native owner per connected deck, terminal, or adaptive-shell scene.
/// The delegate decodes/restores a framework-neutral payload, chooses shell
/// mode once, builds the corresponding UIKit controller tree, forwards URLs
/// and foreground state, and writes every terminal route mutation back to
/// `UISceneSession.stateRestorationActivity`.
@MainActor
final class MultiplexSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    @MainActor
    private enum MountedContent {
        case deck(DeckWindowViewController)
        case terminal(TerminalWindowViewController)
        case shell(SingleWindowShellViewController)

        func setSceneActive(_ active: Bool) {
            switch self {
            case .deck(let controller): controller.setSceneActive(active)
            case .terminal: break
            case .shell(let controller): controller.setSceneActive(active)
            }
        }

        func prepareForRemoval() {
            switch self {
            case .deck(let controller): controller.prepareForRemoval()
            case .terminal(let controller): controller.prepareForRemoval()
            case .shell(let controller): controller.prepareForRemoval()
            }
        }
    }

    private var sceneRouter: UIKitSceneRouter?
    private var rootController: UIKitSceneRootViewController?
    private var mountedContent: MountedContent?
    private var payload: ScenePayload?
    private var connectionPhase: UIKitSceneConnectionPhase = .awaitingRestoration
    private var urlBuffer = UIKitSceneURLBuffer()
    /// Scene callbacks that landed before this delegate connected. The legacy
    /// adoption path installs the delegate mid-connection, so UIKit can offer
    /// restored state or activate the scene while there is still nothing to
    /// apply it to. Dropping either is what leaves a restored terminal window
    /// coming back as a bare deck, or a scene parked on its placeholder.
    private var pendingRestorationActivity: NSUserActivity?
    private var pendingActivation = false
    private var preservesDeckIdentity = true
    private weak var connectedSession: UISceneSession?
    private var reduceMotionObserver: NSObjectProtocol?
    #if os(visionOS)
    private let windowSizes = SceneWindowSizeStore()
    #endif

    private var runtime: AppRuntime {
        guard let delegate = UIApplication.shared.delegate
            as? MultiplexApplicationDelegate else {
            preconditionFailure("Multiplex application runtime is unavailable")
        }
        return delegate.runtime
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        connect(
            windowScene,
            session: session,
            activationActivities: Array(connectionOptions.userActivities),
            initialURLs: connectionOptions.urlContexts.map(\.url)
        )
    }

    func connectPersistedLegacySceneIfNeeded(_ windowScene: UIWindowScene) {
        connect(
            windowScene,
            session: windowScene.session,
            activationActivities: [],
            initialURLs: []
        )
    }

    private func connect(
        _ windowScene: UIWindowScene,
        session: UISceneSession,
        activationActivities: [NSUserActivity],
        initialURLs: [URL]
    ) {
        guard connectedSession == nil else {
            adoptLateConnectionOptions(
                activationActivities: activationActivities,
                initialURLs: initialURLs,
                in: windowScene
            )
            return
        }
        connectedSession = session
        // A legacy session may not have handed over its restoration activity
        // yet (UISceneSession documents that), but it always carries the same
        // SwiftUI envelope in `userInfo`.
        let restorationActivity = session.stateRestorationActivity
            ?? SceneActivityCodec.legacySessionActivity(from: session.userInfo)
        let resolution = UIKitScenePayloadResolver.resolution(
            activationActivities: activationActivities,
            restorationActivity: restorationActivity
        )
        connectionPhase = UIKitSceneConnectionPhase.initial(
            resolution: resolution,
            restorationActivityWasSupplied: restorationActivity != nil
        )

        let router = UIKitSceneRouter(scene: windowScene)
        sceneRouter = router
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        if connectionPhase == .awaitingRestoration {
            mountAwaitingRestoration(in: windowScene)
        } else {
            mount(resolution.payload, in: windowScene, routing: router.routing)
        }
        window.makeKeyAndVisible()
        if connectionPhase.persistsImmediately {
            persist(resolution.payload)
        }
        if connectionPhase == .activation,
           resolution.requestsInitialGeometry {
            configureGeometry(for: resolution.payload, in: windowScene)
        }
        installReduceMotionObserver()
        drainPendingSceneCallbacks(in: windowScene)

        for url in initialURLs.sorted(by: {
            $0.absoluteString < $1.absoluteString
        }) {
            receiveOrBuffer(url)
        }
    }

    /// UIKit's `scene(_:willConnectTo:)` can reach a session this delegate
    /// already connected from `willConnectNotification`. The mount is done, but
    /// the options it brings are the launch itself — a widget tap, a
    /// `multiplex://` URL, a Shortcut — and are the one thing still owed.
    private func adoptLateConnectionOptions(
        activationActivities: [NSUserActivity],
        initialURLs: [URL],
        in windowScene: UIWindowScene
    ) {
        let resolution = UIKitScenePayloadResolver.resolution(
            activationActivities: activationActivities,
            restorationActivity: nil
        )
        if resolution.source == .activation {
            activate(resolution.payload, in: windowScene)
        }
        for url in initialURLs.sorted(by: {
            $0.absoluteString < $1.absoluteString
        }) {
            receiveOrBuffer(url)
        }
    }

    private func drainPendingSceneCallbacks(in windowScene: UIWindowScene) {
        // Restored state first: it is what activation would otherwise
        // overwrite with the fresh value-less deck.
        if let activity = pendingRestorationActivity {
            pendingRestorationActivity = nil
            applyRestoration(activity, in: windowScene)
        }
        if pendingActivation {
            pendingActivation = false
            promoteAwaitingRestorationIfNeeded(in: windowScene)
            mountedContent?.setSceneActive(true)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if sceneRouter == nil {
            pendingActivation = true
        } else if let windowScene = scene as? UIWindowScene {
            promoteAwaitingRestorationIfNeeded(in: windowScene)
        }
        mountedContent?.setSceneActive(true)
        Task { await runtime.appLock.autoUnlock() }
    }

    private func promoteAwaitingRestorationIfNeeded(in windowScene: UIWindowScene) {
        guard connectionPhase == .awaitingRestoration, let sceneRouter else {
            return
        }
        // UIKit promises restoreInteractionState before activation. If
        // no callback arrived by this point, this is genuinely the fresh
        // value-less deck/shell scene rather than protected delayed state.
        connectionPhase = .freshDefault
        replaceContent(
            with: .deck(.main),
            in: windowScene,
            routing: sceneRouter.routing
        )
        configureGeometry(for: .deck(.main), in: windowScene)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        #if os(visionOS)
        recordSceneGeometry()
        #endif
        mountedContent?.setSceneActive(false)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        mountedContent?.setSceneActive(false)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        mountedContent?.setSceneActive(false)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        #if os(visionOS)
        recordSceneGeometry()
        #endif
        mountedContent?.prepareForRemoval()
        rootController?.prepareForRemoval()
        mountedContent = nil
        rootController = nil
        sceneRouter = nil
        pendingRestorationActivity = nil
        pendingActivation = false
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
            self.reduceMotionObserver = nil
        }
    }

    func scene(
        _ scene: UIScene,
        openURLContexts URLContexts: Set<UIOpenURLContext>
    ) {
        for context in URLContexts.sorted(by: {
            $0.url.absoluteString < $1.url.absoluteString
        }) {
            receiveOrBuffer(context.url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let incoming = SceneActivityCodec.payload(from: userActivity),
              let windowScene = scene as? UIWindowScene
        else { return }
        activate(incoming, in: windowScene)
    }

    private func activate(_ incoming: ScenePayload, in windowScene: UIWindowScene) {
        guard let sceneRouter else { return }
        connectionPhase = .activation
        if let current = payload,
           !UIKitSceneContentReplacementPolicy.requiresReplacement(
                current: current,
                incoming: incoming
           ) {
            // `openDeck()` intentionally activates the stable existing deck
            // with the same value. Persist the current envelope but preserve
            // the mounted controller tree and its live lifecycle state.
            persist(incoming)
            return
        }
        replaceContent(with: incoming, in: windowScene, routing: sceneRouter.routing)
    }

    func scene(
        _ scene: UIScene,
        restoreInteractionStateWith stateRestorationActivity: NSUserActivity
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard sceneRouter != nil else {
            pendingRestorationActivity = stateRestorationActivity
            return
        }
        applyRestoration(stateRestorationActivity, in: windowScene)
    }

    private func applyRestoration(
        _ activity: NSUserActivity,
        in windowScene: UIWindowScene
    ) {
        guard connectionPhase.acceptsInitialRestorationCallback,
              let sceneRouter
        else { return }
        let restored: ScenePayload
        if let decoded = SceneActivityCodec.payload(from: activity) {
            restored = decoded
        } else if connectionPhase == .awaitingRestoration {
            restored = .deck(.main)
        } else {
            return
        }
        connectionPhase = .restoration
        if payload == restored {
            persist(restored)
        } else {
            replaceContent(with: restored, in: windowScene, routing: sceneRouter.routing)
        }
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        // Nothing is mounted yet, so this delegate has nothing to say about
        // the window — but UIKit is free to snapshot here, and answering nil
        // would erase the session's own persisted activity, i.e. the window
        // the person actually left open. Hand back what is already on file.
        guard connectionPhase != .awaitingRestoration, let payload else {
            return connectedSession?.stateRestorationActivity
        }
        return try? SceneActivityCodec.makeActivity(for: payload)
    }

    private func replaceContent(
        with payload: ScenePayload,
        in windowScene: UIWindowScene,
        routing: SceneWindowRouting
    ) {
        mountedContent?.prepareForRemoval()
        rootController?.prepareForRemoval()
        mountedContent = nil
        rootController = nil
        mount(payload, in: windowScene, routing: routing)
        persist(payload)
        releaseBufferedURLs()
    }

    private func mountAwaitingRestoration(in windowScene: UIWindowScene) {
        payload = nil
        mountedContent = nil
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = UIKitChassis.chassis
        let inertRouting = SceneWindowRouting(
            supportsMultipleWindows: false,
            perform: { _ in }
        )
        let root = UIKitSceneRootViewController(
            content: placeholder,
            themes: runtime.themes,
            appLock: runtime.appLock,
            externalActions: runtime.externalActions,
            bind: runtime.bind,
            sceneWindows: inertRouting,
            handlesExternalActions: false
        )
        rootController = root
        window?.rootViewController = root
        windowScene.title = "Multiplex"
    }

    private func receiveOrBuffer(_ url: URL) {
        let ready = urlBuffer.accept([url], phase: connectionPhase)
        for url in ready {
            _ = rootController?.receive(url)
        }
    }

    private func releaseBufferedURLs() {
        for url in urlBuffer.release(phase: connectionPhase) {
            _ = rootController?.receive(url)
        }
    }

    private func mount(
        _ payload: ScenePayload,
        in windowScene: UIWindowScene,
        routing: SceneWindowRouting
    ) {
        self.payload = payload
        preservesDeckIdentity = {
            if case .deck = payload { return true }
            return false
        }()

        let plan = presentationPlan(for: payload, in: windowScene)
        let content: UIViewController
        switch plan {
        case .deck:
            let controller = DeckWindowViewController(
                configuration: classicDeckConfiguration(
                    routing: routing,
                    sceneIsActive: windowScene.activationState == .foregroundActive
                )
            )
            mountedContent = .deck(controller)
            content = controller

        case .terminal(let route):
            let controller = TerminalWindowViewController(
                route: route,
                dependencies: terminalDependencies,
                sceneWindows: routing,
                routeChanged: { [weak self] route in
                    self?.persist(.terminal(route))
                }
            )
            mountedContent = .terminal(controller)
            #if os(visionOS)
            content = controller
            #else
            let navigation = UINavigationController(rootViewController: controller)
            navigation.navigationBar.prefersLargeTitles = false
            navigation.view.backgroundColor = UIKitChassis.chassis
            UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
            content = navigation
            #endif

        case .shell(let route):
            let controller = SingleWindowShellViewController(
                dependencies: shellDependencies(routing: routing),
                initialRoute: route,
                sceneIsActive: windowScene.activationState == .foregroundActive,
                reduceMotion: UIAccessibility.isReduceMotionEnabled,
                routeChanged: { [weak self] route in
                    guard let self else { return }
                    if preservesDeckIdentity {
                        persist(.deck(.main))
                    } else {
                        persist(.terminal(route))
                    }
                }
            )
            mountedContent = .shell(controller)
            content = controller
        }

        // visionOS's terminal scene was declared `.windowStyle(.plain)`: no
        // system glass platter, so the pane stack's own 24pt rounded chassis
        // (`TerminalWindowUIKitRootView`) is the window's silhouette against
        // the room. UIKit spells the same thing
        // `preferredContainerBackgroundStyle == .hidden`, and it only reads
        // as plain while nothing opaque is painted behind that rounded rect —
        // hence the clear root view and window backing below. The deck keeps
        // the platter, exactly as `.windowStyle` left it.
        let plainWindowBackground: Bool = {
            #if os(visionOS)
            if case .terminal = plan { return true }
            #endif
            return false
        }()

        let root = UIKitSceneRootViewController(
            content: content,
            themes: runtime.themes,
            appLock: runtime.appLock,
            externalActions: runtime.externalActions,
            bind: runtime.bind,
            sceneWindows: routing,
            plainWindowBackground: plainWindowBackground
        )
        rootController = root
        window?.rootViewController = root
        window?.backgroundColor = plainWindowBackground ? .clear : nil
        windowScene.title = title(for: payload)
        log(plan: plan, in: windowScene)
    }

    private var terminalDependencies: TerminalWindowDependencies {
        TerminalWindowDependencies(
            store: runtime.store,
            hub: runtime.hub,
            themes: runtime.themes,
            workspace: runtime.workspace,
            entitlements: runtime.entitlements
        )
    }

    private func shellDependencies(
        routing: SceneWindowRouting
    ) -> SingleWindowShellDependencies {
        SingleWindowShellDependencies(
            store: runtime.store,
            hub: runtime.hub,
            themes: runtime.themes,
            workspace: runtime.workspace,
            entitlements: runtime.entitlements,
            attention: runtime.attention,
            localNetworkAccess: runtime.localNetworkAccess,
            networkChanges: runtime.networkChanges,
            externalActions: runtime.externalActions,
            appLock: runtime.appLock,
            bind: runtime.bind,
            openURL: Self.openSystemURL,
            sceneWindows: routing
        )
    }

    /// The one shape a deck scene of its own mounts with. Both the mount and
    /// the Reduce Motion refresh build it here so the two can never drift.
    private func classicDeckConfiguration(
        routing: SceneWindowRouting,
        sceneIsActive: Bool
    ) -> DeckWindowConfiguration {
        deckConfiguration(
            routing: routing,
            terminalOpener: TerminalRouteOpener(
                destination: .window,
                action: routing.openTerminal
            ),
            presentation: .standard,
            selectedTerminal: nil,
            shellSafeArea: .zero,
            sceneIsActive: sceneIsActive
        )
    }

    private func deckConfiguration(
        routing: SceneWindowRouting,
        terminalOpener: TerminalRouteOpener,
        presentation: FleetWall.Presentation,
        selectedTerminal: TerminalRoute?,
        shellSafeArea: UIEdgeInsets,
        sceneIsActive: Bool
    ) -> DeckWindowConfiguration {
        DeckWindowConfiguration(
            store: runtime.store,
            entitlements: runtime.entitlements,
            hub: runtime.hub,
            workspace: runtime.workspace,
            localNetworkAccess: runtime.localNetworkAccess,
            networkChanges: runtime.networkChanges,
            bind: runtime.bind,
            themes: runtime.themes,
            attention: runtime.attention,
            appLock: runtime.appLock,
            externalActions: runtime.externalActions,
            sceneWindows: routing,
            openURL: Self.openSystemURL,
            terminalOpener: terminalOpener,
            presentation: presentation,
            selectedTerminal: selectedTerminal,
            shellSafeArea: shellSafeArea,
            sceneIsActive: sceneIsActive,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
    }

    private func presentationPlan(
        for payload: ScenePayload,
        in scene: UIWindowScene
    ) -> UIKitScenePresentationPlan {
        #if os(visionOS)
        let platform = ShellModeDecision.Platform.visionOS
        let isFullScreen = false
        #else
        let platform = ShellModeDecision.Platform.iOS
        let isFullScreen = scene.isFullScreen
        #endif
        let idiom: ShellModeDecision.Idiom = switch scene.traitCollection
            .userInterfaceIdiom {
        case .phone: .phone
        case .pad: .pad
        default: .other
        }
        #if DEBUG
        let override = ProcessInfo.processInfo.environment["MULTIPLEX_FORCE_SHELL"]
        #else
        let override: String? = nil
        #endif
        return UIKitScenePresentationPlan.resolve(
            payload: payload,
            platform: platform,
            idiom: idiom,
            isFullScreen: isFullScreen,
            environmentOverride: override
        )
    }

    private func persist(_ payload: ScenePayload) {
        self.payload = payload
        let activity = try? SceneActivityCodec.makeActivity(for: payload)
        connectedSession?.stateRestorationActivity = activity
        window?.windowScene?.title = title(for: payload)
    }

    private func configureGeometry(
        for payload: ScenePayload,
        in scene: UIWindowScene
    ) {
        #if os(visionOS)
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        #else
        let environment: [String: String] = [:]
        #endif
        // SwiftUI's `.defaultSize` was a hint: visionOS reopens a window group
        // at whatever size the user last left it and only reaches for the
        // declared default when it remembers nothing. This request runs on
        // every scene UIKit creates, so it answers the same question in the
        // same order — otherwise one resized terminal is undone by the next
        // attach. Raising an existing scene still requests no geometry at all.
        let kind = SceneGeometryKind(payload)
        let size = SceneGeometryPolicy.chooseInitialSize(
            environmentOverride: environment[kind.debugSizeEnvironmentKey]
                .flatMap(UIKitSceneGeometryPolicy.parseSize),
            remembered: windowSizes.lastSize(for: kind),
            default: UIKitSceneGeometryPolicy.preferredSize(
                for: payload,
                environment: [:]
            )
        )
        scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.Vision(
            size: size,
            resizingRestrictions: .freeform
        )) { error in
            Self.logger.error(
                "scene geometry failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
    }

    #if os(visionOS)
    /// `UIWindowSceneGeometry` exposes no size on visionOS (only the app's own
    /// minimum/maximum and resizing restriction), so the live size is read
    /// from the scene coordinate space where that exists and from the window
    /// UIKit keeps spanning the scene everywhere else.
    private func currentSceneSize() -> CGSize? {
        if #available(visionOS 26.0, *), let scene = window?.windowScene {
            return scene.effectiveGeometry.coordinateSpace.bounds.size
        }
        return window?.bounds.size
    }

    private func recordSceneGeometry() {
        guard let payload, let size = currentSceneSize() else { return }
        windowSizes.record(size, for: SceneGeometryKind(payload))
    }

    /// The resize signal itself. Older visionOS has no such callback, so
    /// there the scene lifecycle captures (resign active, disconnect) are
    /// what carry a resize into the next window of the same kind.
    @available(visionOS 26.0, *)
    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry
    ) {
        recordSceneGeometry()
    }
    #endif

    private func installReduceMotionObserver() {
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyReduceMotion()
            }
        }
    }

    private func applyReduceMotion() {
        guard let mountedContent else { return }
        switch mountedContent {
        case .deck(let controller):
            // The classic deck takes Reduce Motion through its immutable
            // configuration (the rail's LINKING pulse, the tile-grid
            // crossfade), where the SwiftUI wall read it from the
            // environment and followed it live. Rebuilding the same
            // configuration re-reads the current value and lands as a wall
            // re-render: every dependency reference is identical, so no part
            // of the deck's lifecycle restarts.
            guard let routing = sceneRouter?.routing else { return }
            controller.update(configuration: classicDeckConfiguration(
                routing: routing,
                sceneIsActive: controller.sceneIsActive
            ))
        case .terminal:
            break
        case .shell(let controller):
            controller.setReduceMotion(UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func title(for payload: ScenePayload) -> String {
        switch payload {
        case .deck:
            return "Multiplex"
        case .terminal(let route):
            return route.activeTab?.displayName ?? "Terminal"
        }
    }

    private func log(plan: UIKitScenePresentationPlan, in scene: UIWindowScene) {
        #if DEBUG
        let override = ProcessInfo.processInfo.environment["MULTIPLEX_FORCE_SHELL"]
            ?? "none"
        #else
        let override = "none"
        #endif
        Self.logger.info(
            "connected plan=\(String(describing: plan), privacy: .public) idiom=\(String(describing: scene.traitCollection.userInterfaceIdiom), privacy: .public) isFullScreen=\(scene.isFullScreen, privacy: .public) override=\(override, privacy: .public)"
        )
    }

    private static func openSystemURL(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "shell"
    )
}
