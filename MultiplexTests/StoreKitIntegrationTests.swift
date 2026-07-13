import StoreKit
import StoreKitTest
import XCTest
@testable import Multiplex

/// Loads the real local catalog through StoreKit, rather than merely parsing
/// its JSON. Transaction automation stays out of the required suite while
/// Xcode 27 beta emits invalidDeviceVerification for locally created
/// transactions on both iPadOS and visionOS simulators. EntitlementStoreTests
/// exhaustively exercise the app-owned purchase/restore/update policy through
/// an injected client; Apple-signature and universal-purchase verification
/// remains a TestFlight/Sandbox release check until Apple fixes the runtime.
@MainActor
final class StoreKitIntegrationTests: XCTestCase {
    func testLocalCatalogLoadsNonConsumableProProduct() async throws {
        let session = try SKTestSession(configurationFileNamed: "Multiplex")
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        // The first Product request establishes the just-created test
        // session on iPadOS; app-level requests made before that activation
        // can race StoreKit's catalog swap and briefly see an empty result.
        let products = try await Product.products(for: [EntitlementStore.proProductID])
        let product = try XCTUnwrap(
            products.first(where: { $0.id == EntitlementStore.proProductID })
        )
        XCTAssertEqual(product.type, .nonConsumable)
        XCTAssertEqual(product.displayName, "Multiplex Pro")
        XCTAssertEqual(product.description, "Unlimited hosts, mosh, agent tools & themes.")

        let suiteName = "StoreKitIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "MultiplexProUnlocked")

        let store = EntitlementStore(defaults: defaults, startStoreKit: false)
        await store.loadStorefront()

        XCTAssertEqual(store.commerceState, .idle)
        XCTAssertNil(store.productLoadError)
        XCTAssertFalse(store.productIsLoading)
        XCTAssertTrue(store.productDisplayPrice?.contains("19.99") == true)
        XCTAssertFalse(store.isPro)
    }

}
