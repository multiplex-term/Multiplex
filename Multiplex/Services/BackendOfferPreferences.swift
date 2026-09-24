import Foundation

/// Which backend offers this device has been told to stop showing.
///
/// Deliberately device-local (`UserDefaults`, beside `NewSessionPreferences`)
/// and never part of the synced `Host` record: dismissing an offer is a
/// this-device annoyance judgement — "I know, stop mentioning it here" — not
/// a fleet fact about the machine. Opting a backend IN is the opposite and
/// does ride the record (`Host.secondaryBackends`), because it changes what
/// the host costs to monitor everywhere.
///
/// A dismissal silences the chip only. Discovery keeps running (it is ~1 ms),
/// Host Settings keeps its switch, and turning the backend on there clears
/// the dismissal so the two surfaces can't contradict each other.
struct BackendOfferPreferences {
    private static let dismissedKey = "backendOffer.dismissed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isDismissed(_ backend: Host.SessionBackend, for hostID: UUID) -> Bool {
        stored()[hostID.uuidString]?.contains(backend.rawValue) ?? false
    }

    func setDismissed(
        _ dismissed: Bool, backend: Host.SessionBackend, for hostID: UUID
    ) {
        var all = stored()
        var backends = Set(all[hostID.uuidString] ?? [])
        if dismissed {
            backends.insert(backend.rawValue)
        } else {
            backends.remove(backend.rawValue)
        }
        // Sorted so the stored plist stays stable across launches.
        all[hostID.uuidString] = backends.isEmpty ? nil : backends.sorted()
        write(all)
    }

    /// The host was deleted. Nothing else prunes this, and a recycled UUID
    /// is not a thing, so an orphan entry would simply persist forever.
    func forget(hostID: UUID) {
        var all = stored()
        guard all.removeValue(forKey: hostID.uuidString) != nil else { return }
        write(all)
    }

    private func stored() -> [String: [String]] {
        defaults.dictionary(forKey: Self.dismissedKey) as? [String: [String]] ?? [:]
    }

    private func write(_ all: [String: [String]]) {
        if all.isEmpty {
            defaults.removeObject(forKey: Self.dismissedKey)
        } else {
            defaults.set(all, forKey: Self.dismissedKey)
        }
    }
}
