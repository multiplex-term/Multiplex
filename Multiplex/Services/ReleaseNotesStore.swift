import Foundation

/// The release whose notes this device has already been shown.
///
/// Deliberately device-local (`UserDefaults`, beside `BackendOfferPreferences`
/// and `NewSessionPreferences`) and never part of the synced Host record:
/// updating on iPad must not consume the notice on Vision Pro. Each device
/// updates on its own day and is owed the notes on the launch that follows.
struct ReleaseNotesStore {
    private static let lastSeenKey = "releaseNotes.lastSeenVersion"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `nil` on any install that predates this stamp — which is every device
    /// updating from 1.2, so it cannot be read as "first run" on its own.
    /// `ReleaseNotesGate` is where that distinction is made.
    var lastSeenVersion: String? {
        defaults.string(forKey: Self.lastSeenKey)
    }

    /// Stamped when the card appears rather than when it is dismissed: a
    /// force-quit mid-animation should not turn a one-time notice into a
    /// recurring visitor. Settings ▸ About ▸ What's New is the way back.
    func markSeen(_ version: String) {
        defaults.set(version, forKey: Self.lastSeenKey)
    }
}
