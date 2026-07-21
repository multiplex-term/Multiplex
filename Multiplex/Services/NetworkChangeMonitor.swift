import Foundation
import Network
import Observation

/// Watches the device's network path and turns meaningful changes (Wi-Fi ↔
/// cellular, VPN toggles, a different Wi-Fi network, connectivity returning)
/// into deck reconnect triggers. The deck's SSH control links are bound to
/// the old path's sockets — after a change they are black-holed at worst and
/// stale at best, so without this the wall burns a whole exec deadline per
/// host discovering it and failed hosts wait out their retry backoff.
@MainActor
@Observable
final class NetworkChangeMonitor {
    /// Advances once per settled, meaningful path change while watching.
    /// The deck observes this edge and rebuilds its control connections.
    private(set) var reconnectRevision = 0
    /// The device itself has no usable route (Wi-Fi off, airplane mode) —
    /// distinct from a host being unreachable. The rail shows OFFLINE over
    /// every per-host phase while this holds: a stale CONNECTED would
    /// otherwise survive until a probe burns its exec deadline, and the
    /// failure it settles into blames the host for a device-side condition.
    /// Debounced by the same settle delay as reconnects, so an interface
    /// handoff that passes through unsatisfied never flashes it. Clearing
    /// is immediate — a usable route is instant truth.
    private(set) var isOffline = false

    @ObservationIgnored private var detector = NetworkChangeDetector()
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var offlineTask: Task<Void, Never>?
    @ObservationIgnored private let queue = DispatchQueue(
        label: "app.multiplexterm.multiplex.network-change",
        qos: .utility
    )

    /// Interface transitions arrive as a burst of intermediate paths (Wi-Fi
    /// drops, cellular joins, then routes settle). Reconnect once after the
    /// burst goes quiet, not once per update.
    private static let settleDelay: Duration = .milliseconds(600)

    func begin() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkPathSnapshot(
                isSatisfied: path.status == .satisfied,
                interfaces: path.availableInterfaces.map(\.name).sorted(),
                gateways: path.gateways.map { "\($0)" }.sorted()
            )
            Task { @MainActor [weak self] in
                self?.register(snapshot)
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    /// Stop watching while the deck is inactive — same policy as
    /// `LocalNetworkAccessMonitor.suspend`. Detector state deliberately
    /// survives: resuming compares the current path against the pre-suspend
    /// one, so a network that changed while backgrounded still triggers one
    /// reconnect the moment the deck returns.
    func suspend() {
        monitor?.cancel()
        monitor = nil
        settleTask?.cancel()
        settleTask = nil
        offlineTask?.cancel()
        offlineTask = nil
    }

    private func register(_ snapshot: NetworkPathSnapshot) {
        // A cancelled monitor's queue can still deliver a late update.
        guard monitor != nil else { return }
        if snapshot.isSatisfied {
            offlineTask?.cancel()
            offlineTask = nil
            if isOffline { isOffline = false }
        } else if !isOffline, offlineTask == nil {
            // First unsatisfied update starts the clock; repeats while it
            // runs must not push the deadline out.
            offlineTask = Task { [weak self] in
                do { try await Task.sleep(for: Self.settleDelay) }
                catch { return }
                guard let self, self.monitor != nil else { return }
                self.offlineTask = nil
                self.isOffline = true
            }
        }
        guard detector.register(snapshot) else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.settleDelay) }
            catch { return }
            guard let self, self.monitor != nil else { return }
            self.settleTask = nil
            self.reconnectRevision &+= 1
        }
    }
}
