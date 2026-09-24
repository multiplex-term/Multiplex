import StoreKit
import XCTest
@testable import Multiplex

private enum ProStoreDoubleError: LocalizedError {
    case load
    case purchase
    case sync

    var errorDescription: String? {
        switch self {
        case .load: "catalog unavailable"
        case .purchase: "purchase failed"
        case .sync: "restore failed"
        }
    }
}

@MainActor
private final class ProStoreDouble {
    var product: ProStoreProduct? = ProStoreProduct(
        id: EntitlementStore.proProductID,
        displayPrice: "$19.99"
    )
    var loadError: ProStoreDoubleError?
    var loadDelay: Duration?
    var purchaseResult: ProStorePurchaseResult = .userCancelled
    var purchaseThroughPresenter = false
    var purchaseError: ProStoreDoubleError?
    var purchaseDelay: Duration?
    var finishDelay: Duration?
    var current: [ProStoreVerification] = []
    var currentDelay: Duration?
    var afterSync: [ProStoreVerification]?
    var syncError: ProStoreDoubleError?
    var syncDelay: Duration?
    var sandboxEnvironment = false

    private(set) var loadCount = 0
    private(set) var purchaseCount = 0
    private(set) var purchasePresenterCount = 0
    private(set) var syncCount = 0
    private(set) var finishCount = 0
    private(set) var currentRequestCount = 0

    private let updateStream: AsyncStream<ProStoreVerification>
    private let updateContinuation: AsyncStream<ProStoreVerification>.Continuation

    init() {
        let pair = AsyncStream<ProStoreVerification>.makeStream()
        updateStream = pair.stream
        updateContinuation = pair.continuation
    }

    func client() -> ProStoreClient {
        ProStoreClient(
            loadProduct: { [weak self] in
                guard let self else { return nil }
                loadCount += 1
                if let loadDelay { try await Task.sleep(for: loadDelay) }
                if let loadError { throw loadError }
                return product
            },
            purchase: { [weak self] product, presenter in
                guard let self else { return .unknown }
                purchaseCount += 1
                if presenter != nil { purchasePresenterCount += 1 }
                if let purchaseDelay { try await Task.sleep(for: purchaseDelay) }
                if let purchaseError { throw purchaseError }
                if purchaseThroughPresenter {
                    guard let presenter else { throw ProStoreDoubleError.purchase }
                    return try await presenter(product)
                }
                return purchaseResult
            },
            currentEntitlements: { [weak self] in
                guard let self else { return Self.finishedStream([]) }
                currentRequestCount += 1
                return Self.finishedStream(current, delay: currentDelay)
            },
            updates: { [weak self] in
                self?.updateStream ?? Self.finishedStream([])
            },
            sync: { [weak self] in
                guard let self else { return }
                syncCount += 1
                if let syncDelay { try await Task.sleep(for: syncDelay) }
                if let syncError { throw syncError }
                if let afterSync { current = afterSync }
            },
            isSandboxStoreEnvironment: { [weak self] in
                self?.sandboxEnvironment ?? false
            }
        )
    }

    func transaction(
        revokedAt: Date? = nil,
        expiresAt: Date? = nil
    ) -> ProStoreTransaction {
        ProStoreTransaction(
            productID: EntitlementStore.proProductID,
            revocationDate: revokedAt,
            expirationDate: expiresAt,
            finish: { [weak self] in
                guard let self else { return }
                if let finishDelay { try? await Task.sleep(for: finishDelay) }
                finishCount += 1
            }
        )
    }

    func emit(_ result: ProStoreVerification) {
        updateContinuation.yield(result)
    }

    func finishUpdates() {
        updateContinuation.finish()
    }

    private static func finishedStream(
        _ values: [ProStoreVerification],
        delay: Duration? = nil
    ) -> AsyncStream<ProStoreVerification> {
        AsyncStream { continuation in
            if let delay {
                Task {
                    try? await Task.sleep(for: delay)
                    for value in values { continuation.yield(value) }
                    continuation.finish()
                }
            } else {
                for value in values { continuation.yield(value) }
                continuation.finish()
            }
        }
    }
}

