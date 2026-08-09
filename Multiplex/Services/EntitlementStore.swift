import Foundation
import Observation
import OSLog
import StoreKit
import UIKit

/// App-owned StoreKit values. Keeping this boundary smaller than StoreKit's
/// concrete types lets the entitlement policy be exhaustively exercised even
/// when a simulator runtime cannot verify its locally-created JWS.
struct ProStoreProduct {
    let id: String
    let displayPrice: String
    fileprivate let product: Product?

    init(id: String, displayPrice: String, product: Product? = nil) {
        self.id = id
        self.displayPrice = displayPrice
        self.product = product
    }
}

struct ProStoreTransaction {
    let productID: String
    let revocationDate: Date?
    let expirationDate: Date?
    private let finishAction: @MainActor () async -> Void

    init(
        productID: String,
        revocationDate: Date? = nil,
        expirationDate: Date? = nil,
        finish: @escaping @MainActor () async -> Void = {}
    ) {
        self.productID = productID
        self.revocationDate = revocationDate
        self.expirationDate = expirationDate
        finishAction = finish
    }

    @MainActor
    func finish() async {
        await finishAction()
    }
}

enum ProStoreVerification {
    case verified(ProStoreTransaction)
    /// The product id is available on StoreKit's unverified result even
    /// though its signed fields must not be trusted for entitlement.
    case unverified(productID: String?)
}

enum ProStorePurchaseResult {
    case success(ProStoreVerification)
    case pending
    case userCancelled
    case unknown
}

private enum ProStoreClientError: LocalizedError {
    case missingProduct
    case missingPurchasePresenter

    var errorDescription: String? {
        switch self {
        case .missingProduct:
            "Multiplex Pro is not available from the App Store right now."
        case .missingPurchasePresenter:
            "The App Store purchase sheet could not be presented from this window."
        }
    }
}

/// The only StoreKit-facing dependency of `EntitlementStore`. Production uses
/// `.live`; tests inject the same outcomes without weakening verification in
/// the shipping implementation.
@MainActor
struct ProStoreClient {
    var loadProduct: () async throws -> ProStoreProduct?
    var purchase: (ProStoreProduct, ProPurchasePresenter?) async throws -> ProStorePurchaseResult
    var currentEntitlements: () -> AsyncStream<ProStoreVerification>
    var updates: () -> AsyncStream<ProStoreVerification>
    var sync: () async throws -> Void

    static let live = ProStoreClient(
        loadProduct: {
            let products = try await Product.products(for: [EntitlementStore.proProductID])
            guard let product = products.first(where: { $0.id == EntitlementStore.proProductID })
            else { return nil }
            return ProStoreProduct(
                id: product.id,
                displayPrice: product.displayPrice,
                product: product
            )
        },
        purchase: { product, presenter in
            guard let presenter else { throw ProStoreClientError.missingPurchasePresenter }
            return try await presenter(product)
        },
        currentEntitlements: {
            currentEntitlementStream()
        },
        updates: {
            transactionUpdateStream()
        },
        sync: {
            try await AppStore.sync()
        }
    )

    fileprivate static func map(
        _ result: VerificationResult<StoreKit.Transaction>
    ) -> ProStoreVerification {
        switch result {
        case .verified(let transaction):
            .verified(ProStoreTransaction(
                productID: transaction.productID,
                revocationDate: transaction.revocationDate,
                expirationDate: transaction.expirationDate,
                finish: { await transaction.finish() }
            ))
        case .unverified(let transaction, _):
            .unverified(productID: transaction.productID)
        }
    }

