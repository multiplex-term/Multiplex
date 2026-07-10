import SwiftUI

@main
struct MultiplexApp: App {
    @State private var store = HostStore()
    @State private var hub = ConnectionHub()
    @State private var themes = ThemeStore()
    @State private var workspace = TerminalWorkspace()

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
                .environment(themes)
                .environment(workspace)
                .modifier(PlatformChrome())
        }
    }

    private var terminalScene: some Scene {
        WindowGroup(id: "terminal", for: TerminalWindowRoute.self) { $route in
            if let binding = Binding($route) {
                TerminalWindowRoot(route: binding)
                    .environment(store)
                    .environment(hub)
                    .environment(themes)
                    .environment(workspace)
                    .modifier(PlatformChrome())
            }
        }
    }
}

/// iPad sits on chassis (dark UI, neutral signal accent — color is spent on
/// state, not actions); visionOS keeps native glass for sheets and system
/// controls.
private struct PlatformChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        content
        #else
        content
            .preferredColorScheme(.dark)
            .tint(Theme.signal)
        #endif
    }
}
