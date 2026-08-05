import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class SingleWindowShellUIKitTests: XCTestCase {
    func testCompactEmptyShellKeepsDeckLiveAndTerminalOffstage() throws {
        let harness = makeController()
        let controller = harness.controller
        controller.loadViewIfNeeded()
        controller.applyTestLayout(size: CGSize(width: 390, height: 844))

        let metrics = try XCTUnwrap(controller.currentLayoutMetrics)
        XCTAssertFalse(metrics.expanded)
        XCTAssertEqual(metrics.deckFrame, CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertEqual(metrics.terminalFrame, CGRect(x: 390, y: 0, width: 390, height: 844))
        XCTAssertEqual(metrics.deckAlpha, 1)
        XCTAssertEqual(metrics.terminalAlpha, 0)
        XCTAssertTrue(metrics.deckInteractive)
        XCTAssertFalse(metrics.terminalInteractive)
        XCTAssertEqual(harness.deckBuilds.value, 1)
        XCTAssertEqual(harness.terminalBuilds.value, 0)

        let empty = try XCTUnwrap(view(
            "singleWindowShell.emptyTerminal",
            in: controller.view
        ))
        XCTAssertTrue(renderedText(in: empty).contains("NO TERMINAL SELECTED"))
        XCTAssertTrue(renderedText(in: empty).contains(
            "Choose a session from the deck to attach it here."
        ))
    }

    func testOpeningCompactRouteSlidesTheNativeTerminalHostOverMountedDeck() throws {
        let harness = makeController()
        let controller = harness.controller
        controller.loadViewIfNeeded()
        controller.applyTestLayout(size: CGSize(width: 390, height: 844))
        let tab = terminal("main")

        controller.openTerminalRoute(TerminalWindowRoute(tab: tab))

        let metrics = try XCTUnwrap(controller.currentLayoutMetrics)
        XCTAssertTrue(controller.compactShowsTerminal)
        XCTAssertEqual(controller.shellState.terminalRoute.tabs, [tab])
        XCTAssertEqual(metrics.terminalFrame.origin.x, 0)
        XCTAssertEqual(metrics.terminalAlpha, 1)
        XCTAssertEqual(metrics.deckAlpha, 0)
        XCTAssertFalse(metrics.deckInteractive)
        XCTAssertTrue(metrics.terminalInteractive)
        XCTAssertEqual(harness.deckBuilds.value, 1)
        XCTAssertEqual(harness.terminalBuilds.value, 1)
        XCTAssertNotNil(view("singleWindowShell.stubTerminal", in: controller.view))

        controller.showDeck()
        XCTAssertFalse(controller.compactShowsTerminal)
        XCTAssertEqual(controller.currentLayoutMetrics?.terminalFrame.origin.x, 390)
        XCTAssertEqual(controller.currentLayoutMetrics?.deckAlpha, 1)
        // Navigation hides but never unmounts a live terminal.
        XCTAssertEqual(harness.terminalBuilds.value, 1)
        XCTAssertNotNil(view("singleWindowShell.stubTerminal", in: controller.view))
    }

    func testExpandedShellUsesRailAndRailToggleHandsItsSafeBandToTerminal() throws {
        let harness = makeController(initialRoute: TerminalWindowRoute(
            tab: terminal("main")
        ))
        let controller = harness.controller
        controller.loadViewIfNeeded()
        controller.applyTestLayout(
            size: CGSize(width: 1_024, height: 768),
            safeArea: UIEdgeInsets(top: 24, left: 20, bottom: 18, right: 16),
            verticalSizeClass: .regular
        )

        var metrics = try XCTUnwrap(controller.currentLayoutMetrics)
        XCTAssertTrue(metrics.expanded)
        XCTAssertEqual(metrics.deckFrame, CGRect(x: 0, y: 24, width: 336, height: 744))
        XCTAssertEqual(metrics.terminalFrame, CGRect(x: 336, y: 24, width: 688, height: 726))
        XCTAssertEqual(metrics.dividerFrame.origin.x, 335)
        XCTAssertEqual(metrics.deckSafeArea.left, 20)
        XCTAssertEqual(metrics.terminalSafeArea.left, 0)
        XCTAssertEqual(metrics.terminalSafeArea.right, 16)
        XCTAssertEqual(metrics.terminalAvailableWidth, 672)
        XCTAssertEqual(controller.shellState.presentation.deckControlLabel, "◧ HIDE")
        XCTAssertTrue(metrics.deckInteractive)
        XCTAssertTrue(metrics.terminalInteractive)

        controller.showDeck()
        metrics = try XCTUnwrap(controller.currentLayoutMetrics)
        XCTAssertFalse(controller.deckRailVisible)
        XCTAssertEqual(metrics.deckFrame.width, 0)
        XCTAssertEqual(metrics.terminalFrame, CGRect(x: 0, y: 24, width: 1_024, height: 726))
        XCTAssertEqual(metrics.terminalSafeArea.left, 20)
        XCTAssertEqual(metrics.terminalAvailableWidth, 988)
        XCTAssertEqual(controller.shellState.presentation.deckControlLabel, "◧ DECK")
        XCTAssertFalse(metrics.deckInteractive)
        XCTAssertTrue(view("singleWindowShell.divider", in: controller.view)?.isHidden == true)
    }

    func testSafeAreaMathMatchesCompactLandscapeAndBottomRailOwnership() {
        let regular = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 600, height: 500),
            safeArea: UIEdgeInsets(top: 12, left: 44, bottom: 21, right: 44),
            verticalSizeClass: .regular,
            deckRailVisible: true,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false
        )
        XCTAssertFalse(regular.expanded)
        XCTAssertEqual(regular.deckSafeArea.left, 44)
        XCTAssertEqual(regular.deckSafeArea.right, 44)
        XCTAssertEqual(regular.terminalSafeArea.left, 44)
        XCTAssertEqual(regular.terminalSafeArea.right, 44)
        XCTAssertEqual(regular.terminalAvailableWidth, 512)
        XCTAssertEqual(regular.terminalFrame.height, 467)
        XCTAssertFalse(regular.railOwnsBottomSafeArea)

        let compactHeight = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 600, height: 500),
            safeArea: UIEdgeInsets(top: 12, left: 44, bottom: 21, right: 44),
            verticalSizeClass: .compact,
            deckRailVisible: true,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 0,
            compactBackSwipeActive: false
        )
        XCTAssertEqual(compactHeight.terminalFrame.height, 488)
        XCTAssertTrue(compactHeight.railOwnsBottomSafeArea)
    }

    func testTerminalBottomBackfillDisappearsWhenRailOwnsSafeArea() throws {
        let harness = makeController(initialRoute: TerminalWindowRoute(
            tab: terminal("main")
        ))
        let controller = harness.controller
        controller.loadViewIfNeeded()
        controller.applyTestLayout(
            size: CGSize(width: 844, height: 390),
            safeArea: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59),
            verticalSizeClass: .compact
        )

        let backfill = try XCTUnwrap(view(
            "singleWindowShell.terminalBottomBackfill",
            in: controller.view
        ))
        XCTAssertEqual(backfill.frame.height, 0)
        XCTAssertTrue(backfill.isHidden)
    }

    func testIncomingRoutesMergeDeduplicateAndActivateIncomingSelection() {
        let first = terminal("first")
        let second = terminal("second")
        let third = terminal("third")
        let harness = makeController(initialRoute: TerminalWindowRoute(tab: first))
        let controller = harness.controller
        controller.loadViewIfNeeded()
        controller.applyTestLayout(size: CGSize(width: 390, height: 844))

        controller.openTerminalRoute(TerminalWindowRoute(
            tabs: [first, second, third],
            activeTabID: third.id
        ))

        XCTAssertEqual(controller.shellState.terminalRoute.tabs, [first, second, third])
        XCTAssertEqual(controller.shellState.terminalRoute.activeTabID, third.id)
        XCTAssertEqual(harness.terminalBuilds.value, 1)
    }

    func testInteractiveBackSwipeRevealsLiveDeckThenVelocityCommitsNavigation() throws {
        let harness = makeController(initialRoute: TerminalWindowRoute(
            tab: terminal("main")
        ))
        let controller = harness.controller
        controller.loadViewIfNeeded()
        controller.applyTestLayout(size: CGSize(width: 390, height: 844))

        // The pure metrics seam pins interactive travel even on a runner with
        // Reduce Motion enabled globally.
        let interactive = SingleWindowShellNativeLayout.resolve(
            size: CGSize(width: 390, height: 844),
            safeArea: .zero,
            verticalSizeClass: .regular,
            deckRailVisible: true,
            compactShowsTerminal: true,
            compactBackSwipeOffset: 110,
            compactBackSwipeActive: true
        )
        XCTAssertEqual(interactive.terminalFrame.origin.x, 110)
        XCTAssertEqual(interactive.deckAlpha, 1)
        XCTAssertFalse(interactive.deckInteractive)

        controller.finishBackSwipe(
            translation: 70,
            velocity: 1_000,
            width: 390
        )
        XCTAssertFalse(controller.compactShowsTerminal)
        XCTAssertEqual(controller.currentLayoutMetrics?.terminalFrame.origin.x, 390)
        XCTAssertEqual(controller.currentLayoutMetrics?.deckAlpha, 1)
        XCTAssertEqual(harness.terminalBuilds.value, 1)
    }

    func testReduceMotionKeepsBackSwipeAsAStaticNavigationShortcut() {
        let harness = makeController(initialRoute: TerminalWindowRoute(
            tab: terminal("main")
        ))
        let controller = harness.controller
        controller.loadViewIfNeeded()
        controller.applyTestLayout(size: CGSize(width: 390, height: 844))
        controller.setReduceMotion(true)

        controller.updateBackSwipe(translation: 120, width: 390)
        XCTAssertEqual(controller.compactBackSwipeOffset, 0)
        XCTAssertFalse(controller.compactBackSwipeActive)

        controller.finishBackSwipe(
            translation: 80,
            velocity: 600,
            width: 390
        )
        XCTAssertFalse(controller.compactShowsTerminal)
        XCTAssertEqual(controller.currentLayoutMetrics?.terminalFrame.origin.x, 390)
        XCTAssertEqual(harness.terminalBuilds.value, 1)
    }

    func testTabsEmptiedReplacesTerminalHostWithNativeEmptyState() {
        let harness = makeController(initialRoute: TerminalWindowRoute(
            tab: terminal("main")
        ))
        let controller = harness.controller
        controller.loadViewIfNeeded()
        controller.applyTestLayout(size: CGSize(width: 1_024, height: 768))
        XCTAssertEqual(harness.terminalBuilds.value, 1)

        controller.shellState.terminalRoute = TerminalWindowRoute(tabs: [])
        controller.terminalTabsEmptied()

        XCTAssertFalse(controller.compactShowsTerminal)
        XCTAssertTrue(controller.deckRailVisible)
        XCTAssertNil(view("singleWindowShell.stubTerminal", in: controller.view))
        XCTAssertNotNil(view("singleWindowShell.emptyTerminal", in: controller.view))
        // Expanded mode keeps the native empty terminal stage visible beside
        // the restored deck rail.
        XCTAssertEqual(controller.currentLayoutMetrics?.terminalAlpha, 1)
    }

    func testNativeTerminalConfigurationReceivesExactShellPresentation() {
        let state = SingleWindowShellState(
            terminalRoute: TerminalWindowRoute(tab: terminal("main")),
            sceneIsActive: true,
            reduceMotion: false
        )
        state.presentation = SingleWindowShellPresentation(
            expanded: true,
            deckPresentation: .shellRail,
            deckSafeArea: UIEdgeInsets(top: 0, left: 18, bottom: 12, right: 0),
            terminalAvailableWidth: 704,
            terminalSafeArea: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 16),
            railOwnsBottomSafeArea: true,
            deckControlLabel: "◧ HIDE",
            terminalFocusAllowed: true
        )
        let configuration = SingleWindowShellViewController
            .nativeTerminalShellConfiguration(
                state: state,
                actions: SingleWindowShellActions()
            )

        XCTAssertEqual(configuration.deckControlLabel, "◧ HIDE")
        XCTAssertEqual(configuration.availableWidth, 704)
        XCTAssertEqual(
            configuration.contentSafeArea,
            UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 16)
        )
        XCTAssertTrue(configuration.railOwnsBottomSafeArea)
        XCTAssertTrue(configuration.terminalFocusAllowed)
    }

    func testNativeSceneAndMotionUpdatesReachMountedDeckWithoutSwiftUIPhase() {
        let recorder = DeckStateRecorder()
        let controller = SingleWindowShellViewController(
            workspace: TerminalWorkspace(),
            sceneIsActive: true,
            reduceMotion: false,
            deckFactory: { _, _ in
                StubChildController(identifier: "singleWindowShell.stubDeck")
            },
            deckUpdater: { _, state, _ in
                recorder.values.append((state.sceneIsActive, state.reduceMotion))
            },
            terminalFactory: { _, _ in
                StubChildController(identifier: "singleWindowShell.stubTerminal")
            }
        )
        controller.loadViewIfNeeded()
        controller.applyTestLayout(size: CGSize(width: 390, height: 844))

        XCTAssertEqual(recorder.values.last?.0, true)
        XCTAssertEqual(recorder.values.last?.1, false)

        controller.setSceneActive(false)
        XCTAssertEqual(recorder.values.last?.0, false)

        controller.setReduceMotion(true)
        XCTAssertEqual(recorder.values.last?.1, true)
    }

    func testRouteCallbackReportsMutationsForSceneRestorationWithoutDuplicates() {
        let recorder = RouteRecorder()
        let controller = SingleWindowShellViewController(
            workspace: TerminalWorkspace(),
            deckFactory: { _, _ in
                StubChildController(identifier: "singleWindowShell.stubDeck")
            },
            terminalFactory: { _, _ in
                StubChildController(identifier: "singleWindowShell.stubTerminal")
            },
            routeChanged: { recorder.routes.append($0) }
        )
        controller.loadViewIfNeeded()
        let route = TerminalWindowRoute(tab: terminal("main"))

        controller.openTerminalRoute(route)
        XCTAssertEqual(recorder.routes, [controller.currentRoute])

        controller.replaceTerminalRoute(controller.currentRoute)
        XCTAssertEqual(recorder.routes.count, 1)
    }

    private func makeController(
        initialRoute: TerminalWindowRoute = TerminalWindowRoute(tabs: [])
    ) -> (
        controller: SingleWindowShellViewController,
        deckBuilds: Counter,
        terminalBuilds: Counter
    ) {
        let deckBuilds = Counter()
        let terminalBuilds = Counter()
        let controller = SingleWindowShellViewController(
            workspace: TerminalWorkspace(),
            initialRoute: initialRoute,
            deckFactory: { _, _ in
                deckBuilds.value += 1
                return StubChildController(identifier: "singleWindowShell.stubDeck")
            },
            terminalFactory: { _, _ in
                terminalBuilds.value += 1
                return StubChildController(identifier: "singleWindowShell.stubTerminal")
            }
        )
        return (controller, deckBuilds, terminalBuilds)
    }

    private func terminal(_ name: String) -> TerminalRoute {
        TerminalRoute(hostID: UUID(), mode: .attach(sessionName: name))
    }

    private func view(_ identifier: String, in root: UIView) -> UIView? {
        descendants(of: UIView.self, in: root).first {
            $0.accessibilityIdentifier == identifier
        }
    }

    private func renderedText(in root: UIView) -> [String] {
        descendants(of: UILabel.self, in: root).compactMap {
            $0.text ?? $0.attributedText?.string
        }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }
}

@MainActor
private final class StubChildController: UIViewController {
    private let identifier: String

    init(identifier: String) {
        self.identifier = identifier
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let view = UIView()
        view.accessibilityIdentifier = identifier
        view.backgroundColor = UIKitChassis.chassis
        self.view = view
    }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
private final class DeckStateRecorder {
    var values: [(Bool, Bool)] = []
}

@MainActor
private final class RouteRecorder {
    var routes: [TerminalWindowRoute] = []
}
