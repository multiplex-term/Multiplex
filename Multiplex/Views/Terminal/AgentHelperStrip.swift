import SwiftUI
#if DEBUG
import notify
#endif

/// Quick commands for the CLI agent (Claude Code / Codex) detected in the
/// attached session's active pane — a lower bezel under the screen. Chips
/// only ever *type* into the shell (through the same ordered input pump as
/// the keyboard), so a stale command fails visibly in the agent's own input
/// box and nothing auto-fires. Free users receive a daily slash-command
/// taste; after it is spent, the strip passively becomes the Pro pill until
/// the next local day (no modal interrupts the terminal).
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
    /// Floating slab (visionOS ornament, UMD chrome) vs full-width bar
    /// (iPad, docked under the screen).
    var floating = false
    /// Live scene-width constraint supplied by the visionOS terminal window.
    /// Ornaments otherwise size from their contents and can outgrow a window
    /// after the user narrows it.
    var floatingMaximumWidth: CGFloat? = nil
    let send: (AgentCommand) -> Void
    let openPaywall: () -> Void

    var body: some View {
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

    private var row: some View {
        HStack(spacing: 10) {
            ChassisLabel(agent.displayName, size: 10, color: Theme.signal2)
            Rectangle().fill(Theme.bezelHi).frame(width: 1, height: 14)
            if canShowCommands {
                chips
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ChassisChip("✳ AGENT HELPERS · PRO", prominent: true, action: openPaywall)
                    Text("Free daily slash commands return tomorrow")
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
                }
                .frame(height: Self.chipHeight)
            }
            .frame(height: Self.chipHeight)
            .clipped()
            Menu {
                ForEach(AgentCommandSet.overflow(for: agent)) { command in
                    Button(command.label) { send(command) }
                }
            } label: {
                ChassisBadge("MORE")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .chassisHover(2)
            .accessibilityLabel("More \(agent.displayName) commands")
        }
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
}

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
