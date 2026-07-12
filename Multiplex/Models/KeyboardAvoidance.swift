import CoreGraphics

/// Decides whether a reported keyboard frame should displace the terminal.
///
/// Keyboard-frame notifications describe every presentation the same way,
/// but only keyboards *docked* to the bottom of the screen deserve an inset:
/// the full software keyboard and the accessory-only bar of hardware-keyboard
/// mode. A floating pill, a split keyboard, or the collapsed shortcuts pill
/// hovers wherever the user parked it — reserving rows under those just
/// wastes the viewport (the reported frame can sit anywhere on screen).
/// Pure geometry so the docked call stays unit-tested.
enum KeyboardAvoidance {
    /// All values in screen coordinates. `containerWidth` is the terminal
    /// container's on-screen width: the accessory bar tracks the window in
    /// windowed iPadOS, so a keyboard as wide as either the screen or the
    /// container counts as spanning; a floating pill is far narrower.
    static func isDocked(keyboard: CGRect, screen: CGRect, containerWidth: CGFloat) -> Bool {
        guard keyboard.width > 0, keyboard.height > 0 else { return false }
        let pinnedToBottom = keyboard.maxY >= screen.maxY - 2
        let spans = keyboard.width + 2 >= min(screen.width, containerWidth)
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

    /// The rendered input accessory (the key rail) gets its own docked test.
    /// Hardware-keyboard mode draws the rail as the only keyboard chrome, but
    /// where it lands differs by presentation — the screen bottom fullscreen,
    /// the *window* bottom in windowed iPadOS — so bottom-pinning is judged
    /// against the terminal container, not the screen. A rail riding a
    /// floating keyboard fails both tests (pill-narrow, floats above the
    /// container's bottom edge); insetting by a moving pill would resize the
    /// PTY — a tmux reflow — on every drag frame. A rail sitting on top of a
    /// docked keyboard also fails: the keyboard end frame already includes
    /// it, and `isDocked` owns that inset. All values in screen coordinates.
    static func accessoryIsDocked(accessory: CGRect, container: CGRect, screen: CGRect) -> Bool {
        guard accessory.width > 0, accessory.height > 0 else { return false }
        let reachesContainerBottom = accessory.maxY >= container.maxY - 2
        let spans = accessory.width + 2 >= min(screen.width, container.width)
        return reachesContainerBottom && spans
    }
}
