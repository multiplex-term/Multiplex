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
/// App-wide keyboard-lock state, observable by the key rail's lock face and
/// the pane's LOCKED badge. Only `TerminalFocusArbiter` writes it.
@Observable @MainActor
final class KeyboardLock {
    static let shared = KeyboardLock()
    fileprivate(set) var isLocked = false
}

/// A zero-size custom input view: while the keyboard is locked, the focused
/// terminal keeps its live input session (rail keys, hardware keys) but
/// UIKit has nothing to present, so taps cannot raise the software keyboard.
private final class LockedKeyboardInputView: UIView {}

@MainActor
enum TerminalFocusArbiter {
    private(set) static weak var current: TerminalView?
    /// An app-owned field that borrowed the keyboard from the current
    /// terminal (the Talkback composer's). Any claim resigns it first, so
    /// one input session stays live app-wide even across scenes.
    private static weak var borrower: UIView?
    private static var keyboardVisible = false
    private static var observersInstalled = false

    /// While the app lock veil covers every scene, no terminal may hold or
    /// acquire the app-wide input session: an overlay does not stop
    /// hardware keystrokes from reaching a first responder, and
    /// foregrounding restoration would otherwise re-summon one behind the
    /// veil. Setting this releases the current owner; `claim`/`restore`
    /// refuse while it holds. The native `AppLockViewController` is the only
    /// writer; its SwiftUI gate is merely a transitional mounting adapter.
    static var inputSuppressed = false {
        didSet {
            guard inputSuppressed, let owner = current else { return }
            release(owner)
        }
    }

