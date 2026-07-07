import SwiftUI

/// Root of one terminal window scene, resolved from its `TerminalRoute`.
struct TerminalWindowRoot: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    let route: TerminalRoute

    @State private var controller: TerminalSessionController?
    @State private var hostMissing = false

    var body: some View {
        Group {
            if let controller {
                TerminalContainerView(controller: controller)
            } else if hostMissing {
                missingHost
            } else {
                Theme.ink.ignoresSafeArea()
            }
        }
        .task {
            guard controller == nil else { return }
            guard let host = store.host(id: route.hostID) else {
                hostMissing = true
                return
            }
            let fresh = TerminalSessionController(route: route, host: host)
            controller = fresh
            fresh.start()
        }
    }

    /// A restored window whose host was removed — say so, never a blank pane.
    private var missingHost: some View {
        VStack(spacing: 14) {
            Text("This host was removed")
                .font(.mono(17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("The window can't reconnect because its host no longer exists in the deck.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Close Window") {
                dismissWindow(id: "terminal", value: route)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.phosphor)
            .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink.ignoresSafeArea())
    }
}

/// The screen itself: opaque ink, terminal edge to edge. Chrome lives in a
/// bottom ornament on visionOS and the toolbar on iPad.
struct TerminalContainerView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    let controller: TerminalSessionController

    @State private var fontSize: CGFloat = 14

    var body: some View {
        #if os(visionOS)
        terminalSurface
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .center) {
                ornamentBar
            }
        #else
        NavigationStack {
            terminalSurface
                .navigationTitle(controller.windowTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.ink, for: .navigationBar)
                .toolbar { toolbarContent }
        }
        #endif
    }

    private var terminalSurface: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            SwiftTermView(controller: controller, fontSize: fontSize)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            statusOverlay
        }
        // Keyboard focus follows the window: restore the owner when the scene
        // reactivates; a shell that (re)connects claims focus outright.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.restoreFocusIfOwner() }
        }
        .onChange(of: controller.status) { _, status in
            if status == .live { controller.focusTerminal() }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch controller.status {
        case .connecting:
            VStack(spacing: 14) {
                ProgressView()
                Text("Connecting to \(controller.host.name)…")
                    .font(.mono(14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(30)
            .background(Theme.inkRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .live:
            EmptyView()
        case .ended(let reason):
            VStack(spacing: 16) {
                Text(reason == nil ? "Detached" : "Connection ended")
                    .font(.mono(17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let reason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                HStack(spacing: 12) {
                    Button("Reconnect") { controller.reconnect() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.phosphor)
                        .foregroundStyle(Theme.ink)
                    Button("Close Window") { closeWindow() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(34)
            .background(Theme.inkRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: Chrome

    private var sessionIdentity: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.status == .live ? Theme.phosphor : Theme.line)
                .frame(width: 7, height: 7)
            Text(controller.windowTitle)
                .font(.mono(14, weight: .medium))
                .lineLimit(1)
        }
    }

    #if os(visionOS)
    private var ornamentBar: some View {
        HStack(spacing: 18) {
            deckButton
            Divider().frame(height: 20)
            sessionIdentity
            Divider().frame(height: 20)
            keyboardButton
            fontButtons
            Divider().frame(height: 20)
            Button("Detach") { detachAndClose() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.phosphor)
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }
    #else
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            deckButton
        }
        ToolbarItemGroup(placement: .primaryAction) {
            keyboardButton
            fontButtons
            Button("Detach") { detachAndClose() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.phosphor)
                .foregroundStyle(Theme.ink)
        }
    }
    #endif

    /// Back to the main screen: opens (or brings forward) the deck window.
    private var deckButton: some View {
        Button {
            openWindow(id: "deck")
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Show Deck")
    }

    private var keyboardButton: some View {
        Button {
            controller.summonKeyboard()
        } label: {
            Image(systemName: "keyboard")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Show keyboard")
    }

    private var fontButtons: some View {
        HStack(spacing: 4) {
            Button {
                fontSize = max(9, fontSize - 1)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .accessibilityLabel("Smaller text")
            Button {
                fontSize = min(24, fontSize + 1)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .accessibilityLabel("Larger text")
        }
        .buttonStyle(.borderless)
    }

    private func detachAndClose() {
        controller.detach()
        closeWindow()
    }

    private func closeWindow() {
        dismissWindow(id: "terminal", value: controller.route)
    }
}
