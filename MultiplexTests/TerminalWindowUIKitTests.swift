import UIKit
import SwiftTerm
import XCTest
#if os(visionOS)
import SwiftUI
#endif
@testable import Multiplex

@MainActor
final class TerminalWindowUIKitTests: XCTestCase {
    func testSurfaceAppearanceRestoresOnlyTheExistingAppWideFocusOwner() {
        TerminalFocusArbiter.inputSuppressed = false
        let host = Host(
            name: "devbox",
            hostname: "127.0.0.1",
            username: "dev"
        )
        let first = TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main")),
            host: host
        )
        let second = TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "scratch")),
            host: host
        )
        let owner = TerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 14, weight: .regular)
        )
        let contender = TerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 14, weight: .regular)
        )
        first.bind(owner)
        second.bind(contender)

        TerminalFocusArbiter.claim(owner)
        TerminalWindowViewController.restoreFocusAfterSurfaceAppearance(
            second,
            allowed: true
        )
        XCTAssertTrue(TerminalFocusArbiter.current === owner)

        TerminalFocusArbiter.release(owner)
        TerminalWindowViewController.restoreFocusAfterSurfaceAppearance(
            second,
            allowed: true
        )
        XCTAssertTrue(
            TerminalFocusArbiter.current === contender,
            "An empty ownership is re-elected on restore: app-unlock clears the owner via "
                + "inputSuppressed and a closed focused window deallocates it, and neither "
                + "has another claim site"
        )
    }

    func testTerminalActivationRoutesFileURLsBeforeLinksAndOrdinaryPaths() {
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let controller = TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main")),
            host: host
        )

        XCTAssertTrue(controller.activateLink(
            "file:///tmp/My%20Folder/Release%20Notes.swift:42"
        ))
        XCTAssertNil(controller.pendingLink)
        XCTAssertEqual(controller.pendingPath?.path, "/tmp/My Folder/Release Notes.swift")
        XCTAssertEqual(controller.pendingPath?.line, 42)

        controller.dismissPendingPath()
        XCTAssertTrue(controller.activateLink("example.com/docs"))
        XCTAssertNil(controller.pendingPath)
        XCTAssertEqual(controller.pendingLink?.raw, "https://example.com/docs")

        controller.dismissPendingLink()
        XCTAssertTrue(controller.activateLink("file://fileserver/etc/hosts"))
        guard case .blockedScheme("file")? = controller.pendingLink?.kind else {
            return XCTFail("A non-local file URI must stay copy-only")
        }
        XCTAssertNil(controller.pendingPath)
    }

    func testAgentHelperReuseIsKeyedByHostNotOnlyAgentKind() {
        let firstHost = UUID()
        let secondHost = UUID()

        XCTAssertTrue(TerminalWindowViewController.canReuseAgentHelper(
            currentHostID: firstHost,
            nextHostID: firstHost
        ))
        XCTAssertFalse(TerminalWindowViewController.canReuseAgentHelper(
            currentHostID: firstHost,
            nextHostID: secondHost
        ))
        XCTAssertFalse(TerminalWindowViewController.canReuseAgentHelper(
            currentHostID: nil,
            nextHostID: secondHost
        ))
    }

    func testNativeWindowKeepsOnePaneControllerPerTabAndActivatesInPlace() throws {
        let first = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let second = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "scratch"))
        var changed: [TerminalWindowRoute] = []
        let fixture = makeFixture(
            route: TerminalWindowRoute(tabs: [first, second]),
            routeChanged: { changed.append($0) }
        )

        fixture.controller.loadViewIfNeeded()
        fixture.controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 620)
        fixture.controller.view.layoutIfNeeded()

        let initialPanes = fixture.controller.children.compactMap {
            $0 as? TerminalPaneViewController
        }
        XCTAssertEqual(initialPanes.count, 2)
        XCTAssertEqual(initialPanes.filter { !$0.view.isHidden }.count, 1)
        #if !os(visionOS)
        XCTAssertFalse(controllerTree(fixture.controller).contains {
            String(describing: type(of: $0)).contains("UIHostingController")
        })
        #endif

        fixture.controller.activate(second.id)

        let updatedPanes = fixture.controller.children.compactMap {
            $0 as? TerminalPaneViewController
        }
        XCTAssertEqual(Set(initialPanes.map(ObjectIdentifier.init)),
                       Set(updatedPanes.map(ObjectIdentifier.init)))
        XCTAssertEqual(fixture.controller.route.activeTabID, second.id)
        XCTAssertEqual(changed.last?.activeTabID, second.id)
        XCTAssertEqual(updatedPanes.filter { !$0.view.isHidden }.count, 1)
        XCTAssertEqual(fixture.workspace.windows.first?.tabs, [first, second])
    }

    func testTabStripPreservesOrderingAccessibilityAndClassicSplitAction() throws {
        let first = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let second = TerminalRoute(hostID: UUID(), mode: .shell)
        let fixture = makeFixture(route: TerminalWindowRoute(tabs: [first, second]))
        fixture.controller.loadViewIfNeeded()

        #if os(visionOS)
        let strip = fixture.controller.visionOrnamentTabStripForTesting
        #else
        let strip = try XCTUnwrap(descendant(
            of: TerminalTabStripView.self,
            in: fixture.controller.view
        ))
        #endif
        XCTAssertEqual(strip.accessibilityLabel, "2 tabs")
        XCTAssertEqual(strip.cells.map(\.itemID), [first.id, second.id])
        XCTAssertTrue(strip.cells[0].accessibilityTraits.contains(.selected))
        XCTAssertEqual(
            strip.cells[0].accessibilityCustomActions?.map(\.name),
            ["Move to New Window", "Close Tab"]
        )

        XCTAssertTrue(strip.cells[1].accessibilityActivate())
        XCTAssertEqual(fixture.controller.route.activeTabID, second.id)
    }

    func testShellWindowUsesNativeUMDAndSuppressesSplitAction() throws {
        let first = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let second = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "scratch"))
        let shell = TerminalWindowShellConfiguration(
            deckControlLabel: "DECK",
            availableWidth: 720,
            contentSafeArea: UIEdgeInsets(top: 4, left: 8, bottom: 12, right: 8),
            railOwnsBottomSafeArea: true,
            showDeck: {},
            openTerminalRoute: { _ in },
            revealTab: { _ in },
            tabsEmptied: {},
            terminalFocusAllowed: false
        )
        let fixture = makeFixture(
            route: TerminalWindowRoute(tabs: [first, second]),
            shell: shell
        )
        fixture.controller.loadViewIfNeeded()

        let strip = try XCTUnwrap(descendant(
            of: TerminalTabStripView.self,
            in: fixture.controller.view
        ))
        XCTAssertEqual(
            strip.cells[0].accessibilityCustomActions?.map(\.name),
            ["Close Tab"]
        )
        XCTAssertTrue(fixture.controller.children.contains { $0 is UMDBarViewController })
        XCTAssertFalse(controllerTree(fixture.controller).contains {
            String(describing: type(of: $0)).contains("UIHostingController")
        })
    }

    func testTabRailScrollerTracksPressesAtOnceAndSizesWithItsLayoutPass() throws {
        let first = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let second = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "scratch"))
        // The rail only exists on the shell stage: a classic visionOS window
        // hands its strip to the ornament instead.
        let shell = TerminalWindowShellConfiguration(
            deckControlLabel: "DECK",
            availableWidth: 420,
            showDeck: {},
            openTerminalRoute: { _ in },
            revealTab: { _ in },
            tabsEmptied: {},
            terminalFocusAllowed: false
        )
        let fixture = makeFixture(
            route: TerminalWindowRoute(tabs: [first, second]),
            shell: shell
        )
        fixture.controller.loadViewIfNeeded()
        fixture.controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 620)
        fixture.controller.view.setNeedsLayout()
        fixture.controller.view.layoutIfNeeded()

        let rail = try XCTUnwrap(
            view("terminalWindow.tabs", in: fixture.controller.view)
                as? TerminalTabScrollView
        )
        let strip = try XCTUnwrap(descendant(
            of: TerminalTabStripView.self,
            in: fixture.controller.view
        ))
        let cell = try XCTUnwrap(strip.cells.first)

        XCTAssertFalse(
            rail.delaysContentTouches,
            "A delayed content touch is the press a drifting finger loses"
        )
        XCTAssertTrue(
            rail.touchesShouldCancel(in: cell),
            "A real drag starting on a cell must still scroll the strip"
        )
        XCTAssertEqual(
            rail.contentSize.width,
            strip.frame.maxX + TerminalWindowUIKitRootView.tabRailHorizontalInset,
            accuracy: 0.5,
            "Strip frame and content size are one measurement per layout pass"
        )
        XCTAssertGreaterThanOrEqual(strip.frame.width, strip.fittingContentSize().width)
    }

    func testRestoredAuxiliaryWithoutLiveControllerIsStrippedBeforeRendering() {
        let terminal = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let orphan = TerminalRoute(
            hostID: terminal.hostID,
            mode: .viewport(urlString: "https://example.com:5173")
        )
        var changed: [TerminalWindowRoute] = []
        let fixture = makeFixture(
            route: TerminalWindowRoute(
                tabs: [orphan, terminal],
                activeTabID: orphan.id
            ),
            routeChanged: { changed.append($0) }
        )

        fixture.controller.loadViewIfNeeded()

        XCTAssertEqual(fixture.controller.route.tabs, [terminal])
        XCTAssertEqual(fixture.controller.route.activeTabID, terminal.id)
        XCTAssertEqual(changed.last?.tabs, [terminal])
        XCTAssertEqual(
            fixture.controller.children.compactMap { $0 as? TerminalPaneViewController }.count,
            1
        )
    }

    func testClosingLastTabUnregistersWindowAndClosesOwningScene() {
        let tab = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        var intents: [SceneWindowRouting.Intent] = []
        var changed: [TerminalWindowRoute] = []
        let fixture = makeFixture(
            route: TerminalWindowRoute(tab: tab),
            performSceneIntent: { intents.append($0) },
            routeChanged: { changed.append($0) }
        )
        fixture.controller.loadViewIfNeeded()
        XCTAssertEqual(fixture.workspace.windows.count, 1)

        fixture.controller.closeTab(tab.id)

        XCTAssertTrue(fixture.controller.route.tabs.isEmpty)
        XCTAssertEqual(changed.last?.tabs, [])
        XCTAssertTrue(fixture.workspace.windows.isEmpty)
        XCTAssertEqual(intents, [.closeCurrentScene])
    }

    func testSplittingTabMovesItWithoutClosingAndOpensASecondRoute() {
        let first = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let second = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "scratch"))
        var intents: [SceneWindowRouting.Intent] = []
        let fixture = makeFixture(
            route: TerminalWindowRoute(tabs: [first, second]),
            performSceneIntent: { intents.append($0) }
        )
        fixture.controller.loadViewIfNeeded()

        fixture.controller.splitTab(second.id)

        XCTAssertEqual(fixture.controller.route.tabs, [first])
        guard case .openTerminal(let splitRoute) = intents.last else {
            return XCTFail("Expected a new terminal window intent")
        }
        XCTAssertEqual(splitRoute.tabs, [second])
        XCTAssertEqual(splitRoute.activeTabID, second.id)
    }

    #if !os(visionOS)
    func testClassicLayoutReservesBottomSafeAreaWhileShellOwnsItsStageBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 950, height: 1_200)
        let safeArea = UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 0)

        XCTAssertEqual(
            TerminalWindowUIKitRootView.contentBounds(
                in: bounds,
                reservesBottomSafeArea: true,
                safeAreaInsets: safeArea
            ),
            CGRect(x: 0, y: 0, width: 950, height: 1_179),
            "A classic iPad key rail must stop above the home/resize strip"
        )
        XCTAssertEqual(
            TerminalWindowUIKitRootView.contentBounds(
                in: bounds,
                reservesBottomSafeArea: false,
                safeAreaInsets: safeArea
            ),
            bounds,
            "The outer shell has already decided whether its rail spends the strip"
        )
    }

    func testClassicAuxiliaryRailPaintsThroughProtectedBottomStrip() throws {
        let hostID = UUID()
        let fileViewer = TerminalRoute(
            hostID: hostID,
            mode: .fileViewer(path: "/workspace/README.md")
        )
        let viewport = TerminalRoute(
            hostID: hostID,
            mode: .viewport(urlString: "https://example.com:5173")
        )

        for tab in [fileViewer, viewport] {
            XCTAssertEqual(
                TerminalWindowBottomSafeAreaFill.resolve(
                    isClassic: true,
                    activeTab: tab,
                    hasActiveTerminalController: false
                ),
                .auxiliaryRail,
                "Both auxiliary panes end in the same legacy bezel rail"
            )
        }

        let root = TerminalWindowUIKitRootView(frame: .zero)
        let protectedStrip = CGRect(x: 0, y: 1_179, width: 950, height: 21)
        let interactiveBounds = TerminalWindowUIKitRootView.contentBounds(
            in: CGRect(x: 0, y: 0, width: 950, height: 1_200),
            reservesBottomSafeArea: true,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 0)
        )
        root.setBottomSafeAreaBackfill(
            frame: protectedStrip,
            fill: .auxiliaryRail
        )
        let backfill = try XCTUnwrap(view(
            "terminalWindow.bottomSafeAreaBackfill",
            in: root
        ))
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let actualColor = try XCTUnwrap(backfill.backgroundColor)
            .resolvedColor(with: dark)

        XCTAssertEqual(interactiveBounds.maxY, protectedStrip.minY)
        XCTAssertEqual(backfill.frame, protectedStrip)
        XCTAssertFalse(backfill.isUserInteractionEnabled)
        XCTAssertTrue(actualColor.isEqual(
            UIKitChassis.bezel.resolvedColor(with: dark)
        ))
        XCTAssertFalse(actualColor.isEqual(
            UIKitChassis.chassis.resolvedColor(with: dark)
        ))
    }

    func testClassicNavigationChipsOptOutOfNativeSharedBackgroundAndPadding() throws {
        let host = Host(
            name: "devbox",
            hostname: "127.0.0.1",
            port: 1,
            username: "dev"
        )
        let tab = TerminalRoute(
            hostID: host.id,
            mode: .attach(sessionName: "main")
        )
        let fixture = makeFixture(
            route: TerminalWindowRoute(tab: tab),
            hosts: [host]
        )
        defer {
            fixture.controller.prepareForRemoval()
            fixture.store.remove(host)
        }

        let navigation = UINavigationController(
            rootViewController: fixture.controller
        )
        navigation.setOverrideTraitCollection(
            UITraitCollection(horizontalSizeClass: .regular),
            forChild: fixture.controller
        )
        navigation.loadViewIfNeeded()
        fixture.controller.loadViewIfNeeded()
        fixture.controller.viewWillAppear(false)

        let items = [fixture.controller.navigationItem.leftBarButtonItem]
            .compactMap { $0 }
            + (fixture.controller.navigationItem.rightBarButtonItems ?? [])
        XCTAssertFalse(items.isEmpty)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(
                items.allSatisfy(\.hidesSharedBackground),
                "TALLY faces own their background; iPadOS must not wrap them in Glass"
            )
        }
        if #available(iOS 27.0, *) {
            XCTAssertTrue(
                items.allSatisfy(\.isPaddingRemoved),
                "System bar padding must not inflate the exact chip geometry"
            )
        }
        if #available(iOS 26.0, *) {
            let rightmost = try XCTUnwrap(
                fixture.controller.navigationItem.rightBarButtonItems?.first?.customView
                    as? TerminalNavigationTrailingInsetView
            )
            let contentSize = rightmost.contentView.intrinsicContentSize
            XCTAssertEqual(TerminalNavigationTrailingInsetView.trailingInset, 12)
            XCTAssertEqual(
                rightmost.intrinsicContentSize.width - contentSize.width,
                12,
                accuracy: 0.001,
                "Only the window-edge item restores the beta's 12-point breathing room"
            )
        }
    }

    func testClassicCompactOverflowTracksAttachmentAvailabilityWithoutChurn() throws {
        var host = Host(
            name: "devbox",
            hostname: "127.0.0.1",
            port: 1,
            username: "dev"
        )
        host.useMosh = false
        let tab = TerminalRoute(
            hostID: host.id,
            mode: .attach(sessionName: "main")
        )
        let fixture = makeFixture(
            route: TerminalWindowRoute(tab: tab),
            hosts: [host]
        )
        defer {
            fixture.controller.prepareForRemoval()
            fixture.store.remove(host)
        }

        let navigation = UINavigationController(
            rootViewController: fixture.controller
        )
        navigation.setOverrideTraitCollection(
            UITraitCollection(horizontalSizeClass: .compact),
            forChild: fixture.controller
        )
        navigation.loadViewIfNeeded()
        fixture.controller.loadViewIfNeeded()
        fixture.controller.viewWillAppear(false)

        XCTAssertEqual(
            fixture.controller.traitCollection.horizontalSizeClass,
            .compact
        )
        let rightmost = try XCTUnwrap(
            fixture.controller.navigationItem.rightBarButtonItems?.first?.customView
                as? TerminalNavigationTrailingInsetView
        )
        XCTAssertEqual(
            rightmost.intrinsicContentSize.width
                - rightmost.contentView.intrinsicContentSize.width,
            12,
            accuracy: 0.001
        )
        let overflow = try XCTUnwrap(navigationButton(
            accessibilityLabel: "Terminal actions",
            in: fixture.controller
        ))
        let menu = try XCTUnwrap(overflow.menu)
        let actions = menuActions(in: menu)
        XCTAssertTrue(menu.children.contains {
            ($0 as? UIMenu)?.title == "Send File…"
        })
        XCTAssertTrue(actions.contains { $0.title == "Camera…" })
        XCTAssertTrue(actions.contains { $0.title == "Photo Library…" })
        XCTAssertTrue(actions.contains { $0.title == "Files…" })
        XCTAssertTrue(
            actions.first { $0.title == "Files…" }?.attributes.contains(.disabled)
                == true,
            "A connecting terminal advertises upload sources but cannot invoke them"
        )

        fixture.controller.update(
            route: fixture.controller.route,
            shell: nil
        )
        fixture.controller.viewWillAppear(false)
        let retainedOverflow = try XCTUnwrap(navigationButton(
            accessibilityLabel: "Terminal actions",
            in: fixture.controller
        ))
        XCTAssertTrue(retainedOverflow === overflow)
        XCTAssertTrue(retainedOverflow.menu === menu)

        fixture.controller.renderCompactNavigationChromeForTesting(
            attachmentAvailability: FileAttachMenuAvailability(
                canOffer: true,
                isLive: true
            )
        )
        let liveOverflow = try XCTUnwrap(navigationButton(
            accessibilityLabel: "Terminal actions",
            in: fixture.controller
        ))
        let liveMenu = try XCTUnwrap(liveOverflow.menu)
        let liveFiles = try XCTUnwrap(
            menuActions(in: liveMenu).first { $0.title == "Files…" }
        )
        XCTAssertFalse(liveOverflow === overflow)
        XCTAssertFalse(liveMenu === menu)
        XCTAssertFalse(
            liveFiles.attributes.contains(.disabled),
            "The connecting-to-live transition must rebuild enabled upload actions"
        )

        fixture.controller.renderCompactNavigationChromeForTesting(
            attachmentAvailability: FileAttachMenuAvailability(
                canOffer: true,
                isLive: true
            )
        )
        let retainedLiveOverflow = try XCTUnwrap(navigationButton(
            accessibilityLabel: "Terminal actions",
            in: fixture.controller
        ))
        XCTAssertTrue(retainedLiveOverflow === liveOverflow)
        XCTAssertTrue(retainedLiveOverflow.menu === liveMenu)
    }
    #endif

    #if os(visionOS)
    func testVisionOrnamentPresentationPinsVisibilityWidthAndAnchorGuide() {
        let terminal = TerminalVisionOrnamentPresentation.resolve(
            tabCount: 2,
            isAuxiliary: false,
            hasUMD: true,
            hasHelper: false,
            windowWidth: 900
        )
        XCTAssertTrue(terminal.showsTopSourceLabels)
        XCTAssertEqual(terminal.bottom, .terminal(showsHelper: false))
        XCTAssertEqual(terminal.maximumConsoleWidth, 876)
        XCTAssertEqual(terminal.bottomCenterGuide, 24)

        let withHelper = TerminalVisionOrnamentPresentation.resolve(
            tabCount: 1,
            isAuxiliary: false,
            hasUMD: true,
            hasHelper: true,
            windowWidth: 600
        )
        XCTAssertFalse(withHelper.showsTopSourceLabels)
        XCTAssertEqual(withHelper.bottom, .terminal(showsHelper: true))
        XCTAssertEqual(withHelper.maximumConsoleWidth, 576)
        XCTAssertEqual(withHelper.bottomCenterGuide, 40)

        let auxiliary = TerminalVisionOrnamentPresentation.resolve(
            tabCount: 2,
            isAuxiliary: true,
            hasUMD: true,
            hasHelper: true,
            windowWidth: 12
        )
        XCTAssertEqual(auxiliary.bottom, .auxiliary)
        XCTAssertEqual(auxiliary.maximumConsoleWidth, 1)
        XCTAssertEqual(auxiliary.bottomCenterGuide, 24)

        let hidden = TerminalVisionOrnamentPresentation.resolve(
            tabCount: 2,
            isAuxiliary: false,
            hasUMD: false,
            hasHelper: true,
            windowWidth: 900
        )
        XCTAssertEqual(hidden.bottom, .hidden)
    }

    func testVisionConsoleMountsNativeCenterOnceAcrossFittingCandidates() async {
        let counter = VisionConsoleCenterMountCounter()
        let nativeCenter = UIViewController()
        nativeCenter.loadViewIfNeeded()
        nativeCenter.view.accessibilityIdentifier = "terminal.vision.centerProbe"
        let centerSize = CGSize(width: 260, height: 34)
        let cluster = TerminalKeyCluster(
            controller: nil,
            centerSize: centerSize
        ) {
            VisionConsoleCenterProbe(
                counter: counter,
                nativeCenter: nativeCenter,
                fittingSize: centerSize
            )
        }
        let hosting = UIHostingController(rootView: cluster)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 80))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        _ = hosting.sizeThatFits(in: window.bounds.size)
        for _ in 0..<8 { await Task.yield() }
        hosting.view.layoutIfNeeded()

        XCTAssertEqual(counter.makeCount, 1)
        XCTAssertNotNil(nativeCenter.parent)
        XCTAssertTrue(nativeCenter.view.window === window)
        XCTAssertEqual(
            descendants(of: UIView.self, in: hosting.view).filter {
                $0.accessibilityIdentifier == "terminal.vision.centerProbe"
            }.count,
            1
        )

        // Force ViewThatFits from its regular tier toward the compact/floor
        // candidates. The native UMD identity must remain in the one visible
        // center mount instead of being adopted by a measured-away branch.
        window.frame.size.width = 420
        hosting.view.frame = window.bounds
        hosting.view.setNeedsLayout()
        _ = hosting.sizeThatFits(in: window.bounds.size)
        for _ in 0..<8 { await Task.yield() }
        hosting.view.layoutIfNeeded()
        XCTAssertEqual(counter.makeCount, 1)
        XCTAssertNotNil(nativeCenter.parent)
        XCTAssertTrue(nativeCenter.view.window === window)
        XCTAssertEqual(
            descendants(of: UIView.self, in: hosting.view).filter {
                $0.accessibilityIdentifier == "terminal.vision.centerProbe"
            }.count,
            1
        )
    }

    func testClassicVisionWindowMovesNativeChromeOutOfWindowAndIntoOrnamentState() {
        let first = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let second = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "scratch"))
        let fixture = makeFixture(route: TerminalWindowRoute(tabs: [first, second]))

        fixture.controller.loadViewIfNeeded()
        fixture.controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 620)
        fixture.controller.view.setNeedsLayout()
        fixture.controller.view.layoutIfNeeded()

        let presentation = fixture.controller.visionOrnamentPresentationForTesting
        XCTAssertTrue(presentation.showsTopSourceLabels)
        XCTAssertEqual(presentation.bottom, .terminal(showsHelper: false))
        XCTAssertEqual(presentation.maximumConsoleWidth, 876)
        XCTAssertGreaterThan(fixture.controller.visionOrnamentRevisionForTesting, 0)
        XCTAssertNil(descendant(
            of: TerminalTabStripView.self,
            in: fixture.controller.view
        ))
        XCTAssertFalse(fixture.controller.children.contains {
            $0 is UMDBarViewController
        })
        XCTAssertEqual(
            fixture.controller.visionOrnamentTabStripForTesting.cells.map(\.itemID),
            [first.id, second.id]
        )
        XCTAssertNil(fixture.controller.visionShellKeyClusterForTesting.superview)
    }

    func testForcedVisionShellMountsAndFramesStandaloneKeyClusterInWindow() throws {
        let tab = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let shell = TerminalWindowShellConfiguration(
            deckControlLabel: "DECK",
            availableWidth: 420,
            showDeck: {},
            openTerminalRoute: { _ in },
            revealTab: { _ in },
            tabsEmptied: {},
            terminalFocusAllowed: false
        )
        let fixture = makeFixture(
            route: TerminalWindowRoute(tab: tab),
            shell: shell
        )
        fixture.controller.loadViewIfNeeded()
        fixture.controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 620)
        fixture.controller.view.setNeedsLayout()
        fixture.controller.view.layoutIfNeeded()

        let cluster = fixture.controller.visionShellKeyClusterForTesting
        let panes = try XCTUnwrap(view(
            "terminalWindow.panes",
            in: fixture.controller.view
        ))
        XCTAssertTrue(cluster.isDescendant(of: fixture.controller.view))
        XCTAssertFalse(cluster.frame.isEmpty)
        XCTAssertEqual(cluster.frame.maxY, panes.frame.maxY - 10, accuracy: 0.5)
        XCTAssertEqual(
            fixture.controller.visionOrnamentPresentationForTesting.bottom,
            .hidden
        )
    }

    func testAppLockRemovesAndUnlockRestoresClassicVisionOrnaments() {
        let tab = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let fixture = makeFixture(route: TerminalWindowRoute(tab: tab))
        fixture.controller.loadViewIfNeeded()
        fixture.controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 620)
        fixture.controller.view.layoutIfNeeded()
        let unlocked = fixture.controller.visionOrnamentPresentationForTesting
        XCTAssertNotEqual(unlocked.bottom, .hidden)

        fixture.controller.setAppLocked(true)
        XCTAssertEqual(
            fixture.controller.visionOrnamentPresentationForTesting.bottom,
            .hidden
        )

        fixture.controller.setAppLocked(false)
        XCTAssertEqual(
            fixture.controller.visionOrnamentPresentationForTesting,
            unlocked
        )
    }
    #endif

    private struct Fixture {
        let controller: TerminalWindowViewController
        let workspace: TerminalWorkspace
        let store: HostStore
    }

    private func makeFixture(
        route: TerminalWindowRoute,
        shell: TerminalWindowShellConfiguration? = nil,
        hosts: [Host] = [],
        performSceneIntent: @escaping (SceneWindowRouting.Intent) -> Void = { _ in },
        routeChanged: @escaping (TerminalWindowRoute) -> Void = { _ in }
    ) -> Fixture {
        let suffix = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalWindowUIKitTests-\(suffix)")
        let defaults = UserDefaults(
            suiteName: "app.multiplexterm.multiplex.tests.terminal-window.\(suffix)"
        )!
        let workspace = TerminalWorkspace()
        let store = HostStore(directory: directory, knownMirroredIDs: [])
        for host in hosts { store.add(host) }
        let dependencies = TerminalWindowDependencies(
            store: store,
            hub: ConnectionHub(),
            themes: ThemeStore(defaults: defaults, directory: directory),
            workspace: workspace,
            entitlements: EntitlementStore(defaults: defaults, startStoreKit: false)
        )
        let sceneWindows = SceneWindowRouting(
            supportsMultipleWindows: true,
            perform: performSceneIntent
        )
        return Fixture(
            controller: TerminalWindowViewController(
                route: route,
                dependencies: dependencies,
                sceneWindows: sceneWindows,
                shell: shell,
                routeChanged: routeChanged
            ),
            workspace: workspace,
            store: store
        )
    }

    private func controllerTree(_ root: UIViewController) -> [UIViewController] {
        [root] + root.children.flatMap { controllerTree($0) }
    }

    private func descendant<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }

    private func view(_ identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let match = view(identifier, in: child) { return match }
        }
        return nil
    }

    private func navigationButton(
        accessibilityLabel: String,
        in controller: UIViewController
    ) -> UIButton? {
        let items = [controller.navigationItem.leftBarButtonItem]
            .compactMap { $0 }
            + (controller.navigationItem.rightBarButtonItems ?? [])
        return items.compactMap(\.customView).lazy
            .flatMap { self.descendants(of: UIButton.self, in: $0) }
            .first { $0.accessibilityLabel == accessibilityLabel }
    }

    private func menuActions(in menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let submenu = element as? UIMenu { return menuActions(in: submenu) }
            return []
        }
    }
}

