import Foundation
import Observation

/// The sound screen's volume, app-wide and device-local — the text-size
/// store's shape for the same reasons: a level chosen while listening to one
/// file is the level the next should open at, in any window, and it answers
/// to the ears in front of the device, not to a host record. Applied to a
/// clip when it is made and followed by every open panel while it plays.
@MainActor
@Observable
final class FileViewerAudioVolumeStore {
    static let shared = FileViewerAudioVolumeStore()

    private static let key = "MultiplexFileViewerAudioVolume"
    private let defaults: UserDefaults

    private(set) var volume: Float

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.key) as? Double
        volume = stored.map { FileViewerAudioVolume.clamped(Float($0)) }
            ?? FileViewerAudioVolume.default
    }

    func set(_ value: Float) {
        let clamped = FileViewerAudioVolume.clamped(value)
        guard clamped != volume else { return }
        volume = clamped
        defaults.set(Double(clamped), forKey: Self.key)
    }
}
