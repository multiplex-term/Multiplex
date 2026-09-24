import Foundation

/// The experimental Metal terminal renderer switch (Settings → Terminal
/// renderer). Default off — the CoreGraphics damage-strip path stays the
/// shipping renderer until Metal survives a real-device A/B against it.
/// The `MULTIPLEX_METAL=1` env var (harness runs, Xcode scheme env) forces
/// it on regardless of the persisted choice; end users have no way to set
/// process env, so shipping builds only reach Metal through the toggle.
enum MetalRendererSetting {
    static let key = "MultiplexMetalRenderer"

    static var isEnabled: Bool {
        isEnabled(defaults: .standard)
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        if ProcessInfo.processInfo.environment["MULTIPLEX_METAL"] == "1" {
            return true
        }
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
