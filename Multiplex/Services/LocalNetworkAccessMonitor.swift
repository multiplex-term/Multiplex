import Foundation
import Network
import Observation

/// The small, pure state machine behind `LocalNetworkAccessMonitor`.
/// A successful probe only clears a denial when it is for the same host that
/// produced it: a public Internet host can remain reachable while Local
/// Network access is disabled.
struct LocalNetworkPermissionState: Equatable {
    private(set) var deniedHostID: UUID?

    var isDenied: Bool { deniedHostID != nil }

    mutating func retainConfiguredHosts(_ hostIDs: Set<UUID>) {
        guard let deniedHostID, !hostIDs.contains(deniedHostID) else { return }
        self.deniedHostID = nil
    }

    mutating func recordDenied(hostID: UUID) {
        deniedHostID = hostID
    }

    mutating func recordReady(hostID: UUID) {
        guard deniedHostID == hostID else { return }
        deniedHostID = nil
    }
}

/// Checks the routes to configured hosts for the OS's authoritative Local
/// Network privacy failure. There is no general authorization-status API;
/// Network framework exposes a denial on a connection's path instead.
///
/// UDP is deliberate: connecting a UDP socket is a local-network operation,
/// but no payload or SSH connection reaches the host. A public/VPN route can
/// become ready without proving anything about Local Network permission, so
/// only the exact host that reported a denial is allowed to clear it later.
///
/// A denial is never surfaced from a single path report: iOS reports
/// `.localNetworkDenied` transiently while a connection establishes — and for
/// the whole time the system permission prompt is pending — even when access
/// is (or ends up) granted. Each report only arms a confirmation delay; the
/// denial commits when the connection's live path still says denied after the
/// grace period, and a probe reaching `.ready` first disarms it.
@MainActor
@Observable
final class LocalNetworkAccessMonitor {
    private(set) var permission = LocalNetworkPermissionState()
    /// Advances once per newly started probe that confirms a denial. The Deck
    /// uses this edge to present the alert again after returning from Settings.
    private(set) var denialRevision = 0

    var isDenied: Bool { permission.isDenied }

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var probes: [UUID: Probe] = [:]
    @ObservationIgnored private let queue = DispatchQueue(
        label: "app.multiplexterm.multiplex.local-network-check",
        qos: .utility
    )

    private struct Probe {
        let token: UUID
        let connection: NWConnection
        var reportedDenial = false
        var pendingConfirmation: Task<Void, Never>?
    }

    /// How long a reported denial must persist before it is believed. Long
    /// enough to outlive the transient `.localNetworkDenied` flaps a granted
    /// connection emits while establishing; a genuine denial keeps reporting
    /// itself and merely surfaces this much later.
    private let denialConfirmationDelay: Duration

    init(denialConfirmationDelay: Duration = .seconds(2)) {
        self.denialConfirmationDelay = denialConfirmationDelay
    }

    /// Re-check every configured route. Calls are intentionally tied to Deck
    /// activation and fleet edits, not the five-second wall feed.
    func check(hosts: [Host]) {
        generation &+= 1
        cancelAllProbes()

        let hostIDs = Set(hosts.map(\.id))
        permission.retainConfiguredHosts(hostIDs)

        for host in hosts {
            guard let rawPort = UInt16(exactly: host.port),
                  let port = NWEndpoint.Port(rawValue: rawPort)
            else { continue }

            let hostID = host.id
            let token = UUID()
            let connection = NWConnection(
                host: NWEndpoint.Host(host.hostname),
                port: port,
                using: .udp
            )
            let currentGeneration = generation
            probes[hostID] = Probe(token: token, connection: connection)

            connection.pathUpdateHandler = { [weak self] path in
                guard Self.isLocalNetworkDenied(path) else { return }
                Task { @MainActor [weak self] in
                    self?.armDenialConfirmation(
                        hostID: hostID,
                        token: token,
                        generation: currentGeneration
                    )
                }
            }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let connection else { return }
                switch state {
                case .ready:
                    Task { @MainActor [weak self] in
                        self?.recordReady(
                            hostID: hostID,
                            token: token,
                            generation: currentGeneration
                        )
                    }
                case .waiting:
                    guard let path = connection.currentPath,
                          Self.isLocalNetworkDenied(path)
                    else { return }
                    Task { @MainActor [weak self] in
                        self?.armDenialConfirmation(
                            hostID: hostID,
                            token: token,
                            generation: currentGeneration
                        )
                    }
                case .failed, .cancelled:
                    Task { @MainActor [weak self] in
                        self?.finishProbe(
                            hostID: hostID,
                            token: token,
                            generation: currentGeneration
                        )
                    }
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Stop diagnostic sockets while the Deck is inactive. Keep the last
    /// denial so the next foreground check can either confirm or clear it.
    func suspend() {
        generation &+= 1
        cancelAllProbes()
    }

    private nonisolated static func isLocalNetworkDenied(_ path: NWPath) -> Bool {
        path.status == .unsatisfied && path.unsatisfiedReason == .localNetworkDenied
    }

    private func armDenialConfirmation(hostID: UUID, token: UUID, generation: Int) {
        guard generation == self.generation,
              var probe = probes[hostID],
              probe.token == token,
              !probe.reportedDenial,
              probe.pendingConfirmation == nil
        else { return }

        let delay = denialConfirmationDelay
        probe.pendingConfirmation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.confirmDenial(hostID: hostID, token: token, generation: generation)
        }
        probes[hostID] = probe
    }

    private func confirmDenial(hostID: UUID, token: UUID, generation: Int) {
        guard generation == self.generation,
              var probe = probes[hostID],
              probe.token == token,
              !probe.reportedDenial
        else { return }

        probe.pendingConfirmation = nil
        probes[hostID] = probe

        // The report is believed only if the connection's live path still
        // says denied — a transient flap on a granted route has resolved by
        // now (its path is satisfied again, or the probe already finished).
        guard let path = probe.connection.currentPath,
              Self.isLocalNetworkDenied(path)
        else { return }

        // Keep the denied probe alive. If the system prompt is still up and
        // the user allows access, this same connection can transition to
        // ready and retract the in-app alert without another network attempt.
        probe.reportedDenial = true
        probes[hostID] = probe
        permission.recordDenied(hostID: hostID)
        denialRevision &+= 1

        // Permission is app-wide. Once one real route proves the denial,
        // other diagnostic sockets add no information.
        let redundant = probes.filter { $0.key != hostID }
        for (otherHostID, otherProbe) in redundant {
            probes.removeValue(forKey: otherHostID)
            otherProbe.pendingConfirmation?.cancel()
            otherProbe.connection.cancel()
        }
    }

    private func recordReady(hostID: UUID, token: UUID, generation: Int) {
        guard generation == self.generation,
              let probe = probes[hostID],
              probe.token == token
        else { return }

        permission.recordReady(hostID: hostID)
        finishProbe(hostID: hostID, token: token, generation: generation)
    }

    private func finishProbe(hostID: UUID, token: UUID, generation: Int) {
        guard generation == self.generation,
              let probe = probes[hostID],
              probe.token == token
        else { return }
        probes.removeValue(forKey: hostID)
        probe.pendingConfirmation?.cancel()
        probe.connection.cancel()
    }

    private func cancelAllProbes() {
        let active = probes.values
        probes.removeAll()
        for probe in active {
            probe.pendingConfirmation?.cancel()
            probe.connection.cancel()
        }
    }
}