@MainActor
final class EntitlementStoreTests: XCTestCase {
    func testDailyTasteRatchetNeverDropsBelowLaunchAllowance() {
        XCTAssertGreaterThanOrEqual(EntitlementStore.dailySlashChipLimit, 10)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "EntitlementStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func lockedStore(
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        startStoreKit: Bool = false,
        storeClient: ProStoreClient? = nil
    ) -> EntitlementStore {
        defaults.set(false, forKey: "MultiplexProUnlocked")
        return EntitlementStore(
            defaults: defaults,
            now: now,
            calendar: calendar,
            startStoreKit: startStoreKit,
            storeClient: storeClient
        )
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)")
    }

    func testFreeHostGateAllowsTwoHosts() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = lockedStore(defaults: defaults)

        XCTAssertEqual(EntitlementStore.freeHostLimit, 2)
        XCTAssertTrue(store.canAddHost(existingHostCount: 0))
        XCTAssertTrue(store.canAddHost(existingHostCount: 1))
        XCTAssertFalse(store.canAddHost(existingHostCount: 2))
        XCTAssertFalse(store.canAddHost(existingHostCount: 8))

        #if DEBUG
        store.setDebugUnlocked(true)
        XCTAssertTrue(store.canAddHost(existingHostCount: 8))
        #endif
    }

    func testProCapabilityPredicatesPreserveGrandfatheredMosh() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = lockedStore(defaults: defaults)

        XCTAssertFalse(store.canEnableMosh(currentlyEnabled: false))
        XCTAssertTrue(store.canEnableMosh(currentlyEnabled: true))
        XCTAssertFalse(store.canMutateCustomThemes)
        XCTAssertFalse(store.canScheduleAgentAlerts)
        XCTAssertFalse(store.canViewConnectionStats)
        XCTAssertEqual(store.keyCommandLimit, EntitlementStore.freeKeyCommandLimit)
        XCTAssertEqual(store.keyCommandLimit, 5)

        #if DEBUG
        store.setDebugUnlocked(true)
        XCTAssertTrue(store.canEnableMosh(currentlyEnabled: false))
        XCTAssertTrue(store.canMutateCustomThemes)
        XCTAssertTrue(store.canScheduleAgentAlerts)
        XCTAssertTrue(store.canViewConnectionStats)
        XCTAssertEqual(store.keyCommandLimit, KeyCommandSet.maximumCount)
        #endif
    }

    func testFreeSlashMeterAllowsExactlyTenUsesAndPersists() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = lockedStore(defaults: defaults)

        XCTAssertEqual(store.slashChipsRemaining, EntitlementStore.dailySlashChipLimit)
        for expectedRemaining in stride(
            from: EntitlementStore.dailySlashChipLimit - 1,
            through: 0,
            by: -1
        ) {
            XCTAssertTrue(store.consumeSlashChip())
            XCTAssertEqual(store.slashChipsRemaining, expectedRemaining)
        }
        XCTAssertFalse(store.canUseSlashChip)
        XCTAssertFalse(store.consumeSlashChip())

        let relaunched = lockedStore(defaults: defaults)
        XCTAssertFalse(relaunched.canUseSlashChip)
        XCTAssertEqual(relaunched.slashChipsRemaining, 0)
    }

    func testSlashMeterResetsOnNextLocalCalendarDay() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        var currentDate = Date(timeIntervalSince1970: 1_768_381_200) // 2026-01-14 12:00 +08
        let store = lockedStore(
            defaults: defaults,
            now: { currentDate },
            calendar: calendar
        )

        for _ in 0..<EntitlementStore.dailySlashChipLimit {
            XCTAssertTrue(store.consumeSlashChip())
        }
        XCTAssertFalse(store.canUseSlashChip)

        currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        // Reads fail open on the new date even before the explicit lifecycle
        // refresh; refresh then persists and publishes the reset.
        XCTAssertTrue(store.canUseSlashChip)
        XCTAssertEqual(store.slashChipsRemaining, EntitlementStore.dailySlashChipLimit)
        store.refreshSlashChipMeter()
        XCTAssertTrue(store.consumeSlashChip())
        XCTAssertEqual(
            store.slashChipsRemaining,
            EntitlementStore.dailySlashChipLimit - 1
        )
    }

    func testSlashMeterResetsAcrossExactMidnightAndDSTDay() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var currentDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 7, hour: 23, minute: 59, second: 59
        )))
        let store = lockedStore(
            defaults: defaults,
            now: { currentDate },
            calendar: calendar
        )

        for _ in 0..<EntitlementStore.dailySlashChipLimit {
            XCTAssertTrue(store.consumeSlashChip())
        }
        XCTAssertFalse(store.canUseSlashChip)

        currentDate = try XCTUnwrap(calendar.date(byAdding: .second, value: 1, to: currentDate))
        XCTAssertTrue(store.canUseSlashChip)
        store.refreshSlashChipMeter()
        XCTAssertEqual(store.slashChipsRemaining, EntitlementStore.dailySlashChipLimit)

        // March 8 is the 23-hour spring-forward day in this time zone. The
        // meter follows the calendar label, not a fixed 24-hour interval.
        for _ in 0..<EntitlementStore.dailySlashChipLimit {
            XCTAssertTrue(store.consumeSlashChip())
        }
        XCTAssertFalse(store.canUseSlashChip)
        currentDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 9, hour: 0
        )))
        XCTAssertTrue(store.canUseSlashChip)
    }

    func testProSlashUsesAreUnmetered() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = lockedStore(defaults: defaults)

        #if DEBUG
        store.setDebugUnlocked(true)
        for _ in 0..<(EntitlementStore.dailySlashChipLimit * 2) {
            XCTAssertTrue(store.consumeSlashChip())
        }
        XCTAssertEqual(store.slashChipsRemaining, EntitlementStore.dailySlashChipLimit)
        #endif
    }

    func testDebugDefaultIsFailOpenButExplicitOverridePersists() {
        #if DEBUG
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let initial = EntitlementStore(defaults: defaults, startStoreKit: false)
        XCTAssertTrue(initial.isPro)
        initial.setDebugUnlocked(false)
        XCTAssertFalse(initial.isPro)

        let relaunched = EntitlementStore(defaults: defaults, startStoreKit: false)
        XCTAssertFalse(relaunched.isPro)
        #endif
    }

    func testReleasePolicyTrustsOnlyVerifiedStoreEntitlement() {
        XCTAssertFalse(EntitlementStore.resolveProStatus(
            storeEntitled: false,
            debugOverride: true,
            developerFailOpen: false
        ))
        XCTAssertTrue(EntitlementStore.resolveProStatus(
            storeEntitled: true,
            debugOverride: false,
            developerFailOpen: false
        ))
        XCTAssertTrue(EntitlementStore.resolveProStatus(
            storeEntitled: false,
            debugOverride: nil,
            developerFailOpen: true
        ))
        XCTAssertFalse(EntitlementStore.resolveProStatus(
            storeEntitled: true,
            debugOverride: false,
            developerFailOpen: true
        ))
    }

    func testProductLoadIsSingleFlightAndCanRetryAfterFailure() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.loadError = .load
        storeDouble.loadDelay = .milliseconds(30)
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        let leader = Task {
            await store.loadStorefront()
            XCTAssertEqual(store.productLoadError, "catalog unavailable")
            storeDouble.loadError = nil
            storeDouble.loadDelay = .milliseconds(30)
            await store.loadStorefront()
        }
        let oldWaiter = Task { await store.loadStorefront() }
        await leader.value
        await oldWaiter.value

        // A late waiter from the failed generation must not clear the retry.
        XCTAssertEqual(storeDouble.loadCount, 2)
        XCTAssertEqual(store.productDisplayPrice, "$19.99")
        XCTAssertNil(store.productLoadError)
        XCTAssertFalse(store.productIsLoading)
    }

    func testDebugPaywallPreviewRetiresInFlightProductLoad() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.loadDelay = .milliseconds(100)
        storeDouble.product = ProStoreProduct(
            id: EntitlementStore.proProductID,
            displayPrice: "NT$690"
        )
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        let load = Task { await store.loadStorefront() }
        await waitUntil("in-flight storefront load") { store.productIsLoading }
        store.prepareDebugPaywallPreview(displayPrice: "$19.99")
        await load.value

        XCTAssertEqual(store.productDisplayPrice, "$19.99")
        XCTAssertNil(store.productLoadError)
        XCTAssertFalse(store.productIsLoading)
    }

    func testStartupBootstrapsEntitlementsAndLocalizedProduct() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        let store = lockedStore(
            defaults: defaults,
            startStoreKit: true,
            storeClient: storeDouble.client()
        )

        await store.waitForStoreKitBootstrapForTesting()
        XCTAssertEqual(storeDouble.loadCount, 1)
        XCTAssertEqual(store.productDisplayPrice, "$19.99")
        XCTAssertNil(store.productLoadError)
        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
        storeDouble.finishUpdates()
    }

    func testStartupProbePublishesSandboxStoreEnvironment() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.sandboxEnvironment = true
        let store = lockedStore(
            defaults: defaults,
            startStoreKit: true,
            storeClient: storeDouble.client()
        )

        XCTAssertFalse(store.storeEnvironmentIsSandbox)
        await waitUntil("sandbox store environment probe") {
            store.storeEnvironmentIsSandbox
        }
        storeDouble.finishUpdates()
    }

    func testBufferedPositiveUpdateOutranksBootstrapEmptySnapshot() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        let bootstrapAuthority = store.entitlementAuthorityForTesting

        // Model a Transaction.updates value already buffered at launch and
        // delivered before bootstrap has registered currentEntitlements.
        store.startTransactionListenerForTesting()
        storeDouble.emit(.verified(storeDouble.transaction()))
        await waitUntil("buffered positive update") {
            store.hasVerifiedStoreEntitlementForTesting
        }

        storeDouble.current = []
        await store.refreshEntitlementsForTesting(
            ifAuthorityUnchangedSince: bootstrapAuthority
        )
        XCTAssertTrue(store.hasVerifiedStoreEntitlementForTesting)
        storeDouble.finishUpdates()
    }

    func testBufferedRevocationOutranksBootstrapPositiveSnapshot() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        let bootstrapAuthority = store.entitlementAuthorityForTesting

        store.startTransactionListenerForTesting()
        storeDouble.emit(.verified(storeDouble.transaction(revokedAt: Date())))
        await waitUntil("buffered revocation") { storeDouble.finishCount == 1 }

        storeDouble.current = [.verified(storeDouble.transaction())]
        await store.refreshEntitlementsForTesting(
            ifAuthorityUnchangedSince: bootstrapAuthority
        )
        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
        storeDouble.finishUpdates()
    }

    func testStaleBootstrapAuthorityCannotConsumeCurrentRefresh() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        let staleBootstrapAuthority = store.entitlementAuthorityForTesting

        store.startTransactionListenerForTesting()
        storeDouble.emit(.verified(storeDouble.transaction()))
        await waitUntil("authority-advancing update") {
            store.hasVerifiedStoreEntitlementForTesting
        }
        let currentAuthority = store.entitlementAuthorityForTesting

        storeDouble.current = []
        storeDouble.currentDelay = .milliseconds(100)
        let staleRefresh = Task {
            await store.refreshEntitlementsForTesting(
                ifAuthorityUnchangedSince: staleBootstrapAuthority
            )
        }
        // Let the stale caller reach the service first. In the buggy version
        // it created a refresh that the valid caller joined, then stole the
        // shared result before failing its own authority check.
        for _ in 0..<10 { await Task.yield() }
        let validRefresh = Task {
            await store.refreshEntitlementsForTesting(
                ifAuthorityUnchangedSince: currentAuthority
            )
        }
        await staleRefresh.value
        await validRefresh.value

        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertEqual(storeDouble.currentRequestCount, 1)
        storeDouble.finishUpdates()
    }

    func testVerifiedPurchaseImmediatelyUnlocksAndFinishes() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .success(.verified(storeDouble.transaction()))
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        let purchased = await store.purchaseProForTesting()
        XCTAssertTrue(purchased)
        XCTAssertTrue(store.isPro)
        XCTAssertTrue(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertEqual(store.commerceState, .purchased)
        XCTAssertEqual(storeDouble.purchaseCount, 1)
        XCTAssertEqual(storeDouble.finishCount, 1)
    }

    func testAppOwnedPurchasePresenterIsForwardedToInjectedClient() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseThroughPresenter = true
        let transaction = storeDouble.transaction()
        let presenter = ProPurchasePresenter { product in
            XCTAssertEqual(product.id, EntitlementStore.proProductID)
            return .success(.verified(transaction))
        }
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        let purchased = await store.purchasePro(using: presenter)

        XCTAssertTrue(purchased)
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.commerceState, .purchased)
        XCTAssertEqual(storeDouble.purchaseCount, 1)
        XCTAssertEqual(storeDouble.purchasePresenterCount, 1)
        XCTAssertEqual(storeDouble.finishCount, 1)
    }

    func testNewerRevocationWinsWhileVerifiedPurchaseFinishes() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.finishDelay = .milliseconds(100)
        storeDouble.purchaseResult = .success(.verified(storeDouble.transaction()))
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        store.startTransactionListenerForTesting()

        let purchase = Task { await store.purchaseProForTesting() }
        await waitUntil("purchase published before finish") {
            store.hasVerifiedStoreEntitlementForTesting
                && store.commerceState == .purchased
        }
        storeDouble.emit(.verified(storeDouble.transaction(revokedAt: Date())))
        await waitUntil("newer revocation") {
            !store.hasVerifiedStoreEntitlementForTesting
                && store.commerceState == .idle
        }

        let purchaseResult = await purchase.value
        XCTAssertFalse(purchaseResult)
        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertFalse(EntitlementStore.resolveProStatus(
            storeEntitled: store.hasVerifiedStoreEntitlementForTesting,
            debugOverride: nil,
            developerFailOpen: false
        ))
        await waitUntil("both transactions finished") {
            storeDouble.finishCount == 2
        }
        XCTAssertEqual(storeDouble.finishCount, 2)
        storeDouble.finishUpdates()
    }

    func testUnverifiedPurchaseFailsClosedWithoutFinishing() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .success(.unverified(
            productID: EntitlementStore.proProductID
        ))
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        let purchased = await store.purchaseProForTesting()
        XCTAssertFalse(purchased)
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertEqual(
            store.commerceState,
            .failed("The App Store transaction could not be verified.")
        )
        XCTAssertEqual(storeDouble.finishCount, 0)
    }

    func testCancellationAndPurchaseErrorDoNotUnlock() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        storeDouble.purchaseResult = .userCancelled
        let cancelled = await store.purchaseProForTesting()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(store.commerceState, .idle)
        XCTAssertFalse(store.isPro)

        storeDouble.purchaseError = .purchase
        let failed = await store.purchaseProForTesting()
        XCTAssertFalse(failed)
        XCTAssertEqual(store.commerceState, .failed("purchase failed"))
        XCTAssertFalse(store.isPro)
    }

    func testVerifiedUpdateDuringPurchaseErrorOwnsFinalPresentationState() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseDelay = .milliseconds(100)
        storeDouble.purchaseError = .purchase
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        store.startTransactionListenerForTesting()

        let purchase = Task { await store.purchaseProForTesting() }
        await waitUntil("purchase operation") { store.commerceState == .purchasing }
        storeDouble.emit(.verified(storeDouble.transaction()))
        await waitUntil("verified update during purchase") {
            store.hasVerifiedStoreEntitlementForTesting
        }

        let purchaseResult = await purchase.value
        XCTAssertTrue(purchaseResult)
        XCTAssertEqual(store.commerceState, .purchased)
        storeDouble.finishUpdates()
    }

    func testVerifiedButInactiveOrWrongProductPurchaseDoesNotUnlock() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        let invalidTransactions = [
            ProStoreTransaction(productID: "other.product"),
            storeDouble.transaction(revokedAt: Date()),
            storeDouble.transaction(expiresAt: Date(timeIntervalSinceNow: -1)),
        ]
        for transaction in invalidTransactions {
            storeDouble.purchaseResult = .success(.verified(transaction))
            let purchased = await store.purchaseProForTesting()
            XCTAssertFalse(purchased)
            XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
        }
        XCTAssertEqual(storeDouble.finishCount, 0)
    }

    func testPendingPurchaseSuppressesDuplicatesButRestoreCanReconcileDecline() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .pending
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        let firstPurchase = await store.purchaseProForTesting()
        XCTAssertFalse(firstPurchase)
        XCTAssertEqual(store.commerceState, .pending)
        XCTAssertTrue(store.purchaseIsUnavailable)
        XCTAssertFalse(store.commerceIsBusy)

        let duplicateWhilePending = await store.purchaseProForTesting()
        XCTAssertFalse(duplicateWhilePending)
        XCTAssertEqual(storeDouble.purchaseCount, 1)

        let restored = await store.restorePurchases()
        XCTAssertFalse(restored)
        XCTAssertEqual(store.commerceState, .restored)
        XCTAssertEqual(storeDouble.syncCount, 1)
        XCTAssertFalse(store.purchaseIsUnavailable)

        storeDouble.purchaseResult = .pending
        let retryAfterReconciliation = await store.purchaseProForTesting()
        XCTAssertFalse(retryAfterReconciliation)
        XCTAssertEqual(storeDouble.purchaseCount, 2)
        XCTAssertEqual(store.commerceState, .pending)
    }

    func testFailedRestoreDoesNotReopenPurchaseWhileApprovalMayBePending() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .pending
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        store.startTransactionListenerForTesting()

        let pendingResult = await store.purchaseProForTesting()
        XCTAssertFalse(pendingResult)
        storeDouble.syncError = .sync
        let restoreResult = await store.restorePurchases()
        XCTAssertFalse(restoreResult)
        XCTAssertEqual(store.commerceState, .failed("restore failed"))
        XCTAssertTrue(store.purchaseIsUnavailable)

        let duplicateResult = await store.purchaseProForTesting()
        XCTAssertFalse(duplicateResult)
        XCTAssertEqual(storeDouble.purchaseCount, 1)

        // A later approval must clear both the independent pending marker and
        // the stale Restore error copy.
        storeDouble.emit(.verified(storeDouble.transaction()))
        await waitUntil("approval after failed restore") {
            store.hasVerifiedStoreEntitlementForTesting
                && store.commerceState == .purchased
        }
        XCTAssertFalse(store.purchaseIsUnavailable)
        storeDouble.finishUpdates()
    }

    func testStaleBootstrapSnapshotCannotRelockVerifiedPurchase() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.current = []
        storeDouble.currentDelay = .milliseconds(100)
        storeDouble.purchaseResult = .success(.verified(storeDouble.transaction()))
        let store = lockedStore(
            defaults: defaults,
            startStoreKit: true,
            storeClient: storeDouble.client()
        )

        await waitUntil("bootstrap entitlement snapshot") {
            storeDouble.currentRequestCount == 1
        }
        await store.loadStorefront()
        let purchased = await store.purchaseProForTesting()
        XCTAssertTrue(purchased)
        await store.waitForStoreKitBootstrapForTesting()

        XCTAssertTrue(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.commerceState, .purchased)
    }

    func testPendingPurchaseUnlocksFromVerifiedTransactionUpdate() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .pending
        let store = lockedStore(
            defaults: defaults,
            startStoreKit: true,
            storeClient: storeDouble.client()
        )
        await store.waitForStoreKitBootstrapForTesting()
        let purchased = await store.purchaseProForTesting()
        XCTAssertFalse(purchased)

        // Deliberately leave the current-entitlement snapshot empty: the
        // verified update must unlock immediately even if StoreKit publishes
        // its snapshot on a later turn.
        storeDouble.emit(.verified(storeDouble.transaction()))
        await waitUntil("pending transaction unlock") {
            store.commerceState == .purchased && store.isPro
        }

        XCTAssertTrue(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertFalse(store.purchaseIsUnavailable)
        XCTAssertEqual(storeDouble.finishCount, 1)
        storeDouble.finishUpdates()
    }

    func testPendingUnverifiedUpdateSurfacesFailureAndAllowsRetry() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .pending
        let store = lockedStore(
            defaults: defaults,
            startStoreKit: true,
            storeClient: storeDouble.client()
        )
        await store.waitForStoreKitBootstrapForTesting()
        let purchased = await store.purchaseProForTesting()
        XCTAssertFalse(purchased)

        storeDouble.emit(.unverified(productID: EntitlementStore.proProductID))
        await waitUntil("unverified pending failure") {
            if case .failed = store.commerceState { return true }
            return false
        }

        XCTAssertFalse(store.purchaseIsUnavailable)
        XCTAssertFalse(store.isPro)
        storeDouble.finishUpdates()
    }

    func testRestoreReconcilesOwnedAndEmptyHistories() async {
        let (ownedDefaults, ownedName) = makeDefaults()
        defer { ownedDefaults.removePersistentDomain(forName: ownedName) }
        let ownedDouble = ProStoreDouble()
        ownedDouble.afterSync = [.verified(ownedDouble.transaction())]
        let ownedStore = lockedStore(
            defaults: ownedDefaults,
            storeClient: ownedDouble.client()
        )

        let restoredOwned = await ownedStore.restorePurchases()
        XCTAssertTrue(restoredOwned)
        XCTAssertEqual(ownedStore.commerceState, .restored)
        XCTAssertTrue(ownedStore.isPro)
        XCTAssertTrue(ownedStore.hasVerifiedStoreEntitlementForTesting)
        XCTAssertEqual(ownedDouble.syncCount, 1)

        let (emptyDefaults, emptyName) = makeDefaults()
        defer { emptyDefaults.removePersistentDomain(forName: emptyName) }
        let emptyDouble = ProStoreDouble()
        let emptyStore = lockedStore(
            defaults: emptyDefaults,
            storeClient: emptyDouble.client()
        )

        let restoredEmpty = await emptyStore.restorePurchases()
        XCTAssertFalse(restoredEmpty)
        XCTAssertEqual(emptyStore.commerceState, .restored)
        XCTAssertFalse(emptyStore.isPro)
        XCTAssertFalse(emptyStore.hasVerifiedStoreEntitlementForTesting)
    }

    func testPreexistingOwnershipDoesNotHideRestoreFailure() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .success(.verified(storeDouble.transaction()))
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        let purchased = await store.purchaseProForTesting()
        XCTAssertTrue(purchased)

        storeDouble.syncError = .sync
        let restored = await store.restorePurchases()
        XCTAssertFalse(restored)
        XCTAssertTrue(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertEqual(store.commerceState, .failed("restore failed"))
    }

    func testRestoreSyncFailureFallsBackToOwnedEntitlements() async {
        // TestFlight's commerce backend routinely fails AppStore.sync() with
        // internal errors while the entitlement query still answers; owned
        // entitlements must complete the restore anyway.
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.current = [.verified(storeDouble.transaction())]
        storeDouble.syncError = .sync
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        let restored = await store.restorePurchases()
        XCTAssertTrue(restored)
        XCTAssertEqual(store.commerceState, .restored)
        XCTAssertTrue(store.isPro)
        XCTAssertTrue(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertEqual(storeDouble.syncCount, 1)
    }

    func testOpaqueStoreErrorMessageNamesTheDomainAndCode() {
        let message = EntitlementStore.storeErrorMessage(
            NSError(domain: "SKInternalErrorDomain", code: 14)
        )
        XCTAssertTrue(message.contains("(SKInternalErrorDomain 14)"))
        XCTAssertTrue(message.contains("signed in to the App Store"))

        // An authored LocalizedError message must survive untouched.
        XCTAssertEqual(
            EntitlementStore.storeErrorMessage(ProStoreDoubleError.sync),
            "restore failed"
        )
    }

    func testVerifiedUpdateClearsEarlierNonPendingRestoreError() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.syncError = .sync
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        store.startTransactionListenerForTesting()

        let restoreResult = await store.restorePurchases()
        XCTAssertFalse(restoreResult)
        XCTAssertEqual(store.commerceState, .failed("restore failed"))
        storeDouble.emit(.verified(storeDouble.transaction()))
        await waitUntil("verified update clears stale restore error") {
            store.hasVerifiedStoreEntitlementForTesting
                && store.commerceState == .purchased
        }
        storeDouble.finishUpdates()
    }

    func testVerifiedUpdateDuringFailingRestoreOwnsCompletionState() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.syncDelay = .milliseconds(100)
        storeDouble.syncError = .sync
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        store.startTransactionListenerForTesting()

        let restore = Task { await store.restorePurchases() }
        await waitUntil("restore operation") { store.commerceState == .restoring }
        storeDouble.emit(.verified(storeDouble.transaction()))
        await waitUntil("verified update during restore") {
            store.hasVerifiedStoreEntitlementForTesting
        }

        let restoreResult = await restore.value
        XCTAssertTrue(restoreResult)
        XCTAssertEqual(store.commerceState, .restored)
        storeDouble.finishUpdates()
    }

    func testPurchaseAndRestoreCannotOverlap() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseDelay = .milliseconds(50)
        storeDouble.purchaseResult = .userCancelled
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())

        let purchase = Task { await store.purchaseProForTesting() }
        await waitUntil("purchase operation start") { store.commerceIsBusy }
        let restored = await store.restorePurchases()
        XCTAssertFalse(restored)
        XCTAssertEqual(storeDouble.syncCount, 0)
        _ = await purchase.value
        XCTAssertEqual(store.commerceState, .idle)
    }

    func testRevocationAndExpirationRemoveVerifiedOwnershipAndStaleSuccessCopy() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .success(.verified(storeDouble.transaction()))
        let store = lockedStore(defaults: defaults, storeClient: storeDouble.client())
        let purchased = await store.purchaseProForTesting()
        XCTAssertTrue(purchased)
        XCTAssertEqual(store.commerceState, .purchased)

        storeDouble.current = [.verified(storeDouble.transaction(revokedAt: Date()))]
        await store.refreshEntitlements()
        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertEqual(store.commerceState, .idle)

        storeDouble.current = [.verified(storeDouble.transaction(
            expiresAt: Date(timeIntervalSinceNow: -60)
        ))]
        await store.refreshEntitlements()
        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
    }

    func testNegativeTransactionUpdateOverridesLaggingPositiveSnapshot() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .success(.verified(storeDouble.transaction()))
        let store = lockedStore(
            defaults: defaults,
            startStoreKit: true,
            storeClient: storeDouble.client()
        )
        await store.waitForStoreKitBootstrapForTesting()
        let purchased = await store.purchaseProForTesting()
        XCTAssertTrue(purchased)

        // Start a lagging positive snapshot, then deliver the newer verified
        // revocation. The event must retire that older generation.
        storeDouble.current = [.verified(storeDouble.transaction())]
        storeDouble.currentDelay = .milliseconds(100)
        let requestBaseline = storeDouble.currentRequestCount
        let oldRefresh = Task { await store.refreshEntitlements() }
        await waitUntil("lagging positive snapshot") {
            storeDouble.currentRequestCount == requestBaseline + 1
        }
        storeDouble.emit(.verified(storeDouble.transaction(revokedAt: Date())))
        await waitUntil("revocation update") {
            !store.hasVerifiedStoreEntitlementForTesting
                && store.commerceState == .idle
        }
        await oldRefresh.value

        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)

        // A snapshot begun after the revocation is causally newer and may
        // restore ownership (for example, a later repurchase).
        storeDouble.currentDelay = nil
        storeDouble.afterSync = [.verified(storeDouble.transaction())]
        let restored = await store.restorePurchases()
        XCTAssertTrue(restored)
        XCTAssertTrue(store.hasVerifiedStoreEntitlementForTesting)
        storeDouble.finishUpdates()
    }

    func testPositiveUpdateCancelsOlderSnapshotButNewerRestoreCanSupersedeIt() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        let store = lockedStore(
            defaults: defaults,
            startStoreKit: true,
            storeClient: storeDouble.client()
        )
        await store.waitForStoreKitBootstrapForTesting()

        let requestBaseline = storeDouble.currentRequestCount
        storeDouble.current = []
        storeDouble.currentDelay = .milliseconds(100)
        let oldRefresh = Task { await store.refreshEntitlements() }
        await waitUntil("older empty snapshot") {
            storeDouble.currentRequestCount == requestBaseline + 1
        }
        storeDouble.emit(.verified(storeDouble.transaction()))
        await waitUntil("authoritative positive update") {
            store.hasVerifiedStoreEntitlementForTesting
        }
        await oldRefresh.value
        XCTAssertTrue(store.hasVerifiedStoreEntitlementForTesting)

        // Conversely, an empty restore snapshot begun after the update is
        // newer and must not be cancelled/re-overwritten by that old event.
        storeDouble.currentDelay = nil
        let restored = await store.restorePurchases()
        XCTAssertFalse(restored)
        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
        storeDouble.finishUpdates()
    }

    func testInactiveVerifiedUpdateResolvesPendingAsFailure() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let storeDouble = ProStoreDouble()
        storeDouble.purchaseResult = .pending
        let store = lockedStore(
            defaults: defaults,
            startStoreKit: true,
            storeClient: storeDouble.client()
        )
        await store.waitForStoreKitBootstrapForTesting()
        let purchased = await store.purchaseProForTesting()
        XCTAssertFalse(purchased)

        // Again make the snapshot stale-positive; the inactive update must
        // win and, critically, must not leave the purchase stuck pending.
        storeDouble.current = [.verified(storeDouble.transaction())]
        storeDouble.emit(.verified(storeDouble.transaction(
            expiresAt: Date(timeIntervalSinceNow: -1)
        )))
        await waitUntil("inactive pending resolution") {
            if case .failed = store.commerceState { return true }
            return false
        }

        XCTAssertFalse(store.hasVerifiedStoreEntitlementForTesting)
        XCTAssertFalse(store.purchaseIsUnavailable)
        storeDouble.finishUpdates()
    }

    // MARK: - Store error copy

    func testStoreErrorMessageNamesKnownStoreKitFailures() {
        XCTAssertEqual(
            EntitlementStore.storeErrorMessage(
                StoreKitError.networkError(URLError(.notConnectedToInternet))
            ),
            "The App Store could not be reached. Check the internet connection and try again."
        )
        XCTAssertEqual(
            EntitlementStore.storeErrorMessage(StoreKitError.notAvailableInStorefront),
            "Multiplex Pro is not available in this App Store storefront."
        )
        XCTAssertEqual(
            EntitlementStore.storeErrorMessage(StoreKitError.unknown),
            "The App Store could not complete the request. Try again in a moment."
        )
        // Errors StoreKit does not own keep their own description, so the
        // injected-client suites above stay valid and app errors stay honest.
        XCTAssertEqual(
            EntitlementStore.storeErrorMessage(ProStoreDoubleError.purchase),
            "purchase failed"
        )
    }
}
