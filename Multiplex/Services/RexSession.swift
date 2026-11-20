import Foundation
import OSLog

/// One WebSocket to a Rex server, carried over a `RemotePipe`.
///
/// `open` performs the upgrade and returns once frames can flow. Messages
/// then arrive on `messages` in order; pings are answered here, so a
/// consumer only ever sees text, binary, and the closing frame.
struct RexSocket: Sendable {
    let messages: AsyncThrowingStream<WebSocketCodec.Message, Error>
    private let pipe: RemotePipe

    static func open(
        over pipe: RemotePipe, path: String, subprotocol: String
    ) async throws -> RexSocket {
        let key = WebSocketCodec.makeKey()
        let (messages, feed) = AsyncThrowingStream<WebSocketCodec.Message, Error>.makeStream()
        try await pipe.write(WebSocketCodec.upgradeRequest(
            path: path, host: "rex", subprotocol: subprotocol, key: key))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let upgraded = OneShotGate(continuation)
            let reader = Task {
                var head = Data()
                var isUpgraded = false
                var decoder = WebSocketCodec.Decoder()
                do {
                    for try await chunk in pipe.incoming {
                        if isUpgraded {
                            decoder.append(chunk)
                        } else {
                            head.append(chunk)
                            guard case .upgraded(let remainder) =
                                try WebSocketCodec.readUpgradeResponse(
                                    head, key: key, subprotocol: subprotocol)
                            else { continue }
                            isUpgraded = true
                            head = Data()
                            decoder.append(remainder)
                            upgraded.open()
                        }
                        while let message = try decoder.next() {
                            switch message {
                            case .ping(let payload):
                                // The server drops a connection after three
                                // unanswered pings.
                                try await pipe.write(
                                    WebSocketCodec.frame(.pong, payload: payload))
                            case .pong:
                                break
                            case .close:
                                feed.yield(message)
                                feed.finish()
                                return
                            case .text, .binary:
                                feed.yield(message)
                            }
                        }
                    }
                    if !upgraded.fail(RexSession.Failure(String(
                        localized: "The Rex server closed the connection before answering."))) {
                        feed.finish()
                    }
                } catch {
                    if !upgraded.fail(error) { feed.finish(throwing: error) }
                }
            }
            feed.onTermination = { _ in reader.cancel() }
        }
        return RexSocket(messages: messages, pipe: pipe)
    }

    func send(_ opcode: WebSocketCodec.Opcode, _ payload: Data) async throws {
        try await pipe.write(WebSocketCodec.frame(opcode, payload: payload))
    }

    /// Says goodbye and drops the channel. Status 1000 matters on a data
    /// connection: it is what ends the stream instead of parking it for a
    /// resume nobody will send.
    func close() async {
        try? await pipe.write(WebSocketCodec.closeFrame(code: 1000))
        pipe.close()
    }
}

