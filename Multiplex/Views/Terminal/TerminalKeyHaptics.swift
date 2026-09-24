import UIKit

/// The one tap every terminal chip shares — key rail keys and their Ctrl
/// combos, the tmux/herdr shortcut panels, and the agent helper strip. It
/// fires on touch-down so the tap lands with the press, the way the system
/// keyboard's does, and never on the actions that follow (a menu opening, a
/// panel closing) so a press is exactly one tap.
///
/// iPhone only in practice: iPad ships no Taptic Engine, visionOS has no
/// haptic API, and iOS-on-Mac makes the generator a no-op — all stay silent.
@MainActor
enum TerminalKeyHaptics {
    #if os(iOS)
    private static let generator = UIImpactFeedbackGenerator(style: .light)
    #endif

    /// A light tap for one key or chip press. Pass the pressed view where
    /// there is one: iOS 17.5+ anchors the tap to that view's window.
    static func keyPress(on view: UIView? = nil) {
        #if os(iOS)
        if #available(iOS 17.5, *), let view, view.window != nil {
            let anchored = UIImpactFeedbackGenerator(style: .light, view: view)
            anchored.impactOccurred()
        } else {
            generator.impactOccurred()
        }
        #endif
    }
}
