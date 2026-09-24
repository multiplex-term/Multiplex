import Foundation

/// The Key Commands mirror's merge rule, pure so it is assertable without a
/// store: last writer wins by `updatedAt`, ties keep the local set, and a
/// mirror that is older (or missing while a local set exists) is republished
/// from here. `HostSync` is the same idea for the host list.
enum KeyCommandSync {
    struct Resolution: Equatable {
        /// The set the device should hold after the merge.
        var set: KeyCommandSet
        /// The local file must be rewritten (a peer's newer set was adopted).
        var shouldPersist: Bool
        /// The mirror must be rewritten (it is older than, or missing behind,
        /// a local set that has been edited).
        var shouldPush: Bool
    }

    static func merge(local: KeyCommandSet, cloud: KeyCommandSet?) -> Resolution {
        guard let cloud else {
            return Resolution(
                set: local,
                shouldPersist: false,
                shouldPush: local.updatedAt != .distantPast
            )
        }
        if cloud.updatedAt > local.updatedAt {
            return Resolution(
                set: KeyCommandSet(
                    commands: KeyCommandSet.normalized(cloud.commands),
                    updatedAt: cloud.updatedAt
                ),
                shouldPersist: true,
                shouldPush: false
            )
        }
        return Resolution(
            set: local,
            shouldPersist: false,
            shouldPush: cloud.updatedAt < local.updatedAt
        )
    }
}
