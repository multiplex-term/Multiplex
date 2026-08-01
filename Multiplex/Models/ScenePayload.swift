import Foundation

/// Restorable identity and value for one application window. This is kept
/// independent of either SwiftUI's `WindowGroup` encoding or UIKit's scene
/// delegate so both lifecycles can hand off the same route during migration.
enum ScenePayload: Codable, Hashable {
    case deck(DeckWindowRoute)
    case terminal(TerminalWindowRoute)

    private enum Kind: String, Codable {
        case deck
        case terminal
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case deckRoute
        case terminalRoute
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .deck:
            self = .deck(try container.decode(
                DeckWindowRoute.self,
                forKey: .deckRoute
            ))
        case .terminal:
            self = .terminal(try container.decode(
                TerminalWindowRoute.self,
                forKey: .terminalRoute
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .deck(let route):
            try container.encode(Kind.deck, forKey: .kind)
            try container.encode(route, forKey: .deckRoute)
        case .terminal(let route):
            try container.encode(Kind.terminal, forKey: .kind)
            try container.encode(route, forKey: .terminalRoute)
        }
    }

    fileprivate var activityTitle: String {
        switch self {
        case .deck: "Multiplex Deck"
        case .terminal: "Multiplex Terminal"
        }
    }

    fileprivate var targetContentIdentifier: String {
        switch self {
        case .deck(let route):
            "deck/\(route.rawValue)"
        case .terminal(let route):
            "terminal/\(route.id.uuidString.lowercased())"
        }
    }
}

/// Versioned NSUserActivity envelope for future UIKit scene activation and
/// restoration. Only property-list values cross the activity boundary; the
/// route itself remains one JSON blob so schema failures reject the complete
/// payload rather than partially restoring a window.
enum SceneActivityCodec {
    static let activityType = "app.multiplexterm.multiplex.scene"
    static let schemaVersion = 1
    static let schemaVersionKey = "sceneSchemaVersion"
    static let payloadKey = "scenePayload"
    /// Ephemeral activation metadata. Only requests that create a brand-new
    /// scene carry it; persisted activities and activations of existing
    /// sessions omit it so user-resized vision windows are never reset.
    static let newSceneRequestKey = "sceneRequestsInitialGeometry"
    /// SwiftUI's shipping `WindowGroup(id:for:)` envelope. The scene-type
    /// hash is compiler-private and deliberately ignored; the stable scene ID
    /// plus the app's Codable route bytes are the migration boundary.
    static let legacyStateRestorationActivityType = "com.apple.SwiftUI.stateRestoration"
    static let legacyOpenWindowActivityType =
        "app.multiplexterm.multiplex.openWindowByID"
    static let legacySceneIDKey = "com.apple.SwiftUI.sceneID"
    static let legacySceneValueKey = "com.apple.SwiftUI.sceneValue"
    static let legacyPresentedSceneValueKey =
        "com.apple.SwiftUI.presentedSceneValue"

    static func makeActivity(
        for payload: ScenePayload,
        newSceneRequest: Bool = false
    ) throws -> NSUserActivity {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)

        let activity = NSUserActivity(activityType: activityType)
        activity.title = payload.activityTitle
        activity.targetContentIdentifier = payload.targetContentIdentifier
        var requiredKeys = Set([schemaVersionKey, payloadKey])
        var userInfo: [AnyHashable: Any] = [
            schemaVersionKey: schemaVersion,
            payloadKey: data,
        ]
        if newSceneRequest {
            userInfo[newSceneRequestKey] = true
            requiredKeys.insert(newSceneRequestKey)
        }
        activity.requiredUserInfoKeys = requiredKeys
        activity.addUserInfoEntries(from: userInfo)
        // This object is private scene restoration state, not searchable or
        // transferable content. Activation targets the local scene session.
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        return activity
    }

    static func payload(from activity: NSUserActivity) -> ScenePayload? {
        if activity.activityType == activityType,
           let userInfo = activity.userInfo,
           userInfo[schemaVersionKey] as? Int == schemaVersion,
           let data = userInfo[payloadKey] as? Data {
            return try? JSONDecoder().decode(ScenePayload.self, from: data)
        }
        return legacyPayload(from: activity)
    }

    static func requestsInitialGeometry(_ activity: NSUserActivity) -> Bool {
        activity.activityType == activityType
            && activity.userInfo?[newSceneRequestKey] as? Bool == true
    }

    private static func legacyPayload(from activity: NSUserActivity) -> ScenePayload? {
        guard activity.activityType == legacyStateRestorationActivityType
                || activity.activityType == legacyOpenWindowActivityType,
              let userInfo = activity.userInfo,
              let sceneID = userInfo[legacySceneIDKey] as? String
        else { return nil }

        let decoder = JSONDecoder()
        let candidates = [
            userInfo[legacyPresentedSceneValueKey] as? Data,
            userInfo[legacySceneValueKey] as? Data,
        ].compactMap { $0 }
        for data in candidates {
            switch sceneID {
            case "deck":
                if let route = try? decoder.decode(DeckWindowRoute.self, from: data) {
                    return .deck(route)
                }
            case "terminal":
                if let route = try? decoder.decode(
                    TerminalWindowRoute.self,
                    from: data
                ) {
                    return .terminal(route)
                }
            default:
                return nil
            }
        }
        return nil
    }
}
