import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class SettingsUIKitTests: XCTestCase {
    private struct Fixture {
        let controller: SettingsViewController
        let navigation: UINavigationController
        let themes: ThemeStore
        let entitlements: EntitlementStore
        let attention: AttentionCenter
        let appLock: AppLockStore
        let defaults: [UserDefaults]
        let domains: [String]
        let themeDirectory: URL
        let originalAlertsEnabled: Bool
    }

    func testNativeSettingsPreservesStructureCopyNavigationAndAccessibility() {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        fixture.navigation.loadViewIfNeeded()
        fixture.controller.loadViewIfNeeded()

        XCTAssertEqual(fixture.controller.title, "Settings")
        XCTAssertEqual(fixture.controller.navigationItem.largeTitleDisplayMode, .never)
        XCTAssertEqual(fixture.controller.navigationItem.rightBarButtonItem?.title, "Done")
        XCTAssertEqual(fixture.controller.navigationItem.rightBarButtonItem?.style, .plain)
        XCTAssertNil(fixture.controller.navigationItem.rightBarButtonItem?.customView)
        XCTAssertEqual(
            fixture.controller.navigationItem.rightBarButtonItem?.accessibilityLabel,
            "Done"
        )
        XCTAssertEqual(
            fixture.controller.contentStack.spacing,
            SettingsViewController.Metrics.sectionSpacing
        )
        XCTAssertEqual(SettingsViewController.Metrics.outerInset, 18)
        XCTAssertEqual(SettingsViewController.Metrics.contentMaximumWidth, 680)
        XCTAssertTrue(hasContentMaximumWidthConstraint(in: fixture.controller.view))

        let headers = descendants(
            of: UIKitChassisLabel.self,
            in: fixture.controller.view
        ).filter { $0.accessibilityTraits.contains(.header) }
        XCTAssertEqual(headers.compactMap(\.accessibilityLabel), [
            "Appearance",
            "Current theme",
            "Built-in themes",
            "Your themes",
            "Terminal renderer",
            "Connection stats",
            "Agent alerts",
            "App lock",
            "Multiplex Pro",
            "About",
        ])

        let rendered = renderedText(in: fixture.controller.view)
        XCTAssertTrue(rendered.contains("TERMINAL SURFACE"))
        XCTAssertTrue(rendered.contains("TALLY"))
        XCTAssertTrue(rendered.contains("NO CUSTOM THEMES"))
        XCTAssertTrue(rendered.contains("UNLIMITED HOSTS"))
        XCTAssertTrue(rendered.contains("MOSH TRANSPORT"))
        XCTAssertTrue(rendered.contains("AGENT HELPERS"))
        XCTAssertTrue(rendered.contains("Metal renderer"))
        XCTAssertTrue(rendered.contains("AGENT ALERTS"))
        XCTAssertTrue(rendered.contains("CONNECTION STATS"))
        XCTAssertTrue(rendered.contains("CUSTOM THEMES"))
        XCTAssertTrue(rendered.contains("OPEN SOURCE LICENSES"))
        XCTAssertTrue(rendered.contains("PRIVACY POLICY"))
        if GlassPrototype.enabled {
            XCTAssertTrue(rendered.contains {
                $0.contains("Dark and Glass share the dark terminal theme")
            })
        }

        XCTAssertEqual(
            fixture.controller.appearanceChoiceBar?.arrangedSubviews.count,
            AppAppearance.availableCases.count
        )
        XCTAssertEqual(
            fixture.controller.appearanceChoiceBar?.selection,
            AppAppearance.system
        )
        XCTAssertEqual(fixture.controller.agentAlertsControl?.accessibilityLabel, "Agent alerts")
        XCTAssertEqual(
            fixture.controller.agentAlertsControl?.accessibilityHint,
            "Requires Multiplex Pro"
        )
        XCTAssertEqual(
            fixture.controller.appLockControl?.accessibilityLabel,
            "Require \(AppLockStore.methodName)"
        )

        var doneFired = false
        fixture.controller.onDone = { doneFired = true }
        send(fixture.controller.navigationItem.rightBarButtonItem)
        XCTAssertTrue(doneFired)
    }

    func testInitialContentClearsNavigationBarAndLaterRendersPreserveScroll() async throws {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        UIKitChassis.configureSheetNavigationBar(fixture.navigation.navigationBar)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = fixture.navigation
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        fixture.navigation.view.frame = window.bounds
        fixture.navigation.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(
            descendants(of: UIScrollView.self, in: fixture.controller.view).first
        )
        XCTAssertEqual(
            scrollView.contentOffset.y,
            -scrollView.adjustedContentInset.top,
            accuracy: 0.5
        )

        let appearance = try XCTUnwrap(
            descendants(of: SettingsSectionView.self, in: fixture.controller.view)
                .first { $0.title == "Appearance" }
        )
        let appearanceFrame = appearance.convert(appearance.bounds, to: window)
        let navigationFrame = fixture.navigation.navigationBar.convert(
            fixture.navigation.navigationBar.bounds,
            to: window
        )
        XCTAssertEqual(
            appearanceFrame.minY,
            navigationFrame.maxY + SettingsViewController.Metrics.outerInset,
            accuracy: 1
        )

        let retainedOffset = CGPoint(x: 0, y: 120)
        scrollView.setContentOffset(retainedOffset, animated: false)
        fixture.themes.appearance = .dark
        await waitUntil("appearance rerender") {
            fixture.controller.appearanceChoiceBar?.selection == .dark
        }
        XCTAssertEqual(scrollView.contentOffset.y, retainedOffset.y, accuracy: 0.5)
    }

    func testAppearanceChoiceMutatesStoreWithoutReplacingItsControl() async throws {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()

        let originalBar = try XCTUnwrap(fixture.controller.appearanceChoiceBar)
        let originalButtons = originalBar.arrangedSubviews
        let light = try XCTUnwrap(
            originalButtons[1] as? UIControl
        )
        light.sendActions(for: .touchUpInside)

        await waitUntil("appearance observation") {
            fixture.themes.appearance == .light
                && fixture.controller.overrideUserInterfaceStyle == .light
                && fixture.controller.appearanceChoiceBar?.selection == .light
        }
        let observedBar = try XCTUnwrap(fixture.controller.appearanceChoiceBar)
        XCTAssertTrue(observedBar === originalBar)
        XCTAssertEqual(observedBar.arrangedSubviews.count, originalButtons.count)
        for (observed, original) in zip(observedBar.arrangedSubviews, originalButtons) {
            XCTAssertTrue(observed === original)
        }
        XCTAssertNotNil(originalBar.superview)
        XCTAssertEqual(
            fixture.themes.selected(for: .light).id,
            TerminalTheme.lightDefault.id
        )
    }

    func testAppearanceChoiceRunsInterruptibleEaseOutSelectionTransition() throws {
        var changes: [AppAppearance] = []
        let bar = SettingsAppearanceChoiceBar(
            selection: .system,
            reduceMotion: { false },
            changed: { changes.append($0) }
        )
        bar.frame = CGRect(x: 0, y: 0, width: 301, height: 34)
        bar.layoutIfNeeded()
        let light = try XCTUnwrap(bar.arrangedSubviews[1] as? UIControl)

        XCTAssertEqual(SettingsAppearanceChoiceMetrics.height, 34)
        XCTAssertEqual(SettingsAppearanceChoiceMetrics.seam, 1)
        XCTAssertEqual(SettingsAppearanceChoiceMetrics.selectionAnimationDuration, 0.14)
        XCTAssertEqual(SettingsAppearanceChoiceMetrics.selectionAnimationCurve, .easeOut)
        XCTAssertEqual(bar.spacing, SettingsAppearanceChoiceMetrics.seam)
        XCTAssertEqual(bar.distribution, .fillEqually)
        XCTAssertTrue(bar.arrangedSubviews.allSatisfy { view in
            guard let button = view as? UIButton else { return false }
            return button.buttonType == .custom && button.configuration == nil
        })

        light.sendActions(for: .touchUpInside)

        let animator = try XCTUnwrap(bar.activeSelectionAnimator)
        XCTAssertEqual(
            animator.duration,
            SettingsAppearanceChoiceMetrics.selectionAnimationDuration
        )
        XCTAssertEqual(bar.selection, .light)
        XCTAssertEqual(changes, [.light])
        XCTAssertTrue(light.accessibilityTraits.contains(.selected))

        if animator.state == .active {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .end)
        }
    }

    func testThemeSelectionAndNewThemeEditorUseNativeRoutes() async throws {
        let fixture = makeFixture(isPro: true)
        defer { clean(fixture) }
        // Theme selection applies to the appearance currently rendered by the
        // settings surface. Pin this test to dark so its slot assertions do
        // not depend on the simulator's system appearance.
        fixture.themes.appearance = .dark
        fixture.navigation.loadViewIfNeeded()
        fixture.controller.loadViewIfNeeded()

        let nord = try XCTUnwrap(descendants(of: UIControl.self, in: fixture.controller.view)
            .first { $0.accessibilityLabel == "Nord theme" })
        nord.sendActions(for: .touchUpInside)
        await waitUntil("theme selection observation") {
            fixture.themes.selected(for: .dark).id == TerminalTheme.nord.id
        }

        let newTheme = try XCTUnwrap(descendants(
            of: UIKitChassisChip.self,
            in: fixture.controller.view
        ).first { $0.accessibilityLabel == "New theme" })
        XCTAssertTrue(newTheme.accessibilityActivate())
        let editor = try XCTUnwrap(
            fixture.navigation.topViewController as? ThemeEditorViewController
        )
        // A navigation controller without a window may defer loading the
        // pushed controller. Load it explicitly before driving its native
        // fields and bar item; production presentation loads it naturally.
        editor.loadViewIfNeeded()
        XCTAssertEqual(editor.draft.name, "New Theme")
        XCTAssertNotEqual(editor.draft.id, TerminalTheme.nord.id)

        editor.nameField.text = "Nord Console"
        editor.nameField.sendActions(for: .editingChanged)
        send(editor.saveItem)
        await waitUntil("new theme save") {
            fixture.themes.customThemes.contains { $0.name == "Nord Console" }
                && fixture.navigation.topViewController === fixture.controller
        }
        XCTAssertEqual(fixture.themes.selected(for: .dark).name, "Nord Console")
    }

    func testLockedAlertIntentIsRememberedAndRoutesToPaywall() async {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        fixture.attention.alertsEnabled = false
        var paywallRequests = 0
        fixture.controller.presentPaywallOverride = { paywallRequests += 1 }

        fixture.controller.agentAlertsControl?.sendActions(for: .touchUpInside)
        XCTAssertTrue(fixture.attention.alertsEnabled)
        XCTAssertEqual(paywallRequests, 1)
        await waitUntil("locked alert projection") {
            fixture.controller.agentAlertsControl?.isOn == false
        }
    }

    func testAppLockToggleAwaitsAuthenticationAndObservesStoreDecision() async {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        XCTAssertFalse(fixture.appLock.isEnabled)

        fixture.controller.appLockControl?.sendActions(for: .touchUpInside)
        await waitUntil("app-lock authentication") {
            fixture.appLock.isEnabled
                && fixture.controller.appLockControl?.isOn == true
        }
    }

    func testRejectedAppLockAuthenticationNeverPaintsAnOptimisticOnState() async {
        let fixture = makeFixture(isPro: false, appLockAuthenticationSucceeds: false)
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()

        fixture.controller.appLockControl?.sendActions(for: .touchUpInside)
        XCTAssertFalse(fixture.controller.appLockControl?.isOn ?? true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(fixture.appLock.isEnabled)
        XCTAssertFalse(fixture.controller.appLockControl?.isOn ?? true)
    }

    func testUnlockingProRebuildsGatesWithoutSwiftUIStateOwner() async {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        XCTAssertEqual(fixture.controller.agentAlertsControl?.accessibilityHint,
                       "Requires Multiplex Pro")

        fixture.entitlements.setDebugUnlocked(true)
        await waitUntil("settings entitlement observation") {
            fixture.controller.agentAlertsControl?.accessibilityHint == nil
                && self.renderedText(in: fixture.controller.view).contains("UNLOCKED")
        }
    }

    func testLicensesRowPresentsItsOwnModalSheet() async throws {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        // Presenting needs a scene-attached window (a scene-less window
        // cannot present on visionOS).
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = fixture.navigation
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        fixture.navigation.view.frame = window.bounds
        fixture.navigation.view.layoutIfNeeded()

        let row = try XCTUnwrap(descendants(
            of: UIControl.self,
            in: fixture.controller.view
        ).first { $0.accessibilityLabel == "Open source licenses" })
        row.sendActions(for: .touchUpInside)

        await waitUntil("licenses modal presentation") {
            fixture.controller.presentedViewController != nil
        }
        let presented = try XCTUnwrap(
            fixture.controller.presentedViewController as? UINavigationController
        )
        let licenses = try XCTUnwrap(
            presented.viewControllers.first as? LicensesViewController
        )
        licenses.loadViewIfNeeded()
        XCTAssertEqual(licenses.title, "Open Source Licenses")
        XCTAssertEqual(licenses.components.count, 13)
        XCTAssertNotNil(
            licenses.navigationItem.rightBarButtonItem,
            "A modal licenses sheet needs its own Done"
        )
        // Settings itself stays where it was — the licenses page is a
        // sibling sheet, never a push that resizes the settings stack.
        XCTAssertTrue(fixture.navigation.topViewController === fixture.controller)

        // Leave no live presentation behind: the next presenting test would
        // crash the shared test host's sheet machinery. Dismissal completes
        // on later run-loop turns, so poll with real sleeps (Task.yield
        // alone never lets UIKit's completion run).
        fixture.controller.dismiss(animated: false)
        for _ in 0..<100 where fixture.controller.presentedViewController != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(
            fixture.controller.presentedViewController,
            "Licenses modal must be dismissed before the test ends"
        )
    }

    func testPrivacyChipRoutesTheExactPolicyURL() throws {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        var opened: URL?
        fixture.controller.openPrivacyPolicy = { opened = $0 }

        let chip = try XCTUnwrap(descendants(
            of: UIKitChassisChip.self,
            in: fixture.controller.view
        ).first { $0.accessibilityLabel == "Privacy policy" })
        XCTAssertTrue(chip.accessibilityTraits.contains(.link))
        XCTAssertTrue(chip.accessibilityActivate())
        XCTAssertEqual(opened?.absoluteString, "https://multiplexterm.dev/privacy")
    }

    private func makeFixture(
        isPro: Bool,
        appLockAuthenticationSucceeds: Bool = true
    ) -> Fixture {
        let themeDomain = "SettingsUIKitTests.themes.\(UUID().uuidString)"
        let entitlementDomain = "SettingsUIKitTests.pro.\(UUID().uuidString)"
        let appLockDomain = "SettingsUIKitTests.lock.\(UUID().uuidString)"
        let themeDefaults = UserDefaults(suiteName: themeDomain)!
        let entitlementDefaults = UserDefaults(suiteName: entitlementDomain)!
        let appLockDefaults = UserDefaults(suiteName: appLockDomain)!
        [
            (themeDefaults, themeDomain),
            (entitlementDefaults, entitlementDomain),
            (appLockDefaults, appLockDomain),
        ].forEach { defaults, domain in
            defaults.removePersistentDomain(forName: domain)
        }
        let themeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(themeDomain, isDirectory: true)
        let themes = ThemeStore(defaults: themeDefaults, directory: themeDirectory)
        let entitlements = EntitlementStore(
            defaults: entitlementDefaults,
            startStoreKit: false
        )
        entitlements.setDebugUnlocked(isPro)
        let attention = AttentionCenter()
        let originalAlertsEnabled = attention.alertsEnabled
        let appLock = AppLockStore(
            defaults: appLockDefaults,
            authenticate: { _ in appLockAuthenticationSucceeds }
        )
        let controller = SettingsViewController(
            themes: themes,
            entitlements: entitlements,
            attention: attention,
            appLock: appLock
        )
        let navigation = UINavigationController(rootViewController: controller)
        return Fixture(
            controller: controller,
            navigation: navigation,
            themes: themes,
            entitlements: entitlements,
            attention: attention,
            appLock: appLock,
            defaults: [themeDefaults, entitlementDefaults, appLockDefaults],
            domains: [themeDomain, entitlementDomain, appLockDomain],
            themeDirectory: themeDirectory,
            originalAlertsEnabled: originalAlertsEnabled
        )
    }

    private func clean(_ fixture: Fixture) {
        for (defaults, domain) in zip(fixture.defaults, fixture.domains) {
            defaults.removePersistentDomain(forName: domain)
        }
        fixture.attention.alertsEnabled = fixture.originalAlertsEnabled
        try? FileManager.default.removeItem(at: fixture.themeDirectory)
    }

    private func send(_ item: UIBarButtonItem?) {
        guard let item, let action = item.action else {
            return XCTFail("Missing bar-button action")
        }
        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
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
        let stack = descendants(of: UIStackView.self, in: root).first {
            $0.axis == .vertical
                && $0.spacing == SettingsViewController.Metrics.sectionSpacing
        }
        guard let stack else { return false }
        return allConstraints(in: root).contains { constraint in
            (constraint.firstItem as? UIStackView) === stack
                && constraint.firstAttribute == .width
                && constraint.relation == .lessThanOrEqual
                && constraint.constant == SettingsViewController.Metrics.contentMaximumWidth
        }
    }

    private func allConstraints(in view: UIView) -> [NSLayoutConstraint] {
        view.constraints + view.subviews.flatMap { self.allConstraints(in: $0) }
    }

    private func renderedText(in root: UIView) -> [String] {
        descendants(of: UILabel.self, in: root).compactMap {
            $0.attributedText?.string ?? $0.text
        }
    }

    private func descendants<View: UIView>(of type: View.Type, in root: UIView) -> [View] {
        var result: [View] = []
        if let view = root as? View { result.append(view) }
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }
}

