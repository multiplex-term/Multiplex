import Foundation

/// Pure three-way merge between the local host list and the host records
/// mirrored in the iCloud-synced Keychain.
///
/// `mirrored` is the set of host IDs this device knows made it into the
/// mirror at some point. It is what disambiguates the two reasons a local
/// host can be missing from the cloud: never published (→ push it) versus
/// deleted by a peer device (→ drop it locally). Synchronizable Keychain
/// items are always readable locally regardless of upload state, so "absent
/// from the mirror but previously mirrored" can only mean deletion.
enum HostSync {
    struct Resolution: Equatable {
        /// The merged list: local order preserved, hosts adopted from other
        /// devices appended (sorted by name for determinism).
        var hosts: [Host] = []
        /// Records the mirror is missing or holds older copies of.
        var toPush: [Host] = []
        /// Local entries dropped because a peer deleted them.
        var removedIDs: Set<UUID> = []
    }

    static func merge(local: [Host], cloud: [Host], mirrored: Set<UUID>) -> Resolution {
        let cloudByID = Dictionary(cloud.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolution = Resolution()

        for host in local {
            if let remote = cloudByID[host.id] {
                if host.updatedAt > remote.updatedAt {
                    resolution.hosts.append(host)
                    resolution.toPush.append(host)
                } else {
                    resolution.hosts.append(remote)
                }
            } else if mirrored.contains(host.id) {
                resolution.removedIDs.insert(host.id)
            } else {
                resolution.hosts.append(host)
                resolution.toPush.append(host)
            }
        }

        let localIDs = Set(local.map(\.id))
        let adopted = cloud
            .filter { !localIDs.contains($0.id) }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        resolution.hosts.append(contentsOf: adopted)
        return resolution
    }
}