/// A terminal tab attached to one Rex terminal block — the third
/// `TerminalTransport`, beside the SSH PTY and mosh.
///
/// Rex has no terminal client to run in a PTY (see `RexProbe`), so this IS
/// the client: it speaks the server's WebSocket API through two byte pipes
/// on the tab's SSH connection (`SSHConnection.openPipe` running `rex
/// __internal dial-stdio`, the bridge Rex's own `ssh://` transport uses).
///
/// - The **control** connection attaches to the session, claims the block,
///   sizes it, and carries every keystroke as a
///   `com.superlogical.terminal.write` call.
/// - The **data** connection carries the block's output, one way.
///
/// What is deliberate here:
/// - **The screen is bootstrapped from `format`, not from the stream.** The
///   stream opens with a Ghostty binary snapshot SwiftTerm cannot read
///   (`RexTerminalStream` drops it), so the starting screen comes from the
///   `vt` rendering instead. The block is claimed and sized BEFORE either
///   is asked for, so both describe the terminal at this tab's size.
/// - **The two are not atomic, and the gap errs toward repeating.** The
///   stream is opened first and held while `format` is fetched: output the
///   program wrote in between is drawn twice (once inside the rendering,
///   once from the stream) rather than lost. Lost bytes can leave a mode
///   wrong for the rest of the session; a repeated line is one line.
/// - **The last client to type owns the size**, as with tmux's latest-client
///   rule. Another client (the Rex app) can claim the block back; the next
///   keystroke here claims it again and re-sizes it.
/// - **Only what a person does is written.** `write` is what claims, so
///   nothing may reach it that the emulator said by itself. The server
///   parses the terminal's output too and answers its queries there; the
///   emulator's own answers are stopped before this transport
///   (`TerminalSessionController.sendTerminalReport`). Sent on, each one
///   was a second answer in the program's input and a claim nobody made.
/// - **The palette is the app's.** `extra_palette` is not requested: it
///   would repaint the tab in Rex's theme.
/// - **A tab attached during a full-screen program redraws when it exits.**
///   While one is up, `format` renders only its screen — the shell history
///   underneath cannot be asked for — so the emulator's primary screen
///   starts empty and leaving vim showed a bare prompt (seen on the first
///   headless run). `AlternateScreenExitWatch` notices the exit and the
///   screen is fetched again, under the same hold-then-flush rule as the
///   attach.
actor RexSession: TerminalTransport {
    /// A reason a person can read — the tab's ended line.
    struct Failure: Error, Equatable {
        var message: String

        init(_ message: String) {
            self.message = message
        }
    }

    private static let log = Logger(
        subsystem: "app.multiplexterm.multiplex", category: "rex")

    /// How much of a `vt` rendering one request asks for (the method caps
    /// it near 960 KiB), and how large a rendering is still worth fetching
    /// in full. A terminal keeps up to 64 MiB of scrollback; past this the
    /// attach draws a plain-text tail instead of waiting on megabytes.
    private static let bootstrapChunk = 900_000
    private static let bootstrapLimit = 3_000_000
    private static let plainTailBytes = 16 * 1024

    /// Opens one byte pipe to the Rex server's socket; called twice per
    /// attach (control, then data). A closure rather than the connection
    /// itself so the whole session can be driven by an in-process server
    /// under test.
    private let openPipe: @Sendable () async throws -> RemotePipe
    /// Drops whatever the pipes ride on — the tab's SSH connection.
    private let closeLink: @Sendable () async -> Void
    private let sessionID: String
    private let preferredBlockID: String?
    private let clientVersion: String

    private var control: RexSocket?
    private var data: RexSocket?
    private var controlReader: Task<Void, Never>?
    private var dataReader: Task<Void, Never>?

    private struct Reply: @unchecked Sendable {
        var payload: [String: Any]
    }
    private var pending: [String: CheckedContinuation<Reply, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var requestCount = 0

    private enum Milestone: Hashable { case welcome, dataWelcome, live }
    private var reached: Set<Milestone> = []
    private var waiters: [Milestone: CheckedContinuation<Void, Error>] = [:]

    private var clientID: String?
    private(set) var blockID: String?
    private var owner: String?
    private var stream: RexTerminalStream?
    /// Stream output that arrived before the screen was drawn, kept to be
    /// drawn after it. nil once the screen is up: output goes straight
    /// through.
    private var held: Data? = Data()
    /// Set while the emulator's primary screen is known to be incomplete —
    /// the bootstrap was rendered during a full-screen program.
    private var exitWatch: AlternateScreenExitWatch?
    private var lastOutput = ContinuousClock.now
    /// `attaching` until `open` returns; `closed` is final, whichever side
    /// ended it.
    private enum Phase { case attaching, live, closed }
    private var phase = Phase.attaching
    private var size: (cols: Int, rows: Int) = (80, 24)
    private var input = RexInputEncoder()
    private var pendingInput = ""
    private var isWriting = false
    private var isSwitching = false
    /// Bumped whenever the data connection is replaced. A reader reports
    /// with the generation it was started under, so a retired stream's
    /// last words are recognised as that and dropped.
    private var dataGeneration = 0

    private var onData: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (String?) -> Void)?

    init(
        openPipe: @escaping @Sendable () async throws -> RemotePipe,
        closeLink: @escaping @Sendable () async -> Void,
        sessionID: String, blockID: String?, clientVersion: String
    ) {
        self.openPipe = openPipe
        self.closeLink = closeLink
        self.sessionID = sessionID
        preferredBlockID = blockID
        self.clientVersion = clientVersion
    }

    /// The app's form: both pipes ride `connection`, each running the Rex
    /// CLI's stdio bridge, and closing the session closes the connection.
    init(
        connection: SSHConnection, sessionID: String, blockID: String?,
        clientVersion: String
    ) {
        self.init(
            openPipe: { try await connection.openPipe(running: RexProbe.bridgeCommand) },
            closeLink: { await connection.close() },
            sessionID: sessionID, blockID: blockID, clientVersion: clientVersion
        )
    }

    // MARK: - Opening

    /// Attaches and returns once the terminal's current screen has been
    /// handed to `onData`. `onClose` fires at most once, later, when the
    /// block or the link ends on its own (nil for a clean end).
    func open(
        cols: Int, rows: Int,
        onData: @Sendable @escaping (Data) -> Void,
        onClose: @Sendable @escaping (String?) -> Void
    ) async throws {
        self.onData = onData
        self.onClose = onClose
        size = (cols, rows)
        do {
            try await attach()
            if phase == .attaching { phase = .live }
        } catch {
            let failure = Self.failure(from: error)
            await teardown(failing: failure)
            throw failure
        }
    }

    private func attach() async throws {
        let control = try await RexSocket.open(
            over: try await openPipe(),
            path: RexWire.controlPath, subprotocol: RexWire.controlSubprotocol)
        self.control = control
        try await control.send(.text, RexWire.hello(clientVersion: clientVersion))
        startControlReader(control)
        try await wait(for: .welcome)

        let attached = try await call("session.attach", ["session_id": sessionID])
        if let id = attached["client_id"] as? String { clientID = id }
        let blocks = RexWire.terminalBlocks(
            inView: attached["view"] as? [String: Any] ?? [:])
        guard let block = RexWire.attachTarget(in: blocks, preferring: preferredBlockID) else {
            throw Failure(String(localized: "This Rex session has no terminal to open."))
        }
        try await showBlock(block.id)
    }

    /// Points the tab at one terminal block: claim and size it, open its
    /// stream, draw its screen. The attach's second half, and the whole of
    /// a switch.
    private func showBlock(_ blockID: String) async throws {
        self.blockID = blockID
        // Claim and size first: the rendering and the stream below must
        // both describe the terminal at THIS tab's size.
        await claimAndSize()

        let ticket = try await call("data.connect", [
            "session_id": sessionID,
            "block_id": blockID,
            "data_ref_id": "terminal",
            "subprotocol": RexWire.terminalSubprotocol,
        ])
        guard let hello = (ticket["ticket"] as? String).flatMap(RexWire.dataHello) else {
            throw Failure(String(localized: "The Rex server issued no usable stream ticket."))
        }
        let data = try await RexSocket.open(
            over: try await openPipe(),
            path: RexWire.dataPath, subprotocol: RexWire.terminalSubprotocol)
        self.data = data
        try await data.send(.binary, hello)
        startDataReader(data)
        try await wait(for: .dataWelcome)
        // The snapshot has passed once the first server message arrives;
        // only then is the terminal's state settled enough to render.
        try await wait(for: .live)

        await drawScreen(blockID: blockID)
    }

    /// The directory the terminal on show is working in — what a file drop
    /// lands in and a file viewer opens at. nil when the tab is not live or
    /// the server cannot say.
    func workingDirectory() async -> String? {
        guard phase == .live, let blockID,
              let process = try? await terminalCall("process", block: blockID)
        else { return nil }
        return RexWire.workingDirectory(inProcess: process)
    }

    // MARK: - Switching terminals

    /// Every terminal of the session, as the REX panel's Switch Terminal
    /// rows, with the one this tab shows marked. Read fresh each time the
    /// panel opens: windows come and go in Rex without telling the tab.
    func terminalChoices() async -> [TmuxWindowChoice]? {
        guard phase == .live,
              let view = try? await call("session.view", ["session_id": sessionID])
        else { return nil }
        return RexWire.terminalChoices(
            in: RexWire.terminalBlocks(inView: view), showing: blockID)
    }

    /// Points this tab at another terminal of the same session, in place:
    /// the control connection and the tab stay, only the stream and the
    /// screen change.
    ///
    /// The old block is given up as well as left. Owning a block is what
    /// makes it follow this tab's size, and a terminal nobody here is
    /// looking at any more has no business keeping it — the Rex window
    /// showing it gets its own size back. A switch that cannot complete
    /// ends the tab with the reason rather than leaving it on a dead
    /// stream; RECONNECT then attaches afresh.
    func switchBlock(to newID: String) async {
        guard phase == .live, !isSwitching, newID != blockID else { return }
        isSwitching = true
        defer { isSwitching = false }
        let previous = blockID

        // Retire the old stream. The generation bump is what keeps its
        // reader's parting "ended" from being read as the TAB ending.
        dataGeneration += 1
        let oldData = data
        data = nil
        await oldData?.close()
        dataReader?.cancel()
        dataReader = nil
        stream = nil
        reached.subtract([.dataWelcome, .live])
        held = Data()
        exitWatch = nil
        pendingInput = ""
        input = RexInputEncoder()

        if let previous {
            _ = try? await call("session.disown_block", [
                "session_id": sessionID, "block_ids": [previous],
            ])
        }
        do {
            try await showBlock(newID)
        } catch {
            finish(Self.failure(from: error).message)
        }
    }

    /// Renders the terminal's current screen into the emulator, then lets
    /// the stream through. Stream output is held from the moment this is
    /// called (the attach holds it from the start) to the moment the
    /// rendering has been drawn, so nothing is drawn UNDER a rendering that
    /// was taken later, and nothing that arrived meanwhile is dropped.
    private func drawScreen(blockID: String) async {
        held = held ?? Data()
        // Two reads that depend on nothing of each other's, so they share
        // one round trip.
        async let alternate = isOnAlternateScreen(blockID: blockID)
        async let rendering = bootstrapScreen(blockID: blockID)
        let (onAlternateScreen, screen) = await (alternate, rendering)
        guard phase != .closed else { return }
        // RIS first: a resumed tab still shows what the last run drew.
        onData?(Data([0x1B, 0x63]) + screen)
        exitWatch = onAlternateScreen ? AlternateScreenExitWatch() : nil
        let pending = held
        held = nil
        if let pending, !pending.isEmpty { deliver(pending) }
    }

    /// Stream output on its way to the emulator. The one place that also
    /// watches for a full-screen program exiting, when that matters.
    private func deliver(_ output: Data) {
        onData?(output)
        lastOutput = .now
        guard exitWatch?.sawExit(in: output) == true, let blockID else { return }
        exitWatch = nil
        Task { await self.redrawOnceQuiet(blockID: blockID) }
    }

    /// A full-screen program just exited: wait for the burst that follows
    /// it to finish, then render the screen again.
    ///
    /// The wait is what keeps the redraw from repeating the shell's prompt.
    /// Output that arrives while a rendering is being fetched is held and
    /// drawn after it, so anything the rendering already contains is drawn
    /// twice — and a shell prints its prompt within milliseconds of the
    /// program leaving (the first headless run ended on `$ $`). Letting that
    /// burst through first, to be replaced by a rendering taken once the
    /// terminal has gone quiet, leaves nothing in the window to repeat. A
    /// terminal that never goes quiet is redrawn anyway after the cap.
    private func redrawOnceQuiet(blockID: String) async {
        let started = ContinuousClock.now
        while phase != .closed {
            try? await Task.sleep(for: .milliseconds(60))
            let now = ContinuousClock.now
            if now - lastOutput >= .milliseconds(120) || now - started >= .milliseconds(800) {
                break
            }
        }
        guard phase != .closed else { return }
        await drawScreen(blockID: blockID)
    }

    /// Whether a full-screen program currently owns the terminal. Asked of
    /// the server rather than read out of the rendering: `modes` states it
    /// outright. An answer that cannot be had reads as "no".
    private func isOnAlternateScreen(blockID: String) async -> Bool {
        let modes = try? await terminalCall("modes", block: blockID)
        return modes?["screen"] as? String == "alternate"
    }

    /// Makes this client the block's owner and gives it this tab's size.
    /// Best effort: a refusal leaves the terminal at someone else's size,
    /// which is wrong-looking but not fatal.
    private func claimAndSize() async {
        guard let blockID else { return }
        if let claimed = try? await call("session.own_block", [
            "session_id": sessionID, "block_ids": [blockID], "mode": "take",
        ]) {
            let mine = (claimed["blocks"] as? [[String: Any]])?
                .first { $0["block_id"] as? String == blockID }
            owner = mine?["owner"] as? String ?? clientID
        }
        await sendSize(to: blockID)
    }

    /// Applies at once while this client owns the block, and otherwise
    /// waits server-side until it does — never a failure worth raising.
    private func sendSize(to blockID: String) async {
        _ = try? await terminalCall(
            "resize", block: blockID, ["columns": size.cols, "rows": size.rows])
    }

    /// The terminal's screen and scrollback as escape sequences SwiftTerm
    /// can draw. Falls back to a plain-text tail for a terminal whose
    /// rendering is too large to wait for, and to nothing at all — the
    /// stream alone — if the server will not render.
    private func bootstrapScreen(blockID: String) async -> Data {
        guard let first = try? await terminalCall("format", block: blockID, [
            "format": "vt",
            "extra_cursor": true,
            "extra_modes": true,
            "extra_scrolling_region": true,
            "extra_style": true,
            "extra_charsets": true,
            "extra_keyboard": true,
            "extra_kitty_keyboard": true,
            "extra_tabstops": true,
            "max_bytes": Self.bootstrapChunk,
        ])
        else { return Data() }
        var screen = Data((first["content"] as? String ?? "").utf8)
        guard let id = first["id"] as? Int else { return screen }
        let total = first["total"] as? Int ?? .max
        guard total <= Self.bootstrapLimit else {
            return await plainTail(blockID: blockID)
        }
        // Offsets count the rendering's UTF-8 bytes, which is what `screen`
        // holds.
        while screen.count < total {
            guard let more = try? await terminalCall("blob_read", block: blockID, [
                "id": id, "offset": screen.count, "max_bytes": Self.bootstrapChunk,
            ]), let piece = more["data"] as? String, !piece.isEmpty
            else { break }
            screen.append(contentsOf: piece.utf8)
            if more["eof"] as? Bool == true { break }
        }
        return screen
    }

    /// The last screenful or so as plain text — no colors, but the user
    /// lands on what the terminal was showing rather than on nothing. Read
    /// from the END (`RexProbe` explains why a capped read stops short).
    private func plainTail(blockID: String) async -> Data {
        guard let first = try? await terminalCall(
                  "format", block: blockID, ["format": "text", "trim": true, "max_bytes": 1]),
              let id = first["id"] as? Int, let total = first["total"] as? Int
        else { return Data() }
        let offset = max(0, total - Self.plainTailBytes)
        guard let rest = try? await terminalCall(
                  "blob_read", block: blockID, ["id": id, "offset": offset]),
              let tail = rest["data"] as? String
        else { return Data() }
        var lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        // A read that started mid-screen starts mid-line.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    // MARK: - TerminalTransport

    /// Queues the input and returns; it does not wait for the server.
    ///
    /// One write is in flight at a time — the server runs block methods
    /// concurrently, so two calls could land out of order — and whatever is
    /// typed meanwhile rides the next call as one string. Returning at once
    /// is what lets that happen: the tab's input pump awaits each write, so
    /// a write that waited for its answer would turn every keystroke into a
    /// round trip of its own, queued behind the last.
    func write(_ data: Data) async throws {
        guard phase == .live else { throw Failure("not attached") }
        // Mid-switch the screen on show is the terminal being left; a key
        // pressed then is dropped rather than typed into one not yet drawn.
        guard !isSwitching else { return }
        pendingInput += input.encode(data)
        guard !isWriting, !pendingInput.isEmpty else { return }
        isWriting = true
        Task { await self.drainInput() }
    }

    private func drainInput() async {
        defer { isWriting = false }
        while !pendingInput.isEmpty, phase == .live, let blockID {
            let text = pendingInput
            pendingInput = ""
            // Typing is what claims the size back from another client.
            if owner != clientID { await claimAndSize() }
            do {
                _ = try await terminalCall("write", block: blockID, ["data": text])
            } catch {
                Self.log.debug("write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func resize(cols: Int, rows: Int) async throws {
        size = (cols, rows)
        guard phase == .live, let blockID else { return }
        await sendSize(to: blockID)
    }

    /// Idempotent, and always closes the SSH connection the two pipes ride:
    /// a tab that ended on its own (`finish`) still has that link to drop.
    func close() async {
        if phase != .closed {
            phase = .closed
            await teardown(failing: Failure("closed"))
        }
        await closeLink()
    }

    // MARK: - Requests

    /// How long the server gets to answer a request or reach a handshake
    /// milestone.
    private static let replyTimeout = Duration.seconds(10)

    /// One of the terminal's own methods (`com.superlogical.terminal.<verb>`)
    /// on one block of this session.
    private func terminalCall(
        _ verb: String, block blockID: String, _ args: [String: Any] = [:]
    ) async throws -> [String: Any] {
        try await call(
            RexWire.terminalCreator + "." + verb,
            RexWire.blockPayload(sessionID: sessionID, blockID: blockID, args: args))
    }

    private func call(_ method: String, _ payload: [String: Any]) async throws -> [String: Any] {
        guard let control else { throw Failure("not connected") }
        requestCount += 1
        let id = "m\(requestCount)"
        let message = RexWire.request(id: id, method: method, payload: payload)
        let reply: Reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: Self.replyTimeout) } catch { return }
                await self?.settle(id, .failure(Failure(String(
                    localized: "The Rex server did not answer in time."))))
            }
            Task { [weak self] in
                do {
                    try await control.send(.text, message)
                } catch {
                    await self?.settle(id, .failure(error))
                }
            }
        }
        return reply.payload
    }

    private func settle(_ id: String, _ result: Result<Reply, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    // MARK: - Milestones

    private func wait(for milestone: Milestone) async throws {
        guard !reached.contains(milestone) else { return }
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: Self.replyTimeout) } catch { return }
            await self?.fail(milestone, Failure(String(
                localized: "The Rex server did not answer in time.")))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters[milestone] = continuation
        }
    }

    private func reach(_ milestone: Milestone) {
        reached.insert(milestone)
        waiters.removeValue(forKey: milestone)?.resume()
    }

    private func fail(_ milestone: Milestone, _ error: Error) {
        waiters.removeValue(forKey: milestone)?.resume(throwing: error)
    }

    // MARK: - Control connection

    private func startControlReader(_ socket: RexSocket) {
        controlReader = Task { [weak self] in
            do {
                for try await message in socket.messages {
                    await self?.handleControl(message)
                }
                await self?.linkEnded(nil)
            } catch {
                await self?.linkEnded(Self.failure(from: error).message, failed: true)
            }
        }
    }

    private func handleControl(_ message: WebSocketCodec.Message) {
        switch message {
        case .text(let text):
            switch RexWire.decodeInbound(text) {
            case .welcome(let id)?:
                if let id { clientID = id }
                reach(.welcome)
            case .response(let id, let result)?:
                settle(id, result.map(Reply.init(payload:)).mapError { $0 as Error })
            case .event(let type, let fields)?:
                handleEvent(type, fields)
            case .unknown?, nil:
                break
            }
        case .close(_, let reason):
            linkEnded(reason.isEmpty ? nil : reason)
        case .binary, .ping, .pong:
            break
        }
    }

    private func handleEvent(_ type: String, _ fields: [String: Any]) {
        guard fields["block_id"] as? String == blockID else { return }
        switch type {
        case "block_owner_changed":
            // nil when the event names no owner — the next keystroke then
            // claims the block again, which is the safe reading.
            owner = fields["owner"] as? String
        case "block_closed":
            finish(nil)
        default:
            break
        }
    }

    // MARK: - Data connection

    private func startDataReader(_ socket: RexSocket) {
        let generation = dataGeneration
        dataReader = Task { [weak self] in
            do {
                for try await message in socket.messages {
                    await self?.handleData(message, generation: generation)
                }
                await self?.dataLinkEnded(nil, generation: generation)
            } catch {
                await self?.dataLinkEnded(
                    Self.failure(from: error).message, failed: true, generation: generation)
            }
        }
    }

    private func dataLinkEnded(_ reason: String?, failed: Bool = false, generation: Int) {
        guard generation == dataGeneration else { return }
        linkEnded(reason, failed: failed)
    }

    private func handleData(_ message: WebSocketCodec.Message, generation: Int) {
        guard generation == dataGeneration else { return }
        switch message {
        case .binary(let bytes):
            guard stream != nil else {
                switch RexWire.parseDataReply(bytes) {
                case .welcome(let nonce)?:
                    self.stream = RexTerminalStream(nonce: nonce)
                    reach(.dataWelcome)
                case .reject(let reason)?:
                    fail(.dataWelcome, Failure(String(localized: """
                        The Rex server refused the terminal stream: \
                        \(RexWire.rejectDescription(reason)).
                        """)))
                case nil:
                    fail(.dataWelcome, Failure(String(
                        localized: "The Rex server answered the stream handshake unreadably.")))
                }
                return
            }
            // In place: a copy taken out and put back would share the
            // stream's buffer and force it to be duplicated on every chunk.
            let events = stream?.consume(bytes) ?? []
            if stream?.isLive == true { reach(.live) }
            for event in events {
                switch event {
                case .output(let output):
                    if held == nil { deliver(output) } else { held?.append(output) }
                case .resize, .childExited:
                    // The size is this tab's own while it owns the block,
                    // and a program's exit closes the block, which arrives
                    // as the stream's close. Neither needs acting on here.
                    break
                }
            }
        case .close(let code, let reason):
            // 4000 is "block closed" and 1000 a stream that simply ended —
            // both a clean end, like a shell exiting.
            if code == 4000 || code == 1000 || code == nil {
                finish(nil)
            } else {
                finish(String(localized: "Rex closed the terminal stream: \(reason)."))
            }
        case .text, .ping, .pong:
            break
        }
    }

    // MARK: - Ending

    /// A connection ended without this side asking. Before the attach has
    /// finished that is a failed attach (thrown from `open`); after, it is
    /// the tab ending.
    ///
    /// `failed` marks a link that broke rather than closed. Under a live
    /// tab that is said as what it is — the connection was lost — and the
    /// error underneath is left out: it is the transport's own shorthand
    /// (`Already closed`, seen on the first headless run), which reads as a
    /// second, unrelated failure. During the attach the detail IS the
    /// reason ("no Rex server is running"), so it is kept.
    private func linkEnded(_ reason: String?, failed: Bool = false) {
        guard phase != .closed else { return }
        guard phase == .live else {
            let failure = Failure(reason ?? String(
                localized: "The connection to the Rex server ended."))
            for milestone in Array(waiters.keys) { fail(milestone, failure) }
            for id in Array(pending.keys) { settle(id, .failure(failure)) }
            return
        }
        finish(failed
            ? String(localized: "The connection to the Rex server was lost.")
            : reason)
    }

    private func finish(_ reason: String?) {
        guard phase != .closed else { return }
        // Only a tab that went live has someone to tell; a failed attach
        // is reported by `open` throwing.
        let notify = phase == .live ? onClose : nil
        phase = .closed
        Task {
            await self.teardown(failing: Failure(reason ?? "ended"))
            notify?(reason)
        }
    }

    private func teardown(failing failure: Failure) async {
        for milestone in Array(waiters.keys) { fail(milestone, failure) }
        for id in Array(pending.keys) { settle(id, .failure(failure)) }
        let data = self.data, control = self.control
        self.data = nil
        self.control = nil
        // Say goodbye BEFORE the readers are cancelled: cancelling a reader
        // tears its pipe down, and a connection that just drops is kept by
        // the server for a minute — its client listed as "connection lost",
        // its stream parked for a resume nobody will send (seen on the
        // first headless run). The data connection goes first, with status
        // 1000, which ends the stream; a control connection closed with a
        // close frame ends its client at once.
        await data?.close()
        await control?.close()
        controlReader?.cancel()
        dataReader?.cancel()
        controlReader = nil
        dataReader = nil
    }

    /// Turns whatever the layers below threw into one readable sentence.
    private static func failure(from error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if let server = error as? RexWire.ServerError {
            return Failure(server.code == "session_not_found"
                ? String(localized: "This Rex session no longer exists.")
                : String(localized: "The Rex server refused: \(server.message)"))
        }
        if case SSHConnectionError.connectFailed(let detail) = error {
            return Failure(String(localized: "Couldn't reach the Rex server. \(detail)"))
        }
        if case WebSocketCodec.Failure.upgradeRefused(let status, _) = error {
            return Failure(String(
                localized: "The Rex server refused the connection (\(String(status)))."))
        }
        return Failure(String(
            localized: "Couldn't attach the Rex session. \(error.localizedDescription)"))
    }
}
