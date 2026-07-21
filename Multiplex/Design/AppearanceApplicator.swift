import SwiftUI
import UIKit

/// Applies the appearance to the hosting `UIWindow` via
/// `overrideUserInterfaceStyle` — deliberately NOT `preferredColorScheme`.
/// SwiftUI's preference stops at presentation boundaries: with it, an open
/// Settings sheet (its own presentation) kept the old traits, so the
/// trait-dynamic chassis tokens inside it never flipped when the user tapped
/// LIGHT/DARK (user-reported). Every scene root carries one (`PlatformChrome`).
///
/// On visionOS that is not enough: each sheet/popover is hosted in its own
/// window, which inherits a live override *change* while it is open but NOT
/// the override already in place when it presents — a fresh launch with
/// LIGHT pinned opened Settings with dark traits (user-reported). Presented
/// chassis surfaces therefore carry their own applicator through
/// `followsAppAppearance()` (bundled into `chassisSheetGround()`); it
/// resolves the same window on iPad, where re-applying is a no-op.
struct AppearanceApplicator: UIViewRepresentable {
    var appearance: AppAppearance

    func makeUIView(context: Context) -> Applicator {
        Applicator()
    }

    func updateUIView(_ view: Applicator, context: Context) {
        view.style = UIUserInterfaceStyle(appearance.colorSchemeOverride)
    }

    final class Applicator: UIView {
        var style: UIUserInterfaceStyle = .unspecified {
            didSet { apply() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }

        // The window is only reachable once attached; a scene restored in
        // the background attaches late, so apply on every move.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            window?.overrideUserInterfaceStyle = style
        }
    }
}

/// Presentation-side appearance follow-through: reads the store from the
/// environment so any sheet/popover content can carry an applicator without
/// new plumbing. The store is read optionally — UIKit-hosted panels (the
/// iPad popover presenters) build content outside the SwiftUI environment
/// chain, and a missing store must mean "leave the window alone", never a
/// trap or a stomped override.
private struct AppAppearanceFollower: ViewModifier {
    @Environment(ThemeStore.self) private var themes: ThemeStore?

    func body(content: Content) -> some View {
        if let themes {
            content.background(AppearanceApplicator(appearance: themes.appearance))
        } else {
            content
        }
    }
}

extension View {
    /// Make a presented surface (sheet, popover) follow the app appearance
    /// choice even when its hosting window missed the scene override —
    /// see `AppearanceApplicator`.
    func followsAppAppearance() -> some View {
        modifier(AppAppearanceFollower())
    }
}
