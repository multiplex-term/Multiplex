import CoreGraphics
import Foundation

/// Pure decision made once when a UIKit scene connects. It replaces the
/// former SwiftUI `SceneShellGate` and keeps the classic/shell split directly
/// testable without constructing a private `UISceneSession`.
enum UIKitScenePresentationPlan: Equatable {
    case deck
    case terminal(TerminalWindowRoute)
    case shell(TerminalWindowRoute)

    static func resolve(
        payload: ScenePayload,
        platform: ShellModeDecision.Platform,
        idiom: ShellModeDecision.Idiom,
        isFullScreen: Bool,
        environmentOverride: String?
    ) -> Self {
        let usesShell = ShellModeDecision.usesSingleWindowShell(
            platform: platform,
            idiom: idiom,
            isFullScreen: isFullScreen,
            environmentOverride: environmentOverride
        )
        if usesShell {
            switch payload {
            case .deck:
                return .shell(TerminalWindowRoute(tabs: []))
            case .terminal(let route):
                return .shell(route)
            }
        }
        switch payload {
        case .deck:
            return .deck
        case .terminal(let route):
            return .terminal(route)
        }
    }
}

/// Connection-time route precedence. Explicit activation wins over restored
/// state; a value-less first scene is the singleton deck. Sorting the decoded
/// activation set makes malformed multi-activity launches deterministic.
enum UIKitScenePayloadResolver {
    enum Source: Equatable {
        case activation
        case restoration
        case defaultDeck
    }

    struct Resolution: Equatable {
        var payload: ScenePayload
        var source: Source
        var requestsInitialGeometry: Bool
    }

    static func resolve(
        activationActivities: [NSUserActivity],
        restorationActivity: NSUserActivity?
    ) -> ScenePayload {
        resolution(
            activationActivities: activationActivities,
            restorationActivity: restorationActivity
        ).payload
    }

    static func resolution(
        activationActivities: [NSUserActivity],
        restorationActivity: NSUserActivity?
    ) -> Resolution {
        let activation = activationActivities
            .compactMap { activity -> (String, ScenePayload, Bool)? in
                guard let payload = SceneActivityCodec.payload(from: activity)
                else { return nil }
                return (
                    activationSortKey(activity: activity, payload: payload),
                    payload,
                    SceneActivityCodec.requestsInitialGeometry(activity)
                )
            }
            .sorted { $0.0 < $1.0 }
            .first
        if let activation {
            return Resolution(
                payload: activation.1,
                source: .activation,
                requestsInitialGeometry: activation.2
            )
        }
        if let restoration = restorationActivity.flatMap(SceneActivityCodec.payload(from:)) {
            return Resolution(
                payload: restoration,
                source: .restoration,
                requestsInitialGeometry: false
            )
        }
        return Resolution(
            payload: .deck(.main),
            source: .defaultDeck,
            requestsInitialGeometry: false
        )
    }

    private static func activationSortKey(
        activity: NSUserActivity,
        payload: ScenePayload
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(payload))?.base64EncodedString() ?? ""
        let identifier = activity.targetContentIdentifier.flatMap {
            $0.isEmpty ? nil : $0
        }
        let marker = SceneActivityCodec.requestsInitialGeometry(activity) ? "1" : "0"
        // A target identifier is only the primary key. UIKit hands activation
        // activities to us as a Set, so the activity type, canonical payload,
        // and ephemeral geometry marker must break ties as well.
        return [
            identifier == nil ? "1" : "0",
            identifier ?? "",
            activity.activityType,
            encoded,
            marker,
        ].joined(separator: "\u{0}")
    }
}

/// Raising an existing scene with the value it already owns must only bring
/// that scene forward. Rebuilding would tear down live deck probes, sheets,
/// and terminal state even though no route changed.
enum UIKitSceneContentReplacementPolicy {
    static func requiresReplacement(
        current: ScenePayload,
        incoming: ScenePayload
    ) -> Bool {
        current != incoming
    }
}

