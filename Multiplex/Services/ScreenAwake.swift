import UIKit

/// The keep-screen-on opt-in (Settings → Screen). Default off: holding the
/// display awake costs battery, so it is the user's call. Device-local, never
/// synced — whether a phone on a stand should stay lit is per device.
/// `ScreenAwakeCenter` is the only writer, so its hold stays in step.
enum KeepScreenOnSetting {
    static let key = "MultiplexKeepScreenOn"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// Holds the display awake (`isIdleTimerDisabled`, which is app-wide) while
/// Keep screen on is enabled and some surface reports a terminal or the file
/// viewer on screen in a foreground scene. The deck alone lets the device
/// sleep as usual: it is a monitor wall, and attention alerts cover it.
///
/// Surfaces report through `setShowing(_:owner:view:)`; the view is held
/// weakly and only counts while it sits in a window whose scene is not in the
/// background, so an iPad terminal window shelved behind the deck stops
/// holding the screen without having to say so.
@MainActor
final class ScreenAwakeCenter {
    static let shared = ScreenAwakeCenter()

    private struct Surface {
        weak var view: UIView?
    }

    private let defaults: UserDefaults
    private let apply: (Bool) -> Void
    private var surfaces: [ObjectIdentifier: Surface] = [:]
    private var observers: [NSObjectProtocol] = []
    private(set) var isEnabled: Bool
    private(set) var isHoldingAwake = false

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        apply: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }
    ) {
        self.defaults = defaults
        self.apply = apply
        isEnabled = KeepScreenOnSetting.isEnabled(defaults: defaults)
        let names: [Notification.Name] = [
            UIScene.willEnterForegroundNotification,
            UIScene.didActivateNotification,
            UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification,
        ]
        observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        KeepScreenOnSetting.setEnabled(enabled, defaults: defaults)
        isEnabled = enabled
        reconcile()
    }

    func setShowing(_ showing: Bool, owner: AnyObject, view: UIView) {
        let id = ObjectIdentifier(owner)
        if showing {
            surfaces[id] = Surface(view: view)
        } else {
            surfaces[id] = nil
        }
        reconcile()
    }

    private func reconcile() {
        surfaces = surfaces.filter { $0.value.view != nil }
        let hold = isEnabled && surfaces.values.contains { surface in
            guard let view = surface.view else { return false }
            return Self.isOnScreen(view)
        }
        guard hold != isHoldingAwake else { return }
        isHoldingAwake = hold
        apply(hold)
    }

    /// A window with no scene (a unit test's) counts as on screen.
    private static func isOnScreen(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        guard let scene = window.windowScene else { return true }
        switch scene.activationState {
        case .foregroundActive, .foregroundInactive: return true
        default: return false
        }
    }
}
