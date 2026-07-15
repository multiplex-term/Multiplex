/// The deck's only terminal-presentation seam. Classic Multiplex opens a new
/// scene; the single-window shell adopts the same route as one or more tabs.
/// Keeping the destination alongside the closure also lets the tile's
/// duplicate-client context action use truthful copy.
struct TerminalRouteOpener {
    enum Destination {
        case window
        case shell
    }

    let destination: Destination
    private let action: (TerminalWindowRoute) -> Void

    init(
        destination: Destination,
        action: @escaping (TerminalWindowRoute) -> Void
    ) {
        self.destination = destination
        self.action = action
    }

    func callAsFunction(_ route: TerminalWindowRoute) {
        action(route)
    }

    var duplicateAttachTitle: String {
        switch destination {
        case .window: "Attach in New Window"
        case .shell: "Attach as New Tab"
        }
    }

    var openTabAccessibilityText: String {
        switch destination {
        case .window: "Shows its open window"
        case .shell: "Shows its open tab"
        }
    }
}
