import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class DeckWindowUIKitTests: XCTestCase {
    func testDeckMountsNativeFleetWallWithoutHostingController() throws {
        let harness = try makeHarness()
        let controller = harness.controller

        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.children.count, 1)
        XCTAssertTrue(controller.children.first === controller.wallController)
        XCTAssertNotNil(controller.children.first as? FleetWallContainerViewController)
        XCTAssertFalse(controllerTree(controller).contains {
            String(describing: type(of: $0)).contains("UIHostingController")
        })
    }

    func testAddHostRoutesToEditorOrPaywallFromTheNativeGate() throws {
        let available = try makeHarness(isPro: false)
        available.controller.requestAddHost()
        XCTAssertEqual(available.controller.pendingPresentationKinds, [.addHost])
        XCTAssertNil(available.controller.activePresentationKind)

        let hosts = [makeHost(name: "one"), makeHost(name: "two")]
        let limited = try makeHarness(hosts: hosts, isPro: false)
        limited.controller.requestAddHost()
        XCTAssertEqual(limited.controller.pendingPresentationKinds, [.paywall])

        let unlocked = try makeHarness(hosts: hosts, isPro: true)
        unlocked.controller.requestAddHost()
        XCTAssertEqual(unlocked.controller.pendingPresentationKinds, [.addHost])
    }

    /// An install that already has hosts is one that was in use before this
    /// stamp existed — every device updating from a version that wrote
    /// nothing. Reading that as "first run" is what would silence the notes
    /// for exactly the people they are written for.
    func testAnInstallAlreadyInUseIsQueuedTheReleaseNotes() throws {
        let harness = try makeHarness(hosts: [makeHost(name: "devbox")])
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        harness.controller.releaseNotesStore = ReleaseNotesStore(defaults: defaults)

        appear(harness.controller)
        defer { harness.controller.prepareForRemoval() }

        XCTAssertEqual(harness.controller.pendingPresentationKinds, [.whatsNew])
        XCTAssertEqual(
            ReleaseNotesStore(defaults: defaults).lastSeenVersion,
            nil,
            "the stamp belongs to the presentation, not the decision"
        )
    }

    /// A first run owes nobody a changelog for a release they never missed —
    /// it is stamped instead, so the next update is the first one that shows.
    func testAFirstRunIsStampedInsteadOfShownTheReleaseNotes() throws {
        let harness = try makeHarness()
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        harness.controller.releaseNotesStore = ReleaseNotesStore(defaults: defaults)

        appear(harness.controller)
        defer { harness.controller.prepareForRemoval() }

        XCTAssertTrue(harness.controller.pendingPresentationKinds.isEmpty)
        XCTAssertEqual(
            ReleaseNotesStore(defaults: defaults).lastSeenVersion,
            ReleaseNotes.version
        )
    }

    /// A launch carrying a widget deep link asked for something specific.
    func testAPendingExternalActionHoldsTheReleaseNotesBack() throws {
        let harness = try makeHarness(hosts: [makeHost(name: "devbox")])
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        harness.controller.releaseNotesStore = ReleaseNotesStore(defaults: defaults)
        harness.externalActions.submit(
            .openShell(host: .named("devbox"), sessionName: nil)
        )

        appear(harness.controller)
        defer { harness.controller.prepareForRemoval() }

        XCTAssertTrue(harness.controller.pendingPresentationKinds.isEmpty)
        XCTAssertNil(ReleaseNotesStore(defaults: defaults).lastSeenVersion)
    }

    func testHostSettingsDoesNotStackNavigationSmokeInGlass() async throws {
        guard GlassPrototype.enabled else { return }
        let host = makeHost(name: "devbox")
        let harness = try makeHarness(hosts: [host])
        let controller = harness.controller
        harness.themes.appearance = .glass
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        defer {
            controller.prepareForRemoval()
            window.isHidden = true
        }

        controller.requestEditHost(host)
        await drainTasks()

        let navigation = try XCTUnwrap(
            controller.presentedViewController as? UINavigationController
        )
        let editor = try XCTUnwrap(
            navigation.topViewController as? AddHostViewController
        )
        navigation.loadViewIfNeeded()
        editor.loadViewIfNeeded()
        let darkGlass = UITraitCollection(userInterfaceStyle: .dark)
            .replacing(GlassAppearanceTrait.self, value: true)
        XCTAssertEqual(
            navigation.view.backgroundColor?.resolvedColor(with: darkGlass),
            UIColor.clear,
            "The navigation container must not paint a second smoke layer"
        )
        XCTAssertEqual(
            editor.view.backgroundColor?.resolvedColor(with: darkGlass),
            GlassPrototype.smokeMaterial,
            "The Host Settings root owns the sheet's single smoke layer"
        )

    }

    func testPresentationRoutingQueuesDistinctNativeDestinationsInOrder() throws {
        let harness = try makeHarness()
        let controller = harness.controller
        var host = makeHost(name: "devbox")

        controller.requestSettings()
        controller.requestFAQ()
        controller.requestSettings()
        controller.requestEditHost(host)
        host.hostname = "changed.example"
        controller.requestEditHost(host)

        XCTAssertEqual(controller.pendingPresentationKinds, [
            .settings,
            .faq,
            .editHost(host.id),
        ])

        controller.prepareForRemoval()
        XCTAssertTrue(controller.isPreparedForRemoval)
        XCTAssertTrue(controller.pendingPresentationKinds.isEmpty)
        controller.requestFAQ()
        XCTAssertTrue(controller.pendingPresentationKinds.isEmpty)
    }

    func testAppLockQueuesDeckPresentationUntilUnlockWithoutDiscardingState() throws {
        let controller = try makeHarness().controller
        controller.setAppLocked(true)

        controller.requestSettings()
        controller.requestFAQ()

        XCTAssertNil(controller.activePresentationKind)
        XCTAssertEqual(controller.pendingPresentationKinds, [.settings, .faq])

        controller.setAppLocked(false)
        XCTAssertNil(controller.activePresentationKind)
        XCTAssertEqual(
            controller.pendingPresentationKinds,
            [.settings, .faq],
            "Without a window unlock must retain, not consume, queued modal state"
        )
    }

    func testLockedBindSupersessionPreservesActiveEditorUntilUnlock() async throws {
        let host = makeHost(name: "devbox")
        let harness = try makeHarness(hosts: [host])
        let controller = harness.controller
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.viewDidAppear(false)

        controller.requestEditHost(host)
        XCTAssertEqual(controller.activePresentationKind, .editHost(host.id))

        controller.setAppLocked(true)
        harness.bind.wantsBindSurface = true
        await drainTasks()

        XCTAssertEqual(
            controller.activePresentationKind,
            .editHost(host.id),
            "The scene shield must preserve the editor while locked"
        )
        XCTAssertEqual(controller.pendingPresentationKinds.first, .addHost)

        controller.setAppLocked(false)
        await drainTasks()
        controller.prepareForRemoval()
        window.isHidden = true
    }

    func testSceneActivityOwnsBindNetworkAndSnapshotLifetimes() async throws {
        let recorder = LifecycleRecorder()
        let harness = try makeHarness(
            sceneIsActive: false,
            recorder: recorder
        )
        let controller = harness.controller
        harness.bind.bindSurfaceOpen = true

        controller.loadViewIfNeeded()
        controller.viewDidAppear(false)
        await drainTasks()

        XCTAssertTrue(controller.lifecycleStarted)
        XCTAssertFalse(controller.sceneIsActive)
        XCTAssertEqual(recorder.count(.attachBind), 1)
        XCTAssertEqual(recorder.count(.publish([])), 1)
        XCTAssertEqual(recorder.count(.suspendLocalNetwork), 1)
        XCTAssertEqual(recorder.count(.endBindDiscovery), 1)
        XCTAssertEqual(recorder.count(.suspendNetworkChanges), 1)
        XCTAssertEqual(recorder.count(.rotatePendingBindKeys), 1)
        XCTAssertEqual(recorder.count(.refreshHostsFromCloud), 1)

        recorder.events.removeAll()
        controller.setSceneActive(true)
        await drainTasks()

        XCTAssertTrue(controller.sceneIsActive)
        XCTAssertEqual(recorder.count(.checkLocalNetwork([])), 1)
        XCTAssertEqual(recorder.count(.beginBindDiscovery), 1)
        XCTAssertEqual(recorder.count(.beginNetworkChanges), 1)
        XCTAssertEqual(recorder.count(.refreshHostsFromCloud), 1)
        XCTAssertEqual(recorder.count(.flushSnapshots), 0)

        recorder.events.removeAll()
        controller.setSceneActive(false)
        await drainTasks()

        XCTAssertFalse(controller.sceneIsActive)
        XCTAssertEqual(recorder.count(.suspendLocalNetwork), 1)
        XCTAssertEqual(recorder.count(.endBindDiscovery), 1)
        XCTAssertEqual(recorder.count(.suspendNetworkChanges), 1)
        XCTAssertEqual(recorder.count(.flushSnapshots), 1)

        recorder.events.removeAll()
        controller.prepareForRemoval()
        XCTAssertEqual(recorder.count(.suspendLocalNetwork), 1)
        XCTAssertEqual(recorder.count(.suspendNetworkChanges), 1)
        XCTAssertEqual(recorder.count(.endBindDiscovery), 1)
        XCTAssertEqual(recorder.count(.flushSnapshots), 1)
    }

    private struct Harness {
        let controller: DeckWindowViewController
        let bind: BindController
        let themes: ThemeStore
        let externalActions: ExternalActionRouter
    }

    /// Enough of the appear cycle to start the deck's lifecycle without a
    /// window — which is what keeps these assertions on the presentation
    /// QUEUE, never on a real sheet a later test would inherit.
    private func appear(_ controller: DeckWindowViewController) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        controller.view.layoutIfNeeded()
        controller.viewDidAppear(false)
    }

    private func scratchDefaults() throws -> (UserDefaults, String) {
        let suite = "app.multiplexterm.tests.deckNotes.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func makeHarness(
        hosts: [Host] = [],
        isPro: Bool = false,
        sceneIsActive: Bool = false,
        recorder suppliedRecorder: LifecycleRecorder? = nil
    ) throws -> Harness {
        let recorder = suppliedRecorder ?? LifecycleRecorder()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeckWindowUIKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        if !hosts.isEmpty {
            let data = try JSONEncoder().encode(hosts)
            try data.write(to: root.appendingPathComponent("hosts.json"))
        }

        let store = HostStore(directory: root, knownMirroredIDs: [])
        let defaults = UserDefaults(
            suiteName: "app.multiplexterm.tests.deck.\(UUID().uuidString)"
        )!
        let entitlements = EntitlementStore(
            defaults: defaults,
            startStoreKit: false
        )
        #if DEBUG
        entitlements.setDebugUnlocked(isPro)
        #endif
        let attention = AttentionCenter()
        let workspace = TerminalWorkspace(attention: attention)
        attention.workspace = workspace
        attention.entitlements = entitlements
        let hub = ConnectionHub(attention: attention)
        let bind = BindController()
        let themes = ThemeStore(
            defaults: defaults,
            directory: root.appendingPathComponent("themes")
        )
        let externalActions = ExternalActionRouter()
        let configuration = DeckWindowConfiguration(
            store: store,
            entitlements: entitlements,
            hub: hub,
            workspace: workspace,
            localNetworkAccess: LocalNetworkAccessMonitor(),
            networkChanges: NetworkChangeMonitor(),
            bind: bind,
            themes: themes,
            attention: attention,
            appLock: AppLockStore(defaults: defaults, authenticate: { _ in false }),
            externalActions: externalActions,
            sceneWindows: SceneWindowRouting(
                supportsMultipleWindows: false,
                perform: { _ in }
            ),
            openURL: { _ in },
            terminalOpener: TerminalRouteOpener(destination: .shell, action: { _ in }),
            sceneIsActive: sceneIsActive,
            reduceMotion: true,
            lifecycleDriver: recorder.driver
        )
        return Harness(
            controller: DeckWindowViewController(configuration: configuration),
            bind: bind,
            themes: themes,
            externalActions: externalActions
        )
    }

    private func makeHost(name: String) -> Host {
        Host(
            name: name,
            hostname: "\(name).example",
            username: "tester"
        )
    }

    private func controllerTree(_ root: UIViewController) -> [UIViewController] {
        [root] + root.children.flatMap { controllerTree($0) }
    }

    private func drainTasks() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

