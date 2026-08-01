import Observation
import UIKit

/// Controllers that own interaction surfaces outside the ordinary UIKit view
/// hierarchy (vision ornaments in particular) receive the root lock verdict
/// explicitly. The root also walks containment so navigation wrappers do not
/// break the privacy boundary.
@MainActor
protocol UIKitAppLockControlling: AnyObject {
    func setAppLocked(_ locked: Bool)
}

extension TerminalWindowViewController: UIKitAppLockControlling {}
extension SingleWindowShellViewController: UIKitAppLockControlling {}
extension DeckWindowViewController: UIKitAppLockControlling {}

/// Native equivalent of the former `PlatformChrome` modifier. Keeping the
/// platform decision separate makes the iOS-app-on-Mac semantic-type boost
/// testable on simulator runners that are not themselves Designed for iPad.
struct UIKitPlatformChromePolicy: Equatable {
    var appliesSignalTint: Bool
    var preferredContentSizeCategory: UIContentSizeCategory?

    static func iOS(isIOSAppOnMac: Bool) -> Self {
        Self(
            appliesSignalTint: true,
            preferredContentSizeCategory: isIOSAppOnMac ? .extraExtraLarge : nil
        )
    }

    static var current: Self {
        #if os(iOS)
        .iOS(isIOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
        #else
        Self(appliesSignalTint: false, preferredContentSizeCategory: nil)
        #endif
    }
}

/// Native replacement for the former scene-root modifier stack. It owns the
/// actual content controller, applies the global appearance to the UIWindow,
/// mounts the app-lock veil above every responder, receives multiplex URLs,
/// and raises the singleton deck when queued external work has no executor.
@MainActor
final class UIKitSceneRootViewController: UIViewController {
    private struct Snapshot {
        var appearance: AppAppearance
        var pendingSignal: Int
        var externalActionsHaveContext: Bool
    }

    let contentViewController: UIViewController

    private let themes: ThemeStore
    private let appLock: AppLockStore
    private let externalActions: ExternalActionRouter
    private let bind: BindController
    private let sceneWindows: SceneWindowRouting
    private let platformChrome: UIKitPlatformChromePolicy
    private let handlesExternalActions: Bool
    /// The UIKit equivalent of SwiftUI's `.windowStyle(.plain)`, which the
    /// visionOS terminal scene shipped with: the system glass container is
    /// hidden and this root paints nothing, so the content's own rounded
    /// chassis is the whole window. Deck scenes keep the glass platter.
    private let plainWindowBackground: Bool

    private var lockViewController: AppLockViewController?
    private var lockShieldWindow: UIWindow?
    private var appLockObserver: NSObjectProtocol?
    private var observationGeneration = 0
    private var lastHandledPendingSignal: Int

    #if DEBUG
    private static var autoActionFired = false
    #endif

