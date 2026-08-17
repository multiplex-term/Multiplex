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

    func testReorderingTabsUpdatesRouteWorkspaceAndNativeStripInPlace() throws {
        let first = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "main"))
        let second = TerminalRoute(hostID: UUID(), mode: .attach(sessionName: "scratch"))
        let third = TerminalRoute(hostID: UUID(), mode: .shell)
        var changed: [TerminalWindowRoute] = []
        let fixture = makeFixture(
            route: TerminalWindowRoute(tabs: [first, second, third]),
            routeChanged: { changed.append($0) }
        )
        fixture.controller.loadViewIfNeeded()

        #if os(visionOS)
        let strip = fixture.controller.visionOrnamentTabStripForTesting
        #else
        let strip = try XCTUnwrap(descendant(
            of: TerminalTabStripView.self,
            in: fixture.controller.view
        ))
        #endif
        let originalCells = Dictionary(uniqueKeysWithValues: strip.cells.map {
            ($0.itemID, ObjectIdentifier($0))
        })

        fixture.controller.reorderTab(first.id, to: third.id)

        let expected = [second, third, first]
        XCTAssertEqual(fixture.controller.route.tabs, expected)
        XCTAssertEqual(fixture.controller.route.activeTabID, first.id)
        XCTAssertEqual(changed.last?.tabs, expected)
        XCTAssertEqual(fixture.workspace.windows.first?.tabs, expected)
        XCTAssertEqual(strip.cells.map(\.itemID), expected.map(\.id))
        XCTAssertEqual(
            strip.cells.map { ObjectIdentifier($0) },
            expected.compactMap { originalCells[$0.id] },
            "A drop must reorder the live cells instead of destroying its interaction views"
        )
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
        XCTAssertTrue(
            rail.interactions.contains { $0 is UIDropInteraction },
            "The full padded rail must accept a tab-sort drop"
        )
        XCTAssertTrue(
            fixture.controller.view.interactions.contains { $0 is UIDropInteraction },
            "A tab that strays into the pane must remain a sort, never a file drop"
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
    func testPaneBoundsStopAboveBottomStripOnlyWhenTheRailDoesNotSpendIt() {
        let bounds = CGRect(x: 0, y: 0, width: 950, height: 1_200)
        let safeArea = UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 0)

        XCTAssertEqual(
            TerminalWindowUIKitRootView.contentBounds(
                in: bounds,
                reservesBottomSafeArea: true,
                safeAreaInsets: safeArea
            ),
            CGRect(x: 0, y: 0, width: 950, height: 1_179),
            "A pane that keeps the strip must stop above the home/resize band"
        )
        XCTAssertEqual(
            TerminalWindowUIKitRootView.contentBounds(
                in: bounds,
                reservesBottomSafeArea: false,
                safeAreaInsets: safeArea
            ),
            bounds,
            "A rail that spends the strip is the window's own bottom edge"
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

    func testClassicRailClearsTheWindowControlPillWithoutSpendingATopStrip() {
        // iPadOS floats its close/minimise pill over the window's top-left
        // corner whether or not a navigation bar exists, and keeps the same
        // offset either way — so the rail clears it horizontally and never
        // pushes its own row down to make room.
        // Neither the safe area nor the status bar distinguishes a floating
        // window from a maximised one — iPadOS hands a scene the display's
        // 32 pt inset either way (measured: a 711x941 window on a 1032x1376
        // display). Only spanning the display puts a scene under the status
        // bar.
        XCTAssertFalse(TerminalClassicRailInsets.meetsSystemTopChrome(
            sceneSize: CGSize(width: 711, height: 941),
            screenSize: CGSize(width: 1032, height: 1376)
        ))
        XCTAssertTrue(TerminalClassicRailInsets.meetsSystemTopChrome(
            sceneSize: CGSize(width: 1032, height: 1376),
            screenSize: CGSize(width: 1032, height: 1376)
        ))
        // `UIScreen.bounds` does not follow the scene's orientation: a
        // maximised landscape window must still read as spanning.
        XCTAssertTrue(TerminalClassicRailInsets.meetsSystemTopChrome(
            sceneSize: CGSize(width: 1376, height: 1032),
            screenSize: CGSize(width: 1032, height: 1376)
        ))
        XCTAssertFalse(TerminalClassicRailInsets.meetsSystemTopChrome(
            sceneSize: CGSize(width: 1376, height: 700),
            screenSize: CGSize(width: 1032, height: 1376)
        ))
        XCTAssertFalse(TerminalClassicRailInsets.meetsSystemTopChrome(
            sceneSize: CGSize(width: 1032, height: 1376),
            screenSize: .zero
        ))

        // A window's own frame is scene-relative; only its frame in SCREEN
        // coordinates says whether it is parked under the status bar.
        XCTAssertEqual(
            TerminalClassicRailInsets.systemTopChromeOverlap(
                windowFrameOnScreen: CGRect(x: 160.5, y: 217.5, width: 711, height: 941),
                statusBarHeight: 32
            ),
            0,
            "A window floating below the status bar owes it nothing"
        )
        XCTAssertEqual(
            TerminalClassicRailInsets.systemTopChromeOverlap(
                windowFrameOnScreen: CGRect(x: 0, y: 0, width: 1032, height: 1376),
                statusBarHeight: 32
            ),
            32
        )
        XCTAssertEqual(
            TerminalClassicRailInsets.systemTopChromeOverlap(
                windowFrameOnScreen: CGRect(x: 40, y: 12, width: 700, height: 900),
                statusBarHeight: 32
            ),
            20,
            "A window parked partly under the bar spends exactly the overlap"
        )

        let windowed = TerminalClassicRailInsets.safeArea(
            sceneSafeArea: UIEdgeInsets(top: 32, left: 0, bottom: 10, right: 0),
            hostsWindowControls: true,
            systemTopChromeOverlap: 0,
            spansDisplay: false
        )
        XCTAssertEqual(
            windowed.top,
            0,
            "A floating window meets no status bar; a spent strip only lowers the row"
        )

        XCTAssertEqual(
            windowed.left + 10,
            TerminalClassicRailInsets.windowControlsClearance,
            "A floating scene owes its pill the leading corner"
        )

        // Spanning the display: the scene wears the status bar and hides its
        // pill, so it spends the strip and keeps its leading corner.
        let fullScreen = TerminalClassicRailInsets.safeArea(
            sceneSafeArea: UIEdgeInsets(top: 32, left: 0, bottom: 20, right: 0),
            hostsWindowControls: true,
            systemTopChromeOverlap: 32,
            spansDisplay: true
        )
        XCTAssertEqual(fullScreen.top, 32)
        XCTAssertEqual(
            fullScreen.left,
            0,
            "No pill is drawn over a spanning scene; DECK keeps the corner"
        )
        XCTAssertEqual(windowed.bottom, 0, "The rail owns the top edge only")
        XCTAssertEqual(
            windowed.right + 10,
            TerminalClassicRailInsets.windowEdgeClearance,
            "The last chip owes the rounded window corner daylight too"
        )

        let parkedAtTop = TerminalClassicRailInsets.safeArea(
            sceneSafeArea: UIEdgeInsets(top: 32, left: 0, bottom: 10, right: 0),
            hostsWindowControls: true,
            systemTopChromeOverlap: 32,
            spansDisplay: false
        )
        XCTAssertEqual(parkedAtTop.top, 32, "Under the bar, the rail spends the band")
        XCTAssertEqual(
            parkedAtTop.left + 10,
            TerminalClassicRailInsets.windowControlsClearance,
            "It is still a floating window, so its pill still owns the corner"
        )

        // The Mac wears its own title bar above the scene, so nothing floats
        // into the app's leading corner there.
        let mac = TerminalClassicRailInsets.safeArea(
            sceneSafeArea: UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8),
            hostsWindowControls: false,
            systemTopChromeOverlap: 32,
            spansDisplay: true
        )
        XCTAssertEqual(mac.left, 8)
        XCTAssertEqual(
            mac.top,
            0,
            "The Mac's scene sits below its own title bar; a strip there reads as a second one"
        )
    }

    func testClassicRailClearanceNeverReachesThePanes() throws {
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
        fixture.controller.loadViewIfNeeded()
        fixture.controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        fixture.controller.view.layoutIfNeeded()

        let insets = fixture.controller.paneAndRailInsetsForTesting
        XCTAssertEqual(
            insets.pane,
            .zero,
            "The pill clearance is chrome geometry; a pane inset by it lays out off-window"
        )
        // Rail insets need a real window (they are measured against the
        // screen); the pure cases are covered above. Unwindowed, the rail
        // must still fail safe rather than hand a pane anything.
        XCTAssertEqual(insets.rail.top, 0)
    }

    func testClassicWindowWearsTheAppRailInsteadOfANavigationBar() throws {
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
        navigation.loadViewIfNeeded()
        fixture.controller.loadViewIfNeeded()
        fixture.controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        fixture.controller.viewWillAppear(false)
        fixture.controller.view.layoutIfNeeded()

        XCTAssertNil(fixture.controller.navigationItem.leftBarButtonItem)
        XCTAssertNil(fixture.controller.navigationItem.rightBarButtonItems)

        let root = try XCTUnwrap(
            fixture.controller.viewIfLoaded as? TerminalWindowUIKitRootView
        )
        let deck = try XCTUnwrap(
            descendants(of: UIButton.self, in: root.umdContainer)
                .first { $0.accessibilityIdentifier == "umd.deck" }
        )
        XCTAssertEqual(root.umdContainer.frame.minY, 0, "The rail owns the top edge")
        XCTAssertEqual(root.umdContainer.frame.width, 900)
        XCTAssertGreaterThan(root.umdContainer.frame.height, 0)
        XCTAssertEqual(
            root.umdContainer.frame.height,
            TerminalKeyBar.barHeight,
            "The title bar matches the key rail at the pane's other end"
        )
        XCTAssertLessThan(
            root.umdContainer.frame.height,
            64,
            "The whole point is beating the system bar's 54pt-plus-strip band"
        )
        XCTAssertEqual(
            root.paneContainer.frame.minY,
            root.umdContainer.frame.maxY,
            "Nothing insets for the top strip twice — the rail spent it"
        )
        XCTAssertTrue(deck.isDescendant(of: root.umdContainer))
    }

    #endif

    #if os(visionOS)
    func testVisionOrnamentPresentationPinsVisibilityWidthAndModes() {
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

        let auxiliary = TerminalVisionOrnamentPresentation.resolve(
            tabCount: 2,
            isAuxiliary: true,
            hasUMD: true,
            hasHelper: true,
            windowWidth: 12
        )
        XCTAssertEqual(auxiliary.bottom, .auxiliary)
        XCTAssertEqual(auxiliary.maximumConsoleWidth, 1)

        let hidden = TerminalVisionOrnamentPresentation.resolve(
            tabCount: 2,
            isAuxiliary: false,
            hasUMD: false,
            hasHelper: true,
            windowWidth: 900
        )
        XCTAssertEqual(hidden.bottom, .hidden)
    }

    func testVisionConsoleGeometryPutsTheWholeRowBelowTheSceneEdge() {
        let helperless = TerminalVisionConsoleGeometry.resolve(
            helperSize: nil,
            consoleSize: CGSize(width: 600, height: 44),
            helperLeading: false,
            spacing: 10
        )
        XCTAssertEqual(helperless.size, CGSize(width: 600, height: 88))
        XCTAssertEqual(helperless.consoleOrigin, CGPoint(x: 0, y: 44))
        XCTAssertNil(helperless.helperOrigin)
        XCTAssertEqual(
            helperless.consoleOrigin.y,
            helperless.size.height / 2
        )

        let collapsedHelper = TerminalVisionConsoleGeometry.resolve(
            helperSize: CGSize(width: 30, height: 30),
            consoleSize: CGSize(width: 600, height: 44),
            helperLeading: true,
            spacing: 10
        )
        XCTAssertEqual(collapsedHelper.size, CGSize(width: 600, height: 88))
        XCTAssertEqual(collapsedHelper.helperOrigin, CGPoint(x: 0, y: 4))
        XCTAssertEqual(collapsedHelper.consoleOrigin, CGPoint(x: 0, y: 44))
    }

    func testVisionStackedDeckGeometryHangsTheExtraRowBelowTheAnchor() {
        let geometry = TerminalVisionStackedDeckGeometry.resolve(
            contentSize: CGSize(width: 820, height: 95),
            anchorOffset: 48
        )

        XCTAssertEqual(geometry.size, CGSize(width: 820, height: 143))
        XCTAssertEqual(geometry.contentOrigin, CGPoint(x: 0, y: 48))
        XCTAssertEqual(
            geometry.size.height / 2 - geometry.contentOrigin.y,
            (95 - 48) / 2,
            "the slab's top edge sits half a window row above the anchor —"
                + " matching a single-row slab — so the file row never rides up"
                + " over the pane's content"
        )
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

    #if !os(visionOS)
    func testLockingTheKeyboardClosesEveryTalkbackBoxInTheWindow() async throws {
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let first = TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main"))
        let second = TerminalRoute(hostID: host.id, mode: .attach(sessionName: "agent"))
        let fixture = makeFixture(
            route: TerminalWindowRoute(tabs: [first, second], activeTabID: first.id),
            hosts: [host]
        )
        fixture.controller.loadViewIfNeeded()
        let active = try XCTUnwrap(fixture.workspace.controller(for: first.id))
        let other = try XCTUnwrap(fixture.workspace.controller(for: second.id))
        active.setTalkbackOpen(true)
        other.setTalkbackOpen(true)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNotNil(
            view("terminal.talkback.card", in: fixture.controller.view),
            "the active tab's open box mounts its card"
        )

        // The lock is app-wide state only the arbiter writes; a scratch
        // terminal engages it and the defer releases it for the next test.
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        TerminalFocusArbiter.lock(terminal)
        defer { TerminalFocusArbiter.unlock(terminal, summoning: false) }
        for _ in 0..<8 { await Task.yield() }

        XCTAssertFalse(active.talkbackOpen, "locking closes the active tab's box")
        XCTAssertFalse(other.talkbackOpen, "and every other tab's in this window")
        XCTAssertNil(view("terminal.talkback.card", in: fixture.controller.view))

        // Opening again while still locked is allowed — the talk key
        // releases the lock first — and the box mounts once more.
        TerminalFocusArbiter.unlock(terminal, summoning: false)
        active.setTalkbackOpen(true)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(active.talkbackOpen)
        XCTAssertNotNil(view("terminal.talkback.card", in: fixture.controller.view))
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
