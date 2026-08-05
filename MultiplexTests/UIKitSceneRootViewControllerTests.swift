import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class UIKitSceneRootViewControllerTests: XCTestCase {
    func testPinnedAppearanceAppliesToRootAndWindow() {
        let harness = makeHarness(appearance: .dark)
        harness.window.makeKeyAndVisible()
        harness.root.loadViewIfNeeded()
        harness.root.viewDidAppear(false)

        XCTAssertEqual(harness.root.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(harness.window.overrideUserInterfaceStyle, .dark)

        harness.themes.appearance = .light
        drainObservation()
        XCTAssertEqual(harness.root.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(harness.window.overrideUserInterfaceStyle, .light)
    }

    func testGlassAppearanceAppliesAndClearsTheMaterialTraitLive() {
        guard GlassPrototype.enabled else { return }
        let harness = makeHarness(appearance: .glass)
        harness.window.makeKeyAndVisible()
        harness.root.loadViewIfNeeded()
        harness.root.viewDidAppear(false)

        XCTAssertEqual(harness.root.overrideUserInterfaceStyle, .dark)
        XCTAssertTrue(harness.root.traitCollection[GlassAppearanceTrait.self])
        XCTAssertTrue(harness.window.traitCollection[GlassAppearanceTrait.self])

        harness.themes.appearance = .dark
        drainObservation()
        XCTAssertFalse(harness.root.traitCollection[GlassAppearanceTrait.self])
        XCTAssertFalse(harness.window.traitCollection[GlassAppearanceTrait.self])
    }

    func testIOSPlatformChromeUsesSignalTint() {
        let harness = makeHarness(platformChrome: .iOS(isIOSAppOnMac: false))
        harness.window.makeKeyAndVisible()
        harness.root.loadViewIfNeeded()
        harness.root.viewDidAppear(false)

        XCTAssertEqual(harness.root.view.tintColor, TallyPalette.signal)
        XCTAssertEqual(harness.window.tintColor, TallyPalette.signal)
        XCTAssertNil(
            UIKitPlatformChromePolicy.iOS(isIOSAppOnMac: false)
                .preferredContentSizeCategory
        )
    }

    func testIOSAppOnMacPlatformChromeBoostsSemanticDynamicType() {
        let policy = UIKitPlatformChromePolicy.iOS(isIOSAppOnMac: true)
        XCTAssertEqual(policy.preferredContentSizeCategory, .extraExtraLarge)

        let harness = makeHarness(platformChrome: policy)
        harness.root.loadViewIfNeeded()
        XCTAssertEqual(
            harness.root.traitCollection.preferredContentSizeCategory,
            .extraExtraLarge
        )
    }

    func testLockedRootMountsNativeVeilAndDisablesContent() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "MultiplexAppLockEnabled")
        let lock = AppLockStore(defaults: defaults, authenticate: { _ in false })
        let harness = makeHarness(lock: lock)
        harness.window.makeKeyAndVisible()
        harness.root.loadViewIfNeeded()

        XCTAssertFalse(harness.content.view.isUserInteractionEnabled)
        XCTAssertEqual(
            harness.root.children.compactMap { $0 as? AppLockViewController }.count,
            1
        )

        await lock.setEnabled(false)
        // Observation deliberately hops through a MainActor Task so it reads
        // the value after the registrar's will-set callback. Running the
        // CFRunLoop does not yield this async test's main-actor executor;
        // explicitly yield until that observation task has had its turn.
        await drainObservationTasks()
        XCTAssertTrue(harness.content.view.isUserInteractionEnabled)
        XCTAssertTrue(
            harness.root.children.compactMap { $0 as? AppLockViewController }.isEmpty
        )
    }

    func testLockVerdictReachesDirectLockAwareContent() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "MultiplexAppLockEnabled")
        let lock = AppLockStore(defaults: defaults, authenticate: { _ in false })
        let content = LockAwareContentViewController()
        let harness = makeHarness(lock: lock, content: content)
        harness.root.loadViewIfNeeded()

        XCTAssertEqual(content.lockVerdicts, [true])

        await lock.setEnabled(false)
        await drainObservationTasks()
        XCTAssertEqual(content.lockVerdicts, [true, false])
    }

    func testLockVerdictTraversesNavigationContainment() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "MultiplexAppLockEnabled")
        let lock = AppLockStore(defaults: defaults, authenticate: { _ in false })
        let content = LockAwareContentViewController()
        let navigation = UINavigationController(rootViewController: content)
        let harness = makeHarness(lock: lock, content: navigation)
        harness.root.loadViewIfNeeded()

        XCTAssertEqual(content.lockVerdicts, [true])

        await lock.setEnabled(false)
        await drainObservationTasks()
        XCTAssertEqual(content.lockVerdicts, [true, false])
    }

    func testBackgroundLockAppliesBeforeAnyObservationTaskCanRun() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let lock = AppLockStore(defaults: defaults, authenticate: { _ in true })
        let content = LockAwareContentViewController()
        let harness = makeHarness(lock: lock, content: content)
        harness.window.makeKeyAndVisible()
        harness.root.loadViewIfNeeded()
        await lock.setEnabled(true)

        lock.lock()

        XCTAssertFalse(harness.content.view.isUserInteractionEnabled)
        XCTAssertTrue(
            harness.window.isUserInteractionEnabled,
            "An inline shield must keep its own UNLOCK control interactive"
        )
        XCTAssertEqual(content.lockVerdicts.last, true)
        XCTAssertEqual(
            harness.root.children.compactMap { $0 as? AppLockViewController }.count,
            1,
            "The test window has no UIWindowScene, so the synchronous fallback veil is inline"
        )
        let unlock = try XCTUnwrap(firstSubview(
            of: UIButton.self,
            in: harness.root.view,
            where: { $0.accessibilityLabel == "Unlock" }
        ))
        unlock.sendActions(for: .touchUpInside)
        await drainObservationTasks()
        XCTAssertFalse(lock.isLocked)
        XCTAssertTrue(harness.content.view.isUserInteractionEnabled)
        await lock.setEnabled(false)
    }

    func testResolvedRootReplaysWorkIgnoredByAwaitingPlaceholder() {
        let router = ExternalActionRouter()
        router.submit(.openShell(host: .named("devbox"), sessionName: nil))
        var intents: [SceneWindowRouting.Intent] = []
        let routing = SceneWindowRouting(
            supportsMultipleWindows: true,
            perform: { intents.append($0) }
        )

        let placeholder = makeHarness(
            externalActions: router,
            sceneWindows: routing,
            handlesExternalActions: false
        )
        placeholder.window.makeKeyAndVisible()
        placeholder.root.loadViewIfNeeded()
        placeholder.root.viewDidAppear(false)
        XCTAssertTrue(intents.isEmpty)

        let resolved = makeHarness(
            externalActions: router,
            sceneWindows: routing
        )
        resolved.window.makeKeyAndVisible()
        resolved.root.loadViewIfNeeded()
        resolved.root.viewDidAppear(false)
        XCTAssertEqual(intents, [.openDeck(.main)])
    }

    func testExternalURLQueuesActionAndRaisesDeckWithoutContext() throws {
        var intents: [SceneWindowRouting.Intent] = []
        let harness = makeHarness(sceneWindows: SceneWindowRouting(
            supportsMultipleWindows: true,
            perform: { intents.append($0) }
        ))
        harness.root.loadViewIfNeeded()
        let before = harness.externalActions.pendingSignal
        let url = try XCTUnwrap(URL(
            string: "multiplex://open?host=devbox&action=shell"
        ))

        XCTAssertTrue(harness.root.receive(url))
        drainObservation()

        XCTAssertEqual(harness.externalActions.pendingSignal, before + 1)
        XCTAssertEqual(intents, [.openDeck(.main)])
    }

    func testUnknownURLIsIgnored() throws {
        let harness = makeHarness()
        harness.root.loadViewIfNeeded()
        let before = harness.externalActions.pendingSignal
        let url = try XCTUnwrap(URL(string: "https://example.com"))

        XCTAssertFalse(harness.root.receive(url))
        XCTAssertEqual(harness.externalActions.pendingSignal, before)
    }

    private struct Harness {
        let window: UIWindow
        let root: UIKitSceneRootViewController
        let content: UIViewController
        let themes: ThemeStore
        let externalActions: ExternalActionRouter
    }

    private func makeHarness(
        appearance: AppAppearance = .system,
        lock: AppLockStore? = nil,
        content: UIViewController? = nil,
        externalActions suppliedExternalActions: ExternalActionRouter? = nil,
        sceneWindows: SceneWindowRouting = SceneWindowRouting(
            supportsMultipleWindows: false,
            perform: { _ in }
        ),
        platformChrome: UIKitPlatformChromePolicy = .current,
        handlesExternalActions: Bool = true
    ) -> Harness {
        let content = content ?? UIViewController()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(appearance.rawValue, forKey: "MultiplexAppearance")
        let themes = ThemeStore(
            defaults: defaults,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        let externalActions = suppliedExternalActions ?? ExternalActionRouter()
        let root = UIKitSceneRootViewController(
            content: content,
            themes: themes,
            appLock: lock ?? AppLockStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!,
                authenticate: { _ in false }
            ),
            externalActions: externalActions,
            bind: BindController(),
            sceneWindows: sceneWindows,
            platformChrome: platformChrome,
            handlesExternalActions: handlesExternalActions
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        window.rootViewController = root
        return Harness(
            window: window,
            root: root,
            content: content,
            themes: themes,
            externalActions: externalActions
        )
    }

    private func drainObservation() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private func drainObservationTasks() async {
        for _ in 0..<4 { await Task.yield() }
    }

    private func firstSubview<T: UIView>(
        of type: T.Type,
        in root: UIView,
        where predicate: (T) -> Bool
    ) -> T? {
        if let match = root as? T, predicate(match) { return match }
        for child in root.subviews {
            if let match = firstSubview(of: type, in: child, where: predicate) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private final class LockAwareContentViewController:
    UIViewController,
    UIKitAppLockControlling
{
    private(set) var lockVerdicts: [Bool] = []

    func setAppLocked(_ locked: Bool) {
        lockVerdicts.append(locked)
    }
}
