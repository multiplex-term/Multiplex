import SwiftUI

/// Root of one terminal window scene, resolved from its `TerminalRoute`.
struct TerminalWindowRoot: View {
    @Environment(HostStore.self) private var store

    let route: TerminalRoute

    @State private var controller: TerminalSessionController?

    var body: some View {
        Group {
            if let controller {
                TerminalContainerView(controller: controller)
            } else {
                Color.clear
            }
        }
        .task {
            guard controller == nil else { return }
            guard let host = store.host(id: route.hostID) else { return }
            let fresh = TerminalSessionController(route: route, host: host)
            controller = fresh
            fresh.start()
        }
    }
}

/// The screen itself: opaque ink, terminal edge to edge. Chrome lives in a
/// bottom ornament on visionOS and the toolbar on iPad.
struct TerminalContainerView: View {
    @Environment(\.dismissWindow) private var dismissWindow
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
        // Keyboard focus follows the window: reclaim first responder whenever
        // this scene becomes active again or the shell (re)connects.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.focusTerminal() }
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
            sessionIdentity
            Divider().frame(height: 20)
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
        ToolbarItemGroup(placement: .primaryAction) {
            fontButtons
            Button("Detach") { detachAndClose() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.phosphor)
                .foregroundStyle(Theme.ink)
        }
    }
    #endif

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
