import SwiftUI

@main
struct MultiplexApp: App {
    @State private var store = HostStore()
    @State private var hub = ConnectionHub()

    var body: some Scene {
        #if os(visionOS)
        deckScene
            .defaultSize(width: 940, height: 660)
        terminalScene
            .windowStyle(.plain)
            .defaultSize(width: 1120, height: 700)
        #else
        deckScene
        terminalScene
        #endif
    }

    private var deckScene: some Scene {
        WindowGroup(id: "deck") {
            DeckWindow()
                .environment(store)
                .environment(hub)
                .modifier(PlatformChrome())
        }
    }

    private var terminalScene: some Scene {
        WindowGroup(id: "terminal", for: TerminalRoute.self) { $route in
            if let route = $route.wrappedValue {
                TerminalWindowRoot(route: route)
                    .environment(store)
                    .environment(hub)
                    .modifier(PlatformChrome())
            }
        }
    }
}

/// iPad sits on ink (dark UI, amber accent); visionOS keeps native glass
/// with amber applied per-control.
private struct PlatformChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        content
        #else
        content
            .preferredColorScheme(.dark)
            .tint(Theme.phosphor)
        #endif
    }
}
