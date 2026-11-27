import Foundation

/// The Rex server's wire protocol, as far as a tab drawing one window's
/// terminals needs it: the control connection's JSON messages, the session
/// view and its layout tree, the data connection's binary handshake, and
/// the terminal stream. Pure — `RexSession` owns the sockets.
///
/// Written against API revision 24 (Rex 0.1.0-preview.25, 2026-11-27). The
/// authority is the server's own `GET /llms.txt`, not the website docs; what
/// is restated here is what was also exercised against a live server:
/// - Both connections are WebSockets (`WebSocketCodec`): `/api/control` with
///   subprotocol `rex.control.v1`, every message one JSON object in a text
///   frame; `/api/data` with `rex.data.terminal.v1`, binary frames only.
/// - A client sends one `hello` within 5 seconds, then `request`s. The
///   server answers `welcome`, a `response` per request (matched by `id`),
///   and unsolicited `event`s. The hello states the range of revisions the
///   client speaks and the server picks the newest both do (`apiRevision`,
///   `minimumAPIRevision`).
/// - `session.attach` joins a session; `data.connect` needs that attachment
///   and issues a one-use ticket (16 bytes as 22 base64url characters).
/// - A data connection opens with HELLO `0x01 + ticket`; the server answers
///   WELCOME (`0x81`, 32 bytes, ending in a 64-bit little-endian nonce that
///   is never zero) or REJECT (`0x82 + reason`). After that every binary
///   message is stream bytes; message boundaries mean nothing.
/// - Bytes flow server → client only. Typing is the control connection's
///   `com.superlogical.terminal.write`.
enum RexWire {
    static let controlPath = "/api/control"
    static let controlSubprotocol = "rex.control.v1"
    static let dataPath = "/api/data"
    static let terminalSubprotocol = "rex.data.terminal.v1"
    /// The newest API revision this client speaks — the one its shapes
    /// were last read against (`GET /llms.txt` of a preview.25 server).
    static let apiRevision = 24
    /// The oldest revision this client can use. The server settles on the
    /// newest revision both sides speak and translates to it, so an older
    /// server is spoken to at ITS revision: everything a tab sends and
    /// reads was compared at 14, 19 and 24 and has one shape in all three
    /// (`backends-and-probe.md`). A server from before 14 closes the
    /// connection with status 1008 and a reason that says to update it,
    /// which is what the tab's ended line then reads.
    static let minimumAPIRevision = 14
    static let terminalCreator = "com.superlogical.terminal"

    // MARK: - Control: outbound

    /// The first message on a control connection. Kept far under the
    /// protocol's 512-byte ceiling for a hello.
    ///
    /// ⚠ The kind is `other`, deliberately NOT `app`. Rex's CLI and its
    /// agent skill aim client actions (`rex do pane.split`, "switch my Mac
    /// to this session") at "the app client when exactly one is connected";
    /// a second client calling itself an app would make every one of those
    /// ambiguous for as long as a Multiplex tab is attached. It also keeps
    /// this client out of the deck's own count of app clients, which is
    /// what the LIVE lamp reads (`SessionBackend.isSessionLive`).
    static func hello(clientVersion: String) -> Data {
        json([
            "type": "hello",
            "api_revision": apiRevision,
            "api_min_revision": minimumAPIRevision,
            "client": [
                "kind": "other",
                "platform": "ios",
                "name": "Multiplex",
                "version": clientVersion,
            ],
        ])
    }

    static func request(id: String, method: String, payload: [String: Any]?) -> Data {
        var message: [String: Any] = ["type": "request", "id": id, "method": method]
        if let payload { message["payload"] = payload }
        return json(message)
    }

    /// A block method call: the block's own arguments ride under `args`.
    static func blockPayload(
        sessionID: String, blockID: String, args: [String: Any] = [:]
    ) -> [String: Any] {
        ["session_id": sessionID, "block_id": blockID, "args": args]
    }

