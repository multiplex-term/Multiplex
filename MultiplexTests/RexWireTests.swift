import XCTest
@testable import Multiplex

/// Anchors `Bundle(for:)` fixture loading, the BindProtocolTests pattern.
private final class RexWireFixtureAnchor {}

/// The pure half of attaching a Rex terminal: the WebSocket codec, the
/// control and data messages, and the terminal stream. The stream fixture is
/// 2322 bytes recorded off a live data connection (Rex 0.1.0-preview.19,
/// nonce 4078407816757279798): a 1962-byte Ghostty snapshot, a `resize`,
/// `tick 82`, a second `resize`, then three more lines. A second recording,
/// off preview.25, has its own test.
final class RexWireTests: XCTestCase {
    private let nonce: UInt64 = 4_078_407_816_757_279_798

    private func streamFixture(_ name: String = "rex-terminal-stream-preview19") throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: RexWireFixtureAnchor.self).url(forResource: name, withExtension: "bin"))
        return try Data(contentsOf: url)
    }

    private func marked(_ json: String, nonce: UInt64? = nil) -> Data {
        Data("\u{1B}_rex1;\(nonce ?? self.nonce);\(json)\u{1B}\\".utf8)
    }

    // MARK: - WebSocket handshake

    func testTheUpgradeRequestAsksForTheSubprotocol() {
        let request = String(
            decoding: WebSocketCodec.upgradeRequest(
                path: "/api/control", host: "rex",
                subprotocol: "rex.control.v1", key: "dGhlIHNhbXBsZSBub25jZQ=="),
            as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("GET /api/control HTTP/1.1\r\nHost: rex\r\n"))
        XCTAssertTrue(request.contains("Sec-WebSocket-Protocol: rex.control.v1\r\n"))
        XCTAssertTrue(request.contains("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"))
        XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
        // No extension is offered, so no frame may ever set a reserved bit.
        XCTAssertFalse(request.contains("Sec-WebSocket-Extensions"))
    }

    func testTheAcceptValueIsTheRFCsOwnExample() {
        // RFC 6455 §1.3.
        XCTAssertEqual(
            WebSocketCodec.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    private func upgradeResponse(
        accept: String = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        subprotocol: String = "rex.control.v1"
    ) -> String {
        """
        HTTP/1.1 101 Switching Protocols\r
        Connection: Upgrade\r
        Sec-Websocket-Accept: \(accept)\r
        Sec-Websocket-Protocol: \(subprotocol)\r
        Upgrade: websocket\r
        \r

        """
    }

    func testAnUpgradeIsReadAcrossChunksAndKeepsWhatFollows() throws {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let response = Data(upgradeResponse().utf8) + Data([0x81, 0x02, 0x68, 0x69])
        // Header names are case-insensitive: the server spells `Websocket`.
        XCTAssertEqual(
            try WebSocketCodec.readUpgradeResponse(
                response.prefix(40), key: key, subprotocol: "rex.control.v1"),
            .incomplete)
        XCTAssertEqual(
            try WebSocketCodec.readUpgradeResponse(
                response, key: key, subprotocol: "rex.control.v1"),
            .upgraded(remainder: Data([0x81, 0x02, 0x68, 0x69])))
    }

    func testAnUpgradeThatIsNotOursIsRefused() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        func read(_ text: String) throws -> WebSocketCodec.UpgradeReading {
            try WebSocketCodec.readUpgradeResponse(
                Data(text.utf8), key: key, subprotocol: "rex.control.v1")
        }
        XCTAssertThrowsError(try read(upgradeResponse(accept: "bm90IHRoZSBhbnN3ZXI=")))
        XCTAssertThrowsError(try read(upgradeResponse(subprotocol: "rex.data.terminal.v1")))
        // What the server really answers a request with no upgrade headers.
        XCTAssertThrowsError(try read(
            "HTTP/1.1 426 Upgrade Required\r\nUpgrade: websocket\r\n\r\nWebSocket protocol violation"
        )) { error in
            XCTAssertEqual(
                error as? WebSocketCodec.Failure,
                .upgradeRefused(status: 426, body: "WebSocket protocol violation"))
        }
        XCTAssertThrowsError(try read("garbage\r\n\r\n"))
    }

    // MARK: - WebSocket frames

    func testAClientFrameIsMaskedAndRoundTrips() throws {
        let frame = WebSocketCodec.frame(
            .text, payload: Data("Hello".utf8), maskKey: [0x37, 0xFA, 0x21, 0x3D])
        // RFC 6455 §5.7's masked "Hello".
        XCTAssertEqual(
            [UInt8](frame),
            [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58])
        var decoder = WebSocketCodec.Decoder()
        decoder.append(frame)
        XCTAssertEqual(try decoder.next(), .text(Data("Hello".utf8)))
        XCTAssertNil(try decoder.next())
    }

    func testLongPayloadsUseTheExtendedLengths() throws {
        for size in [125, 126, 65_535, 65_536, 70_000] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            var decoder = WebSocketCodec.Decoder()
            decoder.append(WebSocketCodec.frame(.binary, payload: payload))
            XCTAssertEqual(try decoder.next(), .binary(payload), "\(size)")
        }
    }

    func testFramesArriveInArbitraryPieces() throws {
        // An unmasked server text frame, a ping, and a binary frame, fed one
        // byte at a time.
        let stream = Data([0x81, 0x02, 0x68, 0x69])
            + Data([0x89, 0x01, 0x21])
            + Data([0x82, 0x03, 0x01, 0x02, 0x03])
        var decoder = WebSocketCodec.Decoder()
        var messages: [WebSocketCodec.Message] = []
        for byte in stream {
            decoder.append(Data([byte]))
            while let message = try decoder.next() { messages.append(message) }
        }
        XCTAssertEqual(messages, [
            .text(Data("hi".utf8)), .ping(Data([0x21])), .binary(Data([1, 2, 3])),
        ])
    }

    func testFragmentsJoinAndAControlFrameMayInterleave() throws {
        var decoder = WebSocketCodec.Decoder()
        decoder.append(Data([0x01, 0x03, 0x48, 0x65, 0x6C]))       // text, not final
        XCTAssertNil(try decoder.next())
        decoder.append(Data([0x8A, 0x00]))                          // pong in between
        XCTAssertEqual(try decoder.next(), .pong(Data()))
        decoder.append(Data([0x80, 0x02, 0x6C, 0x6F]))              // final continuation
        XCTAssertEqual(try decoder.next(), .text(Data("Hello".utf8)))
    }

    func testACloseFrameCarriesItsCodeAndReason() throws {
        var decoder = WebSocketCodec.Decoder()
        decoder.append(Data([0x88, 0x0E, 0x0F, 0xA0]) + Data("block closed".utf8))
        XCTAssertEqual(try decoder.next(), .close(code: 4000, reason: "block closed"))
        decoder.append(Data([0x88, 0x00]))
        XCTAssertEqual(try decoder.next(), .close(code: nil, reason: ""))
        XCTAssertEqual([UInt8](WebSocketCodec.closeFrame().prefix(2)), [0x88, 0x82])
    }

    func testProtocolViolationsThrowInsteadOfDesynchronizing() {
        func decode(_ bytes: [UInt8]) throws -> WebSocketCodec.Message? {
            var decoder = WebSocketCodec.Decoder()
            decoder.append(Data(bytes))
            return try decoder.next()
        }
        // A reserved bit (a compressed frame) with no extension negotiated.
        XCTAssertThrowsError(try decode([0xC1, 0x01, 0x00]))
        XCTAssertThrowsError(try decode([0x83, 0x00]))                  // unknown opcode
        XCTAssertThrowsError(try decode([0x80, 0x01, 0x00]))            // stray continuation
        XCTAssertThrowsError(try decode([0x09, 0x00]))                  // fragmented ping
        // A length this client refuses to buffer.
        XCTAssertThrowsError(try decode([0x82, 0x7F, 0, 0, 0, 0, 0x40, 0, 0, 0]))
    }

    // MARK: - Control messages

    func testTheHelloStatesItsRevisionRangeAndStaysSmall() throws {
        let hello = RexWire.hello(clientVersion: "1.5.2")
        // The protocol caps a hello at 512 bytes.
        XCTAssertLessThan(hello.count, 512)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: hello) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "hello")
        // The newest revision this client was read against, and the oldest
        // whose shapes are the same: the server picks between them.
        XCTAssertEqual(object["api_revision"] as? Int, 24)
        XCTAssertEqual(object["api_min_revision"] as? Int, 14)
        // Never `app`: Rex aims client actions at "the one app client".
        XCTAssertEqual((object["client"] as? [String: Any])?["kind"] as? String, "other")
    }

    func testARequestIsByteStableAndABlockCallNestsItsArguments() {
        XCTAssertEqual(
            String(decoding: RexWire.request(id: "7", method: "session.list", payload: nil),
                   as: UTF8.self),
            #"{"id":"7","method":"session.list","type":"request"}"#)
        let write = RexWire.request(
            id: "8", method: "com.superlogical.terminal.write",
            payload: RexWire.blockPayload(
                sessionID: "session:s", blockID: "block:b", args: ["data": "ls\u{1B}[A\r"]))
        // The escape reaches the wire as a JSON escape, never a raw control.
        XCTAssertEqual(
            String(decoding: write, as: UTF8.self),
            #"{"id":"8","method":"com.superlogical.terminal.write","#
                + #""payload":{"args":{"data":"ls\u001b[A\r"},"block_id":"block:b","#
                + #""session_id":"session:s"},"type":"request"}"#)
    }

    func testInboundMessagesDecodeToWhatTheSessionActsOn() throws {
        func decode(_ text: String) -> RexWire.Inbound? {
            RexWire.decodeInbound(Data(text.utf8))
        }
        // Verbatim from a live server.
        guard case .welcome(let clientID, let revision)? = decode("""
            {"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576},\
            "client":{"id":"client:01a1e1d4-754f","reconnect_token":"CARtI14i"},\
            "api_revision":24,"api_server_revision":24}
            """)
        else { return XCTFail("welcome") }
        XCTAssertEqual(clientID, "client:01a1e1d4-754f")
        XCTAssertEqual(revision, 24)
        // A welcome that names no revision speaks revision 0.
        guard case .welcome(_, let unnamed)? = decode(
            #"{"type":"welcome","protocol":"rex.control.v1"}"#)
        else { return XCTFail("welcome without a revision") }
        XCTAssertEqual(unnamed, 0)
        // A welcome for some other protocol is not a welcome.
        XCTAssertNil(decode(#"{"type":"welcome","protocol":"rex.control.v2"}"#))

        guard case .response(let id, .success(let payload))? = decode(
            #"{"type":"response","id":"p2","seq":1,"payload":{"ticket":"2hsxxmMxRjpddNEsnIIRXA"}}"#)
        else { return XCTFail("response") }
        XCTAssertEqual(id, "p2")
        XCTAssertEqual(payload["ticket"] as? String, "2hsxxmMxRjpddNEsnIIRXA")

        guard case .response(_, .failure(let error))? = decode("""
            {"type":"response","id":"2","seq":0,\
            "error":{"code":"not_found","message":"block not found","status":404}}
            """)
        else { return XCTFail("error response") }
        XCTAssertEqual(
            error, RexWire.ServerError(code: "not_found", message: "block not found", status: 404))

        // A session event arrives doubly wrapped; the block's own event is
        // what matters.
        guard case .event(let type, let fields)? = decode("""
            {"type":"event","seq":3,"payload":{"type":"session_event","payload":{\
            "session_id":"session:s","event":{"type":"block_closed",\
            "payload":{"block_id":"block:b"}}}}}
            """)
        else { return XCTFail("event") }
        XCTAssertEqual(type, "block_closed")
        XCTAssertEqual(fields["block_id"] as? String, "block:b")

        // A type a newer server added is skipped, not an error.
        guard case .unknown? = decode(#"{"type":"notice","text":"hi"}"#)
        else { return XCTFail("unknown type") }
        XCTAssertNil(decode("not json"))
    }

    // MARK: - Choosing the block

    /// A `session.view` in the server's own shape: two windows, the second
    /// active, with a non-terminal block among its blocks.
    private func view() throws -> [String: Any] {
        let json = """
            {"active_window_id":"window:2","windows":[
              {"window_id":"window:1","label":"editor","focused_block_id":"block:a","layers":[
                {"blocks":[
                  {"block_id":"block:a","label":"shell","creator_name":"com.superlogical.terminal"},
                  {"block_id":"block:b","label":"logs","creator_name":"com.superlogical.terminal"}
                ]}]},
              {"window_id":"window:2","label":"","focused_block_id":"block:d","layers":[
                {"blocks":[
                  {"block_id":"block:t","label":"tunnel","creator_name":"com.superlogical.tunnel"},
                  {"block_id":"block:c","label":"agent","creator_name":"com.superlogical.terminal"},
                  {"block_id":"block:d","label":"repl","creator_name":"com.superlogical.terminal"}
                ]}]}
            ]}
            """
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: - The panes a tab draws

    /// A window as measured on preview.23 (revision 14 shapes): `a | (b / c)`
    /// in its tiled layer with a non-terminal block beside `c`, and a
    /// floating layer holding one more terminal.
    private func layeredView() throws -> [String: Any] {
        let json = """
            {"revision": 7, "active_window_id": "window:1", "windows": [
              {"window_id": "window:1", "label": "editor", "focused_block_id": "block:b",
               "layers": [
                 {"layer_id": "layer:tiled", "kind": "tiled", "bounds": [0, 0, 1, 1],
                  "layout": {"rect": [0, 0, 1, 1], "split": {
                    "split_id": "split:outer", "direction": "horizontal", "ratio": 0.3,
                    "before": {"rect": [0, 0, 0.3, 1], "block_id": "block:a"},
                    "after": {"rect": [0.3, 0, 0.7, 1], "split": {
                      "split_id": "split:inner", "direction": "vertical", "ratio": 0.7,
                      "before": {"rect": [0.3, 0, 0.7, 0.7], "block_id": "block:b"},
                      "after": {"rect": [0.3, 0.7, 0.7, 0.3], "split": {
                        "split_id": "split:mixed", "direction": "sideways", "ratio": 0.5,
                        "before": {"rect": [0.3, 0.7, 0.35, 0.3], "block_id": "block:c"},
                        "after": {"rect": [0.65, 0.7, 0.35, 0.3], "block_id": "block:tunnel"}}}}}}},
                  "blocks": [
                    {"block_id": "block:a", "label": "shell",
                     "creator_name": "com.superlogical.terminal", "owner": "client:me"},
                    {"block_id": "block:b", "label": "logs",
                     "creator_name": "com.superlogical.terminal", "owner": "client:app"},
                    {"block_id": "block:c", "label": "repl",
                     "creator_name": "com.superlogical.terminal"},
                    {"block_id": "block:tunnel", "creator_name": "com.example.tunnel"}]},
                 {"layer_id": "layer:float", "kind": "floating", "bounds": [0.2, 0.2, 0.6, 0.6],
                  "layout": {"rect": [0.2, 0.2, 0.6, 0.6], "block_id": "block:f"},
                  "blocks": [{"block_id": "block:f", "label": "scratch",
                              "creator_name": "com.superlogical.terminal"}]}]},
              {"window_id": "window:2", "label": "old",
               "layers": [{"layer_id": "layer:bare",
                           "blocks": [{"block_id": "block:x",
                                       "creator_name": "com.superlogical.terminal"},
                                      {"block_id": "block:y",
                                       "creator_name": "com.superlogical.terminal"}]}]}]}
            """
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testALayerBecomesThePaneTreeOfItsTerminals() throws {
        let layer = try XCTUnwrap(RexWire.layer(holding: "block:c", inView: try layeredView()))
        XCTAssertEqual(layer.windowID, "window:1")
        XCTAssertEqual(layer.layerID, "layer:tiled")
        // `horizontal` is side by side, `vertical` stacked. The block that
        // is not a terminal is cut out and `c` has its split's room — which
        // takes the split with the direction nobody knows away with it.
        XCTAssertEqual(layer.layout, .split(PaneLayout.Split(
            id: "split:outer", axis: .sideBySide, ratio: 0.3,
            before: .pane(PaneID("block:a")),
            after: .split(PaneLayout.Split(
                id: "split:inner", axis: .stacked, ratio: 0.7,
                before: .pane(PaneID("block:b")), after: .pane(PaneID("block:c")))))))
        XCTAssertEqual(layer.focusedBlockID, "block:b")
        // Each block says whose size it follows.
        XCTAssertEqual(
            RexWire.terminalBlocks(inView: try layeredView()).prefix(3).map(\.owner),
            ["client:me", "client:app", nil])
    }

    func testAFloatingLayerIsALayerOfItsOwnAndTheWindowsFocusIsNotItsOwn() throws {
        let view = try layeredView()
        let floating = try XCTUnwrap(RexWire.layer(holding: "block:f", inView: view))
        XCTAssertEqual(floating.layerID, "layer:float")
        XCTAssertEqual(floating.layout, .pane(PaneID("block:f")))
        // The window is focused on a block of its other layer.
        XCTAssertNil(floating.focusedBlockID)
        // A tab keeps drawing the layer it was on, by window and layer.
        XCTAssertEqual(
            RexWire.layer(
                windowID: "window:1", layerID: "layer:float", preferring: nil, inView: view),
            floating)
        XCTAssertNil(RexWire.layer(
            windowID: "window:1", layerID: "layer:gone", preferring: nil, inView: view))
        // A block nobody shows as a terminal names no layer.
        XCTAssertNil(RexWire.layer(holding: "block:tunnel", inView: view))
        XCTAssertNil(RexWire.layer(holding: "block:gone", inView: view))
    }

    func testALayerThatStatesNoLayoutIsOneOfItsTerminalsAlone() throws {
        let view = try layeredView()
        // The one asked for, not an arrangement invented here.
        XCTAssertEqual(
            RexWire.layer(holding: "block:y", inView: view)?.layout, .pane(PaneID("block:y")))
        XCTAssertEqual(
            RexWire.layer(
                windowID: "window:2", layerID: "layer:bare", preferring: nil, inView: view
            )?.layout,
            .pane(PaneID("block:x")))
    }

    func testLayoutRequestsNameWhatTheServerNeeds() throws {
        let split = RexWire.newSplitPayload(
            sessionID: "session:1", anchorID: "block:a", axis: .stacked, cwd: "/work")
        XCTAssertEqual(split["anchor_id"] as? String, "block:a")
        XCTAssertEqual(split["direction"] as? String, "vertical")
        XCTAssertEqual(split["side"] as? String, "after")
        // Never focused on the server: that would also front the window.
        XCTAssertEqual(split["focus"] as? Bool, false)
        let block = (split["layout"] as? [String: Any])?["block"] as? [String: Any]
        XCTAssertEqual(block?["flavor"] as? String, "com.superlogical.terminal.shell")
        XCTAssertEqual((block?["options"] as? [String: Any])?["cwd"] as? String, "/work")
        // No directory known: none is sent, and the server starts in $HOME.
        let bare = RexWire.newSplitPayload(
            sessionID: "session:1", anchorID: "block:a", axis: .sideBySide, cwd: nil)
        XCTAssertEqual(bare["direction"] as? String, "horizontal")
        XCTAssertNil(((bare["layout"] as? [String: Any])?["block"] as? [String: Any])?["options"])

        // A new tab is a window with one shell — and never the active one.
        let window = RexWire.newWindowPayload(sessionID: "session:1", cwd: "/work")
        XCTAssertEqual(window["focus"] as? Bool, false)
        let shell = (window["layout"] as? [String: Any])?["block"] as? [String: Any]
        XCTAssertEqual(shell?["flavor"] as? String, "com.superlogical.terminal.shell")
        XCTAssertEqual((shell?["options"] as? [String: Any])?["cwd"] as? String, "/work")
        XCTAssertNil(window["window_label"])

        // A split is named by a block on each side of it: the first of each.
        let layer = try XCTUnwrap(RexWire.layer(holding: "block:a", inView: try layeredView()))
        let outer = try XCTUnwrap(layer.layout.split(withID: "split:outer"))
        let resize = RexWire.resizePanePayload(sessionID: "session:1", split: outer, ratio: 0.4)
        XCTAssertEqual(resize["direction"] as? String, "horizontal")
        XCTAssertEqual(resize["before_block_id"] as? String, "block:a")
        XCTAssertEqual(resize["after_block_id"] as? String, "block:b")
        XCTAssertEqual(resize["ratio"] as? Double, 0.4)
    }

    func testOnlyTerminalBlocksAreAttachableAndTheFrontedOneWins() throws {
        let blocks = RexWire.terminalBlocks(inView: try view())
        // A tunnel block is not a terminal.
        XCTAssertEqual(blocks.map(\.id), ["block:a", "block:b", "block:c", "block:d"])
        XCTAssertEqual(RexWire.attachTarget(in: blocks, preferring: nil)?.id, "block:d")
        // A named block is honored while it exists…
        XCTAssertEqual(RexWire.attachTarget(in: blocks, preferring: "block:b")?.id, "block:b")
        // …and falls back to the fronted one once it is gone.
        XCTAssertEqual(RexWire.attachTarget(in: blocks, preferring: "block:gone")?.id, "block:d")
        XCTAssertNil(RexWire.attachTarget(in: [], preferring: nil))
        XCTAssertNil(RexWire.attachTarget(
            in: RexWire.terminalBlocks(inView: [:]), preferring: nil))
    }

    func testSwitchTerminalRowsNameEachTerminalAndMarkTheOneOnShow() throws {
        let blocks = RexWire.terminalBlocks(inView: try view())
        let choices = RexWire.terminalChoices(in: blocks, showing: "block:c")
        XCTAssertEqual(choices.map(\.tmuxID), ["block:a", "block:b", "block:c", "block:d"])
        // A named window leads its terminals; an unnamed one is `window N`.
        XCTAssertEqual(
            choices.map(\.name),
            ["editor — shell", "editor — logs", "window 2 — agent", "window 2 — repl"])
        XCTAssertEqual(choices.map(\.isActive), [false, false, true, false])
        XCTAssertEqual(choices.map(\.index), [1, 2, 3, 4])

        // Rex's generated `Window <id tail>` label is not a name, and a
        // terminal that only repeats its window adds nothing.
        let generated = RexWire.terminalChoices(
            in: [
                RexWire.Block(
                    id: "block:x", label: "", windowID: "window:0000-11112222",
                    windowLabel: "Window 11112222", windowPosition: 3,
                    isFocused: true, isFronted: true),
                RexWire.Block(
                    id: "block:y", label: "Logs", windowID: "window:w",
                    windowLabel: "logs", windowPosition: 4,
                    isFocused: true, isFronted: false),
            ],
            showing: nil)
        XCTAssertEqual(generated.map(\.name), ["window 3", "logs"])
        XCTAssertEqual(generated.map(\.isActive), [false, false])

        // A window split three ways is three shells called `shell`. The tab
        // draws all three, so the rows are counted in the order the panes
        // are in — and a same-named terminal of ANOTHER window is its own.
        func shell(_ id: String, window: String, at position: Int) -> RexWire.Block {
            RexWire.Block(
                id: id, label: "Shell", windowID: "window:" + window, windowLabel: window,
                windowPosition: position, isFocused: false, isFronted: false)
        }
        let split = RexWire.terminalChoices(
            in: [
                shell("block:1", window: "api", at: 1), shell("block:2", window: "api", at: 1),
                shell("block:3", window: "web", at: 2), shell("block:4", window: "API", at: 1),
            ],
            showing: "block:2")
        XCTAssertEqual(
            split.map(\.name),
            ["api — Shell", "api — Shell 2", "web — Shell", "API — Shell 3"])
        XCTAssertEqual(split.map(\.isActive), [false, true, false, false])
    }

    func testTheWorkingDirectoryIsTheForegroundProcesssThenTheChilds() throws {
        func directory(_ json: String) throws -> String? {
            RexWire.workingDirectory(inProcess: try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]))
        }
        // Verbatim shape from a live server: an agent running in a shell.
        XCTAssertEqual(
            try directory("""
                {"last_exit":null,"child":{"pid":1,"name":"zsh","cwd":"/Users/dev"},\
                "foreground":{"pid":2,"name":"claude","cwd":"/Users/dev/src/api"},"home":"/Users/dev"}
                """),
            "/Users/dev/src/api")
        XCTAssertEqual(
            try directory(#"{"child":{"cwd":"/srv/app"},"foreground":null}"#), "/srv/app")
        // Only a clean absolute path may be spliced into a shell line.
        XCTAssertEqual(
            try directory(#"{"foreground":{"cwd":"relative"},"child":{"cwd":"/ok"}}"#), "/ok")
        XCTAssertNil(try directory(#"{"foreground":{"cwd":"/tmp/a\nb"}}"#))
        XCTAssertNil(try directory(#"{"last_exit":{"exit_code":0}}"#))
    }

    // MARK: - Data handshake

    func testTheHelloCarriesTheTicketsSixteenBytes() throws {
        // base64url WITHOUT padding, as `data.connect` returns it.
        let hello = try XCTUnwrap(RexWire.dataHello(ticket: "AAECAwQFBgcICQoLDA0ODw"))
        XCTAssertEqual([UInt8](hello), [0x01] + (0..<16).map { UInt8($0) })
        // `-` and `_` are the URL alphabet.
        XCTAssertNotNil(RexWire.dataHello(ticket: "-_-_-_-_-_-_-_-_-_-_-w"))
        XCTAssertNil(RexWire.dataHello(ticket: "AAEC"))
        XCTAssertNil(RexWire.dataHello(ticket: "not a ticket!"))
    }

    func testAWelcomeYieldsItsLittleEndianNonce() {
        var welcome = [UInt8](repeating: 0, count: 32)
        welcome[0] = 0x81
        welcome[24...] = [0x76, 0xD3, 0x53, 0x6C, 0x2B, 0x74, 0x99, 0x38]
        XCTAssertEqual(
            RexWire.parseDataReply(Data(welcome)), .welcome(nonce: 0x3899_742B_6C53_D376))
        XCTAssertEqual(RexWire.parseDataReply(Data([0x82, 0x07])), .reject(reason: 7))
        // A welcome is exactly 32 bytes, and its nonce is never zero.
        XCTAssertNil(RexWire.parseDataReply(Data(welcome.prefix(31))))
        XCTAssertNil(RexWire.parseDataReply(Data([0x81] + [UInt8](repeating: 0, count: 31))))
        XCTAssertNil(RexWire.parseDataReply(Data()))
    }

    // MARK: - Picking a held stream up again

    func testACleanCutResumesWhereItWasMade() {
        let data = Data("one\r\n\u{1B}[31mtwo\u{1B}[0m\r\nthree".utf8)
        // After a line, after a finished sequence, in plain text.
        for offset in [5, 10, 13, 17, 21] {
            XCTAssertEqual(RexWire.resumeOffset(in: data, from: offset), offset, "\(offset)")
        }
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: 0), 0)
        // Out of range is clamped, not trapped on.
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: -4), 0)
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: 999), data.count)
        XCTAssertEqual(RexWire.resumeOffset(in: Data(), from: 3), 0)
    }

    func testACutInsideAnEscapeSequenceBacksUpToItsStart() {
        // "ab" ESC [ 3 8 ; 5 ; 1 2 m "cd": the sequence starts at 2 and its
        // final byte is at 11.
        let data = Data("ab\u{1B}[38;5;12mcd".utf8)
        for offset in 3...11 {
            XCTAssertEqual(RexWire.resumeOffset(in: data, from: offset), 2, "\(offset)")
        }
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: 12), 12)
        // The same question of a cut at the very end of what has arrived.
        XCTAssertEqual(RexWire.resumeOffset(in: data.prefix(9), from: 9), 2)

        // A lone ESC, a charset designator missing its final byte, and an
        // OSC still waiting for its terminator.
        XCTAssertEqual(RexWire.resumeOffset(in: Data("ab\u{1B}".utf8), from: 3), 2)
        XCTAssertEqual(RexWire.resumeOffset(in: Data("ab\u{1B}(B".utf8), from: 4), 2)
        XCTAssertEqual(RexWire.resumeOffset(in: Data("ab\u{1B}(B".utf8), from: 5), 5)
        let title = Data("ab\u{1B}]0;title\u{07}cd".utf8)
        XCTAssertEqual(RexWire.resumeOffset(in: title, from: 8), 2)
        XCTAssertEqual(RexWire.resumeOffset(in: title, from: 11), 2)
        XCTAssertEqual(RexWire.resumeOffset(in: title, from: 12), 12)
        // An ST's own ESC: the string before it is whole, the ST is not.
        let hyperlink = Data("\u{1B}]8;;x\u{1B}\\y".utf8)
        XCTAssertEqual(RexWire.resumeOffset(in: hyperlink, from: 7), 6)
        XCTAssertEqual(RexWire.resumeOffset(in: hyperlink, from: 8), 8)
    }

    func testACutInsideACharacterBacksUpToItsLeadByte() {
        // "a" + 測 (3 bytes) + "b" + 😀 (4 bytes).
        let data = Data("a測b😀".utf8)
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: 1), 1)
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: 2), 1)
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: 3), 1)
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: 4), 4)
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: 5), 5)
        for offset in 6...8 {
            XCTAssertEqual(RexWire.resumeOffset(in: data, from: offset), 5, "\(offset)")
        }
        XCTAssertEqual(RexWire.resumeOffset(in: data, from: 9), 9)
    }

    // MARK: - Terminal stream

    private func expectedEvents() -> [RexTerminalStream.Event] {
        [
            .resize(cols: 80, rows: 24, owner: "client:01a1e1d4-7523-774b-917e-3547350b855e"),
            .output(Data("tick 82\r\n".utf8)),
            .resize(cols: 100, rows: 30, owner: "client:01a1e1d5-b2e0-75d4-ac80-8bf2099a6c09"),
            .output(Data("tick 83\r\ntyped-by-probe\r\ntick 84\r\n".utf8)),
        ]
    }

    func testTheGhosttySnapshotIsDroppedAndOutputFollowsTheMessages() throws {
        let fixture = try streamFixture()
        XCTAssertEqual(String(decoding: fixture.prefix(8), as: UTF8.self), "GHOSTSNP")
        var stream = RexTerminalStream(nonce: nonce)
        XCTAssertFalse(stream.isLive)
        XCTAssertEqual(stream.consume(fixture), expectedEvents())
        XCTAssertTrue(stream.isLive)
    }

    /// 1558 bytes off a Rex 0.1.0-preview.25 data connection (API revision
    /// 24, 2026-11-27): the stream still opens with a Ghostty snapshot
    /// whose length nothing states, and the first `resize` still ends it.
    func testTheNewestServersStreamOpensTheSameWay() throws {
        let fixture = try streamFixture("rex-terminal-stream-preview25")
        XCTAssertEqual(String(decoding: fixture.prefix(8), as: UTF8.self), "GHOSTSNP")
        let owner = "client:01a21b89-9478-7a29-995c-6da52ce05171"
        var stream = RexTerminalStream(nonce: 12_387_399_168_064_344_086)
        // A `resize` now states the cell size in pixels too; a field this
        // client has no use for is skipped.
        XCTAssertEqual(stream.consume(fixture), [
            .resize(cols: 80, rows: 24, owner: owner),
            .output(Data("tick 8\r\ntick 9\r\n".utf8)),
            .resize(cols: 100, rows: 30, owner: owner),
            .output(Data("tick 10\r\ntick 11\r\n".utf8)),
        ])
        XCTAssertTrue(stream.isLive)
    }

    func testTheStreamSurvivesAnyChunking() throws {
        let fixture = try streamFixture()
        for size in [1, 2, 7, 64, 1961, 1962, 1963, 2000] {
            var stream = RexTerminalStream(nonce: nonce)
            var events: [RexTerminalStream.Event] = []
            var offset = 0
            while offset < fixture.count {
                let end = min(offset + size, fixture.count)
                events += stream.consume(fixture.subdata(in: offset..<end))
                offset = end
            }
            // Adjacent output pieces are one run of program bytes.
            var joined: [RexTerminalStream.Event] = []
            for event in events {
                if case .output(let more) = event, case .output(let sofar)? = joined.last {
                    joined[joined.count - 1] = .output(sofar + more)
                } else {
                    joined.append(event)
                }
            }
            XCTAssertEqual(joined, expectedEvents(), "chunk size \(size)")
        }
    }

    func testAWrongNonceIsProgramOutputNotAServerMessage() {
        var stream = RexTerminalStream(nonce: nonce)
        _ = stream.consume(Data("SNAPSHOT".utf8) + marked(#"{"type":"resize","cols":80,"rows":24}"#))
        // A program can print the same shape; only the nonce makes it the
        // server's, so this is drawn like any other output.
        let forged = marked(#"{"type":"child_exited","exit_code":0}"#, nonce: 42)
        XCTAssertEqual(
            stream.consume(Data("a".utf8) + forged + Data("b".utf8)),
            [.output(Data("a".utf8) + forged + Data("b".utf8))])
    }

    func testChildExitAndUnknownMessagesAreHandled() {
        var stream = RexTerminalStream(nonce: nonce)
        _ = stream.consume(marked(#"{"type":"resize","cols":80,"rows":24,"owner":null}"#))
        XCTAssertEqual(
            stream.consume(
                Data("bye\r\n".utf8)
                    + marked(#"{"type":"theme","background":"000000"}"#)
                    + marked(#"{"type":"child_exited","exit_code":2}"#)),
            [.output(Data("bye\r\n".utf8)), .childExited(code: 2)])
        var fresh = RexTerminalStream(nonce: nonce)
        XCTAssertEqual(
            fresh.consume(marked(#"{"type":"resize","cols":120,"rows":40,"owner":null}"#)),
            [.resize(cols: 120, rows: 40, owner: nil)])
    }

    func testAnEscapeAtTheEndOfAChunkIsHeldNotLost() {
        var stream = RexTerminalStream(nonce: nonce)
        _ = stream.consume(marked(#"{"type":"resize","cols":80,"rows":24}"#))
        // `ESC _` could begin a marker; it is program output only once the
        // next bytes say so.
        XCTAssertEqual(stream.consume(Data("x\u{1B}".utf8)), [.output(Data("x".utf8))])
        XCTAssertEqual(stream.consume(Data("[0m".utf8)), [.output(Data("\u{1B}[0m".utf8))])
    }

    // MARK: - Alternate screen

    func testLeavingTheAlternateScreenIsNoticedInAnySpelling() {
        func saw(_ text: String) -> Bool {
            var watch = AlternateScreenExitWatch()
            return watch.sawExit(in: Data(text.utf8))
        }
        XCTAssertTrue(saw("\u{1B}[?1049l"))
        XCTAssertTrue(saw("bye\u{1B}[?1047l\r\n$ "))
        XCTAssertTrue(saw("\u{1B}[?47l"))
        // One sequence may reset several modes.
        XCTAssertTrue(saw("\u{1B}[?1;1049;2004l"))
        // Entering it, other modes, and look-alikes are not an exit.
        XCTAssertFalse(saw("\u{1B}[?1049h"))
        XCTAssertFalse(saw("\u{1B}[?2004l\u{1B}[?25l"))
        XCTAssertFalse(saw("\u{1B}[1049l"))
        XCTAssertFalse(saw("plain text 1049l"))
        XCTAssertFalse(saw("\u{1B}[?10490l"))
    }

    func testAnExitSplitAcrossChunksIsStillNoticed() {
        let sequence = Data("x\u{1B}[?1049ly".utf8)
        for split in 1..<sequence.count {
            var watch = AlternateScreenExitWatch()
            let first = watch.sawExit(in: sequence.prefix(split))
            let second = watch.sawExit(in: sequence.suffix(from: split))
            XCTAssertTrue(first || second, "split at \(split)")
            XCTAssertFalse(first && second, "counted twice at \(split)")
        }
        // A lone ESC at the end of a chunk that turns out to be something
        // else is not held against the next one.
        var watch = AlternateScreenExitWatch()
        XCTAssertFalse(watch.sawExit(in: Data("a\u{1B}".utf8)))
        XCTAssertFalse(watch.sawExit(in: Data("[0m".utf8)))
    }

    // MARK: - Input

    func testInputBecomesTextWithoutSplittingACharacter() {
        var encoder = RexInputEncoder()
        XCTAssertEqual(encoder.encode(Data("ls\r".utf8)), "ls\r")
        let multibyte = Data("測".utf8)   // three bytes
        XCTAssertEqual(encoder.encode(multibyte.prefix(1)), "")
        XCTAssertEqual(encoder.encode(multibyte.dropFirst().prefix(1)), "")
        XCTAssertEqual(encoder.encode(multibyte.suffix(1) + Data("a".utf8)), "測a")
        // Bytes that will never be UTF-8 are replaced, not held forever.
        XCTAssertEqual(encoder.encode(Data([0x41, 0xFF, 0x42])), "A\u{FFFD}B")
        XCTAssertEqual(encoder.encode(Data()), "")
    }
}
