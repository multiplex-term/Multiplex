import UIKit

/// Native owner of the external-action execution context and its two pieces
/// of presentation UI. A deck/shell controller attaches it while mounted;
/// queued widget/App-Intent work then drains through the same opener as the
/// wall.
@MainActor
final class ExternalActionUIKitCoordinator: NSObject,
    UIAdaptivePresentationControllerDelegate
{
    private weak var presenter: UIViewController?
    private let store: HostStore
    private let hub: ConnectionHub
    private let workspace: TerminalWorkspace
    private let router: ExternalActionRouter
    private let themes: ThemeStore
    private let terminalOpener: TerminalRouteOpener
    private let sceneWindows: SceneWindowRouting

    private var contextToken: UUID?
    private weak var ownedPresentation: UIViewController?
    private var pendingPrompt: AgentPromptRequest?
    private var pendingFailure: ExternalActionFailure?
    private var appLocked = false
    var presentationDidEnd: (() -> Void)?

    init(
        presenter: UIViewController,
        store: HostStore,
        hub: ConnectionHub,
        workspace: TerminalWorkspace,
        router: ExternalActionRouter,
        themes: ThemeStore,
        terminalOpener: TerminalRouteOpener,
        sceneWindows: SceneWindowRouting
    ) {
        self.presenter = presenter
        self.store = store
        self.hub = hub
        self.workspace = workspace
        self.router = router
        self.themes = themes
        self.terminalOpener = terminalOpener
        self.sceneWindows = sceneWindows
        super.init()
    }

    func attach() {
        guard contextToken == nil else { return }
        contextToken = router.attach(.init(
            store: store,
            hub: hub,
            workspace: workspace,
            open: { [terminalOpener] in terminalOpener($0) },
            presentAgentPrompt: { [weak self] in self?.receivePrompt($0) },
            presentFailure: { [weak self] in self?.receiveFailure($0) }
        ))
    }

    func detach() {
        if let contextToken {
            router.detach(contextToken)
            self.contextToken = nil
        }
        pendingPrompt = nil
        pendingFailure = nil
        if let ownedPresentation, ownedPresentation.presentingViewController != nil {
            ownedPresentation.dismiss(animated: false)
        }
        self.ownedPresentation = nil
    }

    func receivePrompt(_ request: AgentPromptRequest) {
        pendingPrompt = request
        revealClassicDeck()
        presentNextIfPossible()
    }

    func receiveFailure(_ failure: ExternalActionFailure) {
        pendingFailure = failure
        revealClassicDeck()
        presentNextIfPossible()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        ownedPresentation = nil
        presentNextIfPossible()
        presentationDidEnd?()
    }

    /// A presenter can temporarily belong to another native deck sheet
    /// (Settings, Add Host, FAQ). The external action remains queued here;
    /// the deck calls this when its own presentation clears so ASK/failure UI
    /// cannot remain stranded until another router event arrives.
    func presenterDidBecomeAvailable() {
        presentNextIfPossible()
    }

    func setAppLocked(_ locked: Bool) {
        guard appLocked != locked else { return }
        appLocked = locked
        if !locked { presentNextIfPossible() }
    }

    /// Kept separate from `present(_:)` so the exact alert contract remains
    /// testable on visionOS, where a unit-test `UIWindow` has no connected
    /// `UIWindowScene` and UIKit intentionally refuses modal presentation.
    static func makeFailureAlert(
        _ failure: ExternalActionFailure,
        acknowledged: @escaping () -> Void
    ) -> UIAlertController {
        let alert = UIAlertController(
            title: "Can't Open \(failure.hostName)",
            message: failure.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in
            acknowledged()
        })
        return alert
    }

    private func presentNextIfPossible() {
        guard !appLocked,
              ownedPresentation == nil,
              let presenter,
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil
        else { return }

        if let request = pendingPrompt {
            pendingPrompt = nil
            let prompt = AgentPromptSheetViewController(
                request: request,
                submit: { [weak router] action in router?.submit(action) }
            )
            prompt.followAppAppearance(themes)
            let navigation = UINavigationController(rootViewController: prompt)
            navigation.navigationBar.prefersLargeTitles = false
            navigation.view.backgroundColor = UIKitChassis.chassis
            UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
            navigation.presentationController?.delegate = self
            prompt.onDismiss = { [weak self, weak navigation] in
                navigation?.dismiss(animated: true) {
                    self?.ownedPresentation = nil
                    self?.presentNextIfPossible()
                    self?.presentationDidEnd?()
                }
            }
            ownedPresentation = navigation
            presenter.present(navigation, animated: true)
            navigation.presentationController?.delegate = self
            return
        }

        if let failure = pendingFailure {
            pendingFailure = nil
            let alert = Self.makeFailureAlert(failure) { [weak self] in
                self?.ownedPresentation = nil
                self?.presentNextIfPossible()
                self?.presentationDidEnd?()
            }
            ownedPresentation = alert
            presenter.present(alert, animated: true)
        }
    }

    private func revealClassicDeck() {
        guard terminalOpener.destination == .window,
              sceneWindows.supportsMultipleWindows
        else { return }
        sceneWindows.openDeck()
    }
}
