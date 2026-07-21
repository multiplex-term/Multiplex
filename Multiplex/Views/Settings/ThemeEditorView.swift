import SwiftUI

/// Edit a custom theme: name, surface colors, full ANSI table — with the
/// preview repainting as colors change. Works on a draft; nothing touches the
/// store until Save. Backing out (pop) discards the draft.
struct ThemeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (TerminalTheme) -> Void
    private let initialTheme: TerminalTheme
    @State private var draft: TerminalTheme

    init(theme: TerminalTheme, onSave: @escaping (TerminalTheme) -> Void) {
        self.onSave = onSave
        initialTheme = theme
        _draft = State(initialValue: theme)
    }

    var body: some View {
        VStack(spacing: 0) {
            livePreview

            ScrollView {
                VStack(spacing: 18) {
                    TallyFormSection(
                        "Theme identity",
                        detail: "Shown in Settings and anywhere this palette is selected."
                    ) {
                        TallyFormField("Name") {
                            TextField("Midnight", text: $draft.name)
                        }
                    }

                    TallyFormSection(
                        "Surface",
                        detail: "The terminal's canvas, text, and insertion cursor."
                    ) {
                        surfacePicker("Background", keyPath: \.background)
                        surfacePicker("Text", keyPath: \.foreground)
                        surfacePicker("Cursor", keyPath: \.cursor)
                    }

                    TallyFormSection(
                        "ANSI · Normal",
                        detail: "The eight standard colors emitted by terminal programs."
                    ) {
                        ansiPickers(0..<8)
                    }

                    TallyFormSection(
                        "ANSI · Bright",
                        detail: "The high-intensity variants used for bold and bright output."
                    ) {
                        ansiPickers(8..<16)
                    }
                }
                .frame(maxWidth: 680)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .chassisSheetGround()
        }
        .navigationTitle(draft.name.isEmpty ? "Theme" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ChassisSheetTitle(draft.name.isEmpty ? "Theme" : draft.name)
            ToolbarItem(placement: .confirmationAction) {
                ChassisBarButton("Save") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Lives outside the ScrollView so only the controls scroll. The draft still
    /// drives it directly, keeping every color change visible in context.
    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ChassisLabel("Live preview", size: 10)
                Spacer()
                Text(draft.name.isEmpty ? "UNTITLED" : draft.name.uppercased())
                    .font(.mono(8, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(Theme.signal3)
                    .lineLimit(1)
            }
            ThemePreview(theme: draft)
        }
        .frame(maxWidth: 680)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chassis)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.bezelHi).frame(height: 1)
        }
    }

    private func ansiPickers(_ range: Range<Int>) -> some View {
        ForEach(range, id: \.self) { index in
            colorPickerRow(
                TerminalTheme.ansiNames[index],
                color: draft.ansi[index],
                selection: ansiBinding(index),
                resetIsDisabled: draft.ansi[index] == initialTheme.ansi[index]
            ) {
                draft.ansi[index] = initialTheme.ansi[index]
            }
        }
    }

    private func surfacePicker(
        _ label: String,
        keyPath: WritableKeyPath<TerminalTheme, ThemeColor>
    ) -> some View {
        colorPickerRow(
            label,
            color: draft[keyPath: keyPath],
            selection: binding(keyPath),
            resetIsDisabled: draft[keyPath: keyPath] == initialTheme[keyPath: keyPath]
        ) {
            draft[keyPath: keyPath] = initialTheme[keyPath: keyPath]
        }
    }

    private func colorPickerRow(
        _ label: String,
        color: ThemeColor,
        selection: Binding<Color>,
        resetIsDisabled: Bool,
        reset: @escaping () -> Void
    ) -> some View {
        TallyFormRow {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.ui(11, weight: .medium))
                        .foregroundStyle(Theme.signal)
                    Text(color.hexString)
                        .font(.mono(9, weight: .medium))
                        .foregroundStyle(Theme.signal3)
                }
                Spacer()
                ColorPicker(label, selection: selection, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel(label)
                resetButton(label, isDisabled: resetIsDisabled, action: reset)
            }
        }
    }

    private func resetButton(
        _ label: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ChassisBadge("", systemImage: "arrow.counterclockwise")
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .chassisHover(2)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .accessibilityLabel("Reset \(label)")
    }

    private func binding(_ keyPath: WritableKeyPath<TerminalTheme, ThemeColor>) -> Binding<Color> {
        Binding(
            get: { Color(draft[keyPath: keyPath]) },
            set: { newValue in
                if let color = ThemeColor(newValue) {
                    draft[keyPath: keyPath] = color
                }
            }
        )
    }

    private func ansiBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { Color(draft.ansi[index]) },
            set: { newValue in
                if let color = ThemeColor(newValue) {
                    draft.ansi[index] = color
                }
            }
        )
    }
}

#if DEBUG
#Preview("Theme Editor") {
    NavigationStack {
        ThemeEditorView(
            theme: TerminalTheme.tally.asCustom(named: "Tally Custom"),
            onSave: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}
#endif
