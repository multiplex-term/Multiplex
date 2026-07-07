import SwiftUI

/// The signature element: a session's tmux windows as a row of physical cells —
/// the tmux status line materialized. Active window is amber-lit; a raised dot
/// marks bell/activity. Every pixel encodes real state.
struct WindowSpine: View {
    let windows: [TmuxWindow]
    var cellSize: CGSize = .init(width: 22, height: 14)

    private let cellShape = RoundedRectangle(cornerRadius: 3.5, style: .continuous)

    var body: some View {
        HStack(spacing: 5) {
            ForEach(windows) { window in
                cell(for: window)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spineDescription)
    }

    private func cell(for window: TmuxWindow) -> some View {
        ZStack {
            cellShape.fill(window.isActive ? Theme.phosphor : Theme.inkRaised)
            cellShape.strokeBorder(window.isActive ? Theme.phosphor : Theme.line, lineWidth: 1)
        }
        .frame(width: cellSize.width, height: cellSize.height)
        .overlay(alignment: .topTrailing) {
            if window.hasBell || window.hasActivity {
                Circle()
                    .fill(window.isActive ? Theme.ink : Theme.phosphor)
                    .frame(width: 4, height: 4)
                    .padding(3)
            }
        }
        .shadow(color: window.isActive ? Theme.phosphor.opacity(0.55) : .clear, radius: 5)
    }

    private var spineDescription: String {
        let active = windows.first(where: \.isActive).map { "\($0.name) active" } ?? ""
        return "\(windows.count) windows. \(active)"
    }
}
