import CoreGraphics

/// Decides whether a reported keyboard frame should displace the terminal.
///
/// Keyboard-frame notifications describe every presentation the same way,
/// but only a full software keyboard *docked* to the bottom of the screen
/// deserves an inset. A floating pill, a split keyboard, or a short/flat
/// system shortcut frame reserves nothing; Multiplex's key rail is normal
/// app chrome and isn't part of keyboard geometry.
/// Pure geometry so the docked call stays unit-tested.
enum KeyboardAvoidance {
    enum Presentation: Equatable {
        case hidden
        case floating
        case docked
        case shortcut
    }

    enum VisibilityUpdate: Equatable {
        case shown
        case hidden
    }

    /// All values in screen coordinates. `containerWidth` is the terminal
    /// container's on-screen width: the accessory bar tracks the window in
    /// windowed iPadOS, so a keyboard as wide as either the screen or the
    /// container counts as spanning; a floating pill is far narrower.
    static func isDocked(keyboard: CGRect, screen: CGRect, containerWidth: CGFloat) -> Bool {
        guard keyboard.width > 0, keyboard.height > 0 else { return false }
        let pinnedToBottom = keyboard.maxY >= screen.maxY - 2
        // A real docked software keyboard spans the screen. Only the short
        // accessory-only rail is allowed to match a Stage Manager window's
        // narrower width; otherwise a floating pill parked at the bottom of
        // a narrow window is misclassified as docked.
        let requiredWidth = keyboard.height >= minRealKeyboardHeight
            ? screen.width
            : min(screen.width, containerWidth)
        let spans = keyboard.width + 2 >= requiredWidth
        return pinnedToBottom && spans
    }

    /// Below this, a "shown keyboard" is just the accessory row that
    /// hardware-keyboard mode docks at the scene bottom (~48–55 pt) — not a
    /// keyboard the user can type on. The real panel is ≥300 pt.
    static let minRealKeyboardHeight: CGFloat = 100

    /// Whether a reported keyboard end frame is a keyboard the user can
    /// actually type on, on screen right now. Docked keyboards post
    /// did-show/did-hide, but floating/undocked presentations post *only*
    /// frame changes — so visibility must be derivable from geometry alone:
    /// tall enough to be a real keyboard (not the accessory rail) and
    /// meaningfully on screen (a dismissed frame parks at/below the screen's
    /// bottom edge). All values in screen coordinates.
    static func isPresented(keyboard: CGRect, screen: CGRect) -> Bool {
        guard keyboard.width > 0, keyboard.height >= minRealKeyboardHeight else { return false }
        return keyboard.intersection(screen).height > 2
    }

    /// Interprets a frame change for focus arbitration. Stage Manager can
    /// report a zero-height end frame while a floating keyboard input session
    /// remains active. That frame is ambiguous, not a hide:
    /// clearing visibility there makes the next terminal tap tear down and
    /// rebuild the live input session. A did-hide notification remains the
    /// definitive hidden signal; a tall off-screen frame is also definitive.
    static func visibilityUpdate(
        keyboard: CGRect,
        screen: CGRect
    ) -> VisibilityUpdate? {
        if isPresented(keyboard: keyboard, screen: screen) { return .shown }
        if keyboard.height >= minRealKeyboardHeight { return .hidden }
        return nil
    }

    /// Classifies how a keyboard-frame notification can affect layout.
    /// Floating and split keyboards are typable but deliberately reserve no
    /// space. Short/flat system shortcut frames are kept separate so their
    /// notification churn cannot move the app-owned key rail.
    static func presentation(
        keyboard: CGRect,
        screen: CGRect
    ) -> Presentation {
        guard keyboard.width > 0 else { return .hidden }
        if keyboard.height >= minRealKeyboardHeight {
            guard isPresented(keyboard: keyboard, screen: screen) else { return .hidden }
            return isDocked(
                keyboard: keyboard,
                screen: screen,
                containerWidth: screen.width
            ) ? .docked : .floating
        }
        if keyboard.height < minRealKeyboardHeight,
           keyboard.maxY >= screen.minY - 2,
           keyboard.minY <= screen.maxY + 2 {
            return .shortcut
        }
        return .hidden
    }

    /// Whether a keyboard-frame notification needs an overlap pass. Every
    /// docked frame remeasures against the moving Stage Manager window, and a
    /// transition *from* docked clears that inset. Floating, short/flat, and
    /// hidden transitions never affect app-owned chrome, so they do no layout.
    static func shouldReapplyFrameChange(
        from previous: Presentation,
        to current: Presentation
    ) -> Bool {
        current == .docked || previous == .docked
    }
}
