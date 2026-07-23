import XCTest
@testable import Multiplex

/// The app lock's decisions — enable-requires-auth, background locking, the
/// once-per-lock automatic prompt — with the LocalAuthentication boundary
/// injected. The shipping authenticator itself is a thin `LAContext` call.
@MainActor
final class AppLockStoreTests: XCTestCase {
    /// Counts authentication attempts and answers with a scripted verdict.
    @MainActor
    private final class AuthDouble {
        var verdict = true
        private(set) var attempts = 0

        func authenticate(_ reason: String) async -> Bool {
            attempts += 1
            return verdict
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "AppLockStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeStore(
        defaults: UserDefaults? = nil,
        auth: AuthDouble
    ) -> AppLockStore {
        AppLockStore(
            defaults: defaults ?? makeDefaults(),
            authenticate: { await auth.authenticate($0) }
        )
    }

    func testDisabledByDefaultAndNeverLocks() {
        let auth = AuthDouble()
        let store = makeStore(auth: auth)
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.isLocked)

        store.lock()
        XCTAssertFalse(store.isLocked, "A disabled lock must ignore backgrounding")
    }

    func testEnableRequiresSuccessfulAuthentication() async {
        let defaults = makeDefaults()
        let auth = AuthDouble()
        let store = makeStore(defaults: defaults, auth: auth)

        auth.verdict = false
        await store.setEnabled(true)
        XCTAssertFalse(store.isEnabled, "A failed confirmation must not enable the lock")
        XCTAssertEqual(auth.attempts, 1)

        auth.verdict = true
        await store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        XCTAssertFalse(store.isLocked, "Enabling happens inside an unlocked app")

        // The choice persists: a relaunch starts locked.
        let relaunched = makeStore(defaults: defaults, auth: auth)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertTrue(relaunched.isLocked)
    }

    func testBackgroundLocksAndUnlockClears() async {
        let auth = AuthDouble()
        let store = makeStore(auth: auth)
        await store.setEnabled(true)

        store.lock()
        XCTAssertTrue(store.isLocked)

        auth.verdict = false
        await store.unlock()
        XCTAssertTrue(store.isLocked, "A failed prompt keeps the veil")

        auth.verdict = true
        await store.unlock()
        XCTAssertFalse(store.isLocked)
    }

    func testAutoUnlockPromptsOncePerLock() async {
        let auth = AuthDouble()
        let store = makeStore(auth: auth)
        await store.setEnabled(true)
        store.lock()
        auth.verdict = false
        let baseline = auth.attempts

        // Every veiled scene asks; only the first attempt reaches the system.
        await store.autoUnlock()
        await store.autoUnlock()
        XCTAssertEqual(auth.attempts, baseline + 1)

        // The explicit UNLOCK chip always retries.
        await store.unlock()
        XCTAssertEqual(auth.attempts, baseline + 2)

        // A fresh lock re-arms the automatic attempt.
        store.lock()
        await store.autoUnlock()
        XCTAssertEqual(auth.attempts, baseline + 3)
    }

    func testDisablingClearsAnyLock() async {
        let defaults = makeDefaults()
        let auth = AuthDouble()
        let store = makeStore(defaults: defaults, auth: auth)
        await store.setEnabled(true)
        store.lock()

        await store.setEnabled(false)
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.isLocked)

        let relaunched = makeStore(defaults: defaults, auth: auth)
        XCTAssertFalse(relaunched.isEnabled)
        XCTAssertFalse(relaunched.isLocked)
    }

    func testUnlockWhileUnlockedIsANoOp() async {
        let auth = AuthDouble()
        let store = makeStore(auth: auth)
        await store.setEnabled(true)
        let baseline = auth.attempts

        await store.unlock()
        await store.autoUnlock()
        XCTAssertEqual(auth.attempts, baseline, "No prompt without a lock to clear")
    }
}
