import SwiftUI

@main
struct MultiplexApp: App {
    @State private var store = HostStore()
    @State private var hub: ConnectionHub
    @State private var themes = ThemeStore()
    @State private var workspace: TerminalWorkspace
    @State private var entitlements = EntitlementStore()
    @State private var attention: AttentionCenter

    init() {
        // Attention wiring: every probe's events funnel through one center,
        // which consults the workspace to skip the session being typed in
        // and the entitlement store to stay behind the Pro gate.
        let entitlements = EntitlementStore()
        let attention = AttentionCenter()
        let workspace = TerminalWorkspace(attention: attention)
        attention.workspace = workspace
        attention.entitlements = entitlements
        _entitlements = State(initialValue: entitlements)
        _attention = State(initialValue: attention)
        _workspace = State(initialValue: workspace)
        _hub = State(initialValue: ConnectionHub(attention: attention))
    }

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
                .environment(entitlements)
                .environment(attention)
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
                    .environment(entitlements)
                    .environment(attention)
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