    init(
        content: UIViewController,
        themes: ThemeStore,
        appLock: AppLockStore,
        externalActions: ExternalActionRouter,
        bind: BindController,
        sceneWindows: SceneWindowRouting,
        platformChrome: UIKitPlatformChromePolicy = .current,
        handlesExternalActions: Bool = true,
        plainWindowBackground: Bool = false
    ) {
        contentViewController = content
        self.themes = themes
        self.appLock = appLock
        self.externalActions = externalActions
        self.bind = bind
        self.sceneWindows = sceneWindows
        self.platformChrome = platformChrome
        self.handlesExternalActions = handlesExternalActions
        self.plainWindowBackground = plainWindowBackground
        lastHandledPendingSignal = externalActions.pendingSignal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = plainWindowBackground ? .clear : UIKitChassis.chassis
        #if os(visionOS)
        // The window resolves the container style from its root view
        // controller, which is this one. The preference is fixed at init, so
        // one request as the view loads under that window is enough.
        setNeedsUpdateOfPreferredContainerBackgroundStyle()
        #endif
        applyPlatformChrome()
        addChild(contentViewController)
        view.addSubview(contentViewController.view)
        contentViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentViewController.view.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            contentViewController.view.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            contentViewController.view.topAnchor.constraint(
                equalTo: view.topAnchor
            ),
            contentViewController.view.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            ),
        ])
        contentViewController.didMove(toParent: self)

        installAppLockObserver()
        applyLock(appLock.isLocked)
        observationGeneration &+= 1
        observeAndApply(generation: observationGeneration)
        submitAutoActionIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyAppearance(themes.appearance)
        if appLock.isLocked { ensureLockShield() }
        replayPendingExternalActionIfNeeded()
        // A request can arrive while this scene is connecting. Once there is
        // a real window, make the same no-context decision again.
        raiseDeckForPendingExternalActionIfNeeded(
            signal: externalActions.pendingSignal,
            hasContext: externalActions.hasContext
        )
    }

    #if os(visionOS)
    /// `.hidden` is what `.windowStyle(.plain)` compiled down to: the scene
    /// drops its glass container and only what the app draws is visible.
    /// `childViewControllerForPreferredContainerBackgroundStyle` stays nil,
    /// so no mounted content controller can hand the platter back.
    override var preferredContainerBackgroundStyle: UIContainerBackgroundStyle {
        plainWindowBackground ? .hidden : super.preferredContainerBackgroundStyle
    }
    #endif

    deinit {
        observationGeneration &+= 1
        if let appLockObserver {
            NotificationCenter.default.removeObserver(appLockObserver)
        }
    }

    /// Scene replacement/disconnection must release a shield window owned by
    /// this root without making a window that is itself leaving key again.
    func prepareForRemoval() {
        observationGeneration &+= 1
        if let appLockObserver {
            NotificationCenter.default.removeObserver(appLockObserver)
            self.appLockObserver = nil
        }
        removeLockShield(restorePrimaryKeyWindow: false)
    }

    /// UISceneDelegate forwards every URL here. Bind payloads are only staged
    /// for explicit confirmation; all other supported URLs join the external
    /// action queue. Returns whether Multiplex recognized the URL.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        if let payload = BindPayload(url: url) {
            bind.receive(payload: payload)
            if !bind.hasContext, sceneWindows.supportsMultipleWindows {
                sceneWindows.openDeck()
            }
            return true
        }
        guard let request = ExternalActionURL.request(from: url) else {
            return false
        }
        // The scheme is public: anything that can ask iOS to open a URL can
        // reach this, prompt and all. Only a link carrying this install's own
        // widget token runs silently; the rest is confirmed in-app first.
        externalActions.submit(
            request.action,
            trusted: ExternalActionTrust.isTrusted(
                token: request.token,
                expected: SharedStateStore.linkToken()
            )
        )
        return true
    }

    private func observeAndApply(generation: Int) {
        guard generation == observationGeneration else { return }
        let snapshot = withObservationTracking {
            Snapshot(
                appearance: themes.appearance,
                pendingSignal: externalActions.pendingSignal,
                externalActionsHaveContext: externalActions.hasContext
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAndApply(generation: generation)
            }
        }
        applyAppearance(snapshot.appearance)
        raiseDeckForPendingExternalActionIfNeeded(
            signal: snapshot.pendingSignal,
            hasContext: snapshot.externalActionsHaveContext
        )
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        let style = appearance.interfaceStyle
        overrideUserInterfaceStyle = style
        viewIfLoaded?.window?.overrideUserInterfaceStyle = style
        lockShieldWindow?.overrideUserInterfaceStyle = style
        lockViewController?.overrideUserInterfaceStyle = style
        if platformChrome.appliesSignalTint {
            viewIfLoaded?.window?.tintColor = TallyPalette.signal
            lockShieldWindow?.tintColor = TallyPalette.signal
        }
    }

    private func applyPlatformChrome() {
        if platformChrome.appliesSignalTint {
            view.tintColor = TallyPalette.signal
        }
        if let category = platformChrome.preferredContentSizeCategory {
            traitOverrides.preferredContentSizeCategory = category
        }
    }

    private func applyLock(_ isLocked: Bool) {
        propagateAppLock(isLocked, through: contentViewController)
        contentViewController.view.isUserInteractionEnabled = !isLocked
        guard isLocked else {
            removeLockShield(restorePrimaryKeyWindow: true)
            return
        }
        ensureLockShield()
    }

    private func propagateAppLock(
        _ locked: Bool,
        through controller: UIViewController
    ) {
        (controller as? UIKitAppLockControlling)?.setAppLocked(locked)
        for child in controller.children {
            propagateAppLock(locked, through: child)
        }
    }

    private func installAppLockObserver() {
        guard appLockObserver == nil else { return }
        appLockObserver = NotificationCenter.default.addObserver(
            forName: AppLockStore.stateDidChangeNotification,
            object: appLock,
            queue: nil
        ) { [weak self, weak appLock] _ in
            MainActor.assumeIsolated {
                guard let self, let appLock else { return }
                self.applyLock(appLock.isLocked)
            }
        }
    }

    /// A child overlay cannot cover a UIKit sheet because presentations live
    /// above the presenting controller's view. Once this root belongs to a
    /// real scene, promote the veil into an opaque scene-scoped UIWindow above
    /// the alert level. Existing sheets remain intact underneath it and resume
    /// at the same navigation/editor state after unlock.
    private func ensureLockShield() {
        guard appLock.isLocked else { return }
        let controller = lockViewController ?? AppLockViewController(lock: appLock)
        lockViewController = controller
        if let category = platformChrome.preferredContentSizeCategory {
            controller.traitOverrides.preferredContentSizeCategory = category
        }

        guard let primaryWindow = viewIfLoaded?.window,
              let windowScene = primaryWindow.windowScene
        else {
            // The inline fallback shares the primary window; disabling that
            // window would also disable its own UNLOCK control.
            viewIfLoaded?.window?.isUserInteractionEnabled = true
            installInlineLockShieldIfNeeded(controller)
            return
        }
        primaryWindow.isUserInteractionEnabled = false
        if let lockShieldWindow {
            lockShieldWindow.isHidden = false
            if !lockShieldWindow.isKeyWindow { lockShieldWindow.makeKey() }
            return
        }

        detachInlineLockShield(controller)
        let shield = UIWindow(windowScene: windowScene)
        shield.frame = windowScene.coordinateSpace.bounds
        shield.windowLevel = .alert + 1
        shield.backgroundColor = TallyPalette.chassis
        shield.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        if platformChrome.appliesSignalTint {
            shield.tintColor = TallyPalette.signal
        }
        shield.rootViewController = controller
        lockShieldWindow = shield
        shield.makeKeyAndVisible()
    }

    private func installInlineLockShieldIfNeeded(
        _ controller: AppLockViewController
    ) {
        guard controller.parent == nil, lockShieldWindow == nil else { return }
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    private func detachInlineLockShield(_ controller: AppLockViewController) {
        guard controller.parent != nil else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func removeLockShield(restorePrimaryKeyWindow: Bool) {
        guard let controller = lockViewController else {
            viewIfLoaded?.window?.isUserInteractionEnabled = restorePrimaryKeyWindow
                ? true
                : !appLock.isLocked
            return
        }
        let primaryWindow = viewIfLoaded?.window
        controller.prepareForRemoval()
        if let shield = lockShieldWindow {
            shield.isHidden = true
            shield.rootViewController = nil
            lockShieldWindow = nil
        } else {
            detachInlineLockShield(controller)
        }
        lockViewController = nil
        primaryWindow?.isUserInteractionEnabled = restorePrimaryKeyWindow
            ? true
            : !appLock.isLocked
        if restorePrimaryKeyWindow {
            primaryWindow?.makeKey()
        }
    }

    private func raiseDeckForPendingExternalActionIfNeeded(
        signal: Int,
        hasContext: Bool
    ) {
        guard handlesExternalActions else { return }
        guard signal != lastHandledPendingSignal else { return }
        lastHandledPendingSignal = signal
        guard !hasContext, sceneWindows.supportsMultipleWindows else { return }
        sceneWindows.openDeck()
    }

    private func replayPendingExternalActionIfNeeded() {
        guard handlesExternalActions,
              externalActions.hasPendingActions,
              !externalActions.hasContext,
              sceneWindows.supportsMultipleWindows
        else { return }
        sceneWindows.openDeck()
    }

    #if DEBUG
    /// Appends this install's widget-link token unless the URL already
    /// carries one (see `submitAutoActionIfNeeded`).
    static func tokenized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = SharedStateStore.linkToken(),
              !(components.queryItems ?? []).contains(where: {
                  $0.name == WidgetLink.tokenItemName
              })
        else { return url }
        components.queryItems = (components.queryItems ?? [])
            + [URLQueryItem(name: WidgetLink.tokenItemName, value: token)]
        return components.url ?? url
    }
    #endif

    private func submitAutoActionIfNeeded() {
        #if DEBUG
        guard handlesExternalActions,
              !Self.autoActionFired,
              let raw = ProcessInfo.processInfo.environment[
                "MULTIPLEX_AUTO_ACTION_URL"
              ],
              let url = URL(string: raw)
        else { return }
        Self.autoActionFired = true
        // Stand-in for a widget tap, so it carries the widget's token and
        // rides the trusted path — the same seam, no confirmation alert
        // parked in front of a headless run.
        _ = receive(Self.tokenized(url))
        #endif
    }
}