    private static func json(_ object: [String: Any]) -> Data {
        // Sorted keys so a request is byte-stable — for the tests, and for
        // anyone reading a capture.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
    }

    // MARK: - Control: inbound

    struct ServerError: Error, Equatable {
        var code: String
        var message: String
        var status: Int
    }

    enum Inbound {
        /// `revision` is the API revision the server settled on for this
        /// connection; a welcome that names none means 0, as the protocol
        /// reads it.
        case welcome(clientID: String?, revision: Int)
        /// `payload` is the method's result as a JSON object (empty for a
        /// result that is not an object).
        case response(id: String, result: Result<[String: Any], ServerError>)
        /// A session event unwrapped to its innermost type and fields.
        case event(type: String, fields: [String: Any])
        /// A `type` this client does not know. The protocol says to skip it.
        case unknown
    }

    static func decodeInbound(_ text: Data) -> Inbound? {
        guard let object = (try? JSONSerialization.jsonObject(with: text)) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        switch type {
        case "welcome":
            guard object["protocol"] as? String == controlSubprotocol else { return nil }
            let client = object["client"] as? [String: Any]
            return .welcome(
                clientID: client?["id"] as? String,
                revision: object["api_revision"] as? Int ?? 0)
        case "response":
            guard let id = object["id"] as? String else { return nil }
            if let error = object["error"] as? [String: Any] {
                return .response(id: id, result: .failure(ServerError(
                    code: error["code"] as? String ?? "internal",
                    message: error["message"] as? String ?? "",
                    status: error["status"] as? Int ?? 500
                )))
            }
            return .response(
                id: id, result: .success(object["payload"] as? [String: Any] ?? [:]))
        case "event":
            guard let payload = object["payload"] as? [String: Any] else { return .unknown }
            return unwrapEvent(payload)
        default:
            return .unknown
        }
    }

    /// A session event arrives wrapped in `session_event`; this client only
    /// ever attaches to one session, so the wrapper carries nothing it needs.
    private static func unwrapEvent(_ payload: [String: Any]) -> Inbound {
        guard let type = payload["type"] as? String else { return .unknown }
        let fields = payload["payload"] as? [String: Any] ?? [:]
        if type == "session_event", let inner = fields["event"] as? [String: Any] {
            return unwrapEvent(inner)
        }
        return .event(type: type, fields: fields)
    }

    // MARK: - Ids and labels

