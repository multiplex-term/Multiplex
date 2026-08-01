import Foundation

/// Identity of the long-lived wall feed. It uses the same normalized host
/// configuration as `ConnectionHub`: whenever the hub replaces a stale model,
/// this changes too, cancelling the old feed and starting one for the new
/// model. Helper-command-only edits intentionally keep the existing feed.
struct FleetFeedID: Hashable {
    private let hostConfigurations: [Host]
    private let active: Bool

    init(hosts: [Host], active: Bool) {
        hostConfigurations = hosts.map(\.connectionModelConfiguration)
        self.active = active
    }
}
