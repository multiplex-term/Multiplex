import SwiftUI
#if !os(visionOS)
import UIKit
#endif
#if DEBUG
import notify
#endif

/// Quick commands for the CLI agent (Claude Code / Codex) detected in the
/// attached session's active pane — a lower bezel under the screen. Chips
/// only ever travel through the shell's ordered input pump, so a stale command
/// fails visibly in the agent's own input box. Auto Submit follows the text
/// with a delayed Return. Free users receive a daily agent-command taste;
/// after it is spent, the strip passively becomes the Pro pill until the next
/// local day (no modal interrupts the terminal).
struct AgentHelperStrip: View {
    static let dockedHeight: CGFloat = 48
    /// ChassisBadge's 9 pt mono label plus 5 pt vertical padding per side.
    /// The horizontal scroll viewport must own this cross-axis size; leaving
    /// it unconstrained lets iPadOS stretch the button container below its
    /// bordered face.
    private static let chipHeight: CGFloat = 22
    #if os(visionOS)
    /// Keep the ornament inside the window's resize controls at either
    /// bottom corner. The command row scrolls inside this narrower slab.
    static let maximumFloatingWidth: CGFloat = 760
    static let floatingEdgeClearance: CGFloat = 60
    #endif

    let agent: AgentKind
    let canShowCommands: Bool
    let customCommands: [CustomAgentCommand]
    /// Floating slab (visionOS ornament, UMD chrome) vs full-width bar
    /// (iPad, docked under the screen).
    var floating = false
    /// Live scene-width constraint supplied by the visionOS terminal window.
    /// Ornaments otherwise size from their contents and can outgrow a window
    /// after the user narrows it.
    var floatingMaximumWidth: CGFloat? = nil
    let send: (AgentCommand) -> Void
    let saveCustomCommands: ([CustomAgentCommand]) -> Void
    let openPaywall: () -> Void

    @State private var showingCustomCommands = false
    @State private var customCommandEditorID = UUID()

