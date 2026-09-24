import CoreGraphics
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

    /// Every shipped SwiftUI scene session carries its scene ID and value in
    /// `UISceneSession.userInfo` as well, and that slot is populated the
    /// moment the session exists. UIKit warns that `stateRestorationActivity`
    /// "may not be immediately available when the scene is connected", so this
    /// reads the same legacy envelope from the slot that always answers — the
    /// difference between an adopted legacy window coming back as itself and
    /// coming back as an inert placeholder waiting for a callback.
    static func legacySessionActivity(
        from userInfo: [String: Any]?
    ) -> NSUserActivity? {
        guard let userInfo,
              let sceneID = userInfo[legacySceneIDKey] as? String
        else { return nil }
        var entries: [AnyHashable: Any] = [legacySceneIDKey: sceneID]
        if let presented = userInfo[legacyPresentedSceneValueKey] as? Data {
            entries[legacyPresentedSceneValueKey] = presented
        }
        if let value = userInfo[legacySceneValueKey] as? Data {
            entries[legacySceneValueKey] = value
        }
        guard entries.count > 1 else { return nil }
        let activity = NSUserActivity(
            activityType: legacyStateRestorationActivityType
        )
        activity.addUserInfoEntries(from: entries)
        return activity
    }

    private static func legacyPayload(from activity: NSUserActivity) -> ScenePayload? {
        guard activity.activityType == legacyStateRestorationActivityType,
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

/// The kind of window a payload opens, which is the grain visionOS window
/// geometry is remembered at — a deck and a terminal are sized for different
/// jobs, while two terminals are the same kind of window.
enum SceneGeometryKind: String, CaseIterable {
    case deck
    case terminal

    init(_ payload: ScenePayload) {
        switch payload {
        case .deck: self = .deck
        case .terminal: self = .terminal
        }
    }

    /// The DEBUG-only size override a headless screenshot run passes. These
    /// are the same keys `UIKitSceneGeometryPolicy.preferredSize` reads; the
    /// pair is pinned together by a unit test so the two cannot drift.
    var debugSizeEnvironmentKey: String {
        switch self {
        case .deck: "MULTIPLEX_DECK_SIZE"
        case .terminal: "MULTIPLEX_TERM_SIZE"
        }
    }

    fileprivate var lastSizeStorageKey: String { "scene.lastSize.\(rawValue)" }
}

/// Pure `.defaultSize` parity for the UIKit port.
///
/// The shipped visionOS scenes were SwiftUI `WindowGroup`s carrying
/// `.defaultSize`, which is advisory: visionOS remembers the size a person
/// resized a window group's window to and opens the *next* window of that
/// group at it, falling back to the declared default only when it has nothing
/// better. UIKit asks for geometry imperatively, on every scene it creates, so
/// the same question has to be answered here — otherwise a terminal resized to
/// 1600×1000 snaps every later terminal back to the authored default.
enum SceneGeometryPolicy {
    /// A size is only worth remembering while it could plausibly be a window
    /// someone left that way. A scene sampled mid-teardown (or before its
    /// window has laid out) reports zero, and that must never become the size
    /// the next window opens at.
    static let minimumRecordableEdge: CGFloat = 200

    static func isRecordable(_ size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width >= minimumRecordableEdge
            && size.height >= minimumRecordableEdge
    }

    /// Order of authority: a DEBUG override is what a screenshot run
    /// explicitly asked for, then what a window of this kind was last left
    /// at, then the authored default.
    static func chooseInitialSize(
        environmentOverride: CGSize?,
        remembered: CGSize?,
        default fallback: CGSize
    ) -> CGSize {
        if let environmentOverride { return environmentOverride }
        if let remembered, isRecordable(remembered) { return remembered }
        return fallback
    }
}

/// Device-local memory of the size a window of each kind was last seen at.
/// Window geometry belongs to the device it was sized on — never the synced
/// host records, never the widget projection.
struct SceneWindowSizeStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastSize(for kind: SceneGeometryKind) -> CGSize? {
        let key = kind.lastSizeStorageKey
        guard let stored = defaults.array(forKey: key) as? [Double],
              stored.count == 2
        else { return nil }
        let size = CGSize(width: stored[0], height: stored[1])
        return SceneGeometryPolicy.isRecordable(size) ? size : nil
    }

    func record(_ size: CGSize, for kind: SceneGeometryKind) {
        guard SceneGeometryPolicy.isRecordable(size),
              lastSize(for: kind) != size
        else { return }
        defaults.set(
            [Double(size.width), Double(size.height)],
            forKey: kind.lastSizeStorageKey
        )
    }
}
