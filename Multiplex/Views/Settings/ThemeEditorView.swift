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

            Divider()

            Form {
                Section("Name") {
                    TextField("Name", text: $draft.name, prompt: Text("Midnight"))
                }

                Section("Surface") {
                    surfacePicker("Background", keyPath: \.background)
                    surfacePicker("Text", keyPath: \.foreground)
                    surfacePicker("Cursor", keyPath: \.cursor)
                }

                Section("ANSI · Normal") {
                    ansiPickers(0..<8)
                }

                Section("ANSI · Bright") {
                    ansiPickers(8..<16)
                }
            }
        }
        .navigationTitle(draft.name.isEmpty ? "Theme" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Lives outside the Form so only the controls scroll. The draft still
    /// drives it directly, keeping every color change visible in context.
    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Live Preview")
            ThemePreview(theme: draft)
            Text("Updates as you change the surface and ANSI colors below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func ansiPickers(_ range: Range<Int>) -> some View {
        ForEach(range, id: \.self) { index in
            HStack(spacing: 8) {
                ColorPicker(
                    TerminalTheme.ansiNames[index],
                    selection: ansiBinding(index),
                    supportsOpacity: false
                )
                resetButton(
                    TerminalTheme.ansiNames[index],
                    isDisabled: draft.ansi[index] == initialTheme.ansi[index]
                ) {
                    draft.ansi[index] = initialTheme.ansi[index]
                }
            }
        }
    }

    private func surfacePicker(
        _ label: String,
        keyPath: WritableKeyPath<TerminalTheme, ThemeColor>
    ) -> some View {
        HStack(spacing: 8) {
            ColorPicker(label, selection: binding(keyPath), supportsOpacity: false)
            resetButton(
                label,
                isDisabled: draft[keyPath: keyPath] == initialTheme[keyPath: keyPath]
            ) {
                draft[keyPath: keyPath] = initialTheme[keyPath: keyPath]
            }
        }
    }

    private func resetButton(
        _ label: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(isDisabled)
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