    /// A session id the app may splice into a command or bake into a
    /// route: `session:` and a UUID's characters, nothing a shell could
    /// reinterpret. What a parser reports is truth; what reaches a shell
    /// line is vetted here.
    static func bakeableSessionID(_ id: String) -> Bool {
        let prefix = "session:"
        guard id.hasPrefix(prefix), id.utf8.count <= 64 else { return false }
        let rest = id.dropFirst(prefix.count)
        return !rest.isEmpty && rest.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9")
                || (scalar >= "a" && scalar <= "f")
                || (scalar >= "A" && scalar <= "F")
                || scalar == "-"
        }
    }

    /// A label as the app can show it: control characters removed (a label
    /// is user text and lands in a single-line row), ends trimmed.
    static func displayLabel(_ label: String) -> String {
        String(String.UnicodeScalarView(label.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespaces)
    }

    /// A window's label if somebody chose it, nil if nobody did.
    ///
    /// A window nobody named carries a label generated from its own id
    /// (`Window 262b0b23`, observed on preview.19) — noise wherever it is
    /// shown. Only that exact shape counts as unnamed, so a label someone
    /// chose is never second-guessed, and a server that generates labels
    /// differently simply shows its own. The one statement of that shape:
    /// the deck's spine and a tab's Switch Terminal list both ask here.
    static func chosenWindowLabel(_ label: String, windowID: String) -> String? {
        let label = displayLabel(label)
        return label.isEmpty || label == "Window " + windowID.suffix(8) ? nil : label
    }

    // MARK: - Session view → the block to attach

    /// One terminal block a session shows, in window (tab) order.
    struct Block: Equatable, Sendable {
        var id: String
        var label: String
        var windowID: String
        var windowLabel: String
        /// The window's place in tab order, counted from one.
        var windowPosition: Int = 1
        /// The window's focused block.
        var isFocused: Bool
        /// In the session's active window.
        var isFronted: Bool
        /// The client its size follows; nil for none.
        var owner: String?
    }

    /// Every terminal block of a `session.view` (or the `view` inside a
    /// `session.attach` result). Other block types are not terminals and
    /// are left out.
    static func terminalBlocks(inView view: [String: Any]) -> [Block] {
        let activeWindow = view["active_window_id"] as? String
        var blocks: [Block] = []
        for (offset, window) in (view["windows"] as? [[String: Any]] ?? []).enumerated() {
            guard let windowID = window["window_id"] as? String else { continue }
            let focused = window["focused_block_id"] as? String
            for layer in window["layers"] as? [[String: Any]] ?? [] {
                for block in layer["blocks"] as? [[String: Any]] ?? [] {
                    guard block["creator_name"] as? String == terminalCreator,
                          let id = block["block_id"] as? String
                    else { continue }
                    blocks.append(Block(
                        id: id,
                        label: block["label"] as? String ?? "",
                        windowID: windowID,
                        windowLabel: window["label"] as? String ?? "",
                        windowPosition: offset + 1,
                        isFocused: id == focused,
                        isFronted: windowID == activeWindow,
                        owner: block["owner"] as? String
                    ))
                }
            }
        }
        return blocks
    }

    /// The block a fresh attach lands on: the one named, else the block the
    /// session is fronting (active window, focused block), else the first
    /// focused block, else the first terminal at all. nil means the session
    /// has no terminal to show.
    static func attachTarget(in blocks: [Block], preferring blockID: String?) -> Block? {
        if let blockID, let named = blocks.first(where: { $0.id == blockID }) { return named }
        return blocks.first { $0.isFronted && $0.isFocused }
            ?? blocks.first(where: \.isFronted)
            ?? blocks.first(where: \.isFocused)
            ?? blocks.first
    }

    // MARK: - Session view → the panes a tab draws

    static let shellFlavor = terminalCreator + ".shell"

    /// The part of a session's view one tab draws: ONE layer of one window,
    /// as the app's own pane tree. A pane's id is its block's.
    struct Layer: Equatable, Sendable {
        var windowID: String
        var layerID: String
        var layout: PaneLayout
        /// The window's focused block, when it is one of this layer's
        /// terminals — where Rex itself would type.
        var focusedBlockID: String?
    }

    /// The layer holding `blockID` — where a tab pointed at that terminal
    /// draws. nil when no window shows it as a terminal.
    static func layer(holding blockID: String, inView view: [String: Any]) -> Layer? {
        layers(inView: view, preferring: blockID)
            .first { $0.layout.contains(PaneID(blockID)) }
    }

    /// The layer a tab was already drawing, as `view` now has it. nil once
    /// the window or the layer is gone, or holds no terminal any more.
    static func layer(
        windowID: String, layerID: String, preferring blockID: String?,
        inView view: [String: Any]
    ) -> Layer? {
        layers(inView: view, preferring: blockID)
            .first { $0.windowID == windowID && $0.layerID == layerID }
    }

    /// Every layer of `view` that holds a terminal, as a pane tree of its
    /// TERMINAL blocks. Any other kind of block has no stream this client
    /// can draw: its leaf is cut out and what was beside it takes the room.
    /// A window's tiled layer and each floating layer are separate entries —
    /// a tab draws one of them, filling its own space (`bounds` is where a
    /// floating layer sits over a Rex window, which a tab has no use for).
    private static func layers(
        inView view: [String: Any], preferring blockID: String?
    ) -> [Layer] {
        var found: [Layer] = []
        for window in view["windows"] as? [[String: Any]] ?? [] {
            guard let windowID = window["window_id"] as? String else { continue }
            let focused = window["focused_block_id"] as? String
            for layer in window["layers"] as? [[String: Any]] ?? [] {
                guard let layerID = layer["layer_id"] as? String else { continue }
                let terminals = (layer["blocks"] as? [[String: Any]] ?? []).compactMap { block in
                    block["creator_name"] as? String == terminalCreator
                        ? block["block_id"] as? String : nil
                }
                guard !terminals.isEmpty else { continue }
                let layout: PaneLayout?
                if let tree = layer["layout"] as? [String: Any] {
                    layout = paneLayout(tree, terminals: Set(terminals))
                } else {
                    // A layer that names its terminals but not how they are
                    // arranged (no server measured leaves the layout out):
                    // one of them, alone, rather than an arrangement
                    // invented here.
                    layout = .pane(PaneID(
                        blockID.flatMap { terminals.contains($0) ? $0 : nil } ?? terminals[0]))
                }
                guard let layout else { continue }
                found.append(Layer(
                    windowID: windowID, layerID: layerID, layout: layout,
                    focusedBlockID: focused.flatMap {
                        layout.contains(PaneID($0)) ? $0 : nil
                    }))
            }
        }
        return found
    }

    /// One node of a layer's `layout`: a block, or a split of two nodes.
    /// A direction this client does not know is drawn side by side, as the
    /// protocol asks.
    private static func paneLayout(
        _ node: [String: Any], terminals: Set<String>
    ) -> PaneLayout? {
        if let block = node["block_id"] as? String {
            return terminals.contains(block) ? .pane(PaneID(block)) : nil
        }
        guard let split = node["split"] as? [String: Any] else { return nil }
        let before = (split["before"] as? [String: Any])
            .flatMap { paneLayout($0, terminals: terminals) }
        let after = (split["after"] as? [String: Any])
            .flatMap { paneLayout($0, terminals: terminals) }
        guard let before, let after else { return before ?? after }
        guard let id = split["split_id"] as? String else { return before }
        let ratio = (split["ratio"] as? NSNumber)?.doubleValue ?? 0.5
        return .split(PaneLayout.Split(
            id: id,
            axis: split["direction"] as? String == "vertical" ? .stacked : .sideBySide,
            ratio: min(
                max(ratio, PaneLayout.ratioBounds.lowerBound),
                PaneLayout.ratioBounds.upperBound),
            before: before, after: after))
    }

    // MARK: - Changing a layout

    /// `session.new_split`: one new shell beside `anchorID` — to its right,
    /// or below it — taking half its space.
    ///
    /// `focus` stays false on purpose. Focusing also makes the block's
    /// window the session's active one, which is what the Rex app on the
    /// host is showing; a tab's own focus is the tab's (`PaneCommand
    /// .focus`). `cwd` is taken literally by the server (`RexProbe`), so it
    /// is only ever a path the server itself reported.
    static func newSplitPayload(
        sessionID: String, anchorID: String, axis: PaneLayout.Axis, cwd: String?
    ) -> [String: Any] {
        var block: [String: Any] = ["flavor": shellFlavor]
        if let cwd { block["options"] = ["cwd": cwd] }
        return [
            "session_id": sessionID,
            "anchor_id": anchorID,
            "direction": direction(axis),
            "side": "after",
            "layout": ["block": block],
            "focus": false,
        ]
    }

    /// `session.new_window`: a new window — a tab, in Rex's own app —
    /// holding one shell.
    ///
    /// `focus` is false for the reason `newSplitPayload`'s is: true (the
    /// default) makes the new window the session's active one, and the Rex
    /// app on the host would flip to it. Measured: with false the session's
    /// `active_window_id` stays where it was, and the block is still its
    /// maker's.
    static func newWindowPayload(sessionID: String, cwd: String?) -> [String: Any] {
        var block: [String: Any] = ["flavor": shellFlavor]
        if let cwd { block["options"] = ["cwd": cwd] }
        return [
            "session_id": sessionID,
            "layout": ["block": block],
            "focus": false,
        ]
    }

    /// `session.resize_pane`: the server finds the split from a block on
    /// each side of it. Any pair works — the split is the only one with one
    /// of them on each side — so the first pane of each side names it.
    static func resizePanePayload(
        sessionID: String, split: PaneLayout.Split, ratio: Double
    ) -> [String: Any] {
        [
            "session_id": sessionID,
            "direction": direction(split.axis),
            "before_block_id": split.before.firstPane.rawValue,
            "after_block_id": split.after.firstPane.rawValue,
            "ratio": ratio,
        ]
    }

    /// Rex's word for an axis: `horizontal` puts the two sides side by side.
    private static func direction(_ axis: PaneLayout.Axis) -> String {
        axis == .sideBySide ? "horizontal" : "vertical"
    }

    // MARK: - Working directory

    /// Where a terminal's program is, out of a `com.superlogical.terminal
    /// .process` result: the foreground process's directory — tmux's
    /// `pane_current_path`, and while an agent runs there, the agent's own
    /// — else the directory of the program the terminal started. The value
    /// is respliced into a shell line and aimed at by SFTP, so only a clean
    /// absolute path answers; nil is the $HOME fallback every backend has.
    static func workingDirectory(inProcess result: [String: Any]) -> String? {
        [result["foreground"], result["child"]]
            .compactMap { ($0 as? [String: Any])?["cwd"] as? String }
            .first(where: isSpliceablePath)
    }

    private static func isSpliceablePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    // MARK: - Switch Terminal list

    /// The rows of a Rex tab's Switch Terminal list — every terminal of the
    /// session, in window order, as the shortcut panel's shared choice
    /// record. A row reads `window — terminal`; a window nobody named
    /// (`chosenWindowLabel`) is `window N`, and a terminal whose label says
    /// nothing more than its window is the window alone. `isActive` marks
    /// the one the tab's keyboard is on.
    ///
    /// Rows that would read the same are counted: a window split three ways
    /// is three shells called `shell`, and the tab draws all three, so the
    /// list has to say which is which — `shell`, `shell 2`, `shell 3`, in
    /// the layout's reading order, which is the order the panes are in on
    /// screen.
    static func terminalChoices(
        in blocks: [Block], showing blockID: String?
    ) -> [TmuxWindowChoice] {
        var seen: [String: Int] = [:]
        return blocks.enumerated().map { offset, block in
            let window = chosenWindowLabel(block.windowLabel, windowID: block.windowID)
                ?? String(localized: "window \(block.windowPosition)")
            let terminal = displayLabel(block.label)
            let base = terminal.isEmpty || terminal.caseInsensitiveCompare(window) == .orderedSame
                ? window
                : "\(window) — \(terminal)"
            let count = (seen[base.lowercased()] ?? 0) + 1
            seen[base.lowercased()] = count
            return TmuxWindowChoice(
                tmuxID: block.id, index: offset + 1,
                isActive: block.id == blockID,
                name: count == 1 ? base : "\(base) \(String(count))")
        }
    }

    // MARK: - Data connection handshake

    /// HELLO: `0x01`, then the ticket's 16 bytes. nil for a ticket that is
    /// not 16 bytes of base64url — never send a guess.
    static func dataHello(ticket: String) -> Data? {
        guard let bytes = Data(base64URLNoPad: ticket), bytes.count == 16 else { return nil }
        return Data([0x01]) + bytes
    }

    enum DataReply: Equatable {
        /// `nonce` marks the server's own messages inside the stream.
        case welcome(nonce: UInt64)
        case reject(reason: UInt8)
    }

    static func parseDataReply(_ message: Data) -> DataReply? {
        let bytes = [UInt8](message)
        switch bytes.first {
        case 0x81:
            guard bytes.count == 32 else { return nil }
            var nonce: UInt64 = 0
            for index in (24..<32).reversed() { nonce = nonce << 8 | UInt64(bytes[index]) }
            // Zero is never a valid nonce; accepting it would make every
            // unmarked APC in the stream look like the server's.
            return nonce == 0 ? nil : .welcome(nonce: nonce)
        case 0x82:
            guard bytes.count >= 2 else { return nil }
            return .reject(reason: bytes[1])
        default:
            return nil
        }
    }

    /// What a REJECT reason means, for the tab's ended line.
    static func rejectDescription(_ reason: UInt8) -> String {
        switch reason {
        case 0x01: "the ticket was not accepted"
        case 0x02: "another connection already has this terminal"
        case 0x03: "the terminal is no longer available"
        case 0x04: "the server is at its connection limit"
        case 0x05: "the handshake was malformed or late"
        case 0x06: "the server failed"
        case 0x07: "the server expected a different subprotocol"
        default: "reason \(reason)"
        }
    }

    // MARK: Picking a held stream up again

    /// Where to resume a held stream whose first `offset` bytes are known
    /// to be in a rendering already — `offset` itself, unless that cut
    /// falls inside an escape sequence or a multi-byte character, in which
    /// case its start. Resumed mid-sequence, the rest of it is drawn as
    /// text (`8;5;12m`); backing up repeats at most one sequence instead.
    ///
    /// Also asked of a cut at the very end: the bytes that complete an
    /// unfinished sequence are then the next to arrive.
    static func resumeOffset(in data: Data, from offset: Int) -> Int {
        let bytes = [UInt8](data)
        let cut = min(max(0, offset), bytes.count)
        guard cut > 0 else { return 0 }
        let floor = max(0, cut - resumeLookback)
        if let escape = bytes[floor..<cut].lastIndex(of: 0x1B),
           !isCompleteSequence(bytes[escape..<cut]) {
            return escape
        }
        // A character split across the cut: back to its lead byte.
        var lead = cut - 1
        while lead > max(0, cut - 4), bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
        let length: Int = switch bytes[lead] {
        case 0xC0...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF7: 4
        default: 1
        }
        return lead + length > cut ? lead : cut
    }

    /// How far back a cut looks for the escape it may have split. Longer
    /// than any sequence but a window title or a hyperlink, and one of
    /// those cut in two is a title lost, not characters on the screen.
    private static let resumeLookback = 256

    /// Whether `sequence`, which starts at an ESC and holds no other,
    /// already has its final byte.
    private static func isCompleteSequence(_ sequence: ArraySlice<UInt8>) -> Bool {
        let body = sequence.dropFirst()
        guard let introducer = body.first else { return false }
        let rest = body.dropFirst()
        switch introducer {
        case UInt8(ascii: "["):
            return rest.contains { (0x40...0x7E).contains($0) }
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"),
             UInt8(ascii: "^"), UInt8(ascii: "X"):
            // A string ends at BEL, or at an ST whose own ESC would have
            // been the last one found.
            return rest.contains(0x07)
        case 0x20...0x2F:
            return rest.contains { $0 >= 0x30 }
        default:
            return true
        }
    }
}

