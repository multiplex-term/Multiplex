import Foundation

/// What the deck cares about in one `NWPath` update: whether the route is
/// usable at all, and which interfaces/gateways carry it. Interface or
/// gateway churn is what severs established TCP links — a same-shape update
/// (signal strength, expense) never does.
struct NetworkPathSnapshot: Equatable {
    var isSatisfied: Bool
    /// Sorted interface names (`en0`, `pdp_ip0`, `utun3`) — catches
    /// Wi-Fi ↔ cellular moves and VPN toggles.
    var interfaces: [String]
    /// Sorted gateway endpoints — catches switching between Wi-Fi networks
    /// that keep the same interface name.
    var gateways: [String]
}

/// Decides whether a path update warrants rebuilding the deck's control
/// connections. Pure: the `NWPathMonitor` plumbing lives in
/// `NetworkChangeMonitor`, this only compares snapshots.
struct NetworkChangeDetector {
    private var last: NetworkPathSnapshot?

    /// Record `snapshot` and report whether it should trigger a reconnect.
    /// The first snapshot is the baseline, never a change. An unsatisfied
    /// path records (so connectivity returning to the *same* network still
    /// reads as a change) but never fires — there is nothing to reconnect
    /// to, and the attempts would only feed retry backoff.
    mutating func register(_ snapshot: NetworkPathSnapshot) -> Bool {
        defer { last = snapshot }
        guard let last else { return false }
        guard snapshot.isSatisfied else { return false }
        return snapshot != last
    }
}
