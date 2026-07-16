import SwiftUI

/// The HISTORY surface: the focused pane's past user prompts, read from the
/// agent's own session file on the host. Rows peek the *full* text —
/// including everything the TUIs render truncated — and, where supported
/// (Claude Code on a tmux tab), JUMP scrolls the live transcript back to
/// the message. Pro, like every other agent helper.
struct AgentHistoryPanel: View {
    static let preferredWidth: CGFloat = 380
    /// Rendered row stack beyond this scrolls; below it the panel hugs its
    /// content (the Command Setup sizing lesson: measure, cap only true
    /// overflow).
    private static let maximumListHeight: CGFloat = 420

    let agent: AgentKind
    let controller: TerminalSessionController
    var width: CGFloat = AgentHistoryPanel.preferredWidth
    let dismiss: () -> Void

    @State private var expandedOrdinal: Int?
    @State private var measuredListHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ChassisLabel("HISTORY", size: 11)
                ChassisLabel(agent.displayName, size: 9, color: Theme.signal3)
                Spacer(minLength: 12)
                ChassisChip("CLOSE", action: dismiss)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.bezelHi).frame(height: 1)
            content
        }
        .frame(width: width)
        .background(Theme.bezel)
        .task { controller.openAgentHistory(for: agent) }
        .onDisappear { controller.closeAgentHistory() }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.agentHistory {
        case nil, .loading:
            statusRow {
                ProgressView()
                ChassisLabel("READING SESSION FILE", size: 9, color: Theme.signal3)
            }
        case .unavailable(let reason):
            statusRow {
                Rectangle().fill(Theme.signal3).frame(width: 5, height: 5)
                ChassisLabel(reason, size: 9, color: Theme.signal3)
            }
        case .loaded(_, let messages, let jumpAvailable):
            if messages.isEmpty {
                statusRow {
                    ChassisLabel("NO MESSAGES YET", size: 9, color: Theme.signal3)
                }
            } else {
                list(messages: messages, jumpAvailable: jumpAvailable)
            }
        }
    }

    private func statusRow<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
    }

    /// Newest first — the prompt someone wants back is almost always a
    /// recent one, and a popover shouldn't need a scroll to reach it.
    private func list(messages: [AgentUserMessage], jumpAvailable: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages.reversed()) { message in
                    row(message, jumpAvailable: jumpAvailable)
                    Rectangle().fill(Theme.bezelHi.opacity(0.6)).frame(height: 1)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HistoryListHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
        }
        .onPreferenceChange(HistoryListHeightKey.self) { measuredListHeight = $0 }
        .frame(height: min(
            max(measuredListHeight, 44),
            Self.maximumListHeight
        ))
    }

    @ViewBuilder
    private func row(_ message: AgentUserMessage, jumpAvailable: Bool) -> some View {
        let expanded = expandedOrdinal == message.ordinal
        HStack(alignment: .top, spacing: 10) {
            Button {
                expandedOrdinal = expanded ? nil : message.ordinal
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if expanded {
                        fullText(message.text)
                    } else {
                        Text(message.firstLine)
                            .font(.mono(11))
                            .foregroundStyle(Theme.signal)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let stamp = timestampLabel(message.timestamp) {
                        Text(stamp)
                            .font(.mono(8, weight: .medium))
                            .foregroundStyle(Theme.signal3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(visionOS)
            .chassisHover(2)
            #endif
            .accessibilityLabel(
                expanded ? "Collapse message" : "Expand message"
            )
            if jumpAvailable, message.reachable {
                // Prompts older than the last /compact no longer render in
                // Claude's transcript — the file remembers them (peek), the
                // pager can't reach them (no JUMP).
                Button {
                    controller.startHistoryJump(to: message)
                    dismiss()
                } label: {
                    ChassisBadge("JUMP")
                }
                .buttonStyle(.plain)
                #if os(visionOS)
                .chassisHover(2)
                #endif
                .accessibilityLabel("Scroll the terminal back to this message")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// The peek: everything the session file holds, selectable — richer
    /// than the terminal, which truncates long prompts to one `…` line.
    @ViewBuilder
    private func fullText(_ text: String) -> some View {
        let body = Text(text)
            .font(.mono(11))
            .foregroundStyle(Theme.signal)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
        if text.count > 900 {
            ScrollView {
                body.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        } else {
            body
        }
    }

    private func timestampLabel(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Self.stampFormatter.localizedString(for: date, relativeTo: Date())
            .uppercased()
    }

    private static let stampFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct HistoryListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#if !os(visionOS)
/// UIKit-hosted iPad presentation, the same content-sized popover boundary
/// as Command Setup and tmux shortcuts: measured preferred size (kept live
/// through `sizingOptions` as the load finishes and rows expand), container
/// safe area only, and never an adaptive sheet over the terminal.
struct AgentHistoryPopoverPresenter: UIViewRepresentable {
    @Binding var isPresented: Bool

    let agent: AgentKind
    let controller: TerminalSessionController

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(anchor: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.dismiss(animated: false)
    }

    @MainActor
    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var parent: AgentHistoryPopoverPresenter

        private weak var hostController: UIViewController?
        private var presentationScheduled = false

        init(parent: AgentHistoryPopoverPresenter) {
            self.parent = parent
        }

        func update(anchor: UIView) {
            guard parent.isPresented else {
                dismiss(animated: true)
                return
            }
            guard hostController == nil, !presentationScheduled else { return }

            // Let the tapped chip's transaction settle before presenting
            // from the same SwiftUI host.
            presentationScheduled = true
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self else { return }
                self.presentationScheduled = false
                guard self.parent.isPresented,
                      self.hostController == nil,
                      let anchor
                else { return }
                self.present(from: anchor)
            }
        }

        func dismiss(animated: Bool) {
            presentationScheduled = false
            guard let hostController else { return }
            self.hostController = nil
            hostController.dismiss(animated: animated)
        }

        private func present(from anchor: UIView) {
            guard let presenter = presentingViewController(from: anchor) else { return }

            let sceneWidth = anchor.window?.bounds.width ?? presenter.view.bounds.width
            let panelWidth = min(
                AgentHistoryPanel.preferredWidth,
                max(280, sceneWidth - 24)
            )
            let panel = AgentHistoryPanel(
                agent: parent.agent,
                controller: parent.controller,
                width: panelWidth,
                dismiss: { [weak self] in self?.parent.isPresented = false }
            )

            let controller = UIHostingController(rootView: panel)
            hostController = controller
            controller.safeAreaRegions = .container
            // The list grows when the read lands and when a row expands;
            // keep UIKit's popover boundary synchronized with SwiftUI.
            controller.sizingOptions = .preferredContentSize
            controller.modalPresentationStyle = .popover
            controller.view.backgroundColor = UIColor(Theme.bezel)

            let fittingSize = controller.sizeThatFits(in: CGSize(
                width: panelWidth,
                height: anchor.window?.bounds.height ?? presenter.view.bounds.height
            ))
            controller.preferredContentSize = CGSize(
                width: panelWidth,
                height: fittingSize.height
            )

            if let popover = controller.popoverPresentationController {
                popover.sourceView = anchor
                popover.sourceRect = anchor.bounds
                popover.permittedArrowDirections = .down
                popover.backgroundColor = UIColor(Theme.bezel)
                popover.delegate = self
            }
            presenter.present(controller, animated: true)
        }

        private func presentingViewController(from anchor: UIView) -> UIViewController? {
            var responder: UIResponder? = anchor
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }

        func presentationControllerDidDismiss(
            _ presentationController: UIPresentationController
        ) {
            hostController = nil
            if parent.isPresented { parent.isPresented = false }
        }

        /// Compact Stage Manager scenes keep the fitted popover; never an
        /// adaptive form sheet over the terminal.
        func adaptivePresentationStyle(
            for controller: UIPresentationController
        ) -> UIModalPresentationStyle {
            .none
        }

        func adaptivePresentationStyle(
            for controller: UIPresentationController,
            traitCollection: UITraitCollection
        ) -> UIModalPresentationStyle {
            .none
        }
    }
}
#endif

#if DEBUG
#Preview("History panel") {
    AgentHistoryPanel(
        agent: .claudeCode,
        controller: TerminalSessionController(
            route: TerminalRoute(
                hostID: UUID(), mode: .attach(sessionName: "main")
            ),
            host: Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        ),
        dismiss: {}
    )
    .padding()
    .background(Theme.screen)
}
#endif
