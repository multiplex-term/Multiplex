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
}

#if DEBUG
/// `MULTIPLEX_DUO_PROBE=1`: the shell logs the geometry its iPhone Duo rules
/// read (category `duo`; `log stream` shows it, `log show` does not).
enum DuoProbe {
    static let enabled = ProcessInfo.processInfo.environment["MULTIPLEX_DUO_PROBE"] == "1"
    static let log = Logger(subsystem: "app.multiplexterm.multiplex", category: "duo")
}
#endif
