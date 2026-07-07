import Foundation
import Observation
import SwiftTerm

/// Owns one terminal window's SSH shell: opens a dedicated connection,
/// requests a PTY (running tmux attach / new-session / a plain shell),
/// and pumps bytes between the channel and the SwiftTerm view.
@MainActor
@Observable
final class TerminalSessionController {
    enum Status: Equatable {
        case connecting
        case live
        case ended(String?)
    }

    let route: TerminalRoute
    let host: Host

    private(set) var status: Status = .connecting
    var remoteTitle: String = ""

    private weak var terminalView: TerminalView?
    private var connection: SSHConnection?
    private var pendingOutput = Data()
    private var lastCols = 80
    private var lastRows = 24
    private var started = false

    init(route: TerminalRoute, host: Host) {
        self.route = route
        self.host = host
    }

    var windowTitle: String {
        "\(route.displayName) — \(host.name)"
    }

    func bind(_ view: TerminalView) {
        terminalView = view
        if !pendingOutput.isEmpty {
            view.feed(byteArray: [UInt8](pendingOutput)[...])
            pendingOutput.removeAll()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await run() }
    }

    private func run() async {
        let connection = SSHConnection(host: host, secrets: .load(for: host))
        self.connection = connection
        do {
            try await connection.connect()
            try await connection.openShell(
                command: route.remoteCommand,
                cols: lastCols,
                rows: lastRows,
                onData: { [weak self] data in
                    Task { @MainActor [weak self] in
                        self?.feed(data)
                    }
                },
                onClose: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        self?.handleClose(reason: reason)
                    }
                }
            )
            status = .live
        } catch {
            let message = (error as? SSHConnectionError)?.userMessage(host: host)
                ?? "Couldn't reach \(host.name). \(error.localizedDescription)"
            status = .ended(message)
            await connection.close()
        }
    }

    private func feed(_ data: Data) {
        guard let terminalView else {
            pendingOutput.append(data)
            return
        }
        terminalView.feed(byteArray: [UInt8](data)[...])
    }

    private func handleClose(reason: String?) {
        if case .ended = status { return }
        status = .ended(reason)
    }

    // MARK: Terminal view events

    func sendInput(_ data: Data) {
        guard status == .live, let connection else { return }
        Task { try? await connection.write(data) }
    }

    func terminalResized(cols: Int, rows: Int) {
        lastCols = cols
        lastRows = rows
        guard status == .live, let connection else { return }
        Task { try? await connection.resize(cols: cols, rows: rows) }
    }

    // MARK: Actions

    /// Closing the channel detaches the tmux client; tmux keeps the session.
    func detach() {
        status = .ended(nil)
        let connection = self.connection
        self.connection = nil
        Task { await connection?.close() }
    }

    func reconnect() {
        guard case .ended = status else { return }
        status = .connecting
        Task { await run() }
    }
}
