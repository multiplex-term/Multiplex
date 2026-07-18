import SwiftUI

/// Attaches this surface as `ExternalActionRouter`'s executor and presents
/// the router's UI — the failure alert and the widget-ASK prompt sheet —
/// over the whole surface. This deliberately sits on the mode ROOT, not on
/// the deck pane: the expanded shell can hold the deck at zero width (rail
/// hidden) and classic mode can hold it in a backgrounded scene, and a
/// presentation anchored inside either never reaches the user.
struct ExternalActionHost: ViewModifier {
    let terminalOpener: TerminalRouteOpener

    @Environment(HostStore.self) private var store
    @Environment(ConnectionHub.self) private var hub
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(ExternalActionRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    @State private var agentPromptRequest: AgentPromptRequest?
    @State private var failure: ExternalActionFailure?
    @State private var contextToken: UUID?

    func body(content: Content) -> some View {
        content
            // The rail's LINKING/UNREACHABLE keeps narrating the status
            // guard; queued actions drain the moment this context attaches.
            .task {
                contextToken = router.attach(.init(
                    store: store,
                    hub: hub,
                    workspace: workspace,
                    open: { terminalOpener($0) },
                    presentAgentPrompt: { request in
                        agentPromptRequest = request
                        revealClassicDeck()
                    },
                    presentFailure: { result in
                        failure = result
                        revealClassicDeck()
                    }
                ))
            }
            .onDisappear {
                if let token = contextToken {
                    router.detach(token)
                    contextToken = nil
                }
            }
            .sheet(item: $agentPromptRequest) { request in
                AgentPromptSheet(request: request)
                    .environment(router)
            }
            .alert(
                "Can't Open \(failure?.hostName ?? "Host")",
                isPresented: Binding(
                    get: { failure != nil },
                    set: { if !$0 { failure = nil } }
                ),
                presenting: failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
    }

    /// Classic mode presents on the deck scene, which may sit behind the
    /// terminal windows — raise it so the result is seen. The shell root is
    /// its whole scene and never needs this.
    private func revealClassicDeck() {
        guard terminalOpener.destination == .window, supportsMultipleWindows
        else { return }
        openWindow(id: "deck", value: DeckWindowRoute.main)
    }
}
