import SwiftUI

@main
struct MultiplexApp: App {
    @State private var store = HostStore()
    @State private var hub: ConnectionHub
    @State private var themes = ThemeStore()
    @State private var customAgentCommands = CustomAgentCommandStore()
    @State private var workspace: TerminalWorkspace
    @State private var entitlements: EntitlementStore
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
        // Snug fit for a two-tile wall row: 26pt wall padding either side +
        // two tiles at the grid's 360pt max + the 14pt gutter wide. Wider
        // and the row gains dead space (a third column needs 950). 330 is
        // the shortest visionOS will actually grant at this width (shorter
        // requests render ~330 anyway — system aspect floor); it shows the
        // header, host rail, and one full tile row, and more rows scroll.
        deckScene
            .defaultSize(debugSize("MULTIPLEX_DECK_SIZE") ?? CGSize(width: 786, height: 330))
        terminalScene
            .windowStyle(.plain)
            .defaultSize(debugSize("MULTIPLEX_TERM_SIZE") ?? CGSize(width: 1120, height: 700))
        #else
        deckScene
        terminalScene
        #endif
    }

    /// Headless-capture hook: `MULTIPLEX_DECK_SIZE`/`MULTIPLEX_TERM_SIZE`
    /// (`<width>x<height>`, DEBUG only) override a scene's default window
    /// size — the simulator has no way to drag-resize a volume, so doc
    /// screenshots request the size they need at launch.
    private func debugSize(_ variable: String) -> CGSize? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment[variable] else { return nil }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
        #else
        return nil
        #endif
    }

    private var deckScene: some Scene {
        #if os(visionOS)
        WindowGroup(id: "deck") {
            deckWindow
        }
        #else
        // iPad has one deck, identified by one stable scene value. Unlike
        // `openWindow(id:)`, opening this value again raises the existing
        // window instead of creating another deck.
        WindowGroup(id: "deck", for: DeckWindowRoute.self) { _ in
            deckWindow
        } defaultValue: {
            .main
        }
        #endif
    }

    private var deckWindow: some View {
        DeckWindow()
            .environment(store)
            .environment(hub)
            .environment(themes)
            .environment(customAgentCommands)
            .environment(workspace)
            .environment(entitlements)
            .environment(attention)
            .modifier(PlatformChrome())
    }

    private var terminalScene: some Scene {
        WindowGroup(id: "terminal", for: TerminalWindowRoute.self) { $route in
            if let binding = Binding($route) {
                TerminalWindowRoot(route: binding)
                    .environment(store)
                    .environment(hub)
                    .environment(themes)
                    .environment(customAgentCommands)
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