    var body: some View {
        Group {
            if floating {
                row
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .frame(maxWidth: floatingMaximumWidth ?? 760)
                    .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.bezelHi, lineWidth: 1))
            } else {
                row
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(height: Self.dockedHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bezel)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.bezelHi).frame(height: 1)
                    }
                    // This strip is overlaid above the UIKit key rail with a
                    // transparent bottom spacer. A horizontal ScrollView can
                    // retain the overlay's taller proposal on iPadOS and let its
                    // chip faces paint through that spacer, covering the rail.
                    // The docked chassis is physically 48 pt tall; contain every
                    // descendant to that declared surface.
                    .clipped()
            }
        }
        // A pane switch may replace Claude Code with Codex in the same view
        // identity. Never let one agent's open drafts relabel or save into the
        // other agent's profile.
        .onChange(of: agent) { showingCustomCommands = false }
    }

    private var row: some View {
        HStack(spacing: 10) {
            ChassisLabel(agent.displayName, size: 10, color: Theme.signal2)
            Rectangle().fill(Theme.bezelHi).frame(width: 1, height: 14)
            if canShowCommands {
                chips
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ChassisChip("✳ AGENT HELPERS · PRO", prominent: true, action: openPaywall)
                    Text("Free daily command taps return tomorrow")
                        .font(.mono(8, weight: .medium))
                        .foregroundStyle(Theme.signal3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AgentCommandSet.primary(for: agent)) { command in
                        commandChip(command)
                    }
                    ForEach(barCustomCommands) { command in
                        customCommandChip(command)
                    }
                }
                .frame(height: Self.chipHeight)
            }
            .frame(height: Self.chipHeight)
            .clipped()
            #if os(visionOS)
            moreMenu
            .popover(
                isPresented: $showingCustomCommands,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                CustomAgentCommandPanel(
                    agent: agent,
                    commands: customCommands,
                    save: {
                        saveCustomCommands($0)
                        showingCustomCommands = false
                    },
                    cancel: { showingCustomCommands = false }
                )
                .id(customCommandEditorID)
                .presentationCompactAdaptation(.popover)
                .customCommandPresentationSizing()
            }
            #else
            moreMenu
                .background {
                    CustomAgentCommandPopoverPresenter(
                        isPresented: $showingCustomCommands,
                        agent: agent,
                        commands: customCommands,
                        editorID: customCommandEditorID,
                        save: {
                            saveCustomCommands($0)
                            showingCustomCommands = false
                        },
                        cancel: { showingCustomCommands = false }
                    )
                    .allowsHitTesting(false)
                }
            #endif
        }
    }

    private var moreMenu: some View {
        Menu {
            ForEach(AgentCommandSet.overflow(for: agent)) { command in
                Button(command.label) { send(command) }
            }
            if !moreCustomCommands.isEmpty {
                Divider()
                Section("Custom") {
                    ForEach(moreCustomCommands) { command in
                        Button(command.menuLabel) { send(command.agentCommand) }
                    }
                }
            }
            Divider()
            Button {
                // A fresh identity makes CANCEL genuinely discard drafts
                // when the same editor is opened again.
                customCommandEditorID = UUID()
                showingCustomCommands = true
            } label: {
                Label("Custom Commands…", systemImage: "slider.horizontal.3")
            }
        } label: {
            ChassisBadge("MORE")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel("More \(agent.displayName) commands")
    }

    private var barCustomCommands: [CustomAgentCommand] {
        customCommands.filter { $0.barLabel != nil }
    }

    private var moreCustomCommands: [CustomAgentCommand] {
        customCommands.filter { $0.barLabel == nil }
    }

    /// Keep the design-system face while owning the button's physical height
    /// directly. `ChassisChip`'s cross-platform hover wrapper can accept the
    /// horizontal ScrollView's taller iPad proposal and paint a second dark
    /// block beneath its bordered label. visionOS still receives the required
    /// chassis hover treatment; iPad gets the plain touch button it needs.
    @ViewBuilder
    private func commandChip(_ command: AgentCommand) -> some View {
        let button = Button {
            send(command)
        } label: {
            ChassisBadge(command.label)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .frame(height: Self.chipHeight)
        .clipped()
        .accessibilityLabel(command.label.capitalized)

        #if os(visionOS)
        button.chassisHover(2)
        #else
        button
        #endif
    }

    /// User-authored commands use a warmer neutral than stock actions. The
    /// color carries provenance, not state; auto-submit behavior remains in
    /// the editor and accessibility copy rather than a semantic signal hue.
    @ViewBuilder
    private func customCommandChip(_ command: CustomAgentCommand) -> some View {
        let button = Button {
            send(command.agentCommand)
        } label: {
            ChassisBadge(command.barLabel ?? command.menuLabel, color: Theme.customCommand)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .frame(height: Self.chipHeight)
        .clipped()
        .accessibilityLabel(
            "Custom command \(command.menuLabel), \(command.autoSubmit ? "auto submit" : "type only")"
        )

        #if os(visionOS)
        button.chassisHover(2)
        #else
        button
        #endif
    }
}

#if !os(visionOS)
/// UIKit-backed iPad presentation for the Custom Commands editor. SwiftUI's
/// popover host accepts a keyboard-adjusted, full-height proposal when the
/// floating keyboard sits near MORE, inflating the panel with a blank bottom
/// tail. As with the tmux shortcuts panel, the measured content size is the
/// boundary and only the popover container contributes a safe area.
private struct CustomAgentCommandPopoverPresenter: UIViewRepresentable {
    @Binding var isPresented: Bool

    let agent: AgentKind
    let commands: [CustomAgentCommand]
    let editorID: UUID
    let save: ([CustomAgentCommand]) -> Void
    let cancel: () -> Void

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
        var parent: CustomAgentCommandPopoverPresenter

        private weak var controller: UIViewController?
        private var presentationScheduled = false

        init(parent: CustomAgentCommandPopoverPresenter) {
            self.parent = parent
        }

        func update(anchor: UIView) {
            guard parent.isPresented else {
                dismiss(animated: true)
                return
            }
            guard controller == nil, !presentationScheduled else { return }

            // Let the Menu finish its selection transaction before presenting
            // another controller from the same SwiftUI host.
            presentationScheduled = true
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self else { return }
                self.presentationScheduled = false
                guard self.parent.isPresented,
                      self.controller == nil,
                      let anchor
                else { return }
                self.present(from: anchor)
            }
        }

        func dismiss(animated: Bool) {
            presentationScheduled = false
            guard let controller else { return }
            self.controller = nil
            controller.dismiss(animated: animated)
        }

        private func present(from anchor: UIView) {
            guard let presenter = presentingViewController(from: anchor) else { return }

            let sceneWidth = anchor.window?.bounds.width ?? presenter.view.bounds.width
            let panelWidth = min(
                CustomAgentCommandPanel.preferredWidth,
                max(280, sceneWidth - 24)
            )
            let panel = CustomAgentCommandPanel(
                agent: parent.agent,
                commands: parent.commands,
                width: panelWidth,
                save: { [weak self] commands in self?.parent.save(commands) },
                cancel: { [weak self] in self?.parent.cancel() }
            )
            .id(parent.editorID)

            let controller = UIHostingController(rootView: panel)
            self.controller = controller
            // Keep the ordinary rounded-window/popover boundary, but exclude
            // the floating keyboard from SwiftUI's content-safe-area proposal.
            controller.safeAreaRegions = .container
            // ADD/DELETE changes the editor's intrinsic height after the
            // controller is already presented. Keep UIKit's popover boundary
            // synchronized with each SwiftUI measurement instead of freezing
            // the one-row size calculated below.
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

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            controller = nil
            if parent.isPresented { parent.isPresented = false }
        }

        /// Compact Stage Manager scenes still have room for this fitted
        /// editor; never replace the terminal with an adaptive form sheet.
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
extension Notification.Name {
    static let multiplexDebugAgentChip = Notification.Name("MultiplexDebugAgentChip")
}

/// Headless-verification hook: `xcrun simctl spawn <udid> notifyutil -p
/// app.multiplexterm.multiplex.debug.agentchip` taps the focused terminal's
/// first slash chip — the whole tap → pump → PTY → tmux → pane path without
/// touching the screen. The Darwin notification fans out through
/// NotificationCenter; the terminal window that owns keyboard focus reacts.
@MainActor
enum AgentChipDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.agentchip", &token, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugAgentChip, object: nil)
        }
    }
}
#endif
