import Foundation
import Observation

/// Terminal theme selection and user-created themes. Custom themes persist as
/// JSON in Application Support (same pattern as hosts.json); the selected
/// theme id lives in UserDefaults. Built-ins come from `TerminalTheme.builtIns`
/// and are never written to disk.
@MainActor
@Observable
final class ThemeStore {
    private(set) var customThemes: [TerminalTheme] = []
    private(set) var selectedID: String

    private let fileURL: URL
    private static let selectedIDKey = "MultiplexSelectedThemeID"

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Multiplex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("themes.json")
        selectedID = UserDefaults.standard.string(forKey: Self.selectedIDKey)
            ?? TerminalTheme.multiplex.id
        load()
    }

    /// The active theme; a stale selection (deleted custom theme, renamed
    /// built-in) falls back to the house default rather than a blank screen.
    var selected: TerminalTheme {
        theme(id: selectedID) ?? .multiplex
    }

    var allThemes: [TerminalTheme] {
        TerminalTheme.builtIns + customThemes
    }

    func theme(id: String) -> TerminalTheme? {
        TerminalTheme.builtIn(id: id) ?? customThemes.first { $0.id == id }
    }

    func select(_ theme: TerminalTheme) {
        selectedID = theme.id
        UserDefaults.standard.set(selectedID, forKey: Self.selectedIDKey)
    }

    func add(_ theme: TerminalTheme) {
        guard theme.isValid, !theme.isBuiltIn else { return }
        customThemes.append(theme)
        save()
    }

    func update(_ theme: TerminalTheme) {
        guard theme.isValid,
              let index = customThemes.firstIndex(where: { $0.id == theme.id })
        else { return }
        customThemes[index] = theme
        save()
    }

    func remove(_ theme: TerminalTheme) {
        customThemes.removeAll { $0.id == theme.id }
        if selectedID == theme.id {
            select(.multiplex)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoded = (try? JSONDecoder().decode([TerminalTheme].self, from: data)) ?? []
        customThemes = decoded.filter { $0.isValid && !$0.isBuiltIn }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(customThemes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
