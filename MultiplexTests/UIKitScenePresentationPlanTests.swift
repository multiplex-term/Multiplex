import XCTest
@testable import Multiplex

final class UIKitScenePresentationPlanTests: XCTestCase {
    func testVisionAlwaysUsesClassicDeckAndTerminalWindows() {
        let route = TerminalWindowRoute(tab: TerminalRoute(
            hostID: UUID(),
            mode: .attach(sessionName: "main")
        ))

        XCTAssertEqual(resolve(.deck(.main), platform: .visionOS), .deck)
        XCTAssertEqual(
            resolve(.terminal(route), platform: .visionOS),
            .terminal(route)
        )
    }

    func testPhoneMapsBothPayloadKindsIntoOneShell() {
        let route = TerminalWindowRoute(tab: TerminalRoute(
            hostID: UUID(),
            mode: .attach(sessionName: "scratch")
        ))

        assertEmptyShell(resolve(.deck(.main), idiom: .phone))
        XCTAssertEqual(
            resolve(.terminal(route), idiom: .phone),
            .shell(route)
        )
    }

    func testFullscreenIPadUsesShellAndWindowedIPadStaysClassic() {
        assertEmptyShell(resolve(.deck(.main), idiom: .pad, isFullScreen: true))
        XCTAssertEqual(
            resolve(.deck(.main), idiom: .pad, isFullScreen: false),
            .deck
        )
    }

    func testEnvironmentOverrideStillWins() {
        assertEmptyShell(resolve(
            .deck(.main),
            idiom: .pad,
            environmentOverride: "1"
        ))
        XCTAssertEqual(
            resolve(
                .deck(.main),
                idiom: .phone,
                isFullScreen: true,
                environmentOverride: "0"
            ),
            .deck
        )
    }

    func testActivationPayloadWinsOverRestorationAndDefaultIsDeck() throws {
        let restored = ScenePayload.deck(.main)
        let route = TerminalWindowRoute(tab: TerminalRoute(
            hostID: UUID(),
            mode: .attach(sessionName: "deploy")
        ))
        let activation = ScenePayload.terminal(route)

        XCTAssertEqual(
            UIKitScenePayloadResolver.resolve(
                activationActivities: [try SceneActivityCodec.makeActivity(for: activation)],
                restorationActivity: try SceneActivityCodec.makeActivity(for: restored)
            ),
            activation
        )
        XCTAssertEqual(
            UIKitScenePayloadResolver.resolve(
                activationActivities: [],
                restorationActivity: try SceneActivityCodec.makeActivity(for: restored)
            ),
            restored
        )
        XCTAssertEqual(
            UIKitScenePayloadResolver.resolve(
                activationActivities: [],
                restorationActivity: nil
            ),
            .deck(.main)
        )

        XCTAssertEqual(
            UIKitScenePayloadResolver.resolution(
                activationActivities: [],
                restorationActivity: try SceneActivityCodec.makeActivity(for: restored)
            ).source,
            .restoration
        )
        let malformed = NSUserActivity(activityType: "unknown")
        XCTAssertEqual(
            UIKitScenePayloadResolver.resolution(
                activationActivities: [],
                restorationActivity: malformed
            ).source,
            .defaultDeck
        )
    }

    func testActivationGeometryMarkerAndLegacyOrderingAreDeterministic() throws {
        let deck = try SceneActivityCodec.makeActivity(
            for: .deck(.main),
            newSceneRequest: true
        )
        let route = TerminalWindowRoute(tab: TerminalRoute(
            hostID: UUID(uuidString: "7D2851DB-ED95-42D8-91D0-4E8F706253DD")!,
            mode: .attach(sessionName: "main")
        ))
        let terminal = NSUserActivity(
            activityType: SceneActivityCodec.legacyStateRestorationActivityType
        )
        terminal.addUserInfoEntries(from: [
            SceneActivityCodec.legacySceneIDKey: "terminal",
            SceneActivityCodec.legacySceneValueKey: try JSONEncoder().encode(route),
        ])

        XCTAssertTrue(UIKitScenePayloadResolver.resolution(
            activationActivities: [deck],
            restorationActivity: nil
        ).requestsInitialGeometry)

        let forward = UIKitScenePayloadResolver.resolve(
            activationActivities: [deck, terminal],
            restorationActivity: nil
        )
        let reversed = UIKitScenePayloadResolver.resolve(
            activationActivities: [terminal, deck],
            restorationActivity: nil
        )
        XCTAssertEqual(forward, reversed)
    }

