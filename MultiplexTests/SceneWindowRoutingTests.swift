import XCTest
@testable import Multiplex

final class SceneWindowRoutingTests: XCTestCase {
    private final class Spy {
        var intents: [SceneWindowRouting.Intent] = []
    }

    func testOpenDeckDelegatesStableSingletonRoute() {
        let spy = Spy()
        let routing = makeRouting(spy: spy)

        routing.openDeck()

        XCTAssertEqual(spy.intents, [.openDeck(.main)])
    }

    func testOpenTerminalDelegatesExactRoute() {
        let spy = Spy()
        let routing = makeRouting(spy: spy)
        let tab = TerminalRoute(
            id: UUID(uuidString: "F20AFFB9-2D8C-40EF-A7BA-3CCB9B2FDE2B")!,
            hostID: UUID(uuidString: "609491B7-D099-461D-A1F4-F8FB3B42120F")!,
            mode: .attach(sessionName: "scratch")
        )
        let route = TerminalWindowRoute(
            id: UUID(uuidString: "57D95F2C-A256-4D93-8065-E3CD771F620A")!,
            tabs: [tab],
            activeTabID: tab.id
        )

        routing.openTerminal(route)

        XCTAssertEqual(spy.intents, [.openTerminal(route)])
    }

    func testCloseCurrentSceneDelegatesWithoutRouteIdentity() {
        let spy = Spy()
        let routing = makeRouting(spy: spy)

        routing.closeCurrentScene()

        XCTAssertEqual(spy.intents, [.closeCurrentScene])
    }

    func testSupportsMultipleWindowsPreservesPerSceneFlag() {
        XCTAssertTrue(makeRouting(supportsMultipleWindows: true).supportsMultipleWindows)
        XCTAssertFalse(makeRouting(supportsMultipleWindows: false).supportsMultipleWindows)
    }

    private func makeRouting(
        supportsMultipleWindows: Bool = true,
        spy: Spy = Spy()
    ) -> SceneWindowRouting {
        SceneWindowRouting(
            supportsMultipleWindows: supportsMultipleWindows,
            perform: { spy.intents.append($0) }
        )
    }
}