/// Splits a Rex terminal stream into what the terminal emulator should draw
/// and what the server said about the terminal.
///
/// The stream is: a snapshot of the terminal **in Ghostty's binary snapshot
/// format** (`GHOSTSNP…`), then everything the program writes, with the
/// server's own messages spliced in as `ESC _ rex1;<nonce>;<json> ESC \`.
///
/// ⚠ The snapshot is why this type exists. SwiftTerm cannot read it — fed to
/// the emulator it is a page of garbage — so it is DROPPED, and the screen
/// is bootstrapped from `com.superlogical.terminal.format` instead
/// (`RexSession`). Its length is not stated anywhere, but the protocol
/// guarantees a `resize` message "comes right after the snapshot", so
/// everything before the first marker carrying the right nonce is snapshot.
/// The nonce is 64 random bits minted per stream, which is what makes
/// scanning binary for it sound.
///
/// Pure and incremental: stream bytes arrive in arbitrary pieces.
struct RexTerminalStream {
    enum Event: Equatable {
        /// Program output, in order — what the emulator is fed.
        case output(Data)
        /// The terminal's size, and the client that owns it (nil for none).
        case resize(cols: Int, rows: Int, owner: String?)
        /// The terminal's program exited; no more output follows.
        case childExited(code: Int)
    }