    #if DEBUG
    private static let keyboardLogger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "kbd"
    )
    #endif

    /// Move keyboard focus to this terminal. No-op if it already has it.
    static func claim(_ view: TerminalView) {
        guard !inputSuppressed else { return }
        installObserversIfNeeded()
        // The borrower resigns only AFTER the terminal became first
        // responder: an explicit resign first dismisses and re-presents the
        // keyboard; letting `becomeFirstResponder` displace the field keeps
        // it up. A field in another window still needs the explicit resign.
        let lentField = borrower
        borrower = nil
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
            if let lentField, lentField.isFirstResponder {
                _ = lentField.resignFirstResponder()
            }
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
        // A newly claimed view must present the lock's suppression before it
        // becomes first responder; an unlocked claim also clears a stale
        // locked input view left on a tab that was focused while locked.
        applyLockState(to: view)
        if let window = view.window, !window.isKeyWindow {
            window.makeKey()
        }
        if !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        }
        if let lentField, lentField.isFirstResponder {
            _ = lentField.resignFirstResponder()
        }
    }

    /// Long press on the chrome's keyboard key: keep input alive but refuse
    /// to present the software keyboard until unlocked. Locking while the
    /// keyboard is up dismisses it.
    static func lock(_ view: TerminalView) {
        guard !KeyboardLock.shared.isLocked else { return }
        #if DEBUG
        keyboardLogger.debug("kbd-lock engaged")
        #endif
        KeyboardLock.shared.isLocked = true
        applyLockState(to: view)
        if let current, current !== view {
            applyLockState(to: current)
        }
    }

    /// Short press on the (locked) keyboard key: release the lock and ask
    /// for the keyboard — the press means "I want to type again". The
    /// Talkback key passes `summoning: false`: its own field is about to
    /// take the keyboard, and a deferred terminal summon would race it.
    static func unlock(_ view: TerminalView, summoning: Bool = true) {
        guard KeyboardLock.shared.isLocked else { return }
        #if DEBUG
        keyboardLogger.debug("kbd-lock released summoning=\(summoning, privacy: .public)")
        #endif
        KeyboardLock.shared.isLocked = false
        applyLockState(to: view)
        if let current, current !== view {
            applyLockState(to: current)
        }
        guard summoning else { return }
        summon(view, force: true)
    }

    private static func applyLockState(to view: TerminalView) {
        if KeyboardLock.shared.isLocked {
            guard !(view.inputView is LockedKeyboardInputView) else { return }
            view.inputView = LockedKeyboardInputView(frame: .zero)
            view.reloadInputViews()
        } else if view.inputView is LockedKeyboardInputView {
            view.inputView = nil
            view.reloadInputViews()
        }
    }

    /// Temporarily resign the current terminal while an app-owned overlay
    /// needs the keyboard's screen space. Ownership stays with this terminal,
    /// so dismissing the overlay can resume input without another window or
    /// tab stealing focus in between.
    @discardableResult
    static func suspendForPresentation(_ view: TerminalView) -> Bool {
        guard current === view, view.isFirstResponder else { return false }
        #if DEBUG
        keyboardLogger.debug("kbd-focus-suspend presentation=true")
        #endif
        _ = view.resignFirstResponder()
        return true
    }

    /// An app-owned field takes the keyboard while this terminal keeps
    /// ownership: the terminal steps down and the field's window is made
    /// key — UIKit resigns responders only within one window, and on
    /// visionOS the Talkback composer lives in the ornament's window while
    /// the terminal stays first responder in the scene's, where key events
    /// go. The next `claim` of ANY terminal resigns the borrower;
    /// `resumeAfterPresentation` hands the keyboard back on close.
    static func lend(_ view: TerminalView?, to field: UIView) {
        borrower = field
        if let view, view.isFirstResponder {
            #if DEBUG
            keyboardLogger.debug("kbd-focus-lend current=\(current === view, privacy: .public)")
            #endif
            _ = view.resignFirstResponder()
        }
        if let window = field.window, !window.isKeyWindow {
            window.makeKey()
        }
    }

    /// Resume a presentation-suspended terminal only if it still owns focus.
    /// A tab/window switch while the overlay was open must win.
    static func resumeAfterPresentation(_ view: TerminalView) {
        guard current === view else { return }
        claim(view)
    }

    /// Relinquish focus when an in-scene terminal stage navigates back to
    /// the deck. Only the current owner may release the app-wide input
    /// session; hidden/inactive tabs cannot disturb another terminal.
    static func release(_ view: TerminalView) {
        guard current === view else { return }
        #if DEBUG
        keyboardLogger.debug("kbd-focus-release")
        #endif
        _ = view.resignFirstResponder()
        current = nil
        keyboardVisible = false
    }

    /// Reassert a scene's prior focus only when its hosting surface is still
    /// visible. A compact single-window shell keeps TerminalView mounted behind
    /// its deck; UIKit can nevertheless restore that hidden responder while
    /// foregrounding. In the disallowed case, resign even if UIKit restored
    /// the responder after the arbiter owner had already been cleared.
    static func restore(_ view: TerminalView, allowed: Bool) {
        // A locked app treats every restoration as a hidden-stage refusal:
        // resign whatever UIKit brought back rather than merely ignoring it.
        let allowed = allowed && !inputSuppressed
        guard allowed else {
            #if DEBUG
            keyboardLogger.debug("kbd-focus-restore-refused hiddenStage=true")
            #endif
            _ = view.resignFirstResponder()
            if current === view {
                current = nil
                keyboardVisible = false
            } else if current == nil {
                keyboardVisible = false
            }
            return
        }
        // An empty ownership IS re-elected here, on purpose: the two ways the
        // app-wide owner goes nil have no other claim site. Releasing the app
        // lock's `inputSuppressed` cleared it, and closing the focused window
        // deallocated its TerminalView out of this weak reference — in both
        // cases the terminal the user is looking at would otherwise sit there
        // with no keyboard until they tap its grid.
        guard current === view || current == nil else { return }
        claim(view)
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
        // A locked keyboard still hands the tapped terminal the input
        // session (hardware keys, rail keys); presentation stays suppressed
        // by the locked input view, so skip the resign-and-rebuild dance.
        if KeyboardLock.shared.isLocked {
            claim(view)
            return
        }
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

    /// The chrome's keyboard key is a toggle: hide the keyboard this terminal
    /// is presenting, otherwise bring the normal system keyboard back — even
    /// if it was dismissed while the terminal stayed first responder, even if
    /// SwiftTerm's accessory toggled its F-key pad in as a custom input view
    /// (which otherwise sticks until toggled again), and even if the OS
    /// suppressed the software keyboard because a hardware keyboard was
    /// attached (the forced summon rebuilds the input session, re-checking
    /// that state).
    ///
    /// visionOS posts no keyboard show/hide notifications for its spatially
    /// separate keyboard, so the input session itself is the toggle's
    /// authority there: first responder means the keyboard is up.
    static func toggle(_ view: TerminalView) {
        installObserversIfNeeded()
        // While locked, the keyboard key's short press is the unlock.
        if KeyboardLock.shared.isLocked {
            unlock(view)
            return
        }
        #if os(visionOS)
        let presenting = current === view && view.isFirstResponder
        #else
        let presenting = current === view && view.isFirstResponder && keyboardVisible
        #endif
        if presenting {
            _ = view.resignFirstResponder()
            return
        }
        if view.inputView != nil {
            view.inputView = nil
            view.reloadInputViews()
        }
        summon(view, force: true)
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
        installDebugKeyboardLockHook()
        installDebugResizeDragHook()
    }

    /// Headless stand-in for the long-press-on-border resize drag (no
    /// headless route can synthesize a touch): `… -p
    /// app.multiplexterm.multiplex.debug.resizedrag` finds the first vertical
    /// divider glyph the focused terminal's drag filter claims, then drives
    /// the exact begin → motion → release path the gesture takes, dragging
    /// six columns right. Proof is host-side: the herdr split ratio moves
    /// (`herdr --session <name> pane layout`).
    private static func installDebugResizeDragHook() {
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.resizedrag", &token, .main
        ) { _ in
            MainActor.assumeIsolated {
                performDebugResizeDrag()
            }
        }
    }

    private static func performDebugResizeDrag() {
        guard let view = current, let filter = view.longPressMouseDragFilter else { return }
        let terminal = view.getTerminal()
        // herdr draws several vertical-bar columns (sidebar edge, pane
        // frames); the shared divider of a side-by-side split is the bar
        // column nearest the grid's horizontal center. Drag at that column's
        // median bar row.
        var rowsByColumn: [Int: [Int]] = [:]
        for row in 0..<terminal.rows {
            for col in 0..<terminal.cols {
                let content = terminal.getCharacter(col: col, row: row)
                if HerdrPaneBorder.isVerticalBar(content), filter((col, row), content) {
                    rowsByColumn[col, default: []].append(row)
                }
            }
        }
        guard let (column, rows) = rowsByColumn.min(by: {
            abs($0.key - terminal.cols / 2) < abs($1.key - terminal.cols / 2)
        }) else {
            keyboardLogger.debug("resizedrag no vertical bar found cols=\(terminal.cols) rows=\(terminal.rows)")
            return
        }
        let cell = (col: column, row: rows[rows.count / 2])
        let candidates = rowsByColumn.keys.sorted().map { "\($0)x\(rowsByColumn[$0]!.count)" }
            .joined(separator: ",")
        keyboardLogger.debug(
            "resizedrag grid=\(terminal.cols)x\(terminal.rows) candidates=\(candidates) chose=\(cell.col),\(cell.row)")
        Task { @MainActor in
            guard view.beginRemoteMouseDrag(at: view.pointForCell(col: cell.col, row: cell.row))
            else { return }
            for step in 1...6 {
                try? await Task.sleep(nanoseconds: 40_000_000)
                view.continueRemoteMouseDrag(
                    at: view.pointForCell(col: cell.col + step, row: cell.row))
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
            view.endRemoteMouseDrag(at: view.pointForCell(col: cell.col + 6, row: cell.row))
        }
    }

    /// Headless stand-in for the keyboard key's long press (no simulator
    /// route can hold a software key): `… -p
    /// app.multiplexterm.multiplex.debug.kbdlock` locks the focused
    /// terminal's keyboard, and posting it again unlocks — the same
    /// lock/unlock pair the rail key drives.
    private static func installDebugKeyboardLockHook() {
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.kbdlock", &token, .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let view = current else { return }
                if KeyboardLock.shared.isLocked {
                    unlock(view)
                } else {
                    lock(view)
                }
            }
        }
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
