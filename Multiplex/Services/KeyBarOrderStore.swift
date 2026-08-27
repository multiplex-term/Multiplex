import Foundation
import Observation

/// The iPad/iPhone key rail's remembered order, app-wide and device-local
/// (like the side-panel widths): a phone's arrangement is the phone's
/// business — its tiers show a different subset of keys than an iPad's —
/// so it never rides the synced Host record or the Keychain mirror. Nothing
/// stored means the shipped order, exactly the rail before arranging existed.
@MainActor
@Observable
final class KeyBarOrderStore {
    static let shared = KeyBarOrderStore()

    nonisolated static let key = "MultiplexKeyBarOrder"

    private let defaults: UserDefaults
    private(set) var order: KeyBarOrder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = KeyBarOrder(tokens: defaults.stringArray(forKey: Self.key) ?? [])
    }

    func setOrder(_ order: KeyBarOrder) {
        guard order != self.order else { return }
        self.order = order
        if order.isStandard {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(order.tokens, forKey: Self.key)
        }
    }

    func reset() {
        setOrder(.standard)
    }
}
