import Foundation

/// Whether dictation runs the microphone through RNNoise first. On by
/// default, but only ever *active* once the model is installed — downloading
/// it from Settings is the opt-in, and this switch is the way back out
/// without deleting it. Device-local, never synced: the model itself is per
/// device.
enum NoiseReductionSetting {
    static let key = "MultiplexNoiseReduction"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
