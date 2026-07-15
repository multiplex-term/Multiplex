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
