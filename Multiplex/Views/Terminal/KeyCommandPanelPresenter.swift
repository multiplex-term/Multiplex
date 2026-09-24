import SwiftTerm
import UIKit

/// What the plan lets CUSTOM SETUP hold — the free tier's cap and the route
/// past it. The window that owns the entitlement store builds it; the iPad
/// rail and the visionOS cluster only carry it to the presenter, so neither
/// learns about Pro.
struct KeyCommandPlan {
    /// Commands the set may hold before ADD COMMAND turns into the Pro
    /// route (`KeyCommandSet.maximumCount` once Pro).
    var limit: Int
    /// Opens the paywall; nil when the plan already holds the full cap.
    var upgrade: (() -> Void)?

    /// The full cap and no route — Pro, tests, and the DEBUG hooks.
    static let unrestricted = KeyCommandPlan(limit: KeyCommandSet.maximumCount, upgrade: nil)
}

/// The one owner of a KEY COMMANDS popover's lifecycle, shared by the iPad
/// rail (`TerminalKeyBar`) and the visionOS cluster
/// (`TerminalKeyClusterGroupView`): builds the panel over the shared store,
/// dispatches presses through the terminal, anchors the popover to the CTRL
/// key, and hands the keyboard back on dismissal only if one of the panel's
/// own fields took it. The hosts keep just their anchor, their terminal, and
/// their appearance step.
@MainActor
final class KeyCommandPanelPresenter: NSObject, UIPopoverPresentationControllerDelegate {
    private(set) weak var panel: KeyCommandPanelViewController?
    private weak var terminal: TerminalView?
    /// Whether the terminal owned the keyboard when the panel opened.
    private var resumesFocus = false

    var isPresented: Bool { panel != nil }

    /// - Parameters:
    ///   - host: the presenting view controller.
    ///   - anchor: the CTRL key the popover points at.
    ///   - maximumWidth: the popover's ceiling (scene width less margins).
    ///   - plan: the tier's cap and paywall route. The route runs only after
    ///     this popover is down — the paywall is a sheet from the window, and
    ///     one presentation must end before the next begins.
    ///   - feedback: the host's press feedback (the rail's input click).
    ///   - configure: the host's appearance step — panel ground, popover
    ///     ground, appearance / glass mirroring — after the view loads and
    ///     before presentation.
    func present(
        from host: UIViewController,
        anchor: UIView,
        terminal: TerminalView,
        maximumWidth: CGFloat,
        plan: KeyCommandPlan = .unrestricted,
        feedback: (() -> Void)? = nil,
        configure: (KeyCommandPanelViewController, UIPopoverPresentationController) -> Void
    ) {
        guard panel == nil else { return }
        self.terminal = terminal
        let panel = KeyCommandPanelViewController(
            store: KeyCommandStore.shared,
            terminal: terminal,
            maximumWidth: maximumWidth,
            plan: KeyCommandPlan(
                limit: plan.limit,
                upgrade: plan.upgrade.map { route in
                    { [weak self] in self?.dismiss(then: route) }
                }
            ),
            perform: { [weak terminal] command in
                feedback?()
                guard let terminal else { return }
                KeyCommandDispatcher.perform(command, on: terminal)
            },
            dismiss: { [weak self] in self?.dismiss() }
        )
        self.panel = panel
        resumesFocus = terminal.isFirstResponder
        panel.modalPresentationStyle = .popover
        // Loading sizes the panel (`preferredContentSize` is set as the
        // content is built), so no second measure here.
        panel.loadViewIfNeeded()
        if let popover = panel.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
            popover.permittedArrowDirections = .down
            popover.delegate = self
            configure(panel, popover)
        }
        host.present(panel, animated: true)
        // Labels built before the window attach can retain ink resolved
        // against the wrong traits; re-resolve once trait delivery settles.
        panel.refreshDynamicTextColorsAfterTraitPropagation()
        Task { await KeyCommandStore.shared.refreshFromCloud() }
    }

    /// - Parameter completion: runs once the popover is down and focus is
    ///   settled — the plan's paywall route rides here.
    func dismiss(then completion: (() -> Void)? = nil) {
        guard let panel else {
            completion?()
            return
        }
        self.panel = nil
        panel.prepareForRemoval()
        panel.dismiss(animated: true) { [weak self] in
            self?.resumeFocusIfNeeded()
            completion?()
        }
    }

    /// A composer field that took the keyboard hands it back; a panel that
    /// never touched focus leaves the terminal exactly as it was.
    private func resumeFocusIfNeeded() {
        guard resumesFocus, let terminal else { return }
        resumesFocus = false
        guard TerminalFocusArbiter.current === terminal, !terminal.isFirstResponder else { return }
        TerminalFocusArbiter.resumeAfterPresentation(terminal)
    }

    // MARK: UIPopoverPresentationControllerDelegate

    func adaptivePresentationStyle(
        for controller: UIPresentationController
    ) -> UIModalPresentationStyle { .none }

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle { .none }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let panel, presentationController.presentedViewController === panel else { return }
        self.panel = nil
        panel.prepareForRemoval()
        resumeFocusIfNeeded()
    }
}
