import SwiftUI

/// The app's settings surface, opened from the deck. Independent of any host —
/// today it holds terminal themes; future preferences slot in as new sections.
struct SettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

    /// Non-nil while the editor is pushed; a theme unknown to the store is
    /// a new one and is added (and selected) on save.
    @State private var editingTheme: TerminalTheme?
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(TerminalTheme.builtIns) { theme in
                        ThemeRow(theme: theme, isSelected: themes.selectedID == theme.id) {
                            themes.select(theme)
                        }
                        .contextMenu {
                            duplicateButton(for: theme)
                        }
                    }
                } header: {
                    Eyebrow("Terminal Theme")
                } footer: {
                    Text("Applies to every terminal window, live. Themes recolor the terminal surface only — the deck and window chrome keep the Tally chassis.")
                }

                Section {
                    ForEach(themes.customThemes) { theme in
                        ThemeRow(theme: theme, isSelected: themes.selectedID == theme.id) {
                            themes.select(theme)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { themes.remove(theme) }
                            Button("Edit") { editingTheme = theme }
                        }
                        .contextMenu {
                            Button("Edit…") { editingTheme = theme }
                            duplicateButton(for: theme)
                            Button("Delete", role: .destructive) { themes.remove(theme) }
                        }
                    }

                    Button {
                        editingTheme = themes.selected.asCustom(named: "New Theme")
                    } label: {
                        Label("New Theme…", systemImage: "plus")
                    }
                } header: {
                    Eyebrow("Your Themes")
                } footer: {
                    if themes.customThemes.isEmpty {
                        Text("A new theme starts from the colors of the one selected above.")
                    }
                }

                Section {
                    HStack {
                        Text("Agent Helpers")
                        Spacer()
                        Text(entitlements.isPro ? "Unlocked" : "Locked")
                            .foregroundStyle(.secondary)
                    }
                    Button("About Multiplex Pro…") { showingPaywall = true }
                    #if DEBUG
                    Toggle("Pro unlocked (debug)", isOn: Binding(
                        get: { entitlements.isPro },
                        set: { entitlements.setDebugUnlocked($0) }
                    ))
                    #endif
                } header: {
                    Eyebrow("Pro")
                } footer: {
                    Text("Agent Helpers shows quick commands in a terminal window when Claude Code or Codex is running in the attached session.")
                }
            }
            .sheet(isPresented: $showingPaywall) { ProPaywallView() }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $editingTheme) { theme in
                ThemeEditorView(theme: theme, onSave: save)
            }
        }
    }

    private func duplicateButton(for theme: TerminalTheme) -> some View {
        Button("Duplicate") {
            let copy = theme.asCustom(named: "\(theme.name) Copy")
            themes.add(copy)
            editingTheme = copy
        }
    }

    private func save(_ theme: TerminalTheme) {
        if themes.theme(id: theme.id) == nil {
            themes.add(theme)
            themes.select(theme)
        } else {
            themes.update(theme)
        }
    }
}

/// One selectable theme: live swatch, name, selection mark.
private struct ThemeRow: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 14) {
                ThemePreview(theme: theme, compact: true)
                    .frame(width: 148)
                Text(theme.name)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.signal : Theme.bezelHi)
                    .imageScale(.large)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name)\(isSelected ? ", selected" : "")")
    }
}

/// A theme rendered as what it is — a small terminal: prompt line, cursor,
/// and the ANSI palette. Every color shown is a color the theme defines.
struct ThemePreview: View {
    let theme: TerminalTheme
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            promptLine.font(.mono(fontSize)).lineLimit(1)
            if !compact {
                outputLine.font(.mono(fontSize)).lineLimit(1)
            }
            ansiStrip
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(theme.background),
            in: RoundedRectangle(cornerRadius: compact ? 9 : 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 9 : 14, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1)
        )
    }

    private var fontSize: CGFloat { compact ? 10 : 13 }

    private var promptLine: Text {
        Text("jhen@devbox").foregroundStyle(Color(theme.ansi(2)))
            + Text(" ~").foregroundStyle(Color(theme.ansi(4)))
            + Text(" $ tmux a").foregroundStyle(Color(theme.foreground))
            + Text(" █").foregroundStyle(Color(theme.cursor))
    }

    private var outputLine: Text {
        Text("✓ ").foregroundStyle(Color(theme.ansi(2)))
            + Text("attached · 3 windows").foregroundStyle(Color(theme.ansi(8)))
    }

    private var ansiStrip: some View {
        HStack(spacing: compact ? 3 : 4) {
            ForEach(compact ? Array(0..<8) : Array(0..<16), id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(theme.ansi(index)))
                    .frame(width: compact ? 8 : 12, height: compact ? 8 : 12)
            }
        }
    }
}

private extension TerminalTheme {
    /// Preview-safe palette access — an invalid custom theme must not crash
    /// the settings sheet.
    func ansi(_ index: Int) -> ThemeColor {
        ansi.indices.contains(index) ? ansi[index] : foreground
    }
}
