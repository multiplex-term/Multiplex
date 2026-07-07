import SwiftTerm
import UIKit

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
            current?.resignFirstResponder()
            if let scene = view.window?.windowScene {
                UIApplication.shared.activateSceneSession(
                    for: UISceneSessionActivationRequest(session: scene.session)
                )
            }
        }
        current = view
        view.window?.makeKey()
        if !view.isFirstResponder {
            view.becomeFirstResponder()
        }
    }

    /// Explicit user request for the keyboard (tap or keyboard button):
    /// also recovers from "dismissed while still first responder", where a
    /// plain becomeFirstResponder is a no-op and the keyboard never returns.
    static func summon(_ view: TerminalView) {
        installObserversIfNeeded()
        if current === view, view.isFirstResponder, !keyboardVisible {
            view.resignFirstResponder()
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
            MainActor.assumeIsolated { keyboardVisible = true }
        }
        center.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { keyboardVisible = false }
        }
    }
}
