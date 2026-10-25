import os
import UIKit

/// UIKit's traits as the pure shell policy reads them. One mapping each, so
/// the shell resolver and the terminal window agree by construction.
extension ShellSizeClass {
    init(_ sizeClass: UIUserInterfaceSizeClass?) {
        switch sizeClass {
        case .compact: self = .compact
        case .regular: self = .regular
        default: self = .unspecified
        }
    }
}

extension ShellModeDecision.Idiom {
    init(_ idiom: UIUserInterfaceIdiom) {
        switch idiom {
        case .phone: self = .phone
        case .pad: self = .pad
        default: self = .other
        }
    }

    static var device: ShellModeDecision.Idiom {
        ShellModeDecision.Idiom(UIDevice.current.userInterfaceIdiom)
    }
}

extension ShellRailEdge {
    /// The edge the system's vertical bar stands on (the iOS 27.1 trait),
    /// nil where the system reports none.
    static func systemVerticalBar(in traits: UITraitCollection) -> ShellRailEdge? {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            switch traits.verticalBarEdge {
            case .leading: return .leading
            case .trailing: return .trailing
            default: return nil
            }
        }
        #endif
        return nil
    }
}

extension ShellSideColumn {
    /// The side column from live traits, resolved once by the shell for
    /// both panes: the iOS 27.1 vertical-bar trait when the system reports
    /// one, else `ShellRailPlacement`'s rule; placement from the display.
    static func resolve(
        traits: UITraitCollection,
        isLandscape: Bool,
        foldable: Bool,
        leadingSafeArea: CGFloat,
        trailingSafeArea: CGFloat
    ) -> ShellSideColumn {
        #if os(iOS)
        let edge = ShellRailPlacement.edge(
            systemVerticalBarEdge: ShellRailEdge.systemVerticalBar(in: traits),
            idiom: .device,
            horizontalSizeClass: ShellSizeClass(traits.horizontalSizeClass),
            verticalSizeClass: ShellSizeClass(traits.verticalSizeClass),
            isLandscape: isLandscape,
            foldable: foldable,
            leadingSafeArea: leadingSafeArea,
            trailingSafeArea: trailingSafeArea
        )
        guard edge != .top else { return .none }
        return ShellSideColumn(
            edge: edge,
            placement: RailFit.columnPlacement(
                compactWidth: traits.horizontalSizeClass == .compact,
                landscape: isLandscape,
                trailingEdge: edge == .trailing
            )
        )
        #else
        return .none
        #endif
    }
}

extension UIViewController {
    /// Child containment with the child filling `container` by autoresizing.
    func embed(_ child: UIViewController, in container: UIView) {
        addChild(child)
        container.addSubview(child.view)
        child.view.frame = container.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        child.didMove(toParent: self)
    }

    func unembed(_ child: UIViewController) {
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }

    /// Re-asks the status bar and home indicator preferences (iOS).
    func refreshSystemOverlays() {
        #if os(iOS)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        #endif
    }
}

#if DEBUG
/// `MULTIPLEX_DUO_PROBE=1`: the shell logs the geometry its iPhone Duo rules
/// read (category `duo`; `log stream` shows it, `log show` does not).
enum DuoProbe {
    static let enabled = ProcessInfo.processInfo.environment["MULTIPLEX_DUO_PROBE"] == "1"
    static let log = Logger(subsystem: "app.multiplexterm.multiplex", category: "duo")
}
#endif