    private let marker: Data
    private static let terminator = Data([0x1B, 0x5C])
    /// A server message is a small JSON object. Past this, an unterminated
    /// "message" is treated as program output rather than held forever.
    private static let maxMessageBytes = 256 * 1024

    private var pending = Data()
    private var pastSnapshot = false

    init(nonce: UInt64) {
        marker = Data([0x1B, 0x5F]) + Data("rex1;\(nonce);".utf8)
    }

    /// Whether the snapshot has been passed — the moment the stream starts
    /// carrying program output.
    var isLive: Bool { pastSnapshot }

    mutating func consume(_ chunk: Data) -> [Event] {
        // The steady state — nothing held, and no message in or straddling
        // this chunk: it is output exactly as it came, with no copy made.
        if pastSnapshot, pending.isEmpty, chunk.range(of: marker) == nil,
           Self.partialMarkerSuffix(of: chunk, marker: marker) == 0 {
            return chunk.isEmpty ? [] : [.output(chunk)]
        }
        pending.append(chunk)
        var events: [Event] = []
        var output = Data()

        func flush() {
            guard !output.isEmpty else { return }
            events.append(.output(output))
            output = Data()
        }

        while true {
            guard let found = pending.range(of: marker) else {
                // No marker yet. Everything is output (or snapshot) except a
                // tail that could be the START of a marker split across two
                // chunks — that waits for the next one.
                let keep = Self.partialMarkerSuffix(of: pending, marker: marker)
                let ready = pending.count - keep
                if pastSnapshot { output.append(pending.prefix(ready)) }
                pending = Data(pending.suffix(keep))
                break
            }
            if pastSnapshot {
                output.append(pending[pending.startIndex..<found.lowerBound])
            }
            let body = pending[found.upperBound...]
            guard let end = body.range(of: Self.terminator) else {
                guard body.count <= Self.maxMessageBytes else {
                    // Not a message after all. Pass the marker through as
                    // the bytes it is and keep going after it.
                    if pastSnapshot { output.append(marker) }
                    pending = Data(body)
                    continue
                }
                // The message is still arriving; hold it from its marker.
                pending = Data(pending[found.lowerBound...])
                break
            }
            // The first message with the right nonce ends the snapshot,
            // whatever it says.
            pastSnapshot = true
            if let event = Self.event(from: body[body.startIndex..<end.lowerBound]) {
                flush()
                events.append(event)
            }
            pending = Data(body[end.upperBound...])
        }
        flush()
        return events
    }

