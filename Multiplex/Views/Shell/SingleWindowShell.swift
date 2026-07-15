import SwiftUI

/// Multiplex's real one-scene shell for iPhone and full-screen iPad. The deck
/// and terminal stage remain mounted together: compact navigation slides the
/// live terminal over the deck, while expanded layout exposes the same deck
/// as a one-session-wide rail. TerminalSessionController continues to own the
/// TerminalView, so back navigation, rail collapse, and width transitions do
/// not interrupt the shell or lose scrollback.
struct SingleWindowShell: View {
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var terminalRoute: TerminalWindowRoute
    @State private var compactShowsTerminal: Bool
    @State private var deckRailVisible = true

    init(initialRoute: TerminalWindowRoute? = nil) {
        let route = initialRoute ?? TerminalWindowRoute(tabs: [])
        _terminalRoute = State(initialValue: route)
        _compactShowsTerminal = State(initialValue: !route.tabs.isEmpty)
    }

    var body: some View {
        GeometryReader { geometry in
            let expanded = SingleWindowShellLayout.isExpanded(width: geometry.size.width)
            let deckWidth = expanded
                ? (deckRailVisible ? min(SingleWindowShellLayout.deckRailWidth, geometry.size.width) : 0)
                : geometry.size.width
            let terminalWidth = expanded
                ? max(0, geometry.size.width - deckWidth)
                : geometry.size.width

            ZStack(alignment: .leading) {
                deck(
                    expanded: expanded,
                    bottomSafeAreaInset: geometry.safeAreaInsets.bottom
                )
                    .frame(width: deckWidth, height: geometry.size.height)
                    .clipped()
                    .opacity(expanded || !compactShowsTerminal ? 1 : 0)
                    .allowsHitTesting(expanded ? deckRailVisible : !compactShowsTerminal)
                    .zIndex(0)

                terminalStage(expanded: expanded, availableWidth: terminalWidth)
                    .frame(width: terminalWidth, height: geometry.size.height)
                    .offset(x: expanded
                        ? deckWidth
                        : (compactShowsTerminal ? 0 : geometry.size.width))
                    .opacity(expanded || compactShowsTerminal ? 1 : 0)
                    .allowsHitTesting(expanded || compactShowsTerminal)
                    .zIndex(1)

                if expanded, deckRailVisible {
                    Rectangle()
                        .fill(Theme.bezelHi)
                        .frame(width: 1, height: geometry.size.height)
                        .offset(x: deckWidth - 1)
                        .allowsHitTesting(false)
                        .zIndex(2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Theme.chassis.ignoresSafeArea())
            .animation(shellAnimation, value: compactShowsTerminal)
            .animation(shellAnimation, value: deckRailVisible)
            .animation(shellAnimation, value: expanded)
            .onChange(of: expanded) { _, isExpanded in
                if !isExpanded, !compactShowsTerminal {
                    releaseTerminalFocus()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active,
                      !expanded,
                      !compactShowsTerminal
                else { return }
                // UIKit may try to restore the still-mounted terminal's input
                // session as this scene foregrounds. The deck is frontmost,
                // so reassert the shell's no-terminal-focus invariant through
                // the controller/arbiter path.
                releaseTerminalFocus()
            }
        }
    }

    private func deck(
        expanded: Bool,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
        DeckWindow(
            terminalOpener: TerminalRouteOpener(
                destination: .shell,
                action: openTerminalRoute
            ),
            wallPresentation: expanded ? .shellRail : .shellCompact,
            selectedTerminal: terminalRoute.activeTab,
            shellBottomSafeAreaInset: bottomSafeAreaInset
        )
    }

    @ViewBuilder
    private func terminalStage(expanded: Bool, availableWidth: CGFloat) -> some View {
        if terminalRoute.tabs.isEmpty {
            emptyTerminal
        } else {
            TerminalWindowRoot(
                route: $terminalRoute,
                shell: .init(
                    deckControlLabel: expanded
                        ? (deckRailVisible ? "◧ HIDE" : "◧ DECK")
                        : "‹ DECK",
                    availableWidth: availableWidth,
                    showDeck: { showDeck(expanded: expanded) },
                    openTerminalRoute: openTerminalRoute,
                    revealTab: revealTab,
                    tabsEmptied: terminalTabsEmptied,
                    terminalFocusAllowed: expanded || compactShowsTerminal
                )
            )
        }
    }

    private var emptyTerminal: some View {
        ZStack {
            Theme.screen
            VStack(spacing: 10) {
                ChassisLabel("No terminal selected", size: 13, color: Theme.signal3)
                Text("Choose a session from the deck to attach it here.")
                    .font(.footnote)
                    .foregroundStyle(Theme.signal2)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    private var shellAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)
    }

    /// Every incoming window route becomes tabs in this shell. AUTO_ATTACH
    /// `+` groups arrive as one route and comma-separated entries simply add
    /// to the same ordered tab list.
    private func openTerminalRoute(_ incoming: TerminalWindowRoute) {
        guard !incoming.tabs.isEmpty else { return }
        terminalRoute.merge(incoming.tabs)
        if let selected = incoming.activeTab?.id ?? incoming.tabs.first?.id {
            terminalRoute.activate(selected)
        }
        compactShowsTerminal = true
        focusAfterNavigation(tabID: terminalRoute.activeTabID)
    }

    /// TerminalWorkspace's existing press-to-focus lookup calls this reveal
    /// closure for an already-open session instead of creating a duplicate.
    private func revealTab(_ tabID: UUID) {
        compactShowsTerminal = true
        focusAfterNavigation(tabID: tabID)
    }

    private func showDeck(expanded: Bool) {
        if expanded {
            deckRailVisible.toggle()
        } else {
            releaseTerminalFocus()
            compactShowsTerminal = false
        }
    }

    private func terminalTabsEmptied() {
        releaseTerminalFocus()
        compactShowsTerminal = false
        deckRailVisible = true
    }

    private func focusAfterNavigation(tabID: UUID?) {
        guard let tabID else { return }
        DispatchQueue.main.async {
            workspace.controller(for: tabID)?.focusTerminal()
        }
    }

    private func releaseTerminalFocus() {
        guard let tabID = terminalRoute.activeTab?.id else { return }
        workspace.controller(for: tabID)?.releaseFocus()
    }
}
