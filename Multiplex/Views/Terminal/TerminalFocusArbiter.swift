import SwiftTerm
import UIKit
#if DEBUG
import notify
import os
#endif

/// Exactly one terminal holds keyboard focus at a time, app-wide.
///
/// Every visionOS window is its own scene, permanently scene-active and key
/// within itself — so per-window `makeKey()`/first-responder juggling can't
/// move input between windows, and multiple live first responders leave the
/// system keyboard and hardware keys bound to whichever input session came
/// first. Routing every focus change through this arbiter keeps a single
/// input session alive: claim resigns the previous terminal and, on visionOS,
/// activates the claimed terminal's scene session. On iPadOS the user's tap
/// has already activated its Stage Manager window; requesting activation
/// again can make the system re-place that existing window.
@MainActor
enum TerminalFocusArbiter {
    private(set) static weak var current: TerminalView?
    private static var keyboardVisible = false
    private static var observersInstalled = false

    #if DEBUG
    private static let keyboardLogger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "kbd"
    )
    #endif

    /// Move keyboard focus to this terminal. No-op if it already has it.
    static func claim(_ view: TerminalView) {
        installObserversIfNeeded()
        // Stage Manager can transiently clear `isKeyWindow` while the user
        // moves that very window. The terminal still owns the live input
        // session and remains first responder during that transition. Do not
        // call `makeKey()` to "repair" it: that feeds back into UIKit's
        // keyboard host, reactivating and laying out the floating keyboard on
        // every window move. The user's window interaction restores key state.
        if current === view, view.isFirstResponder {
            #if DEBUG
            if view.window?.isKeyWindow == false {
                keyboardLogger.debug("kbd-focus-preserved transientNonKey=true")
            }
            #endif
            return
        }
        let switching = current !== view
        #if DEBUG
        keyboardLogger.debug(
            "kbd-focus-claim switching=\(switching, privacy: .public) key=\(view.window?.isKeyWindow == true, privacy: .public) responder=\(view.isFirstResponder, privacy: .public)"
        )
        #endif
        if switching {
            _ = current?.resignFirstResponder()
            #if os(visionOS)
            if let scene = view.window?.windowScene {
                UIApplication.shared.activateSceneSession(
                    for: UISceneSessionActivationRequest(session: scene.session)
                )
            }
            #endif
        }
        current = view
        if let window = view.window, !window.isKeyWindow {
            window.makeKey()
        }
        if !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        }
    }

    /// Explicit user request for the keyboard (tap or keyboard button).
    ///
    /// If the terminal already has focus but no input UI is on screen —
    /// dismissed while still first responder, or suppressed because the OS
    /// believed a hardware keyboard was available — a plain
    /// becomeFirstResponder is a no-op. Tearing the input session down and
    /// rebuilding it one runloop turn later makes UIKit re-evaluate what to
    /// present against the *current* hardware-keyboard state (resign+become
    /// within one turn can be coalesced into "nothing changed").
    ///
    /// `force` skips the keyboard-visibility check: the keyboard *button*
    /// always asks UIKit to re-evaluate software-keyboard presentation.
    /// Terminal taps stay unforced so a visible floating keyboard never
    /// blips; the app-owned key rail remains independent of this lifecycle.
    static func summon(_ view: TerminalView, force: Bool = false) {
        installObserversIfNeeded()
        if current === view, view.isFirstResponder, force || !keyboardVisible {
            #if DEBUG
            keyboardLogger.debug(
                "kbd-focus-rebuild force=\(force, privacy: .public) visible=\(keyboardVisible, privacy: .public)"
            )
            #endif
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
        ) { _ in
            MainActor.assumeIsolated {
                keyboardVisible = true
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
        // Floating/undocked keyboards can communicate presentation only via
        // frame changes. A typable frame marks the input session visible, but
        // Stage Manager can replace it temporarily with a zero-height frame.
        // That geometry is ambiguous and must preserve the previous state;
        // otherwise the next terminal tap runs the resign+rebuild branch and
        // makes the floating keyboard blink away.
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
                    guard let view = current,
                          let screen = view.window?.screen.bounds
                    else { return }
                    if let update = KeyboardAvoidance.visibilityUpdate(
                        keyboard: frame,
                        screen: screen
                    ) {
                        keyboardVisible = update == .shown
                    }
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
    /// `….debug.kbd.move` = Stage Manager's zero-height move sequence plus
    /// an ordinary terminal tap, `….debug.kbd.dock` = full-width docked
    /// panel, `….debug.kbd.hide`.
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
                // Stage Manager's window-move hot path repeatedly emits the
                // did-change notification for an already-floating keyboard.
                post(UIResponder.keyboardDidChangeFrameNotification, endFrame: pill, screen: screen)
            }
        }
        var moveToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.kbd.move", &moveToken, .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let view = current,
                      let window = view.window
                else { return }
                let screen = window.screen.bounds
                let flat = CGRect(
                    x: screen.minX,
                    y: screen.maxY,
                    width: screen.width,
                    height: 0
                )
                post(UIResponder.keyboardWillChangeFrameNotification, endFrame: flat, screen: screen)
                post(UIResponder.keyboardWillHideNotification, endFrame: flat, screen: screen)
                post(UIResponder.keyboardDidChangeFrameNotification, endFrame: flat, screen: screen)
                summon(view)
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
