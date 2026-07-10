import SwiftUI

/// The window's tabs as physical cells — the deck's window-spine language
/// grown up: amber-lit active cell, mono session names, a live-status dot.
/// Tap switches; the context menu closes a tab or splits it out into its
/// own window. Shown only when a window holds more than one tab.
struct TerminalTabStrip: View {
    struct Item: Identifiable {
        let id: UUID
        var title: String
        /// Shown when the window's tabs span more than one host.
        var hostName: String?
        var controller: TerminalSessionController?
        var isActive: Bool
    }

    let items: [Item]
    let activate: (UUID) -> Void
    let split: (UUID) -> Void
    let close: (UUID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                tabCell(item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(items.count) tabs")
    }

    private func tabCell(_ item: Item) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Button {
            activate(item.id)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor(item))
                    .frame(width: 6, height: 6)
                Text(item.title)
                    .font(.mono(13, weight: item.isActive ? .semibold : .regular))
                    .lineLimit(1)
                if let host = item.hostName {
                    Text(host)
                        .font(.mono(11))
                        .opacity(0.65)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(item.isActive ? Theme.ink : Theme.textSecondary)
            .background(
                item.isActive ? AnyShapeStyle(Theme.phosphor) : AnyShapeStyle(Theme.inkRaised),
                in: shape
            )
            .overlay(
                shape.strokeBorder(item.isActive ? Theme.phosphor : Theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if items.count > 1 {
                Button {
                    split(item.id)
                } label: {
                    Label("Move to New Window", systemImage: "macwindow.badge.plus")
                }
            }
            Button(role: .destructive) {
                close(item.id)
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
        }
        .accessibilityLabel("\(item.title) tab\(item.isActive ? ", active" : "")")
    }

    private func statusColor(_ item: Item) -> Color {
        guard let controller = item.controller else { return Theme.line }
        switch controller.status {
        case .live: return item.isActive ? Theme.ink : Theme.phosphor
        case .connecting: return item.isActive ? Theme.ink.opacity(0.5) : Theme.phosphorDim
        case .ended: return item.isActive ? Theme.ink.opacity(0.35) : Theme.line
        }
    }
}
