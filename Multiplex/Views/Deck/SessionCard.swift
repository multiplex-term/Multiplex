import SwiftUI

/// An ink-dark card floating on glass: one tmux session, its window spine,
/// and the one verb that matters.
struct SessionCard: View {
    let session: TmuxSession
    let attach: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.name)
                    .font(.mono(20, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                if session.isAttached {
                    attachedBadge
                }
            }

            HStack(spacing: 12) {
                WindowSpine(windows: session.windows)

                Text(windowSummary)
                    .font(.mono(13))
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                Button(action: attach) {
                    Text("Attach")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.phosphor)
                .foregroundStyle(Theme.ink)
            }
        }
        .padding(18)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    private var attachedBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.phosphor).frame(width: 6, height: 6)
            Text("attached")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.phosphor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.phosphor.opacity(0.14), in: Capsule())
    }

    private var windowSummary: String {
        session.windowCount == 1 ? "1 window" : "\(session.windowCount) windows"
    }
}