    func testDuplicateActivationTargetsUsePayloadAndGeometryTieBreakers() throws {
        let windowID = UUID()
        let firstTab = TerminalRoute(
            id: UUID(),
            hostID: UUID(),
            mode: .attach(sessionName: "main")
        )
        let secondTab = TerminalRoute(
            id: UUID(),
            hostID: firstTab.hostID,
            mode: .attach(sessionName: "scratch")
        )
        let firstPayload = ScenePayload.terminal(TerminalWindowRoute(
            id: windowID,
            tabs: [firstTab, secondTab],
            activeTabID: firstTab.id
        ))
        let secondPayload = ScenePayload.terminal(TerminalWindowRoute(
            id: windowID,
            tabs: [firstTab, secondTab],
            activeTabID: secondTab.id
        ))
        let first = try SceneActivityCodec.makeActivity(for: firstPayload)
        let second = try SceneActivityCodec.makeActivity(for: secondPayload)
        XCTAssertEqual(first.targetContentIdentifier, second.targetContentIdentifier)

        let forward = UIKitScenePayloadResolver.resolution(
            activationActivities: [first, second],
            restorationActivity: nil
        )
        let reversed = UIKitScenePayloadResolver.resolution(
            activationActivities: [second, first],
            restorationActivity: nil
        )
        XCTAssertEqual(forward, reversed)

        let marked = try SceneActivityCodec.makeActivity(
            for: firstPayload,
            newSceneRequest: true
        )
        let unmarkedFirst = UIKitScenePayloadResolver.resolution(
            activationActivities: [first, marked],
            restorationActivity: nil
        )
        let markedFirst = UIKitScenePayloadResolver.resolution(
            activationActivities: [marked, first],
            restorationActivity: nil
        )
        XCTAssertEqual(unmarkedFirst, markedFirst)
        XCTAssertFalse(unmarkedFirst.requestsInitialGeometry)
    }

    func testURLBufferReleasesInOrderOnlyAfterSceneResolution() throws {
        var buffer = UIKitSceneURLBuffer()
        let first = try XCTUnwrap(URL(string: "multiplex://open?host=one"))
        let second = try XCTUnwrap(URL(string: "multiplex://open?host=two"))
        let live = try XCTUnwrap(URL(string: "multiplex://open?host=live"))

        XCTAssertTrue(buffer.accept(
            [first, second],
            phase: .awaitingRestoration
        ).isEmpty)
        XCTAssertTrue(buffer.release(phase: .awaitingRestoration).isEmpty)
        XCTAssertEqual(buffer.deferred, [first, second])
        XCTAssertEqual(buffer.release(phase: .restoration), [first, second])
        XCTAssertTrue(buffer.deferred.isEmpty)
        XCTAssertEqual(buffer.accept([live], phase: .activation), [live])
    }

