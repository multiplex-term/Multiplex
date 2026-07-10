import SwiftUI
#if DEBUG
import notify
#endif

/// Quick commands for the CLI agent (Claude Code / Codex) detected in the
/// attached session's active pane — a lower bezel under the screen. Chips
/// only ever *type* into the shell (through the same ordered input pump as
/// the keyboard), so a stale command fails visibly in the agent's own input
/// box and nothing auto-fires. Pro feature: locked state renders a single
/// pill that opens the paywall.
struct AgentHelperStrip: View {
    let agent: AgentKind
    let isPro: Bool
    /// Floating slab (visionOS ornament, UMD chrome) vs full-width bar
    /// (iPad, docked under the screen).
    var floating = false
    let send: (AgentCommand) -> Void
    let openPaywall: () -> Void

    var body: some View {
        if floating {
            row
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .frame(maxWidth: 760)
                .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.bezelHi, lineWidth: 1))
        } else {
            row
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bezel)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.bezelHi).frame(height: 1)
                }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            ChassisLabel(agent.displayName, size: 10, color: Theme.signal2)
            Rectangle().fill(Theme.bezelHi).frame(width: 1, height: 14)
            if isPro {
                chips
            } else {
                ChassisChip("AGENT HELPERS · PRO", prominent: true, action: openPaywall)
                Spacer(minLength: 0)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AgentCommandSet.primary(for: agent)) { command in
                        ChassisChip(command.label) { send(command) }
                    }
                }
            }
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
}

#if DEBUG
extension Notification.Name {
    static let multiplexDebugAgentChip = Notification.Name("MultiplexDebugAgentChip")
}

/// Headless-verification hook: `xcrun simctl spawn <udid> notifyutil -p
/// tools.bricks.multiplex.debug.agentchip` taps the focused terminal's
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
            "tools.bricks.multiplex.debug.agentchip", &token, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugAgentChip, object: nil)
        }
    }
}
#endif
