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
                keyboardVisible = (frame?.height ?? 0) >= KeyboardAvoidance.minRealKeyboardHeight
            }
        }
        center.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { keyboardVisible = false }
        }
        #if !os(visionOS)
        // Floating/undocked keyboards never post didShow/didHide — only
        // frame changes. Without these, `keyboardVisible` stays false while
        // a floating pill is up, so every terminal tap runs the resign+
        // rebuild branch below: the pill blinks away and iPadOS may not
        // re-present it until the app is reactivated. Visibility is pure
        // geometry (`KeyboardAvoidance.isPresented`), so both directions —
        // pill appearing, pill flicked away — track from the same frames.
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification] {
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                      notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool != false
                else { return }
                MainActor.assumeIsolated {
                    guard let screen = current?.window?.screen.bounds else { return }
                    keyboardVisible = KeyboardAvoidance.isPresented(keyboard: frame, screen: screen)
                }
            }
        }
        #endif
        #if DEBUG
        installDebugSummonHook()
        #endif
    }

    #if DEBUG
    /// Headless-verification hook: pressing the keyboard button from the CLI —
    /// `xcrun simctl spawn <udid> notifyutil -p app.multiplexterm.multiplex.debug.summon`
    /// — drives the same path as the in-window "Show keyboard" button.
    private static func installDebugSummonHook() {
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.summon", &token, .main
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
        installDebugDismissHook()
        installDebugScrollHooks()
    }

    /// Headless-capture hook: `… -p app.multiplexterm.multiplex.debug.dismiss`
    /// resigns the focused terminal — the only way to hide the system
    /// keyboard in a screenshot run (the simulator can't tap the dismiss
    /// affordance).
    private static func installDebugDismissHook() {
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.dismiss", &token, .main
        ) { _ in
            MainActor.assumeIsolated {
                _ = current?.resignFirstResponder()
            }
        }
    }

    /// Headless-verification hooks: `… -p app.multiplexterm.multiplex.debug.scrollup`
    /// (or `.scrolldown`) delivers one scroll tick to the focused terminal —
    /// the same remote path a pan takes (wheel report with mouse tracking on,
    /// alternate-screen cursor key otherwise).
    private static func installDebugScrollHooks() {
        var upToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.scrollup", &upToken, .main
        ) { _ in
            MainActor.assumeIsolated {
                current?.performRemoteScroll(ticks: 1)
            }
        }
        var downToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.scrolldown", &downToken, .main
        ) { _ in
            MainActor.assumeIsolated {
                current?.performRemoteScroll(ticks: -1)
            }
        }
        #if !os(visionOS)
        installDebugKeyboardHooks()
        #endif
    }

    #if !os(visionOS)
    /// Headless keyboard-geometry reproduction: posts the same
    /// NotificationCenter keyboard-frame notifications UIKit would.
    /// Drives the app's own keyboard handling (`SwiftTermView`) only —
    /// SwiftUI's automatic avoidance tracks the real keyboard internally
    /// and ignores these, which is fine now that the terminal window opts
    /// out of it. `….debug.kbd.float` = undocked pill mid-screen,
    /// `….debug.kbd.dock` = full-width docked panel, `….debug.kbd.hide`.
    /// visionOS has no window-anchored keyboard (and no `UIWindow.screen`).
    private static func installDebugKeyboardHooks() {
        func post(_ name: Notification.Name, endFrame: CGRect, screen: CGRect) {
            NotificationCenter.default.post(
                name: name,
                object: nil,
                userInfo: [
                    UIResponder.keyboardFrameBeginUserInfoKey: CGRect(
                        x: 0, y: screen.maxY, width: screen.width, height: 346),
                    UIResponder.keyboardFrameEndUserInfoKey: endFrame,
                    UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
                    UIResponder.keyboardAnimationCurveUserInfoKey: 7,
                    UIResponder.keyboardIsLocalUserInfoKey: true,
                ]
            )
        }
        var floatToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.kbd.float", &floatToken, .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let screen = current?.window?.screen.bounds else { return }
                let pill = CGRect(x: screen.midX - 160, y: screen.maxY - 500, width: 320, height: 254)
                post(UIResponder.keyboardWillChangeFrameNotification, endFrame: pill, screen: screen)
            }
        }
        var dockToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.kbd.dock", &dockToken, .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let screen = current?.window?.screen.bounds else { return }
                let panel = CGRect(x: 0, y: screen.maxY - 346, width: screen.width, height: 346)
                post(UIResponder.keyboardWillChangeFrameNotification, endFrame: panel, screen: screen)
            }
        }
        var hideToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.kbd.hide", &hideToken, .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let screen = current?.window?.screen.bounds else { return }
                let gone = CGRect(x: 0, y: screen.maxY, width: screen.width, height: 346)
                post(UIResponder.keyboardWillHideNotification, endFrame: gone, screen: screen)
            }
        }
    }
    #endif
    #endif
}
