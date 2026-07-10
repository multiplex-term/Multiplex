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

    /// File-drop progress surfaced by the pane's status pill.
    enum DropState: Equatable {
        case uploading(name: String, fraction: Double)
        case failed(String)
    }

    let route: TerminalRoute
    let host: Host

    private(set) var status: Status = .connecting
    var remoteTitle: String = ""

    /// Strongly owned (SwiftTerm's delegate back-reference is weak): the view
    /// carries the terminal buffer and scrollback, and tabs move between
    /// windows — the adopting window re-parents this same view, so what's on
    /// screen survives a merge/split. Released with the controller on close.
    private(set) var terminalView: TerminalView?
    private var connection: SSHConnection?
    private var pendingOutput = Data()
    private var lastCols = 80
    private var lastRows = 24
    private var started = false
    private var inputTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<Data>.Continuation?
    private(set) var dropState: DropState?
    private var dropTask: Task<Void, Never>?
    private var dropClearTask: Task<Void, Never>?

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

    /// Explicit user request: bring the normal system keyboard back — even if
    /// it was dismissed while this terminal stayed first responder, even if
    /// SwiftTerm's accessory toggled its F-key pad in as a custom input view
    /// (which otherwise sticks until toggled again), and even if the OS
    /// docked only the accessory because a hardware keyboard was attached
    /// (the arbiter rebuilds the input session, re-checking that state).
    func summonKeyboard() {
        guard let terminalView else { return }
        if terminalView.inputView != nil {
            terminalView.inputView = nil
            terminalView.reloadInputViews()
        }
        TerminalFocusArbiter.summon(terminalView, force: true)
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

    // MARK: File drops

    /// Files dropped on this tab's pane: upload each into the active
    /// pane's working directory over this tab's own connection, then type
    /// the resulting paths through the input pump — no Enter, the user
    /// finishes the prompt. One drop batch at a time.
    func deliverDrop(_ files: [DroppedFile]) {
        guard status == .live, let connection, dropTask == nil, !files.isEmpty else { return }
        dropClearTask?.cancel()
        dropClearTask = nil
        dropTask = Task { [weak self] in
            await self?.performDrop(files, over: connection)
            self?.dropTask = nil
        }
    }

    private func performDrop(_ files: [DroppedFile], over connection: SSHConnection) async {
        do {
            let destination = try await dropDestination(over: connection)
            var typedPaths: [String] = []
            for file in files {
                guard file.data.count <= DropText.maxBytes else {
                    throw DropError(message: "\(file.name) is over 64 MB")
                }
                dropState = .uploading(name: file.name, fraction: 0)
                let finalName = try await connection.uploadFile(
                    file.data,
                    toDirectory: destination.directory,
                    preferredName: DropText.sanitizedName(file.name),
                    prepareGitIgnoredDirectory: destination.prepareGitIgnoredDirectory,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard case .uploading = self?.dropState else { return }
                            self?.dropState = .uploading(name: file.name, fraction: fraction)
                        }
                    }
                )
                // Relative names read best in a prompt, but only when the
                // file verifiably sits under the pane's cwd.
                typedPaths.append(destination.typedPrefix.map { $0 + finalName }
                    ?? destination.directory + "/" + finalName)
            }
            dropState = nil
            sendInput(Data(DropText.typedPaths(typedPaths).utf8))
        } catch is CancellationError {
            dropState = nil
        } catch {
            dropState = .failed((error as? DropError)?.message ?? "Upload failed")
            dropClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.dropState = nil
            }
        }
    }

    private struct DropDestination {
        var directory: String
        /// Prefix for typed relative paths ("" = bare name,
        /// ".multiplex-drops/" inside git worktrees); nil types absolute.
        var typedPrefix: String?
        var prepareGitIgnoredDirectory: Bool
    }

    /// The pane's cwd when tmux can tell us (it follows the foreground
    /// process, i.e. the agent's own cwd) — corralled into a self-ignoring
    /// `.multiplex-drops/` when that cwd is inside a git worktree, so drops
    /// never clutter `git status`. Otherwise $HOME with absolute typed
    /// paths. The query's first `/`-prefixed line is the path; a
    /// MULTIPLEX_GIT line marks a worktree.
    private func dropDestination(
        over connection: SSHConnection
    ) async throws -> DropDestination {
        if let sessionName = route.sessionName {
            let output = (try? await connection.exec(
                TmuxProbe.dropDestinationCommand(sessionName: sessionName)
            )) ?? ""
            let lines = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let path = lines.first(where: { $0.hasPrefix("/") }) {
                if lines.contains("MULTIPLEX_GIT") {
                    return DropDestination(
                        directory: path + "/" + DropText.dropsDirectoryName,
                        typedPrefix: DropText.dropsDirectoryName + "/",
                        prepareGitIgnoredDirectory: true
                    )
                }
                return DropDestination(
                    directory: path,
                    typedPrefix: "",
                    prepareGitIgnoredDirectory: false
                )
            }
        }
        return DropDestination(
            directory: try await connection.remoteHomeDirectory(),
            typedPrefix: nil,
            prepareGitIgnoredDirectory: false
        )
    }

    // MARK: Actions

    /// Closing the channel detaches the tmux client; tmux keeps the session.
    func detach() {
        dropTask?.cancel()
        dropTask = nil
        dropClearTask?.cancel()
        dropState = nil
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
