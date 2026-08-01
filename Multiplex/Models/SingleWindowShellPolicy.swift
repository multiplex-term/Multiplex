import CoreGraphics

/// Pure, UIKit-free policy for choosing Multiplex's single-window shell.
/// UIKit supplies the scene idiom and the connected scene's full-screen bit;
/// tests can cover the complete matrix without constructing a UIWindowScene.
enum ShellModeDecision {
    enum Platform: Equatable {
        case iOS
        case visionOS
    }

    enum Idiom: Equatable {
        case phone
        case pad
        case other
    }

    static func usesSingleWindowShell(
        platform: Platform,
        idiom: Idiom,
        isFullScreen: Bool,
        environmentOverride: String?
    ) -> Bool {
        if environmentOverride == "1" { return true }
        if environmentOverride == "0" { return false }

        guard platform == .iOS else { return false }
        switch idiom {
        case .phone:
            return true
        case .pad:
            return isFullScreen
        case .other:
            return false
        }
    }
}

/// Pure layout constants shared by the real shell and its unit tests.
enum SingleWindowShellLayout {
    static let expandedThreshold: CGFloat = 620
    static let deckRailWidth: CGFloat = 316
    /// An unlocked compact key rail retains TMUX at 390 points. Keyboard lock
    /// adds RET on iPhone; its slightly tighter Air tier keeps both controls at
    /// 420 points, while narrower locked phones move TMUX to the top bar.
    static let keyBarTmuxMinimumWidth: CGFloat = 390
    static let keyBarTmuxWithReturnMinimumWidth: CGFloat = 420

    static func isExpanded(width: CGFloat) -> Bool {
        width >= expandedThreshold
    }

    static func showsTopBarTmuxShortcut(
        availableWidth: CGFloat,
        supportsTmuxShortcuts: Bool,
        keyBarIncludesReturnKey: Bool = false
    ) -> Bool {
        let minimumWidth = keyBarIncludesReturnKey
            ? keyBarTmuxWithReturnMinimumWidth
            : keyBarTmuxMinimumWidth
        return supportsTmuxShortcuts && availableWidth < minimumWidth
    }
}

/// Pure completion policy for the iPhone shell's left-edge back swipe.
/// Translation is in points and velocity is in points per second.
enum SingleWindowShellBackSwipe {
    private static let completionFraction: CGFloat = 0.5
    private static let projectionDuration: CGFloat = 0.2
    private static let minimumFlickDistance: CGFloat = 16
    private static let decisiveReverseVelocity: CGFloat = -100

    /// The compact phone keeps edge-back as a navigation shortcut even when
    /// Reduce Motion is enabled. Motion preference changes the interactive
    /// travel, not whether the route back to the deck exists.
    static func isAvailable(
        idiom: ShellModeDecision.Idiom,
        expanded: Bool,
        compactShowsTerminal: Bool
    ) -> Bool {
        idiom == .phone && !expanded && compactShowsTerminal
    }

    /// Local text-selection drags always stay with the terminal. Otherwise,
    /// only unambiguously rightward horizontal intent starts navigation.
    static func shouldBegin(
        horizontalVelocity: CGFloat,
        verticalVelocity: CGFloat,
        hasActiveTextSelection: Bool
    ) -> Bool {
        guard !hasActiveTextSelection else { return false }
        return horizontalVelocity > 0
            && abs(horizontalVelocity) > abs(verticalVelocity)
    }

    static func constrainedTranslation(_ translation: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(translation, 0), width)
    }

    /// A deliberate half-width drag always completes. A shorter flick can
    /// complete when its forward velocity projects beyond the same midpoint;
    /// a clear reversal always cancels so the interface follows intent.
    static func shouldReturnToDeck(
        translation: CGFloat,
        velocity: CGFloat,
        width: CGFloat
    ) -> Bool {
        guard width > 0 else { return false }
        let distance = constrainedTranslation(translation, width: width)
        guard distance >= minimumFlickDistance,
              velocity > decisiveReverseVelocity
        else { return false }

        if distance >= width * completionFraction { return true }
        let projectedDistance = distance + max(velocity, 0) * projectionDuration
        return projectedDistance >= width * completionFraction
    }
}
