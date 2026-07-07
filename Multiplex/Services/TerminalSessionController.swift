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
    private var inputTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<Data>.Continuation?

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

    /// Route keyboard input to this window's terminal.
    func focusTerminal() {
        guard let terminalView else { return }
        TerminalFocusArbiter.claim(terminalView)
    }

    /// Explicit user request: bring the keyboard back even if it was
    /// dismissed while this terminal stayed first responder.
    func summonKeyboard() {
        guard let terminalView else { return }
        TerminalFocusArbiter.summon(terminalView)
    }

    /// Scene became active again: re-assert focus only if this terminal is
    /// (or nothing is) the app-wide owner — every window's scene activates
    /// at once on foreground, and they must not steal from each other.
    func restoreFocusIfOwner() {
        guard let terminalView,
              TerminalFocusArbiter.current === terminalView || TerminalFocusArbiter.current == nil
        else { return }
        TerminalFocusArbiter.claim(terminalView)
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
            startInputPump(for: connection)
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
        stopInputPump()
        if case .ended = status { return }
        status = .ended(reason)
    }

    // MARK: Input pump

    /// Keystrokes flow through one AsyncStream consumed by a single task —
    /// yield order is preserved, unlike a Task spawned per keystroke, and
    /// the terminal thread never waits on the network.
    private func startInputPump(for connection: SSHConnection) {
        stopInputPump()
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        inputContinuation = continuation
        inputTask = Task {
            for await chunk in stream {
                try? await connection.write(chunk)
            }
        }
    }

    private func stopInputPump() {
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask?.cancel()
        inputTask = nil
    }

    // MARK: Terminal view events

    func sendInput(_ data: Data) {
        guard status == .live else { return }
        inputContinuation?.yield(data)
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
        stopInputPump()
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
