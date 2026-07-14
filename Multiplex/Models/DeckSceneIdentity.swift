import Foundation

/// The deck is the app's one fleet-wide monitor wall. Giving its iPad
/// `WindowGroup` a stable data value lets `openWindow(id:value:)` reactivate
/// the existing window instead of minting another one.
enum DeckWindowRoute: String, Codable, Hashable {
    case main
}

/// Pure ownership bookkeeping for scene types that allow only one live
/// session. The owner is weak so closing that scene immediately lets the next
/// session claim ownership; matching IDs refresh a reconstituted session.
struct SingletonSceneRegistry<Session: AnyObject, ID: Hashable> {
    enum Registration: Equatable {
        case primary
        case duplicate
    }

    private(set) weak var primary: Session?
    private var primaryID: ID?

    mutating func register(_ candidate: Session, id: ID) -> Registration {
        if primary == nil {
            primaryID = nil
        }

        if let primaryID {
            guard primaryID == id else { return .duplicate }
            primary = candidate
            return .primary
        }

        primary = candidate
        primaryID = id
        return .primary
    }
}