@MainActor
final class ThemeEditorUIKitTests: XCTestCase {
    func testEditorPreservesDraftLayoutCopyAndSaveValidation() {
        let theme = TerminalTheme.tally.asCustom(named: "Tally Custom")
        let controller = ThemeEditorViewController(theme: theme, onSave: { _ in })
        let navigation = UINavigationController(rootViewController: controller)
        navigation.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.title, "Tally Custom")
        XCTAssertEqual(controller.navigationItem.largeTitleDisplayMode, .never)
        XCTAssertEqual(controller.saveItem.title, "Save")
        XCTAssertEqual(controller.saveItem.style, .plain)
        XCTAssertNil(controller.saveItem.customView)
        XCTAssertEqual(controller.saveItem.accessibilityLabel, "Save theme")
        XCTAssertTrue(controller.saveItem.isEnabled)
        XCTAssertEqual(controller.colorRows.count, 19)
        XCTAssertEqual(controller.colorRows.map(\.label), [
            "Background", "Text", "Cursor",
        ] + TerminalTheme.ansiNames)
        XCTAssertEqual(controller.preview.theme, theme)

        let rendered = renderedText(in: controller.view)
        XCTAssertTrue(rendered.contains("LIVE PREVIEW"))
        XCTAssertTrue(rendered.contains("THEME IDENTITY"))
        XCTAssertTrue(rendered.contains("SURFACE"))
        XCTAssertTrue(rendered.contains("ANSI · NORMAL"))
        XCTAssertTrue(rendered.contains("ANSI · BRIGHT"))
        XCTAssertTrue(rendered.contains(theme.background.hexString))

