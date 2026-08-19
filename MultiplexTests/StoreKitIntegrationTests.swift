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

        // Product requests establish the just-created test session. Xcode 26's
        // simulator StoreKit daemon can race that catalog swap, log
        // SKInternalError Code=3, and return an empty first response. Retry
        // only that transient empty result; real request errors still fail.
        let loadedProduct = try await loadProProduct()
        let product = try XCTUnwrap(loadedProduct)
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

    private func loadProProduct() async throws -> Product? {
        let maximumAttempts = 3
        for attempt in 1...maximumAttempts {
            let products = try await Product.products(for: [EntitlementStore.proProductID])
            if let product = products.first(where: { $0.id == EntitlementStore.proProductID }) {
                return product
            }
            if attempt < maximumAttempts {
                try await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }
}
