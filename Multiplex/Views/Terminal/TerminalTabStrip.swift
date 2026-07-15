import SwiftUI

/// The window's tabs as multiviewer source labels: square cells in
/// compressed caps, each with its own tally dot — the wall's language at
/// terminal scale. Tap switches; the context menu closes a tab or splits
/// it out into its own window. Shown only when a window holds more than
/// one tab.
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
    var allowsSplit = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                tabCell(item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(items.count) tabs")
    }

    private func tabCell(_ item: Item) -> some View {
        Button {
            activate(item.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor(item))
                    .frame(width: 6, height: 6)
                    .shadow(
                        color: dotColor(item) == Theme.tally
                            ? Theme.tally.opacity(0.7) : .clear,
                        radius: 3)
                ChassisLabel(
                    item.hostName.map { "\(item.title) · \($0)" } ?? item.title,
                    size: 10,
                    color: item.isActive ? Theme.signal : Theme.signal2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(item.isActive ? Theme.bezelHi : Theme.chassis)
            .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chassisHover(3)
        .contextMenu {
            if items.count > 1, allowsSplit {
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

    /// The tab's tally: red = its shell is live, caution = linking,
    /// dim = ended.
    private func dotColor(_ item: Item) -> Color {
        guard let controller = item.controller else { return Theme.signal3 }
        switch controller.status {
        case .live: return Theme.tally
        case .connecting: return Theme.caution
        case .ended: return Theme.signal3
        }
    }
}

#if DEBUG
#Preview("Terminal tabs") {
    TerminalTabStrip(
        items: [
            .init(
                id: UUID(),
                title: "agent",
                hostName: "devbox",
                controller: nil,
                isActive: true
            ),
            .init(
                id: UUID(),
                title: "deploy",
                hostName: "prod",
                controller: nil,
                isActive: false
            ),
            .init(
                id: UUID(),
                title: "scratch",
                hostName: "devbox",
                controller: nil,
                isActive: false
            ),
        ],
        activate: { _ in },
        split: { _ in },
        close: { _ in }
    )
    .padding()
    .background(Theme.chassis)
}
#endif