    /// The length of the longest tail of `data` that is a proper prefix of
    /// `marker`.
    private static func partialMarkerSuffix(of data: Data, marker: Data) -> Int {
        let limit = min(data.count, marker.count - 1)
        guard limit > 0 else { return 0 }
        for length in stride(from: limit, through: 1, by: -1)
        where data.suffix(length).elementsEqual(marker.prefix(length)) {
            return length
        }
        return 0
    }

    private static func event(from json: Data) -> Event? {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        switch type {
        case "resize":
            guard let cols = object["cols"] as? Int, let rows = object["rows"] as? Int
            else { return nil }
            return .resize(cols: cols, rows: rows, owner: object["owner"] as? String)
        case "child_exited":
            return .childExited(code: object["exit_code"] as? Int ?? 0)
        default:
            // `theme` (the terminal's colors are the app's own theme here)
            // and any type a newer server adds: skipped, as the protocol
            // asks.
            return nil
        }
    }
}

/// Notices a program leaving the alternate screen in a run of terminal
/// output — `CSI ? 1049 l`, or its older spellings 1047 and 47, alone or
/// among other modes in one sequence.
///
/// It exists for one case. While a full-screen program is up, Rex's `format`
/// renders only that program's screen: the shell history underneath is not
/// available to ask for. A tab attached at that moment therefore starts
/// with an empty primary screen, and when the program exits the emulator
/// switches back to it — a bare prompt where a terminal would show
/// everything from before. `RexSession` uses this to notice the exit and
/// fetch the screen again, now that the server can render it.
///
/// Pure and incremental: a sequence may be split across two chunks.
struct AlternateScreenExitWatch {
    private var carry = Data()
    private static let exitModes: Set<Substring> = ["1049", "1047", "47"]
    /// Far longer than any real mode-reset sequence; a longer "sequence" is
    /// not one, and is dropped rather than carried forever.
    private static let maxSequence = 64

