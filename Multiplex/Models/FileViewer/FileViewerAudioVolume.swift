import Foundation

/// The listener's level for the file viewer's sound screen — a plain 0…1
/// gain under the device volume, so a loud sample can be turned down without
/// reaching for the hardware. Pure: the clamp and the readout.
enum FileViewerAudioVolume {
    static let `default`: Float = 1

    static func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return `default` }
        return min(1, max(0, value))
    }

    /// Panel readout: `100%`, `35%`, `0%`.
    static func percentLabel(_ value: Float) -> String {
        "\(Int((clamped(value) * 100).rounded()))%"
    }
}
