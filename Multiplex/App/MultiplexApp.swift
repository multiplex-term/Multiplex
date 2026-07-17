import SwiftUI

@main
struct MultiplexApp: App {
    @State private var store = HostStore()
    @State private var hub: ConnectionHub
    @State private var themes = ThemeStore()
    @State private var workspace: TerminalWorkspace
    @State private var entitlements: EntitlementStore
    @State private var attention: AttentionCenter
    @State private var localNetworkAccess = LocalNetworkAccessMonitor()

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
        // two tiles at the grid's 360pt preferred width + the 14pt gutter.
        // Wider windows keep that tile size until another full tile fits (a
        // third needs 1160), so growing never compresses the existing row.
        // 330 is the shortest visionOS will actually grant at this width
        // (shorter requests render ~330 anyway — system aspect floor); it
        // shows the header, host rail, and one full tile row, and more rows scroll.
        deckScene
            // Keep the system's resize range tied to the stable scene
            // boundary below, never to FleetWall's changing grid ideal size.
            .windowResizability(.contentMinSize)
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
        // The deck has one stable data identity on every platform. Opening
        // that value raises the existing scene instead of creating another;
        // on visionOS this also avoids direct UIKit activation, which can
        // reapply the scene's default size to a user-resized window.
        WindowGroup(id: "deck", for: DeckWindowRoute.self) { _ in
            deckWindow
        } defaultValue: {
            .main
        }
    }

    @ViewBuilder
    private var deckWindow: some View {
        configuredRoot(
            SceneShellGate {
                MultiWindowDeckRoot()
                    .modifier(DeckWindowSizingBoundary())
            } shell: {
                SingleWindowShell()
            }
        )
    }

    private var terminalScene: some Scene {
        WindowGroup(id: "terminal", for: TerminalWindowRoute.self) { $route in
            terminalRoot($route)
        }
    }

    @ViewBuilder
    private func terminalRoot(_ route: Binding<TerminalWindowRoute?>) -> some View {
        configuredRoot(
            SceneShellGate {
                if let binding = Binding(route) {
                    TerminalWindowRoot(route: binding)
                } else {
                    // Classic multi-window mode historically leaves a
                    // value-less terminal scene empty.
                    EmptyView()
                }
            } shell: {
                if let binding = Binding(route) {
                    SingleWindowShell(initialRoute: binding.wrappedValue)
                } else {
                    // iOS 27 can connect this value-less group first on a
                    // phone, so it must still be a complete shell root.
                    SingleWindowShell()
                }
            }
        )
    }

    private func configuredRoot<Content: View>(_ content: Content) -> some View {
        content
            .environment(store)
            .environment(hub)
            .environment(themes)
            .environment(workspace)
            .environment(entitlements)
            .environment(attention)
            .environment(localNetworkAccess)
            .modifier(PlatformChrome())
    }
}

/// Classic deck presentation: the injected opener is exactly the existing
/// `openWindow(id:value:)` route. Shell mode supplies a different opener from
/// inside `SingleWindowShell`, leaving this path unchanged for windowed iPad
/// and visionOS.
private struct MultiWindowDeckRoot: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DeckWindow(terminalOpener: TerminalRouteOpener(
            destination: .window,
            action: { openWindow(id: "terminal", value: $0) }
        ))
    }
}

/// visionOS derives a regular window's minimum resize constraints from its
/// root content. FleetWall changes its grid shape at column breakpoints, so
/// exposing that content size to the scene can make the system clamp the
/// window during the user's resize gesture. A flexible base owns scene sizing;
/// the wall fills it as an overlay and therefore cannot resize its own window.
struct DeckWindowSizingBoundary: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(visionOS)
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { content }
        #else
        content
        #endif
    }
}

/// iPad sits on chassis (dark UI, neutral signal accent — color is spent on
/// state, not actions); visionOS keeps native glass for sheets and system
/// controls.
private struct PlatformChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(visionOS)
        content
        #else
        let base = content
            .preferredColorScheme(.dark)
            .tint(Theme.signal)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // The Mac paints the iPad canvas at 77%. Fixed-size chassis type
            // compensates through Theme.typeScale; semantic text styles
            // (.footnote, .subheadline …) keep Dynamic Type on iPad and get
            // the equivalent boost here instead. Fixed-size fonts ignore
            // Dynamic Type, so the two mechanisms never compound.
            base.dynamicTypeSize(.xxLarge)
        } else {
            base
        }
        #endif
    }
}