    /// True if `chunk` (continuing whatever came before) contains an
    /// alternate-screen exit.
    mutating func sawExit(in chunk: Data) -> Bool {
        let bytes = carry.isEmpty ? [UInt8](chunk) : [UInt8](carry) + [UInt8](chunk)
        carry = Data()
        var found = false
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                index += 1
                continue
            }
            // `ESC [ ?` then parameters, then a final byte. Compared byte
            // by byte: a redrawing full-screen program sends thousands of
            // ESCs a second, each of which passes through here.
            let available = bytes.count - index
            guard available >= 3 else {
                // Cut short by the chunk's end: keep it if it could still
                // become one.
                if available == 1 || bytes[index + 1] == 0x5B {
                    carry = Data(bytes[index...])
                }
                break
            }
            guard bytes[index + 1] == 0x5B, bytes[index + 2] == 0x3F else {
                index += 1
                continue
            }
            var end = index + 3
            while end < bytes.count,
                  (0x30...0x39).contains(bytes[end]) || bytes[end] == 0x3B {
                end += 1
            }
            guard end < bytes.count else {
                // Still arriving — keep it for the next chunk.
                if bytes.count - index <= Self.maxSequence { carry = Data(bytes[index...]) }
                break
            }
            if bytes[end] == 0x6C {  // `l`: reset
                let parameters = String(decoding: bytes[(index + 3)..<end], as: UTF8.self)
                    .split(separator: ";")
                if parameters.contains(where: Self.exitModes.contains) { found = true }
            }
            index = end + 1
        }
        return found
    }
}

