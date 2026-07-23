import AppIntents
import SwiftUI
import UIKit

@main
struct MultiplexApp: App {
    @State private var store: HostStore
    @State private var hub: ConnectionHub
    @State private var themes = ThemeStore()
    @State private var workspace: TerminalWorkspace
    @State private var entitlements: EntitlementStore
    @State private var attention: AttentionCenter
    @State private var localNetworkAccess = LocalNetworkAccessMonitor()
    @State private var networkChanges = NetworkChangeMonitor()
    @State private var appLock = AppLockStore()
    private var externalActions: ExternalActionRouter { .shared }

    init() {
        // Attention wiring: every probe's events funnel through one center,
        // which consults the workspace to skip the session being typed in
        // and the entitlement store to stay behind the Pro gate.
        let entitlements = EntitlementStore()
        let attention = AttentionCenter()
        let workspace = TerminalWorkspace(attention: attention)
        attention.workspace = workspace
        attention.entitlements = entitlements
        let store = HostStore()
        _store = State(initialValue: store)
        _entitlements = State(initialValue: entitlements)
        _attention = State(initialValue: attention)
        _workspace = State(initialValue: workspace)
        _hub = State(initialValue: ConnectionHub(attention: attention))
        // App Intents run in this process: the router must be resolvable
        // before any perform() (a cold intent launch performs right after
        // App init), and the Shortcuts host picker reads the live store.
        AppDependencyManager.shared.add(dependency: ExternalActionRouter.shared)
        HostEntityProvider.live = {
            store.hosts.map {
                HostEntity(
                    id: $0.id,
                    name: $0.name,
                    address: $0.address,
                    workingDirs: $0.workingDirs,
                    sessionScripts: $0.sessionScripts.map {
                        ShortcutSessionScript(
                            id: $0.id,
                            displayName: $0.displayName
                        )
                    }
                )
            }
        }
    }

    var body: some Scene {
        #if os(visionOS)
        // A three-tile wall row: 26pt wall padding either side + three tiles
        // at the grid's 360pt preferred width + two 14pt gutters = 1160.
        // Wider windows keep that tile size until another full tile fits, so
        // growing never compresses the existing row. 524 shows the header,
        // host rail, and two full tile rows (330 one-row height + a 180pt
        // tile + the 14pt gutter); more rows scroll.
        deckScene
            // Keep the system's resize range tied to the stable scene
            // boundary below, never to FleetWall's changing grid ideal size.
            .windowResizability(.contentMinSize)
            .defaultSize(debugSize("MULTIPLEX_DECK_SIZE") ?? CGSize(width: 1160, height: 524))
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
            .environment(networkChanges)
            .environment(externalActions)
            .environment(appLock)
            .modifier(ExternalActionReceiver(router: externalActions))
            // The lock veil sits inside PlatformChrome so it follows the
            // pinned appearance, and outside everything else so it covers
            // deck and terminal content alike.
            .modifier(AppLockGate(lock: appLock))
            .modifier(PlatformChrome(themes: themes))
    }
}

/// Every scene root can receive a `multiplex://` URL and feed the shared
/// router; the mounted deck executes. When pending work arrives while no
/// deck is mounted (a terminal-only visionOS/iPad arrangement), raise the
/// one deck scene — the data-driven `WindowGroup` reuses it, never mints a
/// second. The iPhone shell is single-scene and always mounts the deck, so
/// the raise is correctly unavailable there.
private struct ExternalActionReceiver: ViewModifier {
    var router: ExternalActionRouter

    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard let action = ExternalActionURL.action(from: url) else { return }
                router.submit(action)
            }
            .onChange(of: router.pendingSignal) {
                guard !router.hasContext, supportsMultipleWindows else { return }
                openWindow(id: "deck", value: DeckWindowRoute.main)
            }
    }
}

/// Classic deck presentation: the injected opener is exactly the existing
/// `openWindow(id:value:)` route. Shell mode supplies a different opener from
/// inside `SingleWindowShell`, leaving this path unchanged for windowed iPad
/// and visionOS.
private struct MultiWindowDeckRoot: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let opener = TerminalRouteOpener(
            destination: .window,
            action: { openWindow(id: "terminal", value: $0) }
        )
        DeckWindow(terminalOpener: opener)
            // Classic mode's external-action executor: same opener as the
            // wall, with the failure/prompt UI anchored at this scene root.
            .modifier(ExternalActionHost(terminalOpener: opener))
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

/// iPad sits on chassis (opaque UI, neutral signal accent — color is spent on
/// state, not actions); visionOS keeps native glass for system controls
/// (menus, alerts, popover shells), while form sheets sit on the same opaque
/// chassis as iPad (`chassisSheetGround` — glass grounds swallowed the
/// pinned LIGHT appearance, user-reported). The appearance choice
/// (`ThemeStore.appearance`) resolves here: `.system` follows the device —
/// chassis tokens are trait-dynamic, so the whole scene flips live — while
/// LIGHT/DARK pin the scheme.
private struct PlatformChrome: ViewModifier {
    var themes: ThemeStore

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(visionOS)
        content
            .background(AppearanceApplicator(appearance: themes.appearance))
        #else
        let base = content
            .background(AppearanceApplicator(appearance: themes.appearance))
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

