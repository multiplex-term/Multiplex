import Foundation
import Observation
#if DEBUG
import notify
#endif

/// The resolved light/dark appearance currently painting a scene. This is an
/// app-owned value instead of SwiftUI's `ColorScheme`, so theme selection is
/// equally usable from UIKit scene/view-controller code and pure tests.
enum ResolvedAppearance: String, CaseIterable {
    case light
    case dark
}

/// The app-wide appearance choice, persisted by `ThemeStore` and applied at
/// every scene root by `PlatformChrome`. `.system` follows the device (and on
/// visionOS keeps the platform's native appearance); the other choices pin the
/// chassis (GLASS to dark traits). Chassis tokens themselves are trait-dynamic
/// (`Theme`), so the whole chrome — deck, terminal windows, sheets, launch
/// handoff — flips
/// together.
enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark
    /// PROTOTYPE(GLASS): the SMOKE glass chassis as an independent choice —
    /// visionOS only, derived from the dark palette (dark traits + the dark
    /// terminal-theme slot). Exists only where the prototype is compiled in.
    case glass

    /// The choices a platform's Settings bar offers and the DEBUG
    /// appearance hook cycles. GLASS is visionOS DEBUG only.
    static var availableCases: [AppAppearance] {
        #if os(visionOS) && DEBUG
        allCases
        #else
        [.system, .light, .dark]
        #endif
    }

    /// The pinned appearance, when there is one. `nil` means follow the
    /// scene's UIKit traits.
    var resolvedOverride: ResolvedAppearance? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .glass: return .dark
        }
    }
}

/// Terminal theme selection and user-created themes. Custom themes persist as
/// JSON in Application Support (same pattern as hosts.json); the selected
/// theme ids and the appearance choice live in UserDefaults. Built-ins come
/// from `TerminalTheme.builtIns` and are never written to disk.
///
/// Each appearance keeps its own terminal selection: the dark slot keeps the
/// pre-appearance key (existing installs keep their theme), the light slot
/// defaults to the light house theme. Settings always edits the slot of the
/// appearance currently on screen, so "pick a theme" never needs a second UI.
@MainActor
@Observable
final class ThemeStore {
    private(set) var customThemes: [TerminalTheme] = []
    /// The dark-appearance selection (legacy key — predates light mode).
    private(set) var selectedID: String
    /// The light-appearance selection.
    private(set) var selectedLightID: String

    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
        }
    }

    private let defaults: UserDefaults
    private let fileURL: URL
    private static let selectedIDKey = "MultiplexSelectedThemeID"
    private static let selectedLightIDKey = "MultiplexSelectedLightThemeID"
    private static let appearanceKey = "MultiplexAppearance"

    /// `defaults`/`directory` are injectable for tests; the app uses the
    /// standard defaults and Application Support.
    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Multiplex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("themes.json")
        selectedID = defaults.string(forKey: Self.selectedIDKey)
            ?? TerminalTheme.tally.id
        selectedLightID = defaults.string(forKey: Self.selectedLightIDKey)
            ?? TerminalTheme.lightDefault.id
        let storedAppearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        // A persisted GLASS choice on a platform/build without the prototype
        // falls back to SYSTEM rather than acting as a hidden DARK.
        appearance = AppAppearance.availableCases.contains(storedAppearance)
            ? storedAppearance : .system
        load()
        #if DEBUG
        installDebugAppearanceHook()
        #endif
    }

    #if DEBUG
    /// Headless-verification hook: the appearance choice bar can't be tapped
    /// from the CLI, so
    /// `xcrun simctl spawn <udid> notifyutil -p app.multiplexterm.multiplex.debug.appearance`
    /// cycles the platform's available choices through the exact property the
    /// Settings bar sets — proving the live window-override flip (open sheets
    /// included) and the persisted choice.
    private func installDebugAppearanceHook() {
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.appearance", &token, .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let all = AppAppearance.availableCases
                let index = all.firstIndex(of: self.appearance) ?? 0
                self.appearance = all[(index + 1) % all.count]
            }
        }
    }
    #endif

    /// The active theme for a chassis appearance; a stale selection (deleted
    /// custom theme, renamed built-in) falls back to that appearance's house
    /// default rather than a blank screen.
    func selected(for appearance: ResolvedAppearance) -> TerminalTheme {
        theme(id: selectedID(for: appearance)) ?? Self.fallback(for: appearance)
    }

    func selectedID(for appearance: ResolvedAppearance) -> String {
        appearance == .light ? selectedLightID : selectedID
    }

    var allThemes: [TerminalTheme] {
        TerminalTheme.builtIns + customThemes
    }

    func theme(id: String) -> TerminalTheme? {
        TerminalTheme.builtIn(id: id) ?? customThemes.first { $0.id == id }
    }

    func select(_ theme: TerminalTheme, for appearance: ResolvedAppearance) {
        if appearance == .light {
            selectedLightID = theme.id
            defaults.set(selectedLightID, forKey: Self.selectedLightIDKey)
        } else {
            selectedID = theme.id
            defaults.set(selectedID, forKey: Self.selectedIDKey)
        }
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

    /// Removing a theme resets whichever appearance slots pointed at it.
    func remove(_ theme: TerminalTheme) {
        customThemes.removeAll { $0.id == theme.id }
        if selectedID == theme.id {
            select(Self.fallback(for: .dark), for: .dark)
        }
        if selectedLightID == theme.id {
            select(Self.fallback(for: .light), for: .light)
        }
        save()
    }

    private static func fallback(for appearance: ResolvedAppearance) -> TerminalTheme {
        appearance == .light ? .lightDefault : .tally
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
