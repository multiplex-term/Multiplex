import AppIntents

/// Process-wide dependency graph shared by every deck, terminal, and shell
/// scene. Keeping construction here makes the graph independent of SwiftUI's
/// `App` lifecycle so a future UIKit application/scene delegate can own the
/// exact same objects without rebuilding service wiring.
@MainActor
final class AppRuntime {
    let store: HostStore
    let hub: ConnectionHub
    let themes = ThemeStore()
    let workspace: TerminalWorkspace
    let entitlements: EntitlementStore
    let attention: AttentionCenter
    let localNetworkAccess = LocalNetworkAccessMonitor()
    let networkChanges = NetworkChangeMonitor()
    let appLock = AppLockStore()
    let externalActions = ExternalActionRouter.shared
    let bind = BindController.shared
    /// The late half of keep-alive. Registered from
    /// `didFinishLaunchingWithOptions` (BGTaskScheduler rejects anything
    /// later) and re-scheduled whenever the app leaves.
    let backgroundRefresh: BackgroundRefresh

    init() {
        // Attention wiring: every probe's events funnel through one center,
        // which consults the workspace to skip the session being typed in
        // and the entitlement store to stay behind the Pro gate.
        let entitlements = EntitlementStore()
        let attention = AttentionCenter()
        let workspace = TerminalWorkspace(attention: attention)
        attention.workspace = workspace
        attention.entitlements = entitlements
        let store = HostStore()

        self.store = store
        self.entitlements = entitlements
        self.attention = attention
        self.workspace = workspace
        let hub = ConnectionHub(attention: attention)
        self.hub = hub
        backgroundRefresh = BackgroundRefresh(
            store: store,
            hub: hub,
            attention: attention
        )

        // Background keep-alive: the assertion is taken only when a host the
        // user opted in has something for the extra time to do, so the
        // default install's background behaviour is unchanged. Composed here
        // because the answer needs both the live host list and the workspace,
        // which the asking scenes do not all hold.
        BackgroundActivity.shared.demand = { [weak store, weak workspace] in
            guard let store else { return false }
            return BackgroundActivityPolicy.wantsBackgroundTime(
                hosts: store.hosts,
                hostIDsWithLiveSessions: workspace?.hostIDsWithLiveSessions ?? []
            )
        }
        // Every asking loop holds a host snapshot; this is where the switch's
        // live value comes from, so a Host Settings flip reaches a probe
        // already running. A deleted host wants nothing.
        BackgroundActivity.shared.keepAliveLookup = { [weak store] hostID in
            store?.host(id: hostID)?.backgroundKeepAlive ?? false
        }
        BackgroundActivity.shared.start()
        backgroundRefresh.start()
        #if DEBUG
        backgroundRefresh.installDebugHook()
        #endif

        // Mint the widget-link token once per install: the widget process
        // reads it from the App Group to mark its own deep links, and
        // `receive(_ url:)` confirms anything that arrives without it.
        SharedStateStore.ensureLinkToken()

        // The lock holds the external-action queue: nothing that connects to
        // a host, mints a session, or types an agent prompt runs behind the
        // veil. The store posts this notification synchronously as it flips,
        // and the queue drains itself when the hold lifts.
        let externalActions = self.externalActions
        let appLock = self.appLock
        externalActions.isHeldByAppLock = appLock.isLocked
        NotificationCenter.default.addObserver(
            forName: AppLockStore.stateDidChangeNotification,
            object: appLock,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                externalActions.isHeldByAppLock = appLock.isLocked
            }
        }

        // App Intents run in this process: the router must be resolvable
        // before any perform() (a cold intent launch performs right after
        // app initialization), and the Shortcuts host picker reads the live
        // store rather than a separate scene-owned copy.
        AppDependencyManager.shared.add(dependency: self.externalActions)
        HostEntityProvider.live = {
            store.hosts.map {
                HostEntity(
                    id: $0.id,
                    name: $0.name,
                    address: $0.address,
                    workingDirs: $0.workingDirs,
                    sessionScripts: $0.sessionScripts.map {
                        ShortcutSessionScript(
                            id: $0.id,
                            displayName: $0.displayName
                        )
                    },
                    agentModels: $0.agentLaunchModels,
                    backendRaw: $0.sessionBackend.rawValue
                )
            }
        }
    }
}
