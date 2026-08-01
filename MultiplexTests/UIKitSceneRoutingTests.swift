import XCTest
@testable import Multiplex

final class UIKitSceneRoutingTests: XCTestCase {
    func testEqualActivationRaisesMountedSceneWithoutReplacingItsContent() {
        let deck = ScenePayload.deck(.main)
        XCTAssertFalse(UIKitSceneContentReplacementPolicy.requiresReplacement(
            current: deck,
            incoming: deck
        ))

        XCTAssertTrue(UIKitSceneContentReplacementPolicy.requiresReplacement(
            current: deck,
            incoming: .terminal(TerminalWindowRoute(tabs: []))
        ))
    }

    func testDeckReusesConnectedDeckRegardlessOfRequestedRoute() {
        let records = [
            UIKitSceneActivationPlan.ConnectedScene(
                persistentIdentifier: "terminal",
                payload: .terminal(TerminalWindowRoute(tabs: []))
            ),
            UIKitSceneActivationPlan.ConnectedScene(
                persistentIdentifier: "deck-z",
                payload: .deck(.main)
            ),
        ]

        XCTAssertEqual(
            UIKitSceneActivationPlan.resolve(
                .openDeck(.main),
                connectedScenes: records,
                currentPersistentIdentifier: "terminal"
            ),
            .activateExisting(
                persistentIdentifier: "deck-z",
                payload: .deck(.main)
            )
        )
    }

    func testDeckCreationIsUsedWhenNoRestorableDeckExists() {
        let records = [
            UIKitSceneActivationPlan.ConnectedScene(
                persistentIdentifier: "unknown",
                payload: nil
            ),
        ]

        XCTAssertEqual(
            UIKitSceneActivationPlan.resolve(
                .openDeck(.main),
                connectedScenes: records,
                currentPersistentIdentifier: nil
            ),
            .create(.deck(.main))
        )
    }

    func testTerminalAlwaysCreatesANewSessionEvenWhenRouteIDMatches() {
        let route = TerminalWindowRoute(tabs: [])
        let records = [
            UIKitSceneActivationPlan.ConnectedScene(
                persistentIdentifier: "existing-terminal",
                payload: .terminal(route)
            ),
        ]

        XCTAssertEqual(
            UIKitSceneActivationPlan.resolve(
                .openTerminal(route),
                connectedScenes: records,
                currentPersistentIdentifier: nil
            ),
            .create(.terminal(route))
        )
    }

    func testCloseTargetsOnlyTheCurrentPersistentSession() {
        XCTAssertEqual(
            UIKitSceneActivationPlan.resolve(
                .closeCurrentScene,
                connectedScenes: [],
                currentPersistentIdentifier: "current"
            ),
            .destroyCurrent(persistentIdentifier: "current")
        )
        XCTAssertEqual(
            UIKitSceneActivationPlan.resolve(
                .closeCurrentScene,
                connectedScenes: [],
                currentPersistentIdentifier: nil
            ),
            .unavailable
        )
    }

    func testDuplicateDeckRecordsResolveDeterministically() {
        let records = ["z", "a", "m"].map {
            UIKitSceneActivationPlan.ConnectedScene(
                persistentIdentifier: $0,
                payload: .deck(.main)
            )
        }

        XCTAssertEqual(
            UIKitSceneActivationPlan.resolve(
                .openDeck(.main),
                connectedScenes: records,
                currentPersistentIdentifier: nil
            ),
            .activateExisting(
                persistentIdentifier: "a",
                payload: .deck(.main)
            )
        )
    }
}