#if os(visionOS)
@MainActor
private final class VisionConsoleCenterMountCounter {
    var makeCount = 0
}

@MainActor
private struct VisionConsoleCenterProbe: UIViewControllerRepresentable {
    let counter: VisionConsoleCenterMountCounter
    let nativeCenter: UIViewController
    let fittingSize: CGSize

    func makeUIViewController(context: Context) -> VisionConsoleCenterProbeHost {
        counter.makeCount += 1
        let host = VisionConsoleCenterProbeHost()
        host.update(nativeCenter)
        return host
    }

    func updateUIViewController(
        _ host: VisionConsoleCenterProbeHost,
        context: Context
    ) {
        host.update(nativeCenter)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: VisionConsoleCenterProbeHost,
        context: Context
    ) -> CGSize? {
        fittingSize
    }
}

@MainActor
private final class VisionConsoleCenterProbeHost: UIViewController {
    private weak var content: UIViewController?

    override func loadView() {
        view = UIView()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content?.view.frame = view.bounds
    }

    func update(_ replacement: UIViewController) {
        guard content !== replacement else { return }
        if let content, content.parent === self {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        if replacement.parent != nil {
            replacement.willMove(toParent: nil)
            replacement.view.removeFromSuperview()
            replacement.removeFromParent()
        }
        content = replacement
        addChild(replacement)
        view.addSubview(replacement.view)
        replacement.view.frame = view.bounds
        replacement.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        replacement.didMove(toParent: self)
    }
}
#endif
