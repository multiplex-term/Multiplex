import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class ViewportPaneUIKitTests: XCTestCase {
    func testControllerOwnedWebViewReparentsWithoutBeingDestroyed() {
        let controller = makeViewportController()
        controller.stopLoading()
        let first = ViewportPaneViewController(controller: controller, close: {})
        first.loadViewIfNeeded()
        let firstContainer = controller.webView.superview
        XCTAssertNotNil(firstContainer)

        let second = ViewportPaneViewController(controller: controller, close: {})
        second.loadViewIfNeeded()
        XCTAssertNotNil(controller.webView.superview)
        XCTAssertFalse(controller.webView.superview === firstContainer)

        first.prepareForRemoval()
        XCTAssertNotNil(
            controller.webView.superview,
            "Dismantling an old host must not detach the newly adopted live page"
        )
        second.prepareForRemoval()
        controller.shutdown()
    }

    func testObservedTelemetryUpdatesRailFailureAndExactActions() {
        var closeCount = 0
        let controller = makeViewportController()
        controller.stopLoading()
        let pane = ViewportPaneViewController(
            controller: controller,
            contentSafeArea: UIEdgeInsets(top: 0, left: 6, bottom: 9, right: 8),
            close: { closeCount += 1 }
        )
        pane.loadViewIfNeeded()
        var state = ViewportPaneObservedState(controller: controller)
        state.displayURL = URL(string: "https://docs.example:8443/guide?q=tmux")!
        state.railTag = "NET"
        state.isLoading = true
        state.progress = 0.4
        state.canGoBack = true
        state.failure = "The Internet connection appears to be offline."
        state.currentReach = .lan
        state.hostName = "devbox"
        pane.applyObservedState(state)

        XCTAssertEqual(pane.backChip.alpha, 1)
        XCTAssertTrue(pane.backChip.isUserInteractionEnabled)
        XCTAssertEqual(pane.reloadChip.accessibilityLabel, "Stop loading")
        XCTAssertEqual(
            pane.urlButton.attributedTitle(for: .normal)?.string,
            "docs.example:8443/guide?q=tmux"
        )
        XCTAssertEqual(pane.urlButton.accessibilityHint, "Edits the address")
        XCTAssertEqual(pane.reachBadge.accessibilityLabel, "Reach: NET")
        XCTAssertEqual(pane.urlButton.menu?.children.count, 2)
        XCTAssertNotNil(pane.failureOverlay)
        XCTAssertEqual(
            pane.failureOverlay?.retryChip.accessibilityLabel,
            "Retry"
        )
        XCTAssertTrue(pane.closeChip.accessibilityActivate())
        XCTAssertEqual(closeCount, 1)

        let alert = pane.makeClearBrowsingDataAlert()
        XCTAssertEqual(alert.title, "Clear Browsing Data")
        XCTAssertEqual(alert.message, ViewportPaneViewController.clearBrowsingMessage)
        XCTAssertEqual(alert.actions.map(\.title), ["Clear", "Cancel"])
        XCTAssertEqual(alert.actions.first?.style, .destructive)
        pane.prepareForRemoval()
        controller.shutdown()
    }

    func testObservedTelemetryPreservesAddressMenuIdentity() throws {
        let controller = makeViewportController()
        controller.stopLoading()
        let pane = ViewportPaneViewController(controller: controller, close: {})
        pane.loadViewIfNeeded()
        defer {
            pane.prepareForRemoval()
            controller.shutdown()
        }
        let menu = try XCTUnwrap(pane.urlButton.menu)
        XCTAssertEqual(menu.children.map(\.title), ["Copy Address", "Clear Browsing Data…"])

        var state = ViewportPaneObservedState(controller: controller)
        state.displayURL = URL(string: "https://docs.example/guide")!
        state.isLoading = true
        state.progress = 0.25
        pane.applyObservedState(state)

        state.progress = 0.75
        state.isLoading = false
        pane.applyObservedState(state)

        XCTAssertTrue(pane.urlButton.menu === menu)
        XCTAssertEqual(
            pane.urlButton.attributedTitle(for: .normal)?.string,
            "docs.example/guide"
        )
    }

    func testAddressEditorKeepsKeyboardPolicyValidationAndActions() {
        var submitCount = 0
        var cancelCount = 0
        let editor = ViewportAddressEditorView(
            text: "devbox:5173",
            submit: { submitCount += 1 },
            cancel: { cancelCount += 1 }
        )

        XCTAssertEqual(editor.textField.text, "devbox:5173")
        XCTAssertEqual(editor.textField.keyboardType, .URL)
        XCTAssertEqual(editor.textField.returnKeyType, .go)
        XCTAssertEqual(editor.textField.autocapitalizationType, .none)
        XCTAssertEqual(editor.textField.autocorrectionType, .no)
        XCTAssertEqual(editor.textField.clearButtonMode, .never)
        XCTAssertTrue(editor.rejectedLabel.isHidden)
        editor.setRejected(true)
        XCTAssertFalse(editor.rejectedLabel.isHidden)
        XCTAssertEqual(editor.rejectedLabel.accessibilityLabel, "WEB ADDRESSES ONLY")
        XCTAssertTrue(editor.goChip.accessibilityActivate())
        XCTAssertTrue(editor.cancelChip.accessibilityActivate())
        XCTAssertFalse(editor.textFieldShouldReturn(editor.textField))
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(cancelCount, 1)
    }

    func testInteractiveLinkDismissClearsThePendingURL() throws {
        let controller = makeViewportController()
        controller.stopLoading()
        controller.externalLink = try XCTUnwrap(
            TerminalLink.resolve("mailto:dev@example.com")
        )
        let pane = ViewportPaneViewController(controller: controller, close: {})
        pane.loadViewIfNeeded()
        defer {
            pane.prepareForRemoval()
            controller.shutdown()
        }

        let presentation = UIPresentationController(
            presentedViewController: UIViewController(),
            presenting: nil
        )
        pane.presentationControllerDidDismiss(presentation)

        XCTAssertNil(controller.externalLink)
    }

    func testFailurePanelRoutesRetryAndSystemWithReachSpecificHint() {
        var retryCount = 0
        var systemCount = 0
        let failure = ViewportFailureOverlayView(
            message: "Connection refused",
            hint: ViewportPaneViewController.reachHint(.remoteLoopback, hostName: "devbox"),
            retry: { retryCount += 1 },
            openSystem: { systemCount += 1 }
        )
        failure.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        failure.layoutIfNeeded()

        XCTAssertTrue(failure.retryChip.accessibilityActivate())
        XCTAssertTrue(failure.systemChip.accessibilityActivate())
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(systemCount, 1)
        XCTAssertNil(ViewportPaneViewController.reachHint(.internet, hostName: "devbox"))
        XCTAssertEqual(
            ViewportPaneViewController.reachHint(.lan, hostName: "devbox"),
            "This address lives on devbox's network — the device must share it to load the page."
        )
    }

    func testVisionSwitchboardMovesPageAndWindowActionsIntoThreeSlabs() throws {
        let sourceID = UUID()
        var deckCount = 0
        var backCount = 0
        var reloadCount = 0
        var systemCount = 0
        var merged: [UUID] = []
        var closeCount = 0
        let viewport = ViewportOrnamentConfiguration(
            key: .init(
                displayURL: URL(string: "https://docs.example:8443/guide?q=tmux")!,
                railTag: "VIA DEVBOX",
                isLoading: true,
                progress: 0.4,
                canGoBack: false
            ),
            goBack: { backCount += 1 },
            reloadOrStop: { reloadCount += 1 },
            editAddress: {},
            copyAddress: {},
            clearBrowsingData: {},
            openInSystemBrowser: { systemCount += 1 }
        )
        let configuration = ViewportUMDConfiguration(
            title: "⌗ 8443 · devbox",
            mergeSources: [window("agent · devbox", id: sourceID)],
            showDeck: { deckCount += 1 },
            merge: { merged.append($0) },
            close: { closeCount += 1 },
            style: .regular,
            deckControlLabel: "DECK",
            contentSafeArea: .zero,
            closeAccessibilityLabel: "Close viewport",
            textScale: nil,
            viewport: viewport
        )
        let switchboard = ViewportSwitchboardViewController(configuration: configuration)

        XCTAssertEqual(switchboard.slabControllers.count, 3)
        XCTAssertEqual(switchboard.addressButton.accessibilityIdentifier, "viewport.address")
        XCTAssertEqual(
            switchboard.addressButton.attributedTitle(for: .normal)?.string,
            "docs.example:8443/guide?q=tmux"
        )
        XCTAssertEqual(switchboard.reachBadge.accessibilityLabel, "Reach: VIA DEVBOX")
        XCTAssertFalse(switchboard.backChip.isUserInteractionEnabled)
        XCTAssertEqual(switchboard.reloadChip.accessibilityLabel, "Stop loading")
        XCTAssertEqual(switchboard.mergeButton?.menu?.title, "Merge")
        XCTAssertEqual(switchboard.mergeButton?.menu?.children.count, 1)
        XCTAssertEqual(switchboard.closeChip.accessibilityLabel, "Close viewport")
        XCTAssertNil(
            switchboard.navigateSlab.view.descendant(of: UIKitChassisLabel.self),
            "the retired viewport UMD title must not appear in Switchboard"
        )

        XCTAssertTrue(switchboard.deckChip.accessibilityActivate())
        XCTAssertTrue(switchboard.reloadChip.accessibilityActivate())
        XCTAssertTrue(switchboard.systemChip.accessibilityActivate())
        let merge = try XCTUnwrap(switchboard.mergeButton?.menu?.children.first as? UIAction)
        merge.performWithSender(nil, target: nil)
        XCTAssertTrue(switchboard.closeChip.accessibilityActivate())
        XCTAssertEqual(deckCount, 1)
        XCTAssertEqual(backCount, 0)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(systemCount, 1)
        XCTAssertEqual(merged, [sourceID])
        XCTAssertEqual(closeCount, 1)
    }

    func testOrnamentProfileReclaimsTheViewportRailHeight() {
        let controller = makeViewportController()
        controller.stopLoading()
        let pane = ViewportPaneViewController(
            controller: controller,
            showsInWindowRail: false,
            close: {}
        )
        pane.loadViewIfNeeded()
        defer {
            pane.prepareForRemoval()
            controller.shutdown()
        }

        XCTAssertNotNil(pane.ornamentConfiguration)
        XCTAssertNil(pane.view.viewWithAccessibilityIdentifier("viewport.back"))
        XCTAssertNil(pane.view.viewWithAccessibilityIdentifier("viewport.close"))
    }

    func testNativeUMDPreservesRegularMenuAndShellSafeAreaGeometry() {
        let sourceID = UUID()
        let source = TerminalWorkspace.WindowEntry(
            id: sourceID,
            tabs: [],
            label: "agent · devbox",
            reveal: { _ in },
            surrender: { [] },
            adopt: { _ in }
        )
        var deckCount = 0
        var merged: [UUID] = []
        var closeCount = 0
        var configuration = ViewportUMDConfiguration(
            title: "⌗ 5173 · devbox",
            mergeSources: [source],
            showDeck: { deckCount += 1 },
            merge: { merged.append($0) },
            close: { closeCount += 1 },
            style: .regular,
            deckControlLabel: "DECK",
            contentSafeArea: .zero,
            closeAccessibilityLabel: "Close viewport"
        )
        let controller = ViewportUMDViewController(configuration: configuration)
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.deckChip?.accessibilityLabel, "Deck")
        XCTAssertEqual(controller.titleLabel?.accessibilityLabel, "⌗ 5173 · devbox")
        XCTAssertEqual(controller.mergeButton?.menu?.children.count, 1)
        XCTAssertEqual(controller.mergeButton?.buttonType, .custom)
        XCTAssertNil(controller.mergeButton?.configuration)
        XCTAssertLessThan(
            controller.mergeButton?.intrinsicContentSize.height ?? .infinity,
            34
        )
        XCTAssertEqual(
            controller.mergeButton?.accessibilityLabel,
            "Merge another window into this one"
        )
        XCTAssertEqual(controller.closeChip?.accessibilityLabel, "Close viewport")
        XCTAssertEqual(controller.rootView.contentInsets, UIEdgeInsets(top: 11, left: 18, bottom: 11, right: 18))
        controller.perform(.showDeck)
        controller.perform(.merge(sourceID))
        controller.perform(.close)
        XCTAssertEqual(deckCount, 1)
        XCTAssertEqual(merged, [sourceID])
        XCTAssertEqual(closeCount, 1)

        configuration.style = .shell
        configuration.mergeSources = []
        configuration.deckControlLabel = "WALL"
        configuration.contentSafeArea = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 14)
        configuration.closeAccessibilityLabel = "Close file viewer"
        controller.update(configuration: configuration)
        XCTAssertNil(controller.mergeButton)
        XCTAssertEqual(controller.deckChip?.accessibilityLabel, "Wall")
        XCTAssertEqual(controller.closeChip?.accessibilityLabel, "Close file viewer")
        XCTAssertEqual(
            controller.rootView.contentInsets,
            UIEdgeInsets(top: 8, left: 32, bottom: 8, right: 24)
        )
        XCTAssertGreaterThan(controller.fittingContentSize(for: 500).height, 0)
    }

    func testNativeUMDEquivalentUpdatePreservesControlsAndMenuIdentity() throws {
        let sourceID = UUID()
        var originalDeckCount = 0
        var originalMergeCount = 0
        var originalCloseCount = 0
        var configuration = ViewportUMDConfiguration(
            title: "⌗ 5173 · devbox",
            mergeSources: [window("agent · devbox", id: sourceID)],
            showDeck: { originalDeckCount += 1 },
            merge: { _ in originalMergeCount += 1 },
            close: { originalCloseCount += 1 },
            style: .regular,
            deckControlLabel: "DECK",
            contentSafeArea: .zero,
            closeAccessibilityLabel: "Close viewport"
        )
        let controller = ViewportUMDViewController(configuration: configuration)
        controller.loadViewIfNeeded()

        let deckChip = try XCTUnwrap(controller.deckChip)
        let titleLabel = try XCTUnwrap(controller.titleLabel)
        let mergeButton = try XCTUnwrap(controller.mergeButton)
        let mergeMenu = try XCTUnwrap(mergeButton.menu)
        let closeChip = try XCTUnwrap(controller.closeChip)

        var updatedDeckCount = 0
        var updatedMergeIDs: [UUID] = []
        var updatedCloseCount = 0
        configuration.mergeSources = [window("agent · devbox", id: sourceID)]
        configuration.showDeck = { updatedDeckCount += 1 }
        configuration.merge = { updatedMergeIDs.append($0) }
        configuration.close = { updatedCloseCount += 1 }
        configuration.deckControlLabel = "IGNORED IN REGULAR STYLE"
        configuration.contentSafeArea = UIEdgeInsets(top: 3, left: 4, bottom: 5, right: 6)
        controller.update(configuration: configuration)

        XCTAssertTrue(controller.deckChip === deckChip)
        XCTAssertTrue(controller.titleLabel === titleLabel)
        XCTAssertTrue(controller.mergeButton === mergeButton)
        XCTAssertTrue(controller.mergeButton?.menu === mergeMenu)
        XCTAssertTrue(controller.closeChip === closeChip)
        XCTAssertTrue(deckChip.accessibilityActivate())
        controller.perform(.merge(sourceID))
        XCTAssertTrue(closeChip.accessibilityActivate())
        XCTAssertEqual(originalDeckCount, 0)
        XCTAssertEqual(originalMergeCount, 0)
        XCTAssertEqual(originalCloseCount, 0)
        XCTAssertEqual(updatedDeckCount, 1)
        XCTAssertEqual(updatedMergeIDs, [sourceID])
        XCTAssertEqual(updatedCloseCount, 1)
    }

    func testNativeUMDRebuildsMergeMenuWhenItsSemanticItemsChange() throws {
        let sourceID = UUID()
        var configuration = ViewportUMDConfiguration(
            title: "⌗ 5173 · devbox",
            mergeSources: [window("agent · devbox", id: sourceID)],
            showDeck: {},
            merge: { _ in },
            close: {},
            style: .regular,
            deckControlLabel: "DECK",
            contentSafeArea: .zero,
            closeAccessibilityLabel: "Close viewport"
        )
        let controller = ViewportUMDViewController(configuration: configuration)
        controller.loadViewIfNeeded()
        let originalButton = try XCTUnwrap(controller.mergeButton)
        let originalMenu = try XCTUnwrap(originalButton.menu)

        configuration.mergeSources = [
            window("renamed · devbox", id: sourceID),
            window("scratch · devbox"),
        ]
        controller.update(configuration: configuration)

        let updatedButton = try XCTUnwrap(controller.mergeButton)
        let updatedMenu = try XCTUnwrap(updatedButton.menu)
        XCTAssertFalse(updatedButton === originalButton)
        XCTAssertFalse(updatedMenu === originalMenu)
        XCTAssertEqual(
            updatedMenu.children.map(\.title),
            ["renamed · devbox", "scratch · devbox"]
        )
    }

    private func makeViewportController() -> ViewportController {
        ViewportController(
            tabID: UUID(),
            offer: ViewportOffer(
                url: URL(string: "about:blank")!,
                reach: .internet,
                viaHostName: nil
            ),
            host: Host(
                name: "devbox",
                hostname: "127.0.0.1",
                username: "tester"
            )
        )
    }

    private func window(
        _ label: String,
        id: UUID = UUID()
    ) -> TerminalWorkspace.WindowEntry {
        TerminalWorkspace.WindowEntry(
            id: id,
            tabs: [],
            label: label,
            reveal: { _ in },
            surrender: { [] },
            adopt: { _ in }
        )
    }
}

private extension UIView {
    func descendant<T: UIView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        return subviews.lazy.compactMap { $0.descendant(of: type) }.first
    }

    func viewWithAccessibilityIdentifier(_ identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        return subviews.lazy.compactMap {
            $0.viewWithAccessibilityIdentifier(identifier)
        }.first
    }
}