        controller.nameField.text = "   "
        controller.nameField.sendActions(for: .editingChanged)
        XCTAssertFalse(controller.saveItem.isEnabled)
        XCTAssertEqual(controller.title, "   ")
        XCTAssertEqual(controller.preview.theme.name, "   ")

        controller.appAppearance = .light
        XCTAssertEqual(controller.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(navigation.overrideUserInterfaceStyle, .light)
    }

    func testColorWellMutatesDraftAndResetRestoresInitialColor() throws {
        let theme = TerminalTheme.nord.asCustom(named: "Nord Custom")
        let controller = ThemeEditorViewController(theme: theme, onSave: { _ in })
        controller.loadViewIfNeeded()
        let background = try XCTUnwrap(controller.colorRows.first)
        let replacement = ThemeColor(0x123456)

        XCTAssertEqual(background.resetButton.buttonType, .custom)
        XCTAssertNil(background.resetButton.configuration)
        XCTAssertEqual(background.resetButton.backgroundColor, .clear)
        let resetBadge = try XCTUnwrap(descendants(
            of: SettingsBadgeView.self,
            in: background.resetButton
        ).first)
        XCTAssertEqual(
            resetBadge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize),
            CGSize(
                width: 18 + (10 * Theme.typeScale),
                height: 10 + (10 * Theme.typeScale)
            )
        )

