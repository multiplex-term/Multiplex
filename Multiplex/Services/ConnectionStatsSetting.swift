import Foundation

/// The global connection-stats kill switch (Settings → Connection stats).
/// Default ON: every measurement is passive — numbers the transports and
/// probe already compute — so collection costs nothing beyond memory. OFF is
/// fully off: the center stops recording and drops its buffers, and every
/// chip and panel entry disappears with it. Device-local, never synced.
/// `ConnectionStatsCenter` is the only reader and the only writer — every
/// other surface asks the center, whose `isCollecting` mirror stays honest
/// exactly because nothing else touches this key.
enum ConnectionStatsSetting {
    static let key = "MultiplexConnectionStats"

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
