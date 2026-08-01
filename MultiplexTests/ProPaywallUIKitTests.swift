import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class ProPaywallUIKitTests: XCTestCase {
    func testNativeControllerPreservesPaywallLayoutCopyPriceAndAccessibility() {
        let (store, defaults, domain) = makeLockedStore()
        defer { defaults.removePersistentDomain(forName: domain) }
        store.prepareDebugPaywallPreview(displayPrice: "NT$650")

        let controller = ProPaywallViewController(entitlements: store)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.title, "Pro")
        XCTAssertEqual(controller.navigationItem.largeTitleDisplayMode, .never)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.title, "Done")
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.style, .plain)
        XCTAssertNil(controller.navigationItem.rightBarButtonItem?.customView)
        XCTAssertEqual(
            controller.navigationItem.rightBarButtonItem?.accessibilityLabel,
            "Done"
        )
        XCTAssertEqual(controller.contentStack.spacing, ProPaywallViewController.Metrics.sectionSpacing)
        XCTAssertEqual(ProPaywallViewController.Metrics.outerInset, 26)
        XCTAssertEqual(ProPaywallViewController.Metrics.contentMaximumWidth, 620)
        XCTAssertTrue(hasContentMaximumWidthConstraint(in: controller.view))

        let rendered = renderedText(in: controller.view)
        XCTAssertTrue(rendered.contains("MULTIPLEX PRO"))
        XCTAssertTrue(rendered.contains("Buy once. Use it on iPad and Vision Pro."))
        XCTAssertTrue(rendered.contains("UNLIMITED HOSTS"))
        XCTAssertTrue(rendered.contains("MOSH TRANSPORT"))
        XCTAssertTrue(rendered.contains("AGENT HELPERS + ALERTS"))
        XCTAssertTrue(rendered.contains("CUSTOM THEMES"))
        XCTAssertTrue(rendered.contains("Unlock Multiplex Pro · NT$650"))
        XCTAssertTrue(rendered.contains("ONE-TIME"))
        XCTAssertTrue(rendered.contains("Restore Purchases"))
        XCTAssertTrue(rendered.contains(
            "Payment is charged to your Apple ID. No subscription."
        ))

        XCTAssertFalse(controller.purchaseButton.isHidden)
        XCTAssertTrue(controller.unlockedRow.isHidden)
        XCTAssertTrue(controller.purchaseButton.accessibilityTraits.contains(.button))
        XCTAssertEqual(
            controller.purchaseButton.accessibilityLabel,
            "Unlock Multiplex Pro · NT$650"
        )
        XCTAssertEqual(
            controller.purchaseButton.accessibilityHint,
            "Purchases the non-consumable Multiplex Pro unlock"
        )
        XCTAssertFalse(controller.purchaseButton.allTargets.isEmpty)
        XCTAssertFalse(controller.restoreButton.allTargets.isEmpty)

        var doneFired = false
        controller.onDone = { doneFired = true }
        guard let item = controller.navigationItem.rightBarButtonItem,
              let action = item.action else {
            return XCTFail("Missing Done bar action")
        }
        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        XCTAssertTrue(doneFired)

        controller.appAppearance = .light
        XCTAssertEqual(controller.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(navigation.overrideUserInterfaceStyle, .light)
        controller.appAppearance = .dark
        XCTAssertEqual(controller.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(navigation.overrideUserInterfaceStyle, .dark)
    }

    func testNativeControllerObservesUnlockWithoutSwiftUIStateOwner() async {
        let (store, defaults, domain) = makeLockedStore()
        defer { defaults.removePersistentDomain(forName: domain) }
        store.prepareDebugPaywallPreview()

        let controller = ProPaywallViewController(entitlements: store)
        controller.loadViewIfNeeded()
        XCTAssertFalse(controller.purchaseButton.isHidden)
        XCTAssertTrue(controller.unlockedRow.isHidden)

        store.setDebugUnlocked(true)
        await waitUntil("native paywall unlock rendering") {
            controller.purchaseButton.isHidden && !controller.unlockedRow.isHidden
        }

        XCTAssertTrue(controller.unlockedRow.isAccessibilityElement)
        XCTAssertEqual(
            controller.unlockedRow.accessibilityLabel,
            "Multiplex Pro is unlocked. This purchase is available on your devices "
                + "with the same Apple ID."
        )
    }

    func testPurchaseFailureRemainsInlineAndUsesCautionChannel() async {
        let (store, defaults, domain) = makeLockedStore()
        defer { defaults.removePersistentDomain(forName: domain) }
        // This deterministic DEBUG storefront price deliberately has no live
        // StoreKit Product behind it, matching the review-capture hook.
        store.prepareDebugPaywallPreview()

        let controller = ProPaywallViewController(entitlements: store)
        controller.loadViewIfNeeded()
        controller.purchaseButton.sendActions(for: .touchUpInside)

        await waitUntil("native paywall purchase failure") {
            controller.commerceMessageLabel.text
                == "Multiplex Pro is not available from the App Store right now."
        }

        XCTAssertFalse(controller.commerceMessageLabel.isHidden)
        XCTAssertEqual(store.commerceState, .failed(
            "Multiplex Pro is not available from the App Store right now."
        ))
        XCTAssertEqual(
            controller.commerceMessageLabel.textColor.resolvedColor(
                with: controller.traitCollection
            ),
            TallyPalette.caution.resolvedColor(with: controller.traitCollection)
        )
    }

    private func makeLockedStore() -> (EntitlementStore, UserDefaults, String) {
        let domain = "ProPaywallUIKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        let store = EntitlementStore(defaults: defaults, startStoreKit: false)
        store.setDebugUnlocked(false)
        return (store, defaults, domain)
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

    private func hasContentMaximumWidthConstraint(in root: UIView) -> Bool {
        guard let contentStack = descendants(of: UIStackView.self, in: root)
            .first(where: {
                $0.axis == .vertical
                    && $0.spacing == ProPaywallViewController.Metrics.sectionSpacing
            }) else {
            return false
        }

        return allConstraints(in: root).contains { constraint in
            (constraint.firstItem as? UIStackView) === contentStack
                && constraint.firstAttribute == .width
                && constraint.relation == .lessThanOrEqual
                && constraint.constant == ProPaywallViewController.Metrics.contentMaximumWidth
        }
    }

    private func allConstraints(in view: UIView) -> [NSLayoutConstraint] {
        view.constraints + view.subviews.flatMap(allConstraints(in:))
    }

    private func renderedText(in root: UIView) -> [String] {
        let labels = descendants(of: UILabel.self, in: root).compactMap {
            $0.attributedText?.string ?? $0.text
        }
        let buttonTitles = descendants(of: UIButton.self, in: root).compactMap {
            $0.title(for: .normal)
        }
        return labels + buttonTitles
    }

    private func descendants<View: UIView>(
        of type: View.Type,
        in root: UIView
    ) -> [View] {
        var result: [View] = []
        if let match = root as? View {
            result.append(match)
        }
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }
}