@MainActor
private final class LifecycleRecorder {
    enum Event: Equatable {
        case attachBind
        case rotatePendingBindKeys
        case refreshHostsFromCloud
        case publish([UUID])
        case checkLocalNetwork([UUID])
        case suspendLocalNetwork
        case beginNetworkChanges
        case suspendNetworkChanges
        case reconnectAfterNetworkChange
        case beginBindDiscovery
        case endBindDiscovery
        case flushSnapshots
    }

    var events: [Event] = []

    var driver: DeckWindowLifecycleDriver {
        DeckWindowLifecycleDriver(
            attachBind: { [weak self] in self?.events.append(.attachBind) },
            rotatePendingBindKeys: { [weak self] in
                self?.events.append(.rotatePendingBindKeys)
            },
            refreshHostsFromCloud: { [weak self] in
                self?.events.append(.refreshHostsFromCloud)
            },
            publishWidgetState: { [weak self] hosts in
                self?.events.append(.publish(hosts.map(\.id)))
            },
            checkLocalNetwork: { [weak self] hosts in
                self?.events.append(.checkLocalNetwork(hosts.map(\.id)))
            },
            suspendLocalNetwork: { [weak self] in
                self?.events.append(.suspendLocalNetwork)
            },
            beginNetworkChanges: { [weak self] in
                self?.events.append(.beginNetworkChanges)
            },
            suspendNetworkChanges: { [weak self] in
                self?.events.append(.suspendNetworkChanges)
            },
            reconnectAfterNetworkChange: { [weak self] in
                self?.events.append(.reconnectAfterNetworkChange)
            },
            beginBindDiscovery: { [weak self] in
                self?.events.append(.beginBindDiscovery)
            },
            endBindDiscovery: { [weak self] in
                self?.events.append(.endBindDiscovery)
            },
            flushSnapshots: { [weak self] in
                self?.events.append(.flushSnapshots)
            }
        )
    }

    func count(_ event: Event) -> Int {
        events.filter { $0 == event }.count
    }
}
