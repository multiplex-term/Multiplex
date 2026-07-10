import SwiftUI

/// Edit a custom theme: name, surface colors, full ANSI table — with the
/// preview repainting as colors change. Works on a draft; nothing touches the
/// store until Save. Backing out (pop) discards the draft.
struct ThemeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (TerminalTheme) -> Void
    @State private var draft: TerminalTheme

    init(theme: TerminalTheme, onSave: @escaping (TerminalTheme) -> Void) {
        self.onSave = onSave
        _draft = State(initialValue: theme)
    }

    var body: some View {
        Form {
            Section {
                ThemePreview(theme: draft)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Name") {
                TextField("Name", text: $draft.name, prompt: Text("Midnight"))
            }

            Section("Surface") {
                ColorPicker("Background", selection: binding(\.background), supportsOpacity: false)
                ColorPicker("Text", selection: binding(\.foreground), supportsOpacity: false)
                ColorPicker("Cursor", selection: binding(\.cursor), supportsOpacity: false)
            }

            Section("ANSI · Normal") {
                ansiPickers(0..<8)
            }

            Section("ANSI · Bright") {
                ansiPickers(8..<16)
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

    private func ansiPickers(_ range: Range<Int>) -> some View {
        ForEach(range, id: \.self) { index in
            ColorPicker(
                TerminalTheme.ansiNames[index],
                selection: ansiBinding(index),
                supportsOpacity: false
            )
        }
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
