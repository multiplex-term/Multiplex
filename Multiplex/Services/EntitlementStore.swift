import Foundation
import Observation

/// The Pro gate. v1 ships the seam without the commerce: `isPro` is a
/// UserDefaults flag, and the future StoreKit 2 work (non-consumable
/// `dev.multiplexterm.multiplex.pro`, `Transaction.currentEntitlements` listener,
/// restore) replaces only this type's internals — nothing outside it may
/// know how entitlement is decided. DEBUG builds default to unlocked so
/// daily development and the headless harness exercise the real feature;
/// the Settings toggle previews the locked state.
@MainActor
@Observable
final class EntitlementStore {
    private static let unlockedKey = "MultiplexProUnlocked"
    private let defaults: UserDefaults

    private(set) var isPro: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        isPro = defaults.object(forKey: Self.unlockedKey) as? Bool ?? true
        #else
        isPro = defaults.bool(forKey: Self.unlockedKey)
        #endif
    }

    #if DEBUG
    func setDebugUnlocked(_ unlocked: Bool) {
        defaults.set(unlocked, forKey: Self.unlockedKey)
        isPro = unlocked
    }
    #endif
}
