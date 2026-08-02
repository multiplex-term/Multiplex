import XCTest
@testable import Multiplex

/// Per-appearance terminal selection and the appearance choice itself.
/// Every test gets its own defaults suite and themes.json directory, so
/// nothing touches the app's real state.
@MainActor
final class ThemeStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "ThemeStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> ThemeStore {
        ThemeStore(defaults: defaults, directory: directory)
    }

    // MARK: Appearance

    func testAppearanceDefaultsToSystemAndPersists() {
        let store = makeStore()
        XCTAssertEqual(store.appearance, .system)

        store.appearance = .light
        XCTAssertEqual(makeStore().appearance, .light, "appearance survives relaunch")
    }

    func testResolvedOverrideMapping() {
        XCTAssertNil(AppAppearance.system.resolvedOverride, "system follows the device")
        XCTAssertEqual(AppAppearance.light.resolvedOverride, .light)
        XCTAssertEqual(AppAppearance.dark.resolvedOverride, .dark)
        XCTAssertEqual(AppAppearance.glass.resolvedOverride, .dark)
    }

    func testPersistedGlassFallsBackWhereThePrototypeIsUnavailable() {
        defaults.set(AppAppearance.glass.rawValue, forKey: "MultiplexAppearance")

        XCTAssertEqual(
            makeStore().appearance,
            GlassPrototype.enabled ? .glass : .system
        )
    }

    // MARK: Per-appearance selection

    func testEachAppearanceStartsOnItsHouseDefault() {
        let store = makeStore()
        XCTAssertEqual(store.selected(for: .dark).id, TerminalTheme.tally.id)
        XCTAssertEqual(store.selected(for: .light).id, TerminalTheme.tallyFrost.id)
    }

    func testSelectionsAreIndependentAndPersist() {
        let store = makeStore()
        store.select(.dracula, for: .dark)
        store.select(.tallyPaper, for: .light)
        XCTAssertEqual(store.selected(for: .dark).id, TerminalTheme.dracula.id)
        XCTAssertEqual(store.selected(for: .light).id, TerminalTheme.tallyPaper.id)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.selected(for: .dark).id, TerminalTheme.dracula.id)
        XCTAssertEqual(relaunched.selected(for: .light).id, TerminalTheme.tallyPaper.id)
    }

    /// Installs that predate light mode carry only the legacy key — it must
    /// keep meaning the dark slot, and the light slot starts on its default.
    func testLegacySelectionKeyStaysInDarkSlot() {
        defaults.set(TerminalTheme.nord.id, forKey: "MultiplexSelectedThemeID")
        let store = makeStore()
        XCTAssertEqual(store.selected(for: .dark).id, TerminalTheme.nord.id)
        XCTAssertEqual(store.selected(for: .light).id, TerminalTheme.lightDefault.id)
    }

    func testStaleSelectionFallsBackPerAppearance() {
        defaults.set("custom-deleted-long-ago", forKey: "MultiplexSelectedThemeID")
        defaults.set("custom-also-gone", forKey: "MultiplexSelectedLightThemeID")
        let store = makeStore()
        XCTAssertEqual(store.selected(for: .dark).id, TerminalTheme.tally.id)
        XCTAssertEqual(store.selected(for: .light).id, TerminalTheme.lightDefault.id)
    }

    func testRemovingCustomThemeResetsEverySlotThatUsedIt() {
        let store = makeStore()
        let custom = TerminalTheme.tally.asCustom(named: "Mine")
        store.add(custom)
        store.select(custom, for: .dark)
        store.select(custom, for: .light)

        store.remove(custom)
        XCTAssertEqual(store.selected(for: .dark).id, TerminalTheme.tally.id)
        XCTAssertEqual(store.selected(for: .light).id, TerminalTheme.lightDefault.id)
    }

    func testRemovingUnselectedThemeLeavesSlotsAlone() {
        let store = makeStore()
        let custom = TerminalTheme.nord.asCustom(named: "Nordish")
        store.add(custom)
        store.select(.gruvboxDark, for: .dark)
        store.select(.solarizedLight, for: .light)

        store.remove(custom)
        XCTAssertEqual(store.selected(for: .dark).id, TerminalTheme.gruvboxDark.id)
        XCTAssertEqual(store.selected(for: .light).id, TerminalTheme.solarizedLight.id)
    }
}