    func testSceneAdoptionFollowsDelegateOwnershipNotLegacyFingerprints() {
        let native = "Multiplex.MultiplexSceneDelegate"

        // The persisted SwiftUI delegate, resolvable because SwiftUI happens
        // to be loaded. Either slot naming it is the scene UIKit would
        // otherwise connect to a lifecycle this executable no longer runs.
        XCTAssertTrue(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            nativeDelegateClassName: native,
            configuredDelegateClassName:
                UIKitLegacySceneMigrationPolicy.swiftUIDelegateClassName,
            liveDelegateClassName: nil
        ))
        XCTAssertTrue(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            nativeDelegateClassName: native,
            configuredDelegateClassName: nil,
            liveDelegateClassName:
                UIKitLegacySceneMigrationPolicy.swiftUIDelegateClassName
        ))

        // The safety net that used to erase itself: without SwiftUI in the
        // process the persisted class name resolves to nothing in BOTH slots,
        // and after the first adoption the session's restoration activity is
        // this app's own type, so no legacy fingerprint remains to match. A
        // scene in this state has no delegate at all and must still be
        // adopted — the alternative is a blank window on every later launch.
        XCTAssertTrue(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            nativeDelegateClassName: native,
            configuredDelegateClassName: nil,
            liveDelegateClassName: nil
        ))

        // A scene UIKit owns natively is never taken: already connected, and
        // configured-but-not-yet-instantiated (where stealing it would orphan
        // the connection options UIKit is about to deliver).
        XCTAssertFalse(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            nativeDelegateClassName: native,
            configuredDelegateClassName: native,
            liveDelegateClassName: native
        ))
        XCTAssertFalse(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            nativeDelegateClassName: native,
            configuredDelegateClassName: native,
            liveDelegateClassName: nil
        ))
        XCTAssertFalse(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            nativeDelegateClassName: native,
            configuredDelegateClassName:
                UIKitLegacySceneMigrationPolicy.swiftUIDelegateClassName,
            liveDelegateClassName: native
        ))
    }

    func testGeometryDefaultsAndValidatedDebugOverrides() {
        XCTAssertEqual(
            UIKitSceneGeometryPolicy.preferredSize(
                for: .deck(.main),
                environment: [:]
            ),
            CGSize(width: 1_160, height: 524)
        )
        XCTAssertEqual(
            UIKitSceneGeometryPolicy.preferredSize(
                for: .terminal(TerminalWindowRoute(tabs: [])),
                environment: ["MULTIPLEX_TERM_SIZE": "860x540"]
            ),
            CGSize(width: 860, height: 540)
        )
        XCTAssertNil(UIKitSceneGeometryPolicy.parseSize("0x700"))
        XCTAssertNil(UIKitSceneGeometryPolicy.parseSize("1120"))
        XCTAssertNil(UIKitSceneGeometryPolicy.parseSize("wideX700"))
    }

    func testRememberedWindowSizeStandsInForTheAuthoredDefault() throws {
        let suiteName = "SceneWindowSizeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SceneWindowSizeStore(defaults: defaults)
        let terminalDefault = UIKitSceneGeometryPolicy.terminalDefault

        // Nothing remembered: the authored default, exactly as `.defaultSize`.
        XCTAssertNil(store.lastSize(for: .terminal))
        XCTAssertEqual(
            SceneGeometryPolicy.chooseInitialSize(
                environmentOverride: nil,
                remembered: store.lastSize(for: .terminal),
                default: terminalDefault
            ),
            terminalDefault
        )

        // A window the user resized is what the next window of that kind
        // opens at, and it says nothing about the other kind.
        let resized = CGSize(width: 1_600, height: 1_000)
        store.record(resized, for: .terminal)
        XCTAssertNil(store.lastSize(for: .deck))
        XCTAssertEqual(
            SceneGeometryPolicy.chooseInitialSize(
                environmentOverride: nil,
                remembered: store.lastSize(for: .terminal),
                default: terminalDefault
            ),
            resized
        )

        // A DEBUG screenshot override still wins outright.
        XCTAssertEqual(
            SceneGeometryPolicy.chooseInitialSize(
                environmentOverride: CGSize(width: 860, height: 540),
                remembered: store.lastSize(for: .terminal),
                default: terminalDefault
            ),
            CGSize(width: 860, height: 540)
        )

        // A scene sampled mid-teardown reports nothing worth remembering.
        store.record(.zero, for: .terminal)
        store.record(CGSize(width: 1_600, height: CGFloat.nan), for: .terminal)
        XCTAssertEqual(store.lastSize(for: .terminal), resized)
    }

    func testGeometryOverrideKeysStayInStepWithTheGeometryPolicy() {
        for kind in SceneGeometryKind.allCases {
            let payload: ScenePayload = switch kind {
            case .deck: .deck(.main)
            case .terminal: .terminal(TerminalWindowRoute(tabs: []))
            }
            XCTAssertEqual(SceneGeometryKind(payload), kind)
            XCTAssertEqual(
                UIKitSceneGeometryPolicy.preferredSize(
                    for: payload,
                    environment: [kind.debugSizeEnvironmentKey: "900x600"]
                ),
                CGSize(width: 900, height: 600)
            )
        }
    }

    func testConnectionPhaseWaitsForDelayedRestorationAndPreservesActivation() throws {
        let fallback = UIKitScenePayloadResolver.Resolution(
            payload: .deck(.main),
            source: .defaultDeck,
            requestsInitialGeometry: false
        )
        XCTAssertEqual(
            UIKitSceneConnectionPhase.initial(
                resolution: fallback,
                restorationActivityWasSupplied: false
            ),
            .awaitingRestoration
        )
        XCTAssertFalse(UIKitSceneConnectionPhase.awaitingRestoration.persistsImmediately)
        XCTAssertTrue(
            UIKitSceneConnectionPhase.awaitingRestoration
                .acceptsInitialRestorationCallback
        )

        // A supplied but malformed restoration envelope still identifies an
        // existing scene: fall back to the deck without applying fresh size.
        XCTAssertEqual(
            UIKitSceneConnectionPhase.initial(
                resolution: fallback,
                restorationActivityWasSupplied: true
            ),
            .restoration
        )

        let activation = UIKitScenePayloadResolver.resolution(
            activationActivities: [try SceneActivityCodec.makeActivity(
                for: .deck(.main),
                newSceneRequest: true
            )],
            restorationActivity: nil
        )
        let activationPhase = UIKitSceneConnectionPhase.initial(
            resolution: activation,
            restorationActivityWasSupplied: true
        )
        XCTAssertEqual(activationPhase, .activation)
        XCTAssertFalse(
            activationPhase.acceptsInitialRestorationCallback,
            "A later callback must not replace an explicit activation"
        )
        XCTAssertTrue(activation.requestsInitialGeometry)
        XCTAssertFalse(
            UIKitSceneConnectionPhase.freshDefault
                .acceptsInitialRestorationCallback
        )
    }

    private func resolve(
        _ payload: ScenePayload,
        platform: ShellModeDecision.Platform = .iOS,
        idiom: ShellModeDecision.Idiom = .pad,
        isFullScreen: Bool = false,
        environmentOverride: String? = nil
    ) -> UIKitScenePresentationPlan {
        UIKitScenePresentationPlan.resolve(
            payload: payload,
            platform: platform,
            idiom: idiom,
            isFullScreen: isFullScreen,
            environmentOverride: environmentOverride
        )
    }

    private func assertEmptyShell(
        _ plan: UIKitScenePresentationPlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .shell(let route) = plan else {
            XCTFail("Expected an empty shell plan, got \(plan)", file: file, line: line)
            return
        }
        XCTAssertTrue(route.tabs.isEmpty, file: file, line: line)
        XCTAssertNil(route.activeTabID, file: file, line: line)
    }
}
