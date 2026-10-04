import Foundation

/// The iPad single-window opt-in (Settings → Window mode). Default off: the
/// iPad keeps the classic deck plus one window per attach. Device-local.
///
/// Scenes resolve their presentation plan as they connect, so the choice is
/// latched per process — flipping it mid-run would leave a classic deck
/// opening Shell scenes, and remounting open windows would drop every tab.
/// It takes effect at the next launch. `MULTIPLEX_FORCE_SHELL` (DEBUG) wins.
enum SingleWindowShellSetting {
    private static let key = "MultiplexSingleWindowShellOnPad"

    static let enabledForThisLaunch = isEnabled()

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