/// UIKit may withhold a session's restoration activity until after
/// `willConnect`. This phase prevents a provisional deck from overwriting a
/// delayed terminal route and preserves explicit-activation precedence when
/// UIKit subsequently offers the older restored activity.
enum UIKitSceneConnectionPhase: Equatable {
    case awaitingRestoration
    case activation
    case restoration
    case freshDefault

    static func initial(
        resolution: UIKitScenePayloadResolver.Resolution,
        restorationActivityWasSupplied: Bool
    ) -> Self {
        switch resolution.source {
        case .activation:
            return .activation
        case .restoration:
            return .restoration
        case .defaultDeck:
            return restorationActivityWasSupplied
                ? .restoration
                : .awaitingRestoration
        }
    }

    var acceptsInitialRestorationCallback: Bool {
        switch self {
        case .awaitingRestoration, .restoration: true
        case .activation, .freshDefault: false
        }
    }

    var persistsImmediately: Bool {
        self != .awaitingRestoration
    }
}

/// URL contexts can arrive before UIKit supplies a delayed restoration
/// activity. Hold them until the real scene content exists so an inert
/// placeholder cannot acknowledge work that only a Deck can execute.
struct UIKitSceneURLBuffer {
    private(set) var deferred: [URL] = []

    mutating func accept(
        _ urls: [URL],
        phase: UIKitSceneConnectionPhase
    ) -> [URL] {
        guard phase != .awaitingRestoration else {
            deferred.append(contentsOf: urls)
            return []
        }
        return urls
    }

    mutating func release(
        phase: UIKitSceneConnectionPhase
    ) -> [URL] {
        guard phase != .awaitingRestoration else { return [] }
        let ready = deferred
        deferred.removeAll(keepingCapacity: false)
        return ready
    }
}

/// A UISceneSession persists the delegate class that originally created it.
/// After an in-place upgrade from the former SwiftUI lifecycle, UIKit can
/// therefore reconnect `SwiftUI.AppSceneDelegate` even though the executable
/// now has a UIKit `@main`, producing a permanently empty scene. The app
/// delegate uses this pure policy to adopt only those legacy live scenes with
/// a native delegate while every newly created session uses the manifest's
/// UIKit configuration.
enum UIKitLegacySceneMigrationPolicy {
    static let swiftUIDelegateClassName = "SwiftUI.AppSceneDelegate"

    static func requiresAdoption(
        configuredDelegateClassName: String?,
        liveDelegateClassName: String?,
        restorationActivity: NSUserActivity?
    ) -> Bool {
        if configuredDelegateClassName == swiftUIDelegateClassName
            || liveDelegateClassName == swiftUIDelegateClassName {
            return true
        }
        return configuredDelegateClassName == nil
            && liveDelegateClassName == nil
            && restorationActivity?.activityType
                == SceneActivityCodec.legacyStateRestorationActivityType
    }
}

/// The former SwiftUI scene defaults, now shared by UIKit geometry setup and
/// pure tests. Environment overrides remain DEBUG-only at the call site.
enum UIKitSceneGeometryPolicy {
    static let deckDefault = CGSize(width: 1_160, height: 524)
    static let terminalDefault = CGSize(width: 1_120, height: 700)

    static func preferredSize(
        for payload: ScenePayload,
        environment: [String: String]
    ) -> CGSize {
        let key: String
        let fallback: CGSize
        switch payload {
        case .deck:
            key = "MULTIPLEX_DECK_SIZE"
            fallback = deckDefault
        case .terminal:
            key = "MULTIPLEX_TERM_SIZE"
            fallback = terminalDefault
        }
        return environment[key].flatMap(parseSize) ?? fallback
    }

    static func parseSize(_ raw: String) -> CGSize? {
        let parts = raw.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0,
              width.isFinite,
              height.isFinite
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