    private static func currentEntitlementStream() -> AsyncStream<ProStoreVerification> {
        AsyncStream { continuation in
            let task = Task {
                for await result in StoreKit.Transaction.currentEntitlements {
                    guard !Task.isCancelled else { break }
                    continuation.yield(map(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func transactionUpdateStream() -> AsyncStream<ProStoreVerification> {
        AsyncStream { continuation in
            let task = Task {
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(map(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The app-owned purchase presentation seam. `EntitlementStore` and its test
/// client deal only in app-owned product/result values; the live presenter is
/// the one place that unwraps StoreKit's product and anchors its confirmation
/// UI to the UIKit scene containing the paywall.
///
/// Capturing the scene weakly matters for multiwindow Multiplex: a presenter
/// resolved in one terminal/deck window must never keep that scene alive or
/// silently move a later purchase prompt to a different active window.
@MainActor
struct ProPurchasePresenter {
    typealias Purchase = @MainActor (
        ProStoreProduct
    ) async throws -> ProStorePurchaseResult

    private let purchase: Purchase

    /// Injectable app-owned boundary used by StoreKit-independent tests.
    init(purchase: @escaping Purchase) {
        self.purchase = purchase
    }

    /// Production presenter for the paywall's actual hosting controller.
    /// `confirmIn: UIScene` is available at the app's iOS 17 / visionOS 1
    /// deployment floors, including visionOS where unanchored purchase is
    /// unavailable.
    init?(presenting viewController: UIViewController) {
        guard let scene = viewController.viewIfLoaded?.window?.windowScene else {
            return nil
        }
        self.init { [weak scene] product in
            guard let product = product.product else {
                throw ProStoreClientError.missingProduct
            }
            guard let scene else {
                throw ProStoreClientError.missingPurchasePresenter
            }
            let result = try await product.purchase(confirmIn: scene)
            switch result {
            case .success(let verification):
                return .success(ProStoreClient.map(verification))
            case .pending:
                return .pending
            case .userCancelled:
                return .userCancelled
            @unknown default:
                return .unknown
            }
        }
    }

    func callAsFunction(_ product: ProStoreProduct) async throws -> ProStorePurchaseResult {
        try await purchase(product)
    }
}

/// Owns every decision about whether Multiplex Pro is available.
///
/// The rest of the app asks this type about capabilities; StoreKit product and
/// transaction types never escape it. The unlock is a single non-consumable,
/// shared by iPadOS and visionOS through the App Store account.
@MainActor
@Observable
final class EntitlementStore {
    static let proProductID = "app.multiplexterm.multiplex.pro"
    static let freeHostLimit = 2
    static let dailySlashChipLimit = 10

    enum CommerceState: Equatable {
        case idle
        case purchasing
        case pending
        case purchased
        case restoring
        case restored
        case failed(String)
    }

    private enum CommerceOperation {
        case purchase
        case restore
    }

    private enum ProductLoadResult {
        case loaded(ProStoreProduct)
        case failed(String)
    }

    private struct ProductLoad {
        let id: UUID
        let task: Task<ProductLoadResult, Never>
    }

    private struct EntitlementRefresh {
        let id: UUID
        let authority: UUID
        let task: Task<Bool, Never>
    }

    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "commerce"
    )

    private static let unlockedKey = "MultiplexProUnlocked"
    private static let slashChipDayKey = "MultiplexSlashChipDay"
    private static let slashChipCountKey = "MultiplexSlashChipCount"

    private let defaults: UserDefaults
    private let now: () -> Date
    private var calendar: Calendar
    private var storeClient: ProStoreClient

    @ObservationIgnored private var proProduct: ProStoreProduct?
    @ObservationIgnored private var productLoad: ProductLoad?
    @ObservationIgnored private var entitlementRefresh: EntitlementRefresh?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var transactionTask: Task<Void, Never>?

    private var commerceOperation: CommerceOperation?
    /// Changes whenever an authoritative purchase/restore/update begins. The
    /// bootstrap snapshot captures the init-time token so even an update that
    /// was already buffered before launch cannot be overwritten by a snapshot
    /// that registers a moment later.
    private var entitlementAuthority = UUID()
    private var storeEntitled = false
    /// Independent of presentation state so a failed Restore can show its
    /// error without accidentally reopening Purchase while Ask-to-Buy may
    /// still be unresolved.
    private var purchaseAwaitingApproval = false
    private var slashChipDay: String
    private var slashChipCount: Int

    #if DEBUG
    /// An absent override deliberately fails open in developer builds. An
    /// explicit value powers Settings' locked-state preview without changing
    /// or pretending to own an App Store transaction.
    private var debugOverride: Bool?
    /// Enabled only by the explicit review-screenshot launch hook.
    private var debugStorefrontPreview = false
    #endif

    private(set) var isPro: Bool
    private(set) var productDisplayPrice: String?
    private(set) var productIsLoading = false
    private(set) var productLoadError: String?
    private(set) var commerceState: CommerceState = .idle

    var commerceIsBusy: Bool {
        commerceOperation != nil
    }

    /// A pending Ask-to-Buy/SCA transaction suppresses duplicate purchase
    /// submissions. Restore remains available because Ask-to-Buy declines do
    /// not emit a transaction update; a user-initiated reconciliation is the
    /// only in-process way to clear that otherwise permanent pending state.
    var purchaseIsUnavailable: Bool {
        commerceOperation != nil || purchaseAwaitingApproval
    }

    var restoreIsUnavailable: Bool {
        commerceOperation != nil
    }

    /// The free tier permits two hosts. Existing/synced hosts are never
    /// removed or disconnected; callers enforce this only before an add.
    func canAddHost(existingHostCount: Int) -> Bool {
        isPro || existingHostCount < Self.freeHostLimit
    }

    /// Turning on mosh is Pro intent; a record that already has it remains
    /// usable/editable after sync or a temporary entitlement loss.
    func canEnableMosh(currentlyEnabled: Bool) -> Bool {
        isPro || currentlyEnabled
    }

    var canMutateCustomThemes: Bool { isPro }
    var canScheduleAgentAlerts: Bool { isPro }
    /// The HISTORY surface (reading agent session files + jump-to-message)
    /// is a Pro helper like the strip's commands; detection stays free.
    var canBrowseAgentHistory: Bool { isPro }

    /// Slash commands alone consume the taste meter. Keyboard-equivalent
    /// helper chips do not call this API.
    var canUseSlashChip: Bool {
        isPro || normalizedSlashChipCount() < Self.dailySlashChipLimit
    }

    var slashChipsRemaining: Int {
        if isPro { return Self.dailySlashChipLimit }
        return max(0, Self.dailySlashChipLimit - normalizedSlashChipCount())
    }

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        startStoreKit: Bool = true,
        storeClient: ProStoreClient? = nil
    ) {
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        self.storeClient = storeClient ?? .live

        let storedDay = defaults.string(forKey: Self.slashChipDayKey) ?? ""
        let storedCount = max(0, defaults.integer(forKey: Self.slashChipCountKey))
        slashChipDay = storedDay
        slashChipCount = storedCount

        #if DEBUG
        let environmentLocked = ProcessInfo.processInfo.environment[
            "MULTIPLEX_PRO_LOCKED"
        ] == "1"
        let override = environmentLocked
            ? false
            : defaults.object(forKey: Self.unlockedKey) as? Bool
        debugOverride = override
        isPro = override ?? true
        #else
        isPro = false
        #endif

        refreshSlashChipMeter()

        guard startStoreKit else { return }

        // Listen before taking the initial snapshot so a transaction that
        // changes during launch cannot fall between the two operations.
        let bootstrapAuthority = entitlementAuthority
        transactionTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshEntitlements(ifAuthorityUnchangedSince: bootstrapAuthority)
            await self.loadStorefront()
        }
    }

    /// Loads the App Store's localized product metadata. A missing product is
    /// surfaced as an actionable paywall error (normally App Store Connect or
    /// local StoreKit configuration), never silently replaced by a hardcoded
    /// price.
    func loadStorefront() async {
        guard proProduct == nil else { return }
        #if DEBUG
        guard !debugStorefrontPreview else { return }
        #endif

        let load: ProductLoad
        if let inFlight = productLoad {
            load = inFlight
        } else {
            productIsLoading = true
            productLoadError = nil
            let id = UUID()
            let task = Task<ProductLoadResult, Never> { [storeClient] in
                do {
                    guard let product = try await storeClient.loadProduct(),
                          product.id == Self.proProductID else {
                        Self.logger.error("product load returned no Pro product")
                        return .failed("Multiplex Pro is not available from the App Store right now.")
                    }
                    return .loaded(product)
                } catch {
                    Self.logger.error(
                        "product load failed: \(String(describing: error), privacy: .public)"
                    )
                    return .failed(Self.storeErrorMessage(error))
                }
            }
            load = ProductLoad(id: id, task: task)
            productLoad = load
        }

        let result = await load.task.value
        // Several callers may await the same load. Only a waiter for the
        // still-current generation may publish/clear it; a late old waiter
        // must never erase a retry that has already started.
        guard productLoad?.id == load.id else { return }
        productLoad = nil
        productIsLoading = false
        switch result {
        case .loaded(let product):
            proProduct = product
            productDisplayPrice = product.displayPrice
            productLoadError = nil
        case .failed(let message):
            productLoadError = message
        }
    }

    /// Purchases the non-consumable. Returns true only when Pro is owned after
    /// verified transaction processing (or was already owned). The app-owned
    /// presenter is resolved from the paywall's hosting controller because
    /// visionOS must anchor confirmation to that active window; StoreKit's
    /// product and result stay behind this service boundary.
    @discardableResult
    func purchasePro(using purchasePresenter: ProPurchasePresenter?) async -> Bool {
        await performPurchase(using: purchasePresenter)
    }

    #if DEBUG
    /// Test entry point for an injected client. Production always calls the
    /// scene-anchored overload above; a fake client does not need a system
    /// purchase presenter.
    @discardableResult
    func purchaseProForTesting() async -> Bool {
        await performPurchase(using: nil)
    }
    #endif

    private func performPurchase(using purchasePresenter: ProPurchasePresenter?) async -> Bool {
        if isPro {
            commerceState = .purchased
            return true
        }
        guard commerceOperation == nil, !purchaseAwaitingApproval else { return false }
        commerceOperation = .purchase
        commerceState = .purchasing
        defer { commerceOperation = nil }

        if proProduct == nil {
            await loadStorefront()
        }
        guard let product = proProduct else {
            return settlePurchase(withFallback: .failed(
                productLoadError ?? "Multiplex Pro is not available from the App Store right now."
            ))
        }

        do {
            let result = try await storeClient.purchase(product, purchasePresenter)

            switch result {
            case .success(.unverified):
                Self.logger.error("purchase returned an unverified transaction")
                return settlePurchase(withFallback: .failed(
                    "The App Store transaction could not be verified."
                ))

            case .success(.verified(let transaction)):
                guard transactionGrantsPro(transaction) else {
                    return settlePurchase(withFallback: .failed(
                        "The purchase is not an active Multiplex Pro entitlement."
                    ))
                }
                advanceEntitlementAuthority()
                invalidateEntitlementRefresh()
                storeEntitled = true
                purchaseAwaitingApproval = false
                #if DEBUG
                // A real verified purchase ends an explicit locked preview.
                debugOverride = nil
                #endif
                recomputeProStatus()
                commerceState = .purchased
                // Publish before suspension so a newer update (for example a
                // revocation) can supersede this purchase while finish runs.
                await transaction.finish()
                return storeEntitled

            case .pending:
                if storeEntitled {
                    return settlePurchase(withFallback: .pending)
                }
                purchaseAwaitingApproval = true
                commerceState = .pending
                return false

            case .userCancelled:
                return settlePurchase(withFallback: .idle)

            case .unknown:
                return settlePurchase(withFallback: .failed(
                    "The App Store returned an unknown purchase result."
                ))
            }
        } catch {
            Self.logger.error(
                "purchase failed: \(String(describing: error), privacy: .public)"
            )
            return settlePurchase(withFallback: .failed(Self.storeErrorMessage(error)))
        }
    }

    /// Presents the system authentication flow when needed, then reconciles
    /// current entitlements. `AppStore.sync()` must stay user-initiated.
    @discardableResult
    func restorePurchases() async -> Bool {
        guard commerceOperation == nil else { return false }
        let authorityAtStart = entitlementAuthority
        commerceOperation = .restore
        commerceState = .restoring
        defer { commerceOperation = nil }
        do {
            try await storeClient.sync()
            // A snapshot begun before AppStore.sync() cannot prove the state
            // after sync. Retire it before starting the restore snapshot.
            let restoreAuthority = advanceEntitlementAuthority()
            invalidateEntitlementRefresh()
            await refreshEntitlements(ifAuthorityUnchangedSince: restoreAuthority)
            #if DEBUG
            if storeEntitled {
                // Restoring a real purchase ends an explicit locked preview,
                // just like completing a new purchase does.
                debugOverride = nil
                recomputeProStatus()
            }
            #endif
            // A successful user-initiated reconciliation is the escape hatch
            // for an Ask-to-Buy decline, which emits no transaction update.
            purchaseAwaitingApproval = false
            commerceState = .restored
            return storeEntitled
        } catch {
            // Only ownership established/confirmed by a newer StoreKit event
            // may supersede this operation's error. Preexisting ownership or
            // an older snapshot must not masquerade as a successful Restore.
            if entitlementAuthority != authorityAtStart, storeEntitled {
                purchaseAwaitingApproval = false
                commerceState = .restored
                return true
            }
            Self.logger.error(
                "restore sync failed: \(String(describing: error), privacy: .public)"
            )
            // TestFlight's commerce backend routinely fails AppStore.sync()
            // with internal errors (SKInternalErrorDomain) even while the
            // entitlement query works. A snapshot begun NOW is current
            // StoreKit truth — newer than the failed sync — so a verified
            // ownership it reports completes the restore. Promotion only:
            // an EMPTY answer beside a failed sync is the same backend
            // flakiness and must not revoke ownership already established.
            let fallbackAuthority = entitlementAuthority
            let entitled = await currentOwnershipSnapshot()
            if entitlementAuthority == fallbackAuthority {
                if entitled {
                    advanceEntitlementAuthority()
                    invalidateEntitlementRefresh()
                    storeEntitled = true
                    #if DEBUG
                    debugOverride = nil
                    #endif
                    recomputeProStatus()
                    purchaseAwaitingApproval = false
                    commerceState = .restored
                    return true
                }
            } else if storeEntitled {
                // A newer StoreKit event established ownership while the
                // fallback snapshot ran; it owns the outcome.
                purchaseAwaitingApproval = false
                commerceState = .restored
                return true
            }
            commerceState = .failed(Self.storeErrorMessage(error))
            return false
        }
    }

    /// One fresh pass over `currentEntitlements`, published nowhere — the
    /// failed-sync fallback's evidence gathering.
    private func currentOwnershipSnapshot() async -> Bool {
        let entitlementDate = now()
        var entitled = false
        for await result in storeClient.currentEntitlements() {
            guard case .verified(let transaction) = result,
                  Self.transactionGrantsPro(transaction, at: entitlementDate)
            else { continue }
            entitled = true
        }
        return entitled
    }

    /// Rebuilds ownership from verified current App Store entitlements. A
    /// cached UserDefaults bit is intentionally not an authority in Release.
    func refreshEntitlements() async {
        await refreshEntitlements(ifAuthorityUnchangedSince: entitlementAuthority)
    }

    private func refreshEntitlements(ifAuthorityUnchangedSince authority: UUID) async {
        // A bootstrap caller can arrive after a buffered StoreKit update has
        // already advanced authority. Reject it before it can join a newer
        // restore refresh and consume that valid waiter's publication.
        guard entitlementAuthority == authority else { return }

        let refresh: EntitlementRefresh
        if let inFlight = entitlementRefresh, inFlight.authority == authority {
            refresh = inFlight
        } else {
            entitlementRefresh?.task.cancel()
            let id = UUID()
            let entitlementDate = now()
            let task = Task<Bool, Never> { [storeClient] in
                var entitled = false
                for await result in storeClient.currentEntitlements() {
                    guard case .verified(let transaction) = result,
                          Self.transactionGrantsPro(transaction, at: entitlementDate)
                    else { continue }
                    entitled = true
                }
                return entitled
            }
            refresh = EntitlementRefresh(id: id, authority: authority, task: task)
            entitlementRefresh = refresh
        }

        let entitled = await refresh.task.value
        // Only the still-current generation may publish. A verified purchase,
        // sync, or transaction update can invalidate an older snapshot while
        // it is suspended so stale false never overwrites newer truth.
        guard entitlementRefresh?.id == refresh.id,
              entitlementAuthority == authority else { return }
        entitlementRefresh = nil
        storeEntitled = entitled
        recomputeProStatus()
        if !entitled, commerceState == .purchased {
            commerceState = .idle
        }
    }

    /// Atomically checks and consumes one free slash-command use. Pro calls
    /// always succeed without touching the counter.
    @discardableResult
    func consumeSlashChip() -> Bool {
        if isPro { return true }

        refreshSlashChipMeter()
        guard slashChipCount < Self.dailySlashChipLimit else { return false }
        slashChipCount += 1
        defaults.set(slashChipCount, forKey: Self.slashChipCountKey)
        return true
    }

    /// Normalizes persisted meter state to today's local Gregorian date.
    /// Scene activation and the already-running agent probe tick call this so
    /// a visible spent strip updates promptly after midnight; reads also
    /// treat a stale day as an empty counter.
    func refreshSlashChipMeter() {
        let today = dayIdentifier(for: now())
        guard slashChipDay != today else { return }
        slashChipDay = today
        slashChipCount = 0
        defaults.set(today, forKey: Self.slashChipDayKey)
        defaults.set(0, forKey: Self.slashChipCountKey)
    }

    #if DEBUG
    func setDebugUnlocked(_ unlocked: Bool) {
        debugOverride = unlocked
        defaults.set(unlocked, forKey: Self.unlockedKey)
        recomputeProStatus()
    }

    /// Deterministic App Review screenshot setup. The paywall remains the
    /// real view; only its normally App-Store-supplied price is previewed.
    func prepareDebugPaywallPreview(displayPrice: String = "$19.99") {
        // A storefront request may already be suspended. Retire its generation
        // so a late response cannot overwrite the deterministic review price.
        productLoad?.task.cancel()
        productLoad = nil
        productIsLoading = false
        debugOverride = false
        debugStorefrontPreview = true
        productDisplayPrice = displayPrice
        productLoadError = nil
        recomputeProStatus()
    }

    var hasVerifiedStoreEntitlementForTesting: Bool { storeEntitled }

    var entitlementAuthorityForTesting: UUID { entitlementAuthority }

    func startTransactionListenerForTesting() {
        guard transactionTask == nil else { return }
        transactionTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
    }

    func refreshEntitlementsForTesting(ifAuthorityUnchangedSince authority: UUID) async {
        await refreshEntitlements(ifAuthorityUnchangedSince: authority)
    }

    func waitForStoreKitBootstrapForTesting() async {
        await bootstrapTask?.value
    }
    #endif

    private func listenForTransactions() async {
        for await result in storeClient.updates() {
            guard !Task.isCancelled else { return }
            switch result {
            case .verified(let transaction):
                guard transaction.productID == Self.proProductID else { continue }
                let updateGrantsPro = transactionGrantsPro(transaction)
                // Apply the update before the first suspension. That gives
                // causal ordering a simple rule: snapshots already running
                // are retired; a restore/snapshot begun after this point is
                // newer and may legitimately supersede the event. This is a
                // single non-consumable, so no aggregate refresh is needed.
                advanceEntitlementAuthority()
                invalidateEntitlementRefresh()
                let wasAwaitingApproval = purchaseAwaitingApproval
                purchaseAwaitingApproval = false
                if updateGrantsPro {
                    storeEntitled = true
                    #if DEBUG
                    if wasAwaitingApproval { debugOverride = nil }
                    #endif
                    recomputeProStatus()
                    if wasAwaitingApproval {
                        commerceState = .purchased
                    } else if case .failed = commerceState {
                        // Ownership is authoritative; never leave the unlocked
                        // paywall paired with an obsolete operation error.
                        commerceState = .purchased
                    }
                } else {
                    // A verified revocation/expiry update is newer than any
                    // lagging positive snapshot. Fail closed immediately;
                    // a genuinely newer purchase will deliver its own
                    // positive update and unlock again.
                    storeEntitled = false
                    recomputeProStatus()
                    switch (wasAwaitingApproval, commerceState) {
                    case (true, _):
                        commerceState = .failed(
                            "The pending purchase did not grant an active Multiplex Pro entitlement."
                        )
                    case (false, .purchased):
                        commerceState = .idle
                    default:
                        break
                    }
                }
                await transaction.finish()
            case .unverified(let productID):
                Self.logger.error(
                    "unverified transaction update for \(productID ?? "?", privacy: .public)"
                )
                guard productID == Self.proProductID, purchaseAwaitingApproval else { continue }
                purchaseAwaitingApproval = false
                commerceState = .failed("The App Store transaction could not be verified.")
            }
        }
    }

    private func recomputeProStatus() {
        #if DEBUG
        // An absent override stays fail-open for daily development. An
        // explicit value is authoritative so Settings and the review hook
        // can preview the locked surface even on a dirty simulator; a newly
        // verified purchase clears that preview in the purchase paths above.
        isPro = Self.resolveProStatus(
            storeEntitled: storeEntitled,
            debugOverride: debugOverride,
            developerFailOpen: true
        )
        #else
        isPro = Self.resolveProStatus(
            storeEntitled: storeEntitled,
            debugOverride: nil,
            developerFailOpen: false
        )
        #endif
    }

    private func settlePurchase(withFallback fallback: CommerceState) -> Bool {
        if storeEntitled {
            purchaseAwaitingApproval = false
            commerceState = .purchased
            return true
        }
        commerceState = fallback
        return false
    }

    /// StoreKit's `localizedDescription` collapses most failures into "An
    /// unknown error occurred", which is undiagnosable from a screenshot of
    /// the paywall (the shape of the App Review sandbox reports). Name the
    /// known StoreKit failure modes in actionable copy; anything else keeps
    /// its own description.
    static func storeErrorMessage(_ error: Error) -> String {
        switch error {
        case StoreKitError.networkError:
            return "The App Store could not be reached. Check the internet "
                + "connection and try again."
        case StoreKitError.systemError(let underlying):
            return "The App Store reported a system error. "
                + "(\(underlying.localizedDescription))"
        case StoreKitError.notAvailableInStorefront:
            return "Multiplex Pro is not available in this App Store storefront."
        case StoreKitError.notEntitled:
            return "This copy of the app is not entitled to App Store purchases."
        case StoreKitError.unknown:
            return "The App Store could not complete the request. "
                + "Try again in a moment."
        case Product.PurchaseError.purchaseNotAllowed:
            return "Purchases are not allowed for this Apple ID on this device."
        case Product.PurchaseError.productUnavailable:
            return "Multiplex Pro is not available for purchase right now."
        default:
            // An error with no authored description renders as the opaque
            // "operation couldn't be completed (SKInternalErrorDomain error
            // 14)" shape — say something actionable and keep the code as a
            // diagnostic suffix. Bridged Swift errors carry no userInfo, so
            // LocalizedError's authored message must be consulted directly.
            let nsError = error as NSError
            if nsError.userInfo[NSLocalizedDescriptionKey] == nil,
               (error as? LocalizedError)?.errorDescription == nil {
                return "The App Store could not complete the request. Check "
                    + "that this device is signed in to the App Store, then "
                    + "try again. (\(nsError.domain) \(nsError.code))"
            }
            return error.localizedDescription
        }
    }

    /// One policy function serves both compilation modes, so tests can pin
    /// the shipping rule: Release ignores every UserDefaults/debug override
    /// and trusts only a verified current StoreKit entitlement.
    static func resolveProStatus(
        storeEntitled: Bool,
        debugOverride: Bool?,
        developerFailOpen: Bool
    ) -> Bool {
        developerFailOpen ? (debugOverride ?? true) : storeEntitled
    }

    private func invalidateEntitlementRefresh() {
        entitlementRefresh?.task.cancel()
        entitlementRefresh = nil
    }

    @discardableResult
    private func advanceEntitlementAuthority() -> UUID {
        let authority = UUID()
        entitlementAuthority = authority
        return authority
    }

    private func transactionGrantsPro(_ transaction: ProStoreTransaction) -> Bool {
        Self.transactionGrantsPro(transaction, at: now())
    }

    private static func transactionGrantsPro(
        _ transaction: ProStoreTransaction,
        at date: Date
    ) -> Bool {
        transaction.productID == Self.proProductID
            && transaction.revocationDate == nil
            && (transaction.expirationDate.map { $0 > date } ?? true)
    }

    private func normalizedSlashChipCount() -> Int {
        slashChipDay == dayIdentifier(for: now()) ? slashChipCount : 0
    }

    private func dayIdentifier(for date: Date) -> String {
        var localGregorian = Calendar(identifier: .gregorian)
        localGregorian.timeZone = calendar.timeZone
        let components = localGregorian.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
