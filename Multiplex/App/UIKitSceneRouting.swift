import OSLog
import UIKit

/// A serializable scene-routing decision. Keeping the choice separate from
/// UIApplication makes the singleton-deck rule and new-terminal rule fully
/// testable without manufacturing private UISceneSession instances.
enum UIKitSceneActivationPlan: Equatable {
    struct ConnectedScene: Equatable {
        let persistentIdentifier: String
        let payload: ScenePayload?
    }

    case activateExisting(
        persistentIdentifier: String,
        payload: ScenePayload
    )
    case create(ScenePayload)
    case destroyCurrent(persistentIdentifier: String)
    case unavailable

    static func resolve(
        _ intent: SceneWindowRouting.Intent,
        connectedScenes: [ConnectedScene],
        currentPersistentIdentifier: String?
    ) -> Self {
        switch intent {
        case .openDeck(let route):
            let payload = ScenePayload.deck(route)
            if let deck = connectedScenes
                .filter({
                    guard case .deck = $0.payload else { return false }
                    return true
                })
                .sorted(by: {
                    $0.persistentIdentifier < $1.persistentIdentifier
                })
                .first
            {
                return .activateExisting(
                    persistentIdentifier: deck.persistentIdentifier,
                    payload: payload
                )
            }
            return .create(payload)

        case .openTerminal(let route):
            // Every attach/split creates a distinct spatial terminal. A route
            // ID identifies its restoration value, not a singleton scene.
            return .create(.terminal(route))

        case .closeCurrentScene:
            guard let currentPersistentIdentifier else { return .unavailable }
            return .destroyCurrent(
                persistentIdentifier: currentPersistentIdentifier
            )
        }
    }
}

/// UIKit implementation of `SceneWindowRouting`. The scene coordinator owns
/// one executor and passes its framework-neutral `routing` value into native
/// deck/terminal controllers. Opening the deck targets its existing session;
/// terminal routes always request a new session. Every activation carries the
/// same versioned NSUserActivity used for state restoration.
@MainActor
final class UIKitSceneRouter {
    typealias SessionProvider = () -> Set<UISceneSession>
    typealias Activator = (UISceneSessionActivationRequest) -> Void
    typealias Destroyer = (UISceneSession) -> Void

    private weak var scene: UIWindowScene?
    private let supportsMultipleWindows: Bool
    private let sessions: SessionProvider
    private let activate: Activator
    private let destroy: Destroyer

    init(
        scene: UIWindowScene,
        supportsMultipleWindows: Bool,
        sessions: @escaping SessionProvider,
        activate: @escaping Activator,
        destroy: @escaping Destroyer
    ) {
        self.scene = scene
        self.supportsMultipleWindows = supportsMultipleWindows
        self.sessions = sessions
        self.activate = activate
        self.destroy = destroy
    }

    convenience init(scene: UIWindowScene) {
        self.init(
            scene: scene,
            supportsMultipleWindows: UIApplication.shared.supportsMultipleScenes,
            sessions: { UIApplication.shared.openSessions },
            activate: { request in
                UIApplication.shared.activateSceneSession(for: request) { error in
                    Self.logger.error(
                        "scene activation failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            },
            destroy: { session in
                UIApplication.shared.requestSceneSessionDestruction(
                    session,
                    options: nil
                ) { error in
                    Self.logger.error(
                        "scene destruction failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        )
    }

    var routing: SceneWindowRouting {
        SceneWindowRouting(
            supportsMultipleWindows: supportsMultipleWindows,
            perform: { [weak self] intent in self?.perform(intent) }
        )
    }

    func perform(_ intent: SceneWindowRouting.Intent) {
        let openSessions = sessions()
        let records = openSessions.map {
            UIKitSceneActivationPlan.ConnectedScene(
                persistentIdentifier: $0.persistentIdentifier,
                payload: $0.stateRestorationActivity.flatMap(
                    SceneActivityCodec.payload(from:)
                )
            )
        }
        let plan = UIKitSceneActivationPlan.resolve(
            intent,
            connectedScenes: records,
            currentPersistentIdentifier: scene?.session.persistentIdentifier
        )
        execute(plan, sessions: openSessions)
    }

    private func execute(
        _ plan: UIKitSceneActivationPlan,
        sessions openSessions: Set<UISceneSession>
    ) {
        switch plan {
        case .activateExisting(let identifier, let payload):
            guard let session = openSessions.first(where: {
                $0.persistentIdentifier == identifier
            }) else {
                requestNewScene(payload)
                return
            }
            let activity = try? SceneActivityCodec.makeActivity(for: payload)
            activate(UISceneSessionActivationRequest(
                session: session,
                userActivity: activity
            ))

        case .create(let payload):
            requestNewScene(payload)

        case .destroyCurrent(let identifier):
            guard let session = openSessions.first(where: {
                $0.persistentIdentifier == identifier
            }) ?? scene?.session else { return }
            destroy(session)

        case .unavailable:
            break
        }
    }

    private func requestNewScene(_ payload: ScenePayload) {
        do {
            let activity = try SceneActivityCodec.makeActivity(
                for: payload,
                newSceneRequest: true
            )
            activate(UISceneSessionActivationRequest(
                role: .windowApplication,
                userActivity: activity
            ))
        } catch {
            Self.logger.error(
                "scene payload encoding failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "scenes"
    )
}