/// Turns the bytes SwiftTerm wants typed into the text
/// `com.superlogical.terminal.write` takes.
///
/// The method's argument is a JSON string, so it can only carry valid
/// Unicode, while a terminal's input is bytes. Nearly all of it is UTF-8
/// already; what is not (a legacy 8-bit mouse report) is replaced rather
/// than allowed to make the whole request unencodable. A multi-byte
/// character split across two writes is held until its tail arrives.
struct RexInputEncoder {
    private var carry = Data()

    mutating func encode(_ bytes: Data) -> String {
        var data = carry + bytes
        carry = Data()
        // Hold back an incomplete trailing sequence (at most 3 bytes).
        let tail = Self.incompleteTail(of: data)
        if tail > 0 {
            carry = Data(data.suffix(tail))
            data.removeLast(tail)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// How many trailing bytes begin a multi-byte character that has not
    /// finished arriving.
    private static func incompleteTail(of data: Data) -> Int {
        let bytes = [UInt8](data.suffix(3))
        for back in 1...3 where back <= bytes.count {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }  // a continuation byte
            let needed: Int
            switch byte {
            case 0xC0...0xDF: needed = 2
            case 0xE0...0xEF: needed = 3
            case 0xF0...0xF7: needed = 4
            default: return 0  // ASCII or invalid: nothing to wait for
            }
            return needed > back ? back : 0
        }
        return 0
    }
}
