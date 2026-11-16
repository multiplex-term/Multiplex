import CryptoKit
import Foundation

/// A minimal RFC 6455 WebSocket client codec — the handshake and the frame
/// layer, with no socket of its own. Pure: bytes in, bytes and messages out.
///
/// It exists because a Rex server speaks WebSocket on a Unix socket that the
/// app can only reach as a byte pipe through SSH (`SSHConnection.openPipe`),
/// which rules out `URLSessionWebSocketTask` and every other client that
/// wants to own the connection. Deliberately small: no extensions are
/// offered (the server works with or without `permessage-deflate`, and a
/// data connection is never compressed), so RSV bits are always a protocol
/// error, and the only payloads are whole messages.
enum WebSocketCodec {
    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA

        var isControl: Bool { rawValue >= 0x8 }
    }

    /// One complete message, fragments already joined.
    enum Message: Equatable {
        case text(Data)
        case binary(Data)
        case ping(Data)
        case pong(Data)
        /// The peer is closing. `code` is nil when the frame carried none.
        case close(code: UInt16?, reason: String)
    }

    enum Failure: Error, Equatable {
        /// The server answered the upgrade with something other than 101.
        case upgradeRefused(status: Int, body: String)
        case malformedUpgrade(String)
        case protocolViolation(String)
        /// A frame larger than this client will hold in memory.
        case messageTooLarge(Int)
    }

    /// Larger than the control connection's 1 MiB message limit and far
    /// above a data connection's 64 KiB chunks; anything bigger is not a
    /// peer this client was written for.
    static let maxMessageBytes = 4 * 1024 * 1024

    // MARK: - Handshake

    /// 16 random bytes, base64 — the `Sec-WebSocket-Key` of one handshake.
    static func makeKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }

    static func upgradeRequest(
        path: String, host: String, subprotocol: String, key: String
    ) -> Data {
        Data("""
            GET \(path) HTTP/1.1\r
            Host: \(host)\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Key: \(key)\r
            Sec-WebSocket-Version: 13\r
            Sec-WebSocket-Protocol: \(subprotocol)\r
            \r

            """.utf8)
    }

    /// The `Sec-WebSocket-Accept` a server must answer `key` with.
    static func acceptValue(forKey key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        return Data(Insecure.SHA1.hash(data: Data((key + magic).utf8)))
            .base64EncodedString()
    }

    enum UpgradeReading: Equatable {
        /// The response head has not fully arrived.
        case incomplete
        /// Upgraded. `remainder` is whatever followed the head in the same
        /// read — already frame bytes.
        case upgraded(remainder: Data)
    }

    /// Reads the server's answer to `upgradeRequest`. The accept value and
    /// the subprotocol are both checked: a peer that is not a WebSocket
    /// server, or not the protocol asked for, must not be fed frames.
    static func readUpgradeResponse(
        _ buffer: Data, key: String, subprotocol: String
    ) throws -> UpgradeReading {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: terminator) else {
            // A response head has no business being this long; without the
            // cap a peer that never ends its head would buffer forever.
            guard buffer.count <= 16 * 1024 else {
                throw Failure.malformedUpgrade("response head never ended")
            }
            return .incomplete
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ", omittingEmptySubsequences: true)
        guard let status, status.count >= 2, status[0].hasPrefix("HTTP/"),
              let code = Int(status[1])
        else { throw Failure.malformedUpgrade("no status line") }
        guard code == 101 else {
            let body = String(
                decoding: buffer[end.upperBound...].prefix(200), as: UTF8.self)
            throw Failure.upgradeRefused(status: code, body: body)
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["sec-websocket-accept"] == acceptValue(forKey: key) else {
            throw Failure.malformedUpgrade("wrong Sec-WebSocket-Accept")
        }
        guard headers["sec-websocket-protocol"] == subprotocol else {
            throw Failure.malformedUpgrade("subprotocol was not accepted")
        }
        return .upgraded(remainder: Data(buffer[end.upperBound...]))
    }

    // MARK: - Frames out

    /// One unfragmented client frame. Client frames are always masked; the
    /// key is a parameter so the encoding is deterministic under test.
    static func frame(
        _ opcode: Opcode, payload: Data,
        maskKey: [UInt8] = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
    ) -> Data {
        precondition(maskKey.count == 4)
        var frame = Data([0x80 | opcode.rawValue])
        let count = payload.count
        switch count {
        case ..<126:
            frame.append(0x80 | UInt8(count))
        case ..<65_536:
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)])
        default:
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(contentsOf: maskKey)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ maskKey[$0.offset % 4] })
        return frame
    }

    static func closeFrame(code: UInt16 = 1000) -> Data {
        frame(.close, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }

    // MARK: - Frames in

    /// Incremental reader of server frames. Bytes arrive in whatever pieces
    /// the pipe delivers; `next()` returns each complete message in order
    /// and nil when it needs more.
    struct Decoder {
        private var buffer = Data()
        /// The data message being assembled across fragments.
        private var partial: (opcode: Opcode, payload: Data)?

        mutating func append(_ bytes: Data) {
            buffer.append(bytes)
        }

        mutating func next() throws -> Message? {
            while let frame = try nextFrame() {
                if frame.opcode.isControl {
                    // A control frame may sit between the fragments of a
                    // data message and is never fragmented itself.
                    guard frame.fin, frame.payload.count <= 125 else {
                        throw Failure.protocolViolation("fragmented or oversized control frame")
                    }
                    switch frame.opcode {
                    case .ping: return .ping(frame.payload)
                    case .pong: return .pong(frame.payload)
                    default: return closeMessage(frame.payload)
                    }
                }
                switch frame.opcode {
                case .continuation:
                    guard var assembling = partial else {
                        throw Failure.protocolViolation("continuation with nothing to continue")
                    }
                    assembling.payload.append(frame.payload)
                    guard assembling.payload.count <= WebSocketCodec.maxMessageBytes else {
                        throw Failure.messageTooLarge(assembling.payload.count)
                    }
                    partial = frame.fin ? nil : assembling
                    if frame.fin { return message(assembling.opcode, assembling.payload) }
                default:
                    guard partial == nil else {
                        throw Failure.protocolViolation("new message inside a fragmented one")
                    }
                    if frame.fin { return message(frame.opcode, frame.payload) }
                    partial = (frame.opcode, frame.payload)
                }
            }
            return nil
        }

        private func message(_ opcode: Opcode, _ payload: Data) -> Message {
            opcode == .text ? .text(payload) : .binary(payload)
        }

        private func closeMessage(_ payload: Data) -> Message {
            guard payload.count >= 2 else { return .close(code: nil, reason: "") }
            let bytes = [UInt8](payload)
            return .close(
                code: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
                reason: String(decoding: bytes[2...], as: UTF8.self)
            )
        }

        private struct Frame {
            var fin: Bool
            var opcode: Opcode
            var payload: Data
        }

        /// Pops one whole frame off the buffer, or nil if it is not all here.
        private mutating func nextFrame() throws -> Frame? {
            let bytes = buffer
            guard bytes.count >= 2 else { return nil }
            let base = bytes.startIndex
            let first = bytes[base], second = bytes[base + 1]
            guard first & 0x70 == 0 else {
                throw Failure.protocolViolation("reserved bits set with no extension negotiated")
            }
            guard let opcode = Opcode(rawValue: first & 0x0F) else {
                throw Failure.protocolViolation("unknown opcode \(first & 0x0F)")
            }
            var offset = 2
            var length = Int(second & 0x7F)
            if length == 126 {
                guard bytes.count >= offset + 2 else { return nil }
                length = Int(bytes[base + 2]) << 8 | Int(bytes[base + 3])
                offset += 2
            } else if length == 127 {
                guard bytes.count >= offset + 8 else { return nil }
                var wide: UInt64 = 0
                for index in 0..<8 { wide = wide << 8 | UInt64(bytes[base + 2 + index]) }
                guard wide <= UInt64(WebSocketCodec.maxMessageBytes) else {
                    throw Failure.messageTooLarge(Int(clamping: wide))
                }
                length = Int(wide)
                offset += 8
            }
            guard length <= WebSocketCodec.maxMessageBytes else {
                throw Failure.messageTooLarge(length)
            }
            // A server frame is never masked; one that is gets unmasked
            // rather than refused — being liberal here costs nothing.
            let masked = second & 0x80 != 0
            var key: [UInt8] = []
            if masked {
                guard bytes.count >= offset + 4 else { return nil }
                key = [UInt8](bytes[(base + offset)..<(base + offset + 4)])
                offset += 4
            }
            guard bytes.count >= offset + length else { return nil }
            var payload = Data(bytes[(base + offset)..<(base + offset + length)])
            if masked {
                payload = Data(payload.enumerated().map { $0.element ^ key[$0.offset % 4] })
            }
            buffer = Data(bytes[(base + offset + length)...])
            return Frame(fin: first & 0x80 != 0, opcode: opcode, payload: payload)
        }
    }
}
