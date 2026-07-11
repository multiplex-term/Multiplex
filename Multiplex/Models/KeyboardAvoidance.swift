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
}
