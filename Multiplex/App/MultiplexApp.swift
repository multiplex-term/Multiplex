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
            configuredDelegateClassName: configuredName,
            liveDelegateClassName: liveName,
            restorationActivity: session.stateRestorationActivity
        ) else { return }

        let nativeDelegate = MultiplexSceneDelegate()
        scene.delegate = nativeDelegate
        // On current UIKit the notification precedes the delegate callback,
        // so that callback supplies every connection option normally. Older
        // runtimes can post it after the serialized delegate's callback; the
        // next-turn fallback mounts from the session's public restoration
        // activity only when UIKit did not call the native delegate itself.
        DispatchQueue.main.async { [weak scene, weak nativeDelegate] in
            guard let scene, let nativeDelegate else { return }
            nativeDelegate.connectPersistedLegacySceneIfNeeded(scene)
        }
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

        func setReduceMotion(_ reduceMotion: Bool) {
            if case .shell(let controller) = self {
                controller.setReduceMotion(reduceMotion)
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
    private var preservesDeckIdentity = true
    private weak var connectedSession: UISceneSession?
    private var reduceMotionObserver: NSObjectProtocol?

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
        guard connectedSession == nil else { return }
        connectedSession = session
        let resolution = UIKitScenePayloadResolver.resolution(
            activationActivities: activationActivities,
            restorationActivity: session.stateRestorationActivity
        )
        connectionPhase = UIKitSceneConnectionPhase.initial(
            resolution: resolution,
            restorationActivityWasSupplied: session.stateRestorationActivity != nil
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

        for url in initialURLs.sorted(by: {
            $0.absoluteString < $1.absoluteString
        }) {
            receiveOrBuffer(url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if connectionPhase == .awaitingRestoration,
           let windowScene = scene as? UIWindowScene,
           let sceneRouter {
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
        mountedContent?.setSceneActive(true)
        Task { await runtime.appLock.autoUnlock() }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        mountedContent?.setSceneActive(false)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        mountedContent?.setSceneActive(false)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        mountedContent?.setSceneActive(false)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        mountedContent?.prepareForRemoval()
        rootController?.prepareForRemoval()
        mountedContent = nil
        rootController = nil
        sceneRouter = nil
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
              let windowScene = scene as? UIWindowScene,
              let sceneRouter
        else { return }
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
        guard connectionPhase.acceptsInitialRestorationCallback,
              let windowScene = scene as? UIWindowScene,
              let sceneRouter
        else { return }
        let restored: ScenePayload
        if let decoded = SceneActivityCodec.payload(from: stateRestorationActivity) {
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
        guard connectionPhase != .awaitingRestoration, let payload else { return nil }
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
            let controller = DeckWindowViewController(configuration: deckConfiguration(
                routing: routing,
                terminalOpener: TerminalRouteOpener(
                    destination: .window,
                    action: routing.openTerminal
                ),
                presentation: .standard,
                selectedTerminal: nil,
                shellSafeArea: .zero,
                sceneIsActive: windowScene.activationState == .foregroundActive
            ))
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

        let root = UIKitSceneRootViewController(
            content: content,
            themes: runtime.themes,
            appLock: runtime.appLock,
            externalActions: runtime.externalActions,
            bind: runtime.bind,
            sceneWindows: routing
        )
        rootController = root
        window?.rootViewController = root
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
        let size = UIKitSceneGeometryPolicy.preferredSize(
            for: payload,
            environment: environment
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

    private func installReduceMotionObserver() {
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.mountedContent?.setReduceMotion(
                    UIAccessibility.isReduceMotionEnabled
                )
            }
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
