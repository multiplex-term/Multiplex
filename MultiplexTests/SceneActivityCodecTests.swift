import XCTest
@testable import Multiplex

final class SceneActivityCodecTests: XCTestCase {
    func testDeckActivityRoundTrip() throws {
        let payload = ScenePayload.deck(.main)
        let activity = try SceneActivityCodec.makeActivity(for: payload)

        XCTAssertEqual(SceneActivityCodec.payload(from: activity), payload)
    }

    func testMultiTabTerminalActivityRoundTrip() throws {
        let hostID = UUID(uuidString: "95C6BCAE-B5D1-4895-A071-47A8E52A87DB")!
        let first = TerminalRoute(
            id: UUID(uuidString: "A6D2A861-B30C-4867-9394-A204515149E9")!,
            hostID: hostID,
            mode: .attach(sessionName: "main")
        )
        let second = TerminalRoute(
            id: UUID(uuidString: "12413F33-320A-4210-BD51-5CE0F7CA11D9")!,
            hostID: hostID,
            mode: .attach(sessionName: "scratch")
        )
        let route = TerminalWindowRoute(
            id: UUID(uuidString: "B1366B9E-8315-412A-99F9-6990C6FD13C0")!,
            tabs: [first, second],
            activeTabID: second.id
        )
        let payload = ScenePayload.terminal(route)

        let activity = try SceneActivityCodec.makeActivity(for: payload)

        XCTAssertEqual(SceneActivityCodec.payload(from: activity), payload)
    }

    func testMalformedAndUnknownPayloadsAreRejected() {
        let malformed = activity(payloadData: Data([0xFF]))
        XCTAssertNil(SceneActivityCodec.payload(from: malformed))

        let unknownKind = activity(payloadData: Data(
            #"{"kind":"futureScene","route":{}}"#.utf8
        ))
        XCTAssertNil(SceneActivityCodec.payload(from: unknownKind))

        let unknownActivity = NSUserActivity(
            activityType: "app.multiplexterm.multiplex.unknown"
        )
        unknownActivity.addUserInfoEntries(from: malformed.userInfo ?? [:])
        XCTAssertNil(SceneActivityCodec.payload(from: unknownActivity))
    }

