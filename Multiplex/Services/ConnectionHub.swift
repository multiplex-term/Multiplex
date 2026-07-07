import Foundation
import Observation

/// One `HostConnectionModel` per host, created on demand and shared by
/// every window in the app.
@MainActor
@Observable
final class ConnectionHub {
    private var models: [UUID: HostConnectionModel] = [:]

    func model(for host: Host) -> HostConnectionModel {
        if let existing = models[host.id] { return existing }
        let model = HostConnectionModel(host: host)
        models[host.id] = model
        return model
    }

    func dropModel(for hostID: UUID) {
        if let model = models.removeValue(forKey: hostID) {
            Task { await model.disconnect() }
        }
    }
}

/// The deck's view of one host: an SSH control connection used to probe
/// tmux state. Terminal windows open their own dedicated connections.
@MainActor
@Observable
final class HostConnectionModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    let host: Host
    private(set) var phase: Phase = .idle
    private(set) var tmux: TmuxState = .unknown
    private(set) var lastRefreshed: Date?

    private var connection: SSHConnection?
    private var refreshTask: Task<Void, Never>?

    init(host: Host) {
        self.host = host
    }

    var isBusy: Bool {
        phase == .connecting || tmux == .probing
    }

    /// Connect if needed, then re-probe tmux sessions.
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            await performRefresh()
        }
    }

    private func performRefresh() async {
        do {
            let connection = try await ensureConnection()
            tmux = .probing
            let output = try await connection.exec(TmuxProbe.probeCommand)
            tmux = TmuxProbe.parse(output)
            lastRefreshed = Date()
        } catch {
            let message = friendlyMessage(for: error)
            phase = .failed(message)
            tmux = .failed(message)
            connection = nil
        }
    }

    private func ensureConnection() async throws -> SSHConnection {
        if let connection, phase == .connected { return connection }
        phase = .connecting
        let fresh = SSHConnection(host: host, secrets: .load(for: host))
        try await fresh.connect()
        connection = fresh
        phase = .connected
        return fresh
    }

    func disconnect() async {
        refreshTask?.cancel()
        refreshTask = nil
        if let connection {
            await connection.close()
        }
        connection = nil
        phase = .idle
        tmux = .unknown
    }

    private func friendlyMessage(for error: Error) -> String {
        if let sshError = error as? SSHConnectionError {
            return sshError.userMessage(host: host)
        }
        return "Couldn't reach \(host.name). \(error.localizedDescription)"
    }
}
