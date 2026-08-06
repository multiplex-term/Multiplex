import Foundation
import Observation
import CoreGraphics

/// The reader's file-viewer text size, app-wide and device-local.
///
/// App-wide because a ▤ tab is a reading surface, not a document: a size
/// chosen while reading one file is the size the next file should open at,
/// including in another window. Device-local (plain `UserDefaults`, the
/// `ThemeStore` precedent) because it answers to the screen in front of the
/// reader, not to the host record — nothing here syncs.
@MainActor
@Observable
final class FileViewerTextScaleStore {
    static let shared = FileViewerTextScaleStore()

    private static let key = "MultiplexFileViewerTextScale"
    private let defaults: UserDefaults

    private(set) var scale: CGFloat

    /// `defaults` is injectable for tests; the app uses the standard suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.key) as? Double
        scale = stored.map { FileViewerTextScale.snapped(CGFloat($0)) }
            ?? FileViewerTextScale.default
    }

    func set(_ value: CGFloat) {
        let snapped = FileViewerTextScale.snapped(value)
        guard snapped != scale else { return }
        scale = snapped
        defaults.set(Double(snapped), forKey: Self.key)
    }

    /// One rung up or down — the Mac's A+ / A− chips.
    func step(by delta: Int) {
        set(FileViewerTextScale.stepping(scale, by: delta))
    }

    func canStep(by delta: Int) -> Bool {
        FileViewerTextScale.canStep(scale, by: delta)
    }
}