    func testCapturedShippingSwiftUITerminalActivityMigrates() throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "LegacySwiftUITerminalSceneActivity",
            withExtension: "plist"
        ))
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: fixtureData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        let activity = NSUserActivity(activityType: try XCTUnwrap(
            fixture["activityType"] as? String
        ))
        activity.addUserInfoEntries(from: try XCTUnwrap(
            fixture["userInfo"] as? [AnyHashable: Any]
        ))

        let hostID = try XCTUnwrap(UUID(
            uuidString: "2CB2F05C-CE85-404D-B085-B901D4426A5D"
        ))
        let tabID = try XCTUnwrap(UUID(
            uuidString: "3AE6D421-6413-4673-B2FC-598BAF5A4A2E"
        ))
        let routeID = try XCTUnwrap(UUID(
            uuidString: "07763D63-F30A-4AE0-BF66-527D68C3DFC4"
        ))
        let expected = ScenePayload.terminal(TerminalWindowRoute(
            id: routeID,
            tabs: [TerminalRoute(
                id: tabID,
                hostID: hostID,
                mode: .attach(sessionName: "main")
            )],
            activeTabID: tabID
        ))
        XCTAssertEqual(SceneActivityCodec.payload(from: activity), expected)

        // Saved-state archives can carry either value key depending on which
        // lifecycle edge wrote them; the activity type is the same one every
        // real archive uses.
        var savedOnly = activity.userInfo ?? [:]
        savedOnly.removeValue(forKey: SceneActivityCodec.legacyPresentedSceneValueKey)
        let savedActivity = NSUserActivity(
            activityType: SceneActivityCodec.legacyStateRestorationActivityType
        )
        savedActivity.addUserInfoEntries(from: savedOnly)
        XCTAssertEqual(SceneActivityCodec.payload(from: savedActivity), expected)
    }

    func testLegacySessionUserInfoStandsInForADelayedRestorationActivity() throws {
        let route = TerminalWindowRoute(tab: TerminalRoute(
            hostID: UUID(),
            mode: .attach(sessionName: "main")
        ))
        let userInfo: [String: Any] = [
            SceneActivityCodec.legacySceneIDKey: "terminal",
            SceneActivityCodec.legacySceneValueKey: try JSONEncoder().encode(route),
            // A real session also carries keys this app knows nothing about.
            "com.apple.SwiftUI.sceneTypeHash": 12_345,
        ]
        let activity = try XCTUnwrap(
            SceneActivityCodec.legacySessionActivity(from: userInfo)
        )
        XCTAssertEqual(
            activity.activityType,
            SceneActivityCodec.legacyStateRestorationActivityType
        )
        XCTAssertEqual(SceneActivityCodec.payload(from: activity), .terminal(route))

        // Nothing to decode is not a scene: an ID with no value, a session
        // that never was SwiftUI's, and no userInfo at all all decline.
        XCTAssertNil(SceneActivityCodec.legacySessionActivity(from: [
            SceneActivityCodec.legacySceneIDKey: "terminal",
        ]))
        XCTAssertNil(SceneActivityCodec.legacySessionActivity(from: [
            "unrelated": "value",
        ]))
        XCTAssertNil(SceneActivityCodec.legacySessionActivity(from: nil))
    }

    func testCapturedSwiftUIDeckValueMigrates() {
        let activity = NSUserActivity(
            activityType: SceneActivityCodec.legacyStateRestorationActivityType
        )
        activity.addUserInfoEntries(from: [
            SceneActivityCodec.legacySceneIDKey: "deck",
            SceneActivityCodec.legacyPresentedSceneValueKey: Data("\"main\"".utf8),
        ])
        XCTAssertEqual(SceneActivityCodec.payload(from: activity), .deck(.main))
    }

    func testLegacyDecoderFallsBackToSavedValueWhenPresentedValueIsCorrupt() throws {
        let route = TerminalWindowRoute(tab: TerminalRoute(
            hostID: UUID(),
            mode: .attach(sessionName: "main")
        ))
        let activity = NSUserActivity(
            activityType: SceneActivityCodec.legacyStateRestorationActivityType
        )
        activity.addUserInfoEntries(from: [
            SceneActivityCodec.legacySceneIDKey: "terminal",
            SceneActivityCodec.legacyPresentedSceneValueKey: Data([0xFF]),
            SceneActivityCodec.legacySceneValueKey: try JSONEncoder().encode(route),
        ])

        XCTAssertEqual(SceneActivityCodec.payload(from: activity), .terminal(route))
    }

    func testOnlyNewSceneActivationCarriesTheEphemeralGeometryMarker() throws {
        let payload = ScenePayload.deck(.main)
        let persisted = try SceneActivityCodec.makeActivity(for: payload)
        let creation = try SceneActivityCodec.makeActivity(
            for: payload,
            newSceneRequest: true
        )

        XCTAssertFalse(SceneActivityCodec.requestsInitialGeometry(persisted))
        XCTAssertTrue(SceneActivityCodec.requestsInitialGeometry(creation))
        XCTAssertEqual(SceneActivityCodec.payload(from: creation), payload)
        XCTAssertFalse(
            persisted.requiredUserInfoKeys?.contains(
                SceneActivityCodec.newSceneRequestKey
            ) ?? false
        )
        XCTAssertTrue(
            creation.requiredUserInfoKeys?.contains(
                SceneActivityCodec.newSceneRequestKey
            ) ?? false,
            "UIKit must load the ephemeral marker with the activation payload"
        )
    }

    func testActivityMetadataIsStable() throws {
        let deck = try SceneActivityCodec.makeActivity(for: .deck(.main))
        XCTAssertEqual(
            SceneActivityCodec.activityType,
            "app.multiplexterm.multiplex.scene"
        )
        XCTAssertEqual(deck.activityType, SceneActivityCodec.activityType)
        XCTAssertEqual(deck.title, "Multiplex Deck")
        XCTAssertEqual(deck.targetContentIdentifier, "deck/main")
        XCTAssertEqual(
            deck.requiredUserInfoKeys,
            Set([
                SceneActivityCodec.schemaVersionKey,
                SceneActivityCodec.payloadKey,
            ])
        )
        XCTAssertEqual(
            deck.userInfo?[SceneActivityCodec.schemaVersionKey] as? Int,
            SceneActivityCodec.schemaVersion
        )
        XCTAssertFalse(deck.isEligibleForHandoff)
        XCTAssertFalse(deck.isEligibleForSearch)
        XCTAssertFalse(deck.isEligibleForPublicIndexing)

        let routeID = UUID(uuidString: "901CA51B-76CB-4D15-A09A-50B3AC638B31")!
        let terminal = try SceneActivityCodec.makeActivity(for: .terminal(
            TerminalWindowRoute(id: routeID, tabs: [])
        ))
        XCTAssertEqual(terminal.title, "Multiplex Terminal")
        XCTAssertEqual(
            terminal.targetContentIdentifier,
            "terminal/901ca51b-76cb-4d15-a09a-50b3ac638b31"
        )
    }

    private func activity(payloadData: Data) -> NSUserActivity {
        let activity = NSUserActivity(activityType: SceneActivityCodec.activityType)
        activity.addUserInfoEntries(from: [
            SceneActivityCodec.schemaVersionKey: SceneActivityCodec.schemaVersion,
            SceneActivityCodec.payloadKey: payloadData,
        ])
        return activity
    }
}
