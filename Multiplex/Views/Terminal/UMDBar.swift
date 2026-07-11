import SwiftUI

/// The under-monitor display: every broadcast monitor wears one. Source
/// label, captioned status lamp, and the window's controls as chassis
/// chips. Deliberately opaque — the UMD is hardware, not glass.
struct UMDBar: View {
    var controller: TerminalSessionController?
    var title: String
    var mergeSources: [TerminalWorkspace.WindowEntry]
    var showDeck: () -> Void
    var summonKeyboard: () -> Void
    var fontDown: () -> Void
    var fontUp: () -> Void
    /// New tab: a fresh session on the active tab's host, in its pane's
    /// directory — nil for a plain shell session, or an agent to launch.
    var newSession: (AgentKind?) -> Void
    var merge: (UUID) -> Void
    var detach: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ChassisChip("DECK", action: showDeck)
            divider
            ChassisLabel(title, size: 12)
            statusCluster
            divider
            ChassisChip("KBD", action: summonKeyboard)
            ChassisChip("A−", action: fontDown)
            ChassisChip("A+", action: fontUp)
            // Tap = new session in the same directory; long press picks an
            // agent variant — mirrors the deck tile's quick options.
            Menu {
                Button("New Session") { newSession(nil) }
                Button("New Session + Claude Code") { newSession(.claudeCode) }
                Button("New Session + Codex") { newSession(.codex) }
            } label: {
                ChassisBadge("TAB", systemImage: "plus")
            } primaryAction: {
                newSession(nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .chassisHover(2)
            .accessibilityLabel("New tab: another session in this window")
            if !mergeSources.isEmpty {
                Menu {
                    ForEach(mergeSources) { entry in
                        Button {
                            merge(entry.id)
                        } label: {
                            Label(entry.label, systemImage: "macwindow")
                        }
                    }
                    if mergeSources.count > 1 {
                        Divider()
                        Button {
                            for entry in mergeSources { merge(entry.id) }
                        } label: {
                            Label("Merge All Windows", systemImage: "rectangle.stack")
                        }
                    }
                } label: {
                    ChassisBadge("MERGE")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel("Merge another window into this one")
            }
            divider
            ChassisChip("DETACH", prominent: true, action: detach)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Theme.bezelHi).frame(width: 1, height: 18)
    }

    /// The window's lamp: LIVE (tally, captioned), LINK while the shell
    /// connects, ENDED when the channel closed. A mosh tab that's live but
    /// out of contact reads NO LINK — the session is intact and self-heals,
    /// so it's caution, not a fault.
    @ViewBuilder
    private var statusCluster: some View {
        switch controller?.status {
        case .live:
            if controller?.contactLost == true {
                TallyLamp(caption: "NO LINK", color: Theme.caution)
            } else {
                TallyLamp()
            }
        case .connecting:
            TallyLamp(caption: controller?.host.useMosh == true ? "MOSH" : "LINK", color: Theme.caution)
        case .ended:
            TallyLamp(caption: "ENDED", color: Theme.signal3)
        case nil:
            EmptyView()
        }
    }
}
