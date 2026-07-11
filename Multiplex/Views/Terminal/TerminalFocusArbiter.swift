import SwiftTerm
import UIKit
#if DEBUG
import notify
#endif

/// Exactly one terminal holds keyboard focus at a time, app-wide.
///
/// Every visionOS window is its own scene, permanently scene-active and key
/// within itself — so per-window `makeKey()`/first-responder juggling can't
/// move input between windows, and multiple live first responders leave the
/// system keyboard and hardware keys bound to whichever input session came
/// first. Routing every focus change through this arbiter keeps a single
/// input session alive: claim resigns the previous terminal and activates
/// the claimed terminal's scene session.
@MainActor
enum TerminalFocusArbiter {
    private(set) static weak var current: TerminalView?
    private static var keyboardVisible = false
    private static var observersInstalled = false

    /// Below this, a "shown keyboard" is just the accessory row that
    /// hardware-keyboard mode docks at the scene bottom (~48–55 pt) — not a
    /// keyboard the user can type on. The real panel is ≥300 pt.
    private static let minRealKeyboardHeight: CGFloat = 100

    /// Move keyboard focus to this terminal. No-op if it already has it.
    static func claim(_ view: TerminalView) {
        installObserversIfNeeded()
        let switching = current !== view
        if switching {
            _ = current?.resignFirstResponder()
            if let scene = view.window?.windowScene {
                UIApplication.shared.activateSceneSession(
                    for: UISceneSessionActivationRequest(session: scene.session)
                )
            }
        }
        current = view
        view.window?.makeKey()
        if !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        }
    }

    /// Explicit user request for the keyboard (tap or keyboard button).
    ///
    /// If the terminal already has focus but no real keyboard is on screen —
    /// dismissed while still first responder, or suppressed because the OS
    /// believed a hardware keyboard was available — a plain
    /// becomeFirstResponder is a no-op. Tearing the input session down and
    /// rebuilding it one runloop turn later makes UIKit re-evaluate what to
    /// present against the *current* hardware-keyboard state (resign+become
    /// within one turn can be coalesced into "nothing changed").
    ///
    /// `force` skips the keyboard-visibility check: the keyboard *button*
    /// always rebuilds, because in hardware-keyboard mode the OS reports a
    /// tall "shown" keyboard frame while rendering only the accessory row —
    /// visibility tracking can't tell that apart from a usable keyboard.
    /// Terminal taps stay unforced so tapping while typing never blips the
    /// keyboard away.
    static func summon(_ view: TerminalView, force: Bool = false) {
        installObserversIfNeeded()
        if current === view, view.isFirstResponder, force || !keyboardVisible {
            _ = view.resignFirstResponder()
            DispatchQueue.main.async {
                claim(view)
                view.reloadInputViews()
            }
            return
        }
        claim(view)
    }

    private static func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIResponder.keyboardDidShowNotification,
            object: nil,
            queue: .main
        ) { notification in
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated {
                keyboardVisible = (frame?.height ?? 0) >= minRealKeyboardHeight
            }
        }
        center.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { keyboardVisible = false }
        }
        #if DEBUG
        installDebugSummonHook()
        #endif
    }

    #if DEBUG
    /// Headless-verification hook: pressing the keyboard button from the CLI —
    /// `xcrun simctl spawn <udid> notifyutil -p tools.bricks.multiplex.debug.summon`
    /// — drives the same path as the in-window "Show keyboard" button.
    private static func installDebugSummonHook() {
        var token: Int32 = 0
        notify_register_dispatch(
            "tools.bricks.multiplex.debug.summon", &token, .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let view = current else { return }
                if view.inputView != nil {
                    view.inputView = nil
                    view.reloadInputViews()
                }
                summon(view, force: true)
            }
        }
        installDebugScrollHooks()
    }

    /// Headless-verification hooks: `… -p tools.bricks.multiplex.debug.scrollup`
    /// (or `.scrolldown`) delivers one scroll tick to the focused terminal —
    /// the same remote path a pan takes (wheel report with mouse tracking on,
    /// alternate-screen cursor key otherwise).
    private static func installDebugScrollHooks() {
        var upToken: Int32 = 0
        notify_register_dispatch(
            "tools.bricks.multiplex.debug.scrollup", &upToken, .main
        ) { _ in
            MainActor.assumeIsolated {
                current?.performRemoteScroll(ticks: 1)
            }
        }
        var downToken: Int32 = 0
        notify_register_dispatch(
            "tools.bricks.multiplex.debug.scrolldown", &downToken, .main
        ) { _ in
            MainActor.assumeIsolated {
                current?.performRemoteScroll(ticks: -1)
            }
        }
    }
    #endif
}
