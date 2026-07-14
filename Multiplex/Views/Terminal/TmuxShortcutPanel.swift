import SwiftUI

/// Custom TALLY dropdown shared by the iPad key rail and visionOS UMD.
/// It deliberately avoids the system Menu row treatment: commands live in a
/// compact, square grid with the human label, tmux command, and stock binding.
struct TmuxShortcutPanel: View {
    static let preferredWidth: CGFloat = 430
    private static let confirmationWindow: UInt64 = 2_000_000_000

    var width: CGFloat = Self.preferredWidth
    var select: (TmuxShortcut) -> Void

    @State private var armedShortcut: TmuxShortcut?
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                ChassisLabel("TMUX SHORTCUTS", size: 13)
                Spacer(minLength: 12)
                Text("DEFAULT PREFIX  ⌃B")
                    .font(.mono(9, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(Theme.signal2)
            }
            // The title needs breathing room from the rounded top-left
            // corner, without moving or resizing the command grid below it.
            .padding(.top, 6)
            .padding(.leading, 6)

            ForEach(TmuxShortcut.Group.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: 6) {
                    ChassisLabel(group.rawValue, size: 9, color: Theme.signal2)
                    LazyVGrid(columns: columns, spacing: 1) {
                        ForEach(TmuxShortcut.shortcuts(in: group)) { shortcut in
                            shortcutButton(shortcut)
                        }
                    }
                    .background(Theme.bezelHi)
                }
            }
        }
        .padding(14)
        .frame(width: width)
        // A nearby floating iPad keyboard changes the popover's available
        // presentation region. Without an intrinsic vertical boundary,
        // SwiftUI accepts that tall proposal and stretches this background
        // into a blank tail that covers the key rail. The command grid owns
        // its height; the system may reposition it, but never inflate it.
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bezel)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        .presentationBackground(Theme.bezel)
        .onDisappear { disarmTask?.cancel() }
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 1),
            GridItem(.flexible(), spacing: 1),
        ]
    }

    private func shortcutButton(_ shortcut: TmuxShortcut) -> some View {
        let isArmed = armedShortcut == shortcut
        return Button {
            activate(shortcut)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(shortcut.title.uppercased())
                        .font(.system(size: 10, weight: .bold).width(.compressed))
                        .kerning(0.8)
                        .foregroundStyle(Theme.signal)
                    Text(isArmed ? "press again to close" : shortcut.command)
                        .font(.mono(8))
                        .foregroundStyle(Theme.signal2)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(isArmed ? "AGAIN" : shortcut.bindingLabel)
                    .font(.mono(9, weight: .semibold))
                    .foregroundStyle(Theme.signal2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TmuxShortcutRowStyle(armed: isArmed))
        .chassisHover(2)
        .accessibilityLabel(accessibilityLabel(for: shortcut, isArmed: isArmed))
    }

    private func activate(_ shortcut: TmuxShortcut) {
        guard shortcut.requiresDoubleActivation else {
            disarm()
            select(shortcut)
            return
        }

        if armedShortcut == shortcut {
            disarm()
            select(shortcut)
            return
        }

        disarmTask?.cancel()
        armedShortcut = shortcut
        disarmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.confirmationWindow)
            guard !Task.isCancelled, armedShortcut == shortcut else { return }
            armedShortcut = nil
            disarmTask = nil
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        disarmTask = nil
        armedShortcut = nil
    }

    private func accessibilityLabel(
        for shortcut: TmuxShortcut, isArmed: Bool
    ) -> String {
        if isArmed {
            return "\(shortcut.title), press again to close"
        }
        if shortcut.requiresDoubleActivation {
            return "\(shortcut.title), \(shortcut.command), press twice to confirm"
        }
        return "\(shortcut.title), \(shortcut.command), \(shortcut.bindingLabel)"
    }
}

extension View {
    /// Modern SwiftUI presentation controllers can also be told explicitly
    /// to honor the content's fitted size. Older supported OS releases fall
    /// back to `fixedSize` on `TmuxShortcutPanel` itself.
    @ViewBuilder
    func tmuxShortcutPresentationSizing() -> some View {
        #if os(visionOS)
        if #available(visionOS 2.0, *) {
            presentationSizing(.fitted)
        } else {
            self
        }
        #else
        if #available(iOS 18.0, *) {
            presentationSizing(.fitted)
        } else {
            self
        }
        #endif
    }
}

private struct TmuxShortcutRowStyle: ButtonStyle {
    var armed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(armed || configuration.isPressed ? Theme.bezelHi : Theme.chassis)
            .overlay {
                if armed {
                    Rectangle().strokeBorder(Theme.signal2, lineWidth: 1)
                }
            }
    }
}