        background.colorWell.selectedColor = UIColor(replacement)
        background.colorWell.sendActions(for: .valueChanged)
        XCTAssertEqual(controller.draft.background, replacement)
        XCTAssertEqual(controller.preview.theme.background, replacement)
        XCTAssertTrue(background.resetButton.isEnabled)

        background.resetButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.draft.background, theme.background)
        XCTAssertEqual(controller.preview.theme.background, theme.background)
        XCTAssertFalse(background.resetButton.isEnabled)
    }

    func testSaveCommitsExactDraftAndPopsNativeNavigation() throws {
        let theme = TerminalTheme.tally.asCustom(named: "Working")
        var saved: TerminalTheme?
        let controller = ThemeEditorViewController(theme: theme) { saved = $0 }
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()

        controller.nameField.text = "Amber Lab"
        controller.nameField.sendActions(for: .editingChanged)
        let cursor = try XCTUnwrap(controller.colorRows.first { $0.label == "Cursor" })
        cursor.colorWell.selectedColor = UIColor(ThemeColor(0xFFEEDD))
        cursor.colorWell.sendActions(for: .valueChanged)
        send(controller.saveItem)

        XCTAssertEqual(saved?.id, theme.id)
        XCTAssertEqual(saved?.name, "Amber Lab")
        XCTAssertEqual(saved?.cursor, ThemeColor(0xFFEEDD))
        XCTAssertTrue(navigation.topViewController === root)
    }

    func testBackNavigationDoesNotCommitDraft() {
        let theme = TerminalTheme.tally.asCustom(named: "Original")
        var saveCount = 0
        let controller = ThemeEditorViewController(theme: theme) { _ in saveCount += 1 }
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()

        controller.nameField.text = "Discarded"
        controller.nameField.sendActions(for: .editingChanged)
        navigation.popViewController(animated: false)
        XCTAssertEqual(saveCount, 0)
    }

    func testEditsPreviewLiveAndBackClearsWhileSaveKeeps() throws {
        let theme = TerminalTheme.tally.asCustom(named: "Live")
        var previews: [TerminalTheme?] = []
        var saved = 0
        let controller = ThemeEditorViewController(theme: theme) { _ in saved += 1 }
        controller.onPreview = { previews.append($0) }
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        // Appearance callbacks (Back's viewDidDisappear) only run for a
        // scene-attached window.
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 900)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        navigation.pushViewController(controller, animated: false)
        controller.loadViewIfNeeded()
        navigation.view.layoutIfNeeded()
        XCTAssertTrue(previews.isEmpty, "an untouched draft previews nothing")

        let cursor = try XCTUnwrap(controller.colorRows.first { $0.label == "Cursor" })
        cursor.colorWell.selectedColor = UIColor(ThemeColor(0xFFEEDD))
        cursor.colorWell.sendActions(for: .valueChanged)
        XCTAssertEqual(previews.last??.cursor, ThemeColor(0xFFEEDD))

        navigation.popViewController(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(previews.count, 2)
        XCTAssertNil(previews.last ?? nil, "Back ends the preview")
        XCTAssertEqual(saved, 0)

        // Save commits first, then ends the preview, so the store never
        // flashes the old selection between the two.
        previews = []
        var order: [String] = []
        let saver = ThemeEditorViewController(theme: theme) { _ in order.append("save") }
        saver.onPreview = { order.append($0 == nil ? "end" : "preview") }
        navigation.pushViewController(saver, animated: false)
        saver.loadViewIfNeeded()
        saver.nameField.text = "Kept"
        saver.nameField.sendActions(for: .editingChanged)
        send(saver.saveItem)
        XCTAssertEqual(order, ["preview", "save", "end"])
    }

    private func send(_ item: UIBarButtonItem?) {
        guard let item, let action = item.action else {
            return XCTFail("Missing bar-button action")
        }
        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
    }

    private func renderedText(in root: UIView) -> [String] {
        descendants(of: UILabel.self, in: root).compactMap {
            $0.attributedText?.string ?? $0.text
        }
    }

    private func descendants<View: UIView>(of type: View.Type, in root: UIView) -> [View] {
        var result: [View] = []
        if let view = root as? View { result.append(view) }
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }
}
