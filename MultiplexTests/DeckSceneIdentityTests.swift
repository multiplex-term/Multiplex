import XCTest
@testable import Multiplex

final class DeckSceneIdentityTests: XCTestCase {
    private final class Session {}

    func testFirstSessionOwnsSingletonAndDifferentSessionIsDuplicate() {
        var registry = SingletonSceneRegistry<Session, String>()
        let primary = Session()
        let duplicate = Session()

        XCTAssertEqual(registry.register(primary, id: "primary"), .primary)
        XCTAssertEqual(registry.register(duplicate, id: "duplicate"), .duplicate)
        XCTAssertTrue(registry.primary === primary)
    }

    func testMatchingPersistentIDRefreshesPrimarySession() {
        var registry = SingletonSceneRegistry<Session, String>()
        let original = Session()
        let reconstituted = Session()

        XCTAssertEqual(registry.register(original, id: "deck"), .primary)
        XCTAssertEqual(registry.register(reconstituted, id: "deck"), .primary)
        XCTAssertTrue(registry.primary === reconstituted)
    }

    func testClosedPrimaryLetsNextSessionTakeOwnership() {
        var registry = SingletonSceneRegistry<Session, String>()
        var original: Session? = Session()
        XCTAssertEqual(registry.register(original!, id: "old"), .primary)

        original = nil
        let replacement = Session()

        XCTAssertEqual(registry.register(replacement, id: "new"), .primary)
        XCTAssertTrue(registry.primary === replacement)
    }

    func testDeckRouteRoundTripsForSceneRestoration() throws {
        let data = try JSONEncoder().encode(DeckWindowRoute.main)
        XCTAssertEqual(try JSONDecoder().decode(DeckWindowRoute.self, from: data), .main)
    }
}
