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
            activityType: SceneActivityCodec.legacyOpenWindowActivityType
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

    func testPersistedSwiftUISessionAdoptionIsNarrow() {
        let legacy = NSUserActivity(
            activityType: SceneActivityCodec.legacyStateRestorationActivityType
        )
        legacy.addUserInfoEntries(from: [
            SceneActivityCodec.legacySceneIDKey: "deck",
            SceneActivityCodec.legacyPresentedSceneValueKey: Data("\"main\"".utf8),
        ])

        XCTAssertTrue(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            configuredDelegateClassName: "SwiftUI.AppSceneDelegate",
            liveDelegateClassName: nil,
            restorationActivity: legacy
        ))
        XCTAssertTrue(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            configuredDelegateClassName: nil,
            liveDelegateClassName: "SwiftUI.AppSceneDelegate",
            restorationActivity: nil
        ))
        XCTAssertTrue(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            configuredDelegateClassName: nil,
            liveDelegateClassName: nil,
            restorationActivity: legacy
        ))
        XCTAssertFalse(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            configuredDelegateClassName: "Multiplex.MultiplexSceneDelegate",
            liveDelegateClassName: "Multiplex.MultiplexSceneDelegate",
            restorationActivity: legacy
        ))
        XCTAssertFalse(UIKitLegacySceneMigrationPolicy.requiresAdoption(
            configuredDelegateClassName: nil,
            liveDelegateClassName: nil,
            restorationActivity: nil
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
