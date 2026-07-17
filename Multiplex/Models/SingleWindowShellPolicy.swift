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

    static func isExpanded(width: CGFloat) -> Bool {
        width >= expandedThreshold
    }
}

/// Pure completion policy for the iPhone shell's right-swipe navigation.
/// Translation is in points and velocity is in points per second.
enum SingleWindowShellBackSwipe {
    private static let completionFraction: CGFloat = 0.5
    private static let projectionDuration: CGFloat = 0.2
    private static let minimumFlickDistance: CGFloat = 16
    private static let decisiveReverseVelocity: CGFloat = -100

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
