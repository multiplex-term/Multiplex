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

/// A terminal tab attached to one window of a Rex session — the app's first
/// `PanedTerminalTransport`.
///
/// Rex has no terminal client to run in a PTY (see `RexProbe`), so this IS
/// the client: it speaks the server's WebSocket API through byte pipes on
/// the tab's SSH connection (`SSHConnection.openPipe` running `rex
/// __internal dial-stdio`, the bridge Rex's own `ssh://` transport uses).
///
/// - ONE **control** connection attaches to the session, reads its view,
///   claims and sizes terminals, carries every keystroke as a
///   `com.superlogical.terminal.write` call, and changes the layout.
/// - One **data** connection PER TERMINAL carries that terminal's output,
///   one way. A window of five panes is six pipes.
///
/// A tab draws one layer of one window: the layer holding the terminal it
/// was opened on (`RexWire.Layer`). Its panes are that layer's terminal
/// blocks, a pane's id its block's. The layout is the server's — this side
/// asks (`perform`) and then hears the answer in the view like any other
/// client's change.
///
/// What is deliberate here:
/// - **Each screen is bootstrapped from `format`, not from the stream.** A
///   stream opens with a Ghostty binary snapshot SwiftTerm cannot read
///   (`RexTerminalStream` drops it), so the starting screen comes from the
///   `vt` rendering instead. The terminal is claimed and sized BEFORE either
///   is asked for, so both describe it at its pane's size — which is why the
///   tab is asked to lay the panes out first (`PaneEvents.arrange`).
/// - **The two are not atomic, and the gap errs toward repeating.** The
///   stream is opened first and held while `format` is fetched: output the
///   program wrote in between is drawn twice (once inside the rendering,
///   once from the stream) rather than lost. Lost bytes can leave a mode
///   wrong for the rest of the session; a repeated line is one line.
/// - **The last client to type owns the sizes**, as with tmux's
///   latest-client rule. Another client (the Rex app) can claim a terminal
///   back; the next keystroke here claims every terminal the tab draws and
///   re-sizes each to its pane. All of them, because the tab draws them as
///   one window: a pane left at another client's size beside one at this
///   tab's is a layout nobody chose.
/// - **An emulator's grid is its terminal's, not always its pane's.** A
///   terminal has one size, its owner's. While another client owns it the
///   stream says what that size is (`resize`), and the emulator is given
///   that grid (`PaneEvents.grid`) and its screen drawn again — output laid
///   out for 170 columns and parsed at 132 left stray characters all over
///   the tab (user-reported, reproduced with a stand-in client holding the
///   block).
/// - **Only what a person does is written.** `write` is what claims, so
///   nothing may reach it that the emulator said by itself. The server
///   parses the terminal's output too and answers its queries there; the
///   emulator's own answers are stopped before this transport
///   (`TerminalSessionController.sendTerminalReport`). Sent on, each one
///   was a second answer in the program's input and a claim nobody made.
/// - **The tab's focus is the tab's.** Which pane has the keyboard here is
///   never written to the server: `session.focus_block` also makes the
///   block's window the session's active one, which is what the Rex app on
///   the host is showing. `PaneCommand.focus` is only remembered — it
///   decides which layer the tab keeps drawing and where focus goes when
///   that pane closes.
/// - **The palette is the app's.** `extra_palette` is not requested: it
///   would repaint the tab in Rex's theme.
/// - **A terminal attached during a full-screen program redraws when it
///   exits.** While one is up, `format` renders only its screen — the shell
///   history underneath cannot be asked for — so the emulator's primary
///   screen starts empty and leaving vim showed a bare prompt (seen on the
///   first headless run). `AlternateScreenExitWatch` notices the exit and
///   the screen is fetched again, under the same hold-then-flush rule as
///   the attach.
actor RexSession: PanedTerminalTransport {
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

    /// Opens one byte pipe to the Rex server's socket: once for the control
    /// connection, then once per terminal. A closure rather than the
    /// connection itself so the whole session can be driven by an
    /// in-process server under test.
    private let openPipe: @Sendable () async throws -> RemotePipe
    /// Drops whatever the pipes ride on — the tab's SSH connection.
    private let closeLink: @Sendable () async -> Void
    private let sessionID: String
    private let preferredBlockID: String?
    private let clientVersion: String

    private var control: RexSocket?
    private var controlReader: Task<Void, Never>?

    private struct Reply: @unchecked Sendable {
        var payload: [String: Any]
    }
    private var pending: [String: CheckedContinuation<Reply, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var requestCount = 0

    /// A point a handshake has to reach. The two a stream has are named by
    /// its terminal's serial, so a milestone of an earlier stream of the
    /// same block can never be mistaken for this one's.
    private enum Milestone: Hashable {
        case welcome
        case dataWelcome(Int)
        case live(Int)
    }
    private var reached: Set<Milestone> = []
    private var waiters: [Milestone: CheckedContinuation<Void, Error>] = [:]

    private var clientID: String?
    /// `attaching` until `open` returns; `closed` is final, whichever side
    /// ended it.
    private enum Phase { case attaching, live, closed }
    private var phase = Phase.attaching
    private var events: PaneEvents?

    /// One terminal the tab draws: its stream, and everything about putting
    /// that stream on its emulator. A reference so the many steps that
    /// suspend can keep mutating the one record; it never leaves the actor.
    private final class Terminal {
        let id: String
        /// Tells this stream of the block from an earlier one — a pane that
        /// left the tab and came back is a new terminal here.
        let serial: Int
        /// The grid this tab asks the terminal to be: its pane's.
        var size: TerminalGrid
        var socket: RexSocket?
        var reader: Task<Void, Never>?
        var stream: RexTerminalStream?
        /// Stream output that arrived before the screen was drawn, kept to
        /// be drawn after it. nil once the screen is up: output goes
        /// straight through.
        var held: Data? = Data()
        /// Set while the emulator's primary screen is known to be
        /// incomplete — the bootstrap was rendered during a full-screen
        /// program.
        var exitWatch: AlternateScreenExitWatch?
        var lastOutput = ContinuousClock.now
        /// The grid the terminal has while it is someone else's to size —
        /// what the stream last said. nil while its size is this tab's own.
        var terminalGrid: TerminalGrid?
        /// What the emulator was last told (`PaneEvents.grid`); nil is its
        /// own grid.
        var shownGrid: TerminalGrid?
        /// One redraw at a time: each waits for the one before it.
        var drawing: Task<Void, Never>?
        var isResyncing = false
        var owner: String?
        var input = RexInputEncoder()
        var pendingInput = ""
        var isWriting = false
        /// Nothing more will come from it or go to it: its program exited,
        /// its block closed, or its stream could not be opened.
        var hasEnded = false

        init(id: String, serial: Int, size: TerminalGrid) {
            self.id = id
            self.serial = serial
            self.size = size
        }
    }

    private var terminals: [String: Terminal] = [:]
    private var terminalSerial = 0
    /// The window and layer the tab draws.
    private var shown: (windowID: String, layerID: String)?
    private var layout: PaneLayout?
    private var viewRevision = -1
    /// The oldest view worth adopting: the revision the server gave in
    /// answer to this tab's own last change. A view read before that
    /// answer can still arrive after it, and would undo the change on
    /// screen until the next one put it back.
    private var floorRevision = -1
    /// The grid the tab last measured for a pane, kept even before the
    /// terminal is known here: a pane is laid out — and measured — before
    /// its terminal is opened.
    private var requestedSizes: [String: TerminalGrid] = [:]
    /// The pane the tab's keyboard is on (`PaneCommand.focus`).
    private var focusedBlockID: String?
    /// A terminal this tab just made, to be focused when the view shows it.
    private var pendingFocus: String?
    /// A terminal the tab was asked to show, wherever in the session it is.
    private var retarget: String?
    private var wantsViewRefresh = false
    private var isRefreshingView = false
    /// Ratios this tab asked for that the server has not answered yet. Until
    /// it has, they stand in for the view's: the answer to an earlier ask
    /// would otherwise drag a divider back under the finger.
    private var pendingRatios: [String: Double] = [:]
    private var isSendingRatios = false

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

    /// The app's form: every pipe rides `connection`, each running the Rex
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

    /// Attaches and returns once every terminal of the window has been
    /// drawn — or failed to open; one that failed says so in its own pane.
    /// The attach itself fails only when none could be opened.
    /// `events.close` fires at most once, later, when the window or the
    /// link ends on its own.
    func open(events: PaneEvents) async throws {
        self.events = events
        do {
            try await attach()
            if phase == .attaching { phase = .live }
            // A change that arrived mid-attach waited for it to finish.
            if wantsViewRefresh { scheduleViewRefresh() }
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
        let view = attached["view"] as? [String: Any] ?? [:]
        guard let target = RexWire.attachTarget(
                  in: RexWire.terminalBlocks(inView: view), preferring: preferredBlockID),
              let layer = RexWire.layer(holding: target.id, inView: view)
        else {
            throw Failure(String(localized: "This Rex session has no terminal to open."))
        }
        let failures = await show(layer, focusing: target.id, in: view)
        // A pane that could not be opened beside ones that could is that
        // pane's news. With nothing opened there is no tab to show it in.
        if failures.count == layer.layout.panes.count,
           let failure = failures[target.id] ?? failures.values.first {
            throw failure
        }
        for (id, failure) in failures { report(failure, inTerminal: id) }
    }

    // MARK: - The view

    /// The server's view of the session changed, or something here needs it
    /// read again. One reader at a time; a change during a read is read
    /// after it.
    private func scheduleViewRefresh() {
        wantsViewRefresh = true
        guard phase == .live, !isRefreshingView else { return }
        isRefreshingView = true
        Task { await self.refreshView() }
    }

    private func refreshView() async {
        defer { isRefreshingView = false }
        while wantsViewRefresh, phase == .live {
            wantsViewRefresh = false
            guard let view = try? await call("session.view", ["session_id": sessionID]),
                  phase == .live
            else { return }
            // Older than this tab's own last change: the read that follows
            // that change is already asked for.
            if let revision = view["revision"] as? Int, revision < floorRevision { continue }
            let target = retarget
            retarget = nil
            let layer = target.flatMap { RexWire.layer(holding: $0, inView: view) }
                ?? shown.flatMap {
                    RexWire.layer(
                        windowID: $0.windowID, layerID: $0.layerID,
                        preferring: focusedBlockID, inView: view)
                }
            guard let layer else {
                // The window this tab drew has closed, or its last terminal
                // has — a clean end, like a shell exiting.
                finish(nil)
                return
            }
            let failures = await show(layer, focusing: target, in: view)
            for (id, failure) in failures { report(failure, inTerminal: id) }
        }
    }

    /// Makes `layer` what the tab draws: tells the tab how its panes are
    /// arranged, lets go of terminals that left, and opens the ones that
    /// are new. Returns the new terminals that could not be opened.
    ///
    /// Never runs twice at once — the attach calls it before the tab is
    /// live, the view reader after — so what it read before suspending is
    /// still true when it resumes.
    private func show(
        _ layer: RexWire.Layer, focusing wanted: String?, in view: [String: Any]
    ) async -> [String: Failure] {
        if let revision = view["revision"] as? Int { viewRevision = max(viewRevision, revision) }
        shown = (layer.windowID, layer.layerID)
        let previous = layout
        var next = layer.layout
        for (splitID, ratio) in pendingRatios {
            next = next.settingRatio(ratio, ofSplit: splitID)
        }
        let ids = next.panes.map(\.rawValue)
        let gone = terminals.keys.filter { !ids.contains($0) }
        let added = ids.filter { terminals[$0] == nil }
        let blocks = RexWire.terminalBlocks(inView: view)

        // Focus moves only for a reason: a terminal the tab asked for, one
        // it just made, or the one it was on having gone.
        var focus = wanted.flatMap { ids.contains($0) ? $0 : nil }
        if focus == nil, let pendingFocus, ids.contains(pendingFocus) {
            focus = pendingFocus
        }
        if focus == nil, focusedBlockID.map({ !ids.contains($0) }) ?? true {
            let neighbor = focusedBlockID
                .flatMap { previous?.neighbor(ofClosing: PaneID($0))?.rawValue }
                .flatMap { ids.contains($0) ? $0 : nil }
            focus = neighbor ?? layer.focusedBlockID ?? next.firstPane.rawValue
        }
        if let focus {
            focusedBlockID = focus
            if pendingFocus == focus { pendingFocus = nil }
        }

        // Most view changes are not about the layout at all (every change
        // of owner is one); those say nothing to the tab.
        guard next != previous || focus != nil || !added.isEmpty || !gone.isEmpty
        else { return [:] }
        layout = next
        let measured = await events?.arrange(
            PaneArrangement(layout: next, focus: focus.map(PaneID.init))) ?? [:]
        guard phase != .closed else { return [:] }

        for id in gone { await retire(id) }
        // A terminal that only left this tab's window is given up as well
        // as left: owning it is what makes it follow this tab's size, and
        // the client still showing it gets its own back. One that closed
        // is not named — a single unknown id fails the whole call.
        let existing = Set(blocks.map(\.id))
        let released = gone.filter(existing.contains).sorted()
        if !released.isEmpty {
            _ = try? await call("session.disown_block", [
                "session_id": sessionID, "block_ids": released,
            ])
        }

        var opening: [(id: String, serial: Int)] = []
        for id in added where terminals[id] == nil {
            terminalSerial += 1
            // What the pane's pump said since it was laid out is newer than
            // what the layout pass returned.
            let size = requestedSizes[id] ?? measured[PaneID(id)]
                ?? TerminalGrid(cols: 80, rows: 24)
            terminals[id] = Terminal(id: id, serial: terminalSerial, size: size)
            opening.append((id, terminalSerial))
        }
        guard !opening.isEmpty else { return [:] }
        // Claim and size first: the rendering and the stream each terminal
        // is opened with must both describe it at its pane's size.
        //
        // Claimed: what the tab was pointed at (the attach, a switch), what
        // is already this client's — a terminal it just made, which the
        // server hands its maker — and what is nobody's. A pane ANOTHER
        // client holds is not: the tab only follows there, and draws it at
        // its owner's size until someone types here (`drainInput`).
        let theirs = Set(blocks.filter { $0.owner != nil && $0.owner != clientID }.map(\.id))
        await claim(opening.map(\.id).filter { wanted != nil || !theirs.contains($0) })
        return await withTaskGroup(of: (String, Failure?).self) { group in
            for (id, serial) in opening {
                group.addTask { (id, await self.openStream(id, serial)) }
            }
            var failures: [String: Failure] = [:]
            for await (id, failure) in group {
                if let failure { failures[id] = failure }
            }
            return failures
        }
    }

    /// The terminal `id` names, if it is still the one `serial` was.
    private func current(_ id: String, _ serial: Int) -> Terminal? {
        guard phase != .closed, let terminal = terminals[id], terminal.serial == serial
        else { return nil }
        return terminal
    }

    /// Opens one terminal's stream and draws its screen. Returns why it
    /// could not; nil when it is up, or is no longer wanted.
    private func openStream(_ id: String, _ serial: Int) async -> Failure? {
        do {
            let ticket = try await call("data.connect", [
                "session_id": sessionID,
                "block_id": id,
                "data_ref_id": "terminal",
                "subprotocol": RexWire.terminalSubprotocol,
            ])
            guard let hello = (ticket["ticket"] as? String).flatMap(RexWire.dataHello) else {
                throw Failure(String(localized: "The Rex server issued no usable stream ticket."))
            }
            let socket = try await RexSocket.open(
                over: try await openPipe(),
                path: RexWire.dataPath, subprotocol: RexWire.terminalSubprotocol)
            guard let terminal = current(id, serial) else {
                await socket.close()
                return nil
            }
            terminal.socket = socket
            try await socket.send(.binary, hello)
            startDataReader(socket, id: id, serial: serial)
            try await wait(for: .dataWelcome(serial))
            // The snapshot has passed once the first server message
            // arrives; only then is the terminal's state settled enough to
            // render.
            try await wait(for: .live(serial))
            await drawScreen(id, serial)
            return nil
        } catch {
            guard let terminal = current(id, serial) else { return nil }
            terminal.hasEnded = true
            let socket = terminal.socket
            terminal.socket = nil
            await socket?.close()
            terminal.reader?.cancel()
            return Self.failure(from: error)
        }
    }

    /// Says in a terminal's own pane why it could not be opened. The tab
    /// stays: its other panes are fine, and RECONNECT is not on offer while
    /// it is live — closing and reopening the tab attaches afresh.
    private func report(_ failure: Failure, inTerminal id: String) {
        let text = String(localized: "Couldn't open this terminal. \(failure.message)")
        events?.output(PaneID(id), Data("\u{1B}c".utf8) + Data(text.utf8))
    }

    /// Lets go of a terminal the tab no longer draws.
    private func retire(_ id: String) async {
        guard let terminal = terminals.removeValue(forKey: id) else { return }
        requestedSizes[id] = nil
        let failure = Failure("closed")
        for milestone in [Milestone.dataWelcome(terminal.serial), .live(terminal.serial)] {
            reached.remove(milestone)
            fail(milestone, failure)
        }
        terminal.hasEnded = true
        let socket = terminal.socket
        terminal.socket = nil
        // Status 1000 ends the stream rather than parking it for a resume.
        await socket?.close()
        terminal.reader?.cancel()
    }

    /// The directory one terminal is working in — what a file drop lands in
    /// and a file viewer opens at. nil when the tab is not live or the
    /// server cannot say.
    func workingDirectory(of pane: PaneID) async -> String? {
        guard phase == .live, terminals[pane.rawValue] != nil,
              let process = try? await terminalCall("process", block: pane.rawValue)
        else { return nil }
        return RexWire.workingDirectory(inProcess: process)
    }

    // MARK: - The session's other terminals

    /// Every terminal of the session, as the REX panel's Switch Terminal
    /// rows, with the one this tab's keyboard is on marked. Read fresh each
    /// time the panel opens: windows come and go in Rex without telling the
    /// tab.
    func terminalChoices() async -> [TmuxWindowChoice]? {
        guard phase == .live,
              let view = try? await call("session.view", ["session_id": sessionID])
        else { return nil }
        return RexWire.terminalChoices(
            in: RexWire.terminalBlocks(inView: view), showing: focusedBlockID)
    }

    /// Points the tab at a terminal of its session, wherever it is: one of
    /// the panes on show takes the focus; one in another window brings that
    /// window's panes in, in place — the control connection and the tab
    /// stay. One that has since closed changes nothing.
    func showTerminal(_ blockID: String) {
        guard phase == .live else { return }
        retarget = blockID
        scheduleViewRefresh()
    }

    // MARK: - Changing the layout

    func perform(_ command: PaneCommand) async throws {
        guard phase == .live else { throw Failure("not attached") }
        do {
            switch command {
            case .focus(let pane):
                if terminals[pane.rawValue] != nil { focusedBlockID = pane.rawValue }
            case .split(let pane, let axis):
                // A new shell starts where the one it was split from is,
                // as tmux's and herdr's splits do here.
                let cwd = await workingDirectory(of: pane)
                let made = try await call("session.new_split", RexWire.newSplitPayload(
                    sessionID: sessionID, anchorID: pane.rawValue, axis: axis, cwd: cwd))
                pendingFocus = (made["block_ids"] as? [String])?.first
                noteOwnChange(made)
            case .close(let pane):
                let closed = try await call("block.close", [
                    "session_id": sessionID, "block_id": pane.rawValue,
                ])
                noteOwnChange(closed)
            case .newWindow(let pane):
                let cwd = await workingDirectory(of: pane)
                let made = try await call("session.new_window", RexWire.newWindowPayload(
                    sessionID: sessionID, cwd: cwd))
                // The tab goes where its new terminal is: the next view
                // read brings that window in, as Switch Terminal would.
                if let block = (made["block_ids"] as? [String])?.first { retarget = block }
                noteOwnChange(made)
            case .setRatio(let ratio, let splitID):
                guard layout?.split(withID: splitID) != nil else { return }
                pendingRatios[splitID] = ratio
                layout = layout?.settingRatio(ratio, ofSplit: splitID)
                guard !isSendingRatios else { return }
                isSendingRatios = true
                Task { await self.sendRatios() }
            }
        } catch {
            throw Self.failure(from: error)
        }
    }

    /// The server answered a change this tab made: the view is worth reading
    /// again, and nothing older than the answer is.
    private func noteOwnChange(_ result: [String: Any]) {
        if let revision = result["revision"] as? Int {
            floorRevision = max(floorRevision, revision)
        }
        scheduleViewRefresh()
    }

    /// One `resize_pane` in flight at a time, each carrying the newest
    /// ratio asked for: a drag asks many times a second and only where the
    /// divider is NOW matters.
    private func sendRatios() async {
        defer { isSendingRatios = false }
        var sent: [String: Double] = [:]
        while phase == .live,
              let next = pendingRatios.first(where: { sent[$0.key] != $0.value }) {
            guard let split = layout?.split(withID: next.key) else {
                pendingRatios[next.key] = nil
                continue
            }
            sent[next.key] = next.value
            let answer = try? await call("session.resize_pane", RexWire.resizePanePayload(
                sessionID: sessionID, split: split, ratio: next.value))
            if let revision = answer?["revision"] as? Int {
                floorRevision = max(floorRevision, revision)
            }
        }
        // Everything asked for has been answered: the server's word stands
        // again, including where it refused.
        pendingRatios.removeAll()
        scheduleViewRefresh()
    }

    // MARK: - Drawing a screen

    /// How much of the held stream a redraw draws after the rendering.
    private enum Replay {
        /// All of it. The attach's rule: nothing says where in the held
        /// bytes the rendering was taken, so it errs toward repeating.
        case everything
        /// Only what arrived after the rendering was asked for. Whatever
        /// came before that is in the rendering for certain, and the redraw
        /// that asks for this has waited for the terminal to go quiet.
        case sinceRequest
    }

    /// Renders a terminal's current screen into its emulator, then lets the
    /// stream through. Stream output is held from the moment this is called
    /// (an opening terminal holds it from the start) to the moment the
    /// rendering has been drawn, so nothing is drawn UNDER a rendering that
    /// was taken later, and nothing that arrived meanwhile is dropped.
    ///
    /// Redraws of one terminal run one at a time. Two at once shared one
    /// hold: the first to finish let the stream through, and the second
    /// then wiped whatever had been drawn since its own rendering was taken.
    private func drawScreen(_ id: String, _ serial: Int, replay: Replay = .everything) async {
        guard let terminal = current(id, serial) else { return }
        terminal.held = terminal.held ?? Data()
        let previous = terminal.drawing
        let task = Task {
            await previous?.value
            await self.performDraw(id, serial, replay: replay)
        }
        terminal.drawing = task
        await task.value
    }

    private func performDraw(_ id: String, _ serial: Int, replay: Replay) async {
        // Retired since this was asked for: there is no emulator to draw on.
        guard let terminal = current(id, serial) else { return }
        terminal.held = terminal.held ?? Data()
        await adoptTerminalGrid(terminal)
        let asked = terminal.held?.count ?? 0
        // Two reads that depend on nothing of each other's, so they share
        // one round trip.
        async let alternate = isOnAlternateScreen(blockID: id)
        async let rendering = bootstrapScreen(blockID: id)
        let (onAlternateScreen, screen) = await (alternate, rendering)
        guard current(id, serial) != nil else { return }
        // RIS first: a resumed tab still shows what the last run drew.
        events?.output(PaneID(id), Data([0x1B, 0x63]) + screen)
        terminal.exitWatch = onAlternateScreen ? AlternateScreenExitWatch() : nil
        let pending = terminal.held ?? Data()
        terminal.held = nil
        let rest = replay == .everything
            ? pending
            : pending.dropFirst(RexWire.resumeOffset(in: pending, from: asked))
        if !rest.isEmpty { deliver(Data(rest), from: terminal) }
        // The size changed again while the rendering was on its way.
        if terminal.terminalGrid != terminal.shownGrid, !terminal.isResyncing {
            terminal.held = Data()
            Task { await self.resync(id, serial) }
        }
    }

    // MARK: - Another client's size

    /// The stream said what size the terminal is. While this client owns
    /// the block that is its pane's own size and nothing changes; otherwise
    /// it is whatever its owner made it, and the emulator has to follow.
    private func noteTerminalSize(
        cols: Int, rows: Int, owner: String?, of terminal: Terminal
    ) {
        let isOwn = (owner != nil && owner == clientID)
            || (cols == terminal.size.cols && rows == terminal.size.rows)
        terminal.terminalGrid = isOwn ? nil : TerminalGrid(cols: cols, rows: rows)
        // While the screen is still to be drawn (an opening terminal, a
        // redraw already holding) that redraw reads the grid itself.
        guard terminal.terminalGrid != terminal.shownGrid, terminal.held == nil else { return }
        // Everything from here on was written for the new size.
        terminal.held = Data()
        let id = terminal.id, serial = terminal.serial
        Task { await self.resync(id, serial) }
    }

    /// Gives the emulator the terminal's grid and draws the screen again at
    /// it, once the burst a resize sets off has passed — the program
    /// repaints on SIGWINCH, and a rendering taken mid-repaint would have
    /// the rest of it drawn on top a second time.
    ///
    /// It redraws even when the size has gone back by then: what was
    /// written in between was laid out for a grid the emulator never had.
    private func resync(_ id: String, _ serial: Int) async {
        guard let terminal = current(id, serial), !terminal.isResyncing else { return }
        terminal.isResyncing = true
        defer { terminal.isResyncing = false }
        repeat {
            terminal.held = terminal.held ?? Data()
            await waitForQuiet(terminal)
            guard current(id, serial) != nil else { return }
            await drawScreen(id, serial, replay: .sinceRequest)
        } while current(id, serial) != nil && terminal.terminalGrid != terminal.shownGrid
    }

    private func adoptTerminalGrid(_ terminal: Terminal) async {
        while terminal.terminalGrid != terminal.shownGrid,
              current(terminal.id, terminal.serial) != nil {
            let grid = terminal.terminalGrid
            await events?.grid(PaneID(terminal.id), grid)
            terminal.shownGrid = grid
        }
    }

    /// Returns once the terminal has written nothing for a moment, or
    /// after the cap for one that never stops.
    private func waitForQuiet(_ terminal: Terminal) async {
        let started = ContinuousClock.now
        while current(terminal.id, terminal.serial) != nil {
            try? await Task.sleep(for: .milliseconds(60))
            let now = ContinuousClock.now
            if now - terminal.lastOutput >= .milliseconds(120)
                || now - started >= .milliseconds(800) {
                break
            }
        }
    }

    /// Stream output on its way to the emulator. The one place that also
    /// watches for a full-screen program exiting, when that matters.
    private func deliver(_ output: Data, from terminal: Terminal) {
        events?.output(PaneID(terminal.id), output)
        terminal.lastOutput = .now
        guard terminal.exitWatch?.sawExit(in: output) == true else { return }
        terminal.exitWatch = nil
        let id = terminal.id, serial = terminal.serial
        Task { await self.redrawOnceQuiet(id, serial) }
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
    private func redrawOnceQuiet(_ id: String, _ serial: Int) async {
        guard let terminal = current(id, serial) else { return }
        await waitForQuiet(terminal)
        await drawScreen(id, serial)
    }

    /// Whether a full-screen program currently owns the terminal. Asked of
    /// the server rather than read out of the rendering: `modes` states it
    /// outright. An answer that cannot be had reads as "no".
    private func isOnAlternateScreen(blockID: String) async -> Bool {
        let modes = try? await terminalCall("modes", block: blockID)
        return modes?["screen"] as? String == "alternate"
    }

    /// Makes this client the owner of `ids` and gives each terminal its
    /// pane's size. Best effort: a refusal leaves a terminal at someone
    /// else's size, which is wrong-looking but not fatal.
    private func claim(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        let claimed = try? await call("session.own_block", [
            "session_id": sessionID, "block_ids": ids, "mode": "take",
        ])
        // One id that is no longer a block fails the whole call and claims
        // nothing — a pane closing as another is typed into. Each alone,
        // then, so the rest are still claimed.
        if claimed == nil, ids.count > 1 {
            for id in ids { await claim([id]) }
            return
        }
        for entry in claimed?["blocks"] as? [[String: Any]] ?? [] {
            guard let id = entry["block_id"] as? String else { continue }
            terminals[id]?.owner = entry["owner"] as? String ?? clientID
        }
        for id in ids {
            if let terminal = terminals[id] { await sendSize(to: terminal) }
        }
    }

    /// Applies at once while this client owns the block, and otherwise
    /// waits server-side until it does — never a failure worth raising.
    private func sendSize(to terminal: Terminal) async {
        _ = try? await terminalCall(
            "resize", block: terminal.id,
            ["columns": terminal.size.cols, "rows": terminal.size.rows])
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

    // MARK: - PanedTerminalTransport

    /// Queues the input and returns; it does not wait for the server.
    ///
    /// One write per terminal is in flight at a time — the server runs
    /// block methods concurrently, so two calls could land out of order —
    /// and whatever is typed meanwhile rides the next call as one string.
    /// Returning at once is what lets that happen: the tab's input pump
    /// awaits each write, so a write that waited for its answer would turn
    /// every keystroke into a round trip of its own, queued behind the last.
    func write(_ data: Data, to pane: PaneID) async throws {
        guard phase == .live else { throw Failure("not attached") }
        // A pane whose program has gone takes nothing; neither does one the
        // view has not brought in yet.
        guard let terminal = terminals[pane.rawValue], !terminal.hasEnded else { return }
        terminal.pendingInput += terminal.input.encode(data)
        guard !terminal.isWriting, !terminal.pendingInput.isEmpty else { return }
        terminal.isWriting = true
        let id = terminal.id, serial = terminal.serial
        Task { await self.drainInput(id, serial) }
    }

    private func drainInput(_ id: String, _ serial: Int) async {
        guard let terminal = current(id, serial) else { return }
        defer { terminal.isWriting = false }
        while !terminal.pendingInput.isEmpty, phase == .live,
              current(id, serial) != nil, !terminal.hasEnded {
            let text = terminal.pendingInput
            terminal.pendingInput = ""
            // Typing is what claims the sizes back from another client —
            // every terminal the tab draws, the one typed into first.
            if terminal.owner != clientID {
                let others = terminals.values
                    .filter { $0.id != id && !$0.hasEnded && $0.owner != clientID }
                    .map(\.id).sorted()
                await claim([id] + others)
            }
            do {
                _ = try await terminalCall("write", block: id, ["data": text])
            } catch {
                Self.log.debug("write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func resize(pane: PaneID, cols: Int, rows: Int) async throws {
        let grid = TerminalGrid(cols: cols, rows: rows)
        requestedSizes[pane.rawValue] = grid
        guard let terminal = terminals[pane.rawValue] else { return }
        terminal.size = grid
        guard phase != .closed, !terminal.hasEnded else { return }
        await sendSize(to: terminal)
    }

    /// Idempotent, and always closes the SSH connection the pipes ride: a
    /// tab that ended on its own (`finish`) still has that link to drop.
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
        switch type {
        case "session_view_changed":
            // Only the revision rides the event, and events can arrive out
            // of order: one at or below the view on hand is old news.
            if let revision = fields["revision"] as? Int, revision <= viewRevision { return }
            scheduleViewRefresh()
        case "block_owner_changed":
            // nil when the event names no owner — the next keystroke then
            // claims the block again, which is the safe reading.
            guard let id = fields["block_id"] as? String else { return }
            terminals[id]?.owner = fields["owner"] as? String
        case "block_closed":
            guard let id = fields["block_id"] as? String, let terminal = terminals[id]
            else { return }
            terminal.hasEnded = true
            // Its place in the layout goes with the next view.
            scheduleViewRefresh()
        default:
            break
        }
    }

    // MARK: - Data connections

    private func startDataReader(_ socket: RexSocket, id: String, serial: Int) {
        terminals[id]?.reader = Task { [weak self] in
            do {
                for try await message in socket.messages {
                    await self?.handleData(message, id, serial)
                }
                await self?.dataLinkEnded(nil, id, serial)
            } catch {
                await self?.dataLinkEnded(
                    Self.failure(from: error).message, failed: true, id, serial)
            }
        }
    }

    /// A terminal's stream stopped without a closing frame. Before the
    /// stream was up that is this terminal failing to open; after, it is
    /// the link under the whole tab — every pipe rides the one connection.
    private func dataLinkEnded(
        _ reason: String?, failed: Bool = false, _ id: String, _ serial: Int
    ) {
        guard let terminal = current(id, serial), !terminal.hasEnded else { return }
        guard reached.contains(.live(serial)) else {
            let failure = Failure(reason ?? String(
                localized: "The connection to the Rex server ended."))
            fail(.dataWelcome(serial), failure)
            fail(.live(serial), failure)
            return
        }
        linkEnded(reason, failed: failed)
    }

    private func handleData(_ message: WebSocketCodec.Message, _ id: String, _ serial: Int) {
        guard let terminal = current(id, serial), !terminal.hasEnded else { return }
        switch message {
        case .binary(let bytes):
            guard terminal.stream != nil else {
                switch RexWire.parseDataReply(bytes) {
                case .welcome(let nonce)?:
                    terminal.stream = RexTerminalStream(nonce: nonce)
                    reach(.dataWelcome(serial))
                case .reject(let reason)?:
                    fail(.dataWelcome(serial), Failure(String(localized: """
                        The Rex server refused the terminal stream: \
                        \(RexWire.rejectDescription(reason)).
                        """)))
                case nil:
                    fail(.dataWelcome(serial), Failure(String(
                        localized: "The Rex server answered the stream handshake unreadably.")))
                }
                return
            }
            // In place: a copy taken out and put back would share the
            // stream's buffer and force it to be duplicated on every chunk.
            let events = terminal.stream?.consume(bytes) ?? []
            if terminal.stream?.isLive == true { reach(.live(serial)) }
            for event in events {
                switch event {
                case .output(let output):
                    if terminal.held == nil {
                        deliver(output, from: terminal)
                    } else {
                        terminal.held?.append(output)
                        terminal.lastOutput = .now
                    }
                case .resize(let cols, let rows, let owner):
                    noteTerminalSize(cols: cols, rows: rows, owner: owner, of: terminal)
                case .childExited:
                    // A program's exit closes the block, which arrives as
                    // the stream's close.
                    break
                }
            }
        case .close(let code, let reason):
            // 4000 is "block closed" and 1000 a stream that simply ended —
            // both a clean end, like a shell exiting. The pane goes when
            // the view no longer has its block; the tab, when that was the
            // last one.
            if code == 4000 || code == 1000 || code == nil {
                terminal.hasEnded = true
                let ended = Failure(String(
                    localized: "The terminal closed before it could be opened."))
                fail(.dataWelcome(serial), ended)
                fail(.live(serial), ended)
                scheduleViewRefresh()
            } else if reached.contains(.live(serial)) {
                finish(String(localized: "Rex closed the terminal stream: \(reason)."))
            } else {
                // A stream that never came up — refused at its handshake,
                // say, in which case that reason is already on its way out
                // of `openStream`. This terminal's failure, not the tab's.
                let failure = Failure(String(
                    localized: "Rex closed the terminal stream: \(reason)."))
                fail(.dataWelcome(serial), failure)
                fail(.live(serial), failure)
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
        let notify = phase == .live ? events?.close : nil
        phase = .closed
        Task {
            await self.teardown(failing: Failure(reason ?? "ended"))
            notify?(reason)
        }
    }

    private func teardown(failing failure: Failure) async {
        for milestone in Array(waiters.keys) { fail(milestone, failure) }
        for id in Array(pending.keys) { settle(id, .failure(failure)) }
        let streams = terminals.values.sorted { $0.serial < $1.serial }
        let sockets = streams.compactMap(\.socket)
        let control = self.control
        for terminal in streams {
            terminal.socket = nil
            terminal.hasEnded = true
        }
        self.control = nil
        // Say goodbye BEFORE the readers are cancelled: cancelling a reader
        // tears its pipe down, and a connection that just drops is kept by
        // the server for a minute — its client listed as "connection lost",
        // its stream parked for a resume nobody will send (seen on the
        // first headless run). The data connections go first, with status
        // 1000, which ends each stream; a control connection closed with a
        // close frame ends its client at once.
        for socket in sockets { await socket.close() }
        await control?.close()
        controlReader?.cancel()
        controlReader = nil
        for terminal in streams {
            terminal.reader?.cancel()
            terminal.reader = nil
        }
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
