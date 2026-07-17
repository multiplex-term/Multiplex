import Foundation

/// Minimal proto2 wire codec for mosh's three tiny schemas
/// (transportinstruction / userinput / hostinput). Hand-rolled on purpose:
/// the messages are a handful of fields, and a protobuf dependency would be
/// a new supply-chain surface on the transport path. Unknown fields are
/// skipped, per proto2 semantics. Pure — exercised directly by unit tests.
enum MoshProto {
    // MARK: - Writer

    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    static func appendField(_ field: Int, varint: UInt64, to data: inout Data) {
        appendVarint(UInt64(field) << 3, to: &data)
        appendVarint(varint, to: &data)
    }

    static func appendField(_ field: Int, bytes: Data, to data: inout Data) {
        appendVarint(UInt64(field) << 3 | 2, to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    // MARK: - Reader

    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    /// Iterate (field, value) pairs; returns nil at clean end-of-message.
    /// Throws on malformed input — callers drop the packet.
    struct Reader {
        enum Failure: Error { case truncated, unsupportedWireType }

        private let bytes: Data
        private var index: Data.Index

        init(_ data: Data) {
            bytes = data
            index = data.startIndex
        }

        mutating func next() throws -> (field: Int, value: Value)? {
            guard index < bytes.endIndex else { return nil }
            let tag = try varint()
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                return (field, .varint(try varint()))
            case 1: // fixed64 — mosh never sends one; skip for robustness
                try skip(8)
                return try next()
            case 2:
                let length = Int(try varint())
                guard length <= bytes.distance(from: index, to: bytes.endIndex)
                else { throw Failure.truncated }
                let end = bytes.index(index, offsetBy: length)
                let value = bytes[index ..< end]
                index = end
                return (field, .bytes(value))
            case 5: // fixed32 — likewise skip
                try skip(4)
                return try next()
            default: // groups and reserved wire types
                throw Failure.unsupportedWireType
            }
        }

        private mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.endIndex, shift < 64 else { throw Failure.truncated }
                let byte = bytes[index]
                index = bytes.index(after: index)
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        private mutating func skip(_ count: Int) throws {
            guard count <= bytes.distance(from: index, to: bytes.endIndex)
            else { throw Failure.truncated }
            index = bytes.index(index, offsetBy: count)
        }
    }
}

/// `TransportBuffers.Instruction` — the one message every mosh datagram
/// carries (zlib-compressed, then fragmented).
struct MoshInstruction: Equatable {
    static let protocolVersion: UInt64 = 2

    var protocolVersionField: UInt64 = MoshInstruction.protocolVersion
    var oldNum: UInt64 = 0
    var newNum: UInt64 = 0
    var ackNum: UInt64 = 0
    var throwawayNum: UInt64 = 0
    var diff = Data()
    var chaff = Data()

    func encoded() -> Data {
        var out = Data()
        MoshProto.appendField(1, varint: protocolVersionField, to: &out)
        MoshProto.appendField(2, varint: oldNum, to: &out)
        MoshProto.appendField(3, varint: newNum, to: &out)
        MoshProto.appendField(4, varint: ackNum, to: &out)
        MoshProto.appendField(5, varint: throwawayNum, to: &out)
        MoshProto.appendField(6, bytes: diff, to: &out)
        MoshProto.appendField(7, bytes: chaff, to: &out)
        return out
    }

    init() {}

    init?(parsing data: Data) {
        var reader = MoshProto.Reader(data)
        do {
            while let (field, value) = try reader.next() {
                switch (field, value) {
                case (1, .varint(let v)): protocolVersionField = v
                case (2, .varint(let v)): oldNum = v
                case (3, .varint(let v)): newNum = v
                case (4, .varint(let v)): ackNum = v
                case (5, .varint(let v)): throwawayNum = v
                case (6, .bytes(let v)): diff = v
                case (7, .bytes(let v)): chaff = v
                default: continue // unknown field — ignore
                }
            }
        } catch {
            return nil
        }
    }
}

/// One user-side event in a `ClientBuffers.UserMessage` diff.
enum MoshUserEvent: Equatable {
    case keys(Data)
    case resize(cols: Int, rows: Int)
}

/// `ClientBuffers.UserMessage`: repeated Instruction, where each
/// Instruction carries a proto2 extension — keystroke (2) wrapping
/// `Keystroke.keys` (4), or resize (3) wrapping width (5) / height (6).
enum MoshUserMessage {
    static func encode(_ events: ArraySlice<MoshUserEvent>) -> Data {
        var out = Data()
        var pendingKeys = Data()

        func flushKeys() {
            guard !pendingKeys.isEmpty else { return }
            var keystroke = Data()
            MoshProto.appendField(4, bytes: pendingKeys, to: &keystroke)
            var instruction = Data()
            MoshProto.appendField(2, bytes: keystroke, to: &instruction)
            MoshProto.appendField(1, bytes: instruction, to: &out)
            pendingKeys = Data()
        }

        for event in events {
            switch event {
            case .keys(let data):
                // Consecutive keystrokes coalesce into one instruction,
                // exactly like UserStream::diff_from.
                pendingKeys.append(data)
            case .resize(let cols, let rows):
                flushKeys()
                var resize = Data()
                MoshProto.appendField(5, varint: UInt64(cols), to: &resize)
                MoshProto.appendField(6, varint: UInt64(rows), to: &resize)
                var instruction = Data()
                MoshProto.appendField(3, bytes: resize, to: &instruction)
                MoshProto.appendField(1, bytes: instruction, to: &out)
            }
        }
        flushKeys()
        return out
    }

    /// Decode — the client never receives one; this feeds the unit tests'
    /// fake server side.
    static func decode(_ data: Data) -> [MoshUserEvent]? {
        var events: [MoshUserEvent] = []
        var reader = MoshProto.Reader(data)
        do {
            while let (field, value) = try reader.next() {
                guard field == 1, case .bytes(let body) = value else { continue }
                var inner = MoshProto.Reader(body)
                while let (extField, extValue) = try inner.next() {
                    switch (extField, extValue) {
                    case (2, .bytes(let keystroke)):
                        var keysReader = MoshProto.Reader(keystroke)
                        while let (f, v) = try keysReader.next() {
                            if f == 4, case .bytes(let keys) = v { events.append(.keys(keys)) }
                        }
                    case (3, .bytes(let resize)):
                        var cols = 0, rows = 0
                        var resizeReader = MoshProto.Reader(resize)
                        while let (f, v) = try resizeReader.next() {
                            if f == 5, case .varint(let w) = v { cols = Int(truncatingIfNeeded: w) }
                            if f == 6, case .varint(let h) = v { rows = Int(truncatingIfNeeded: h) }
                        }
                        events.append(.resize(cols: cols, rows: rows))
                    default:
                        continue
                    }
                }
            }
        } catch {
            return nil
        }
        return events
    }
}

/// One host-side action in a `HostBuffers.HostMessage` diff.
enum MoshHostInstruction: Equatable {
    /// Terminal bytes that transform the previous screen into this one —
    /// fed straight to the emulator.
    case hostBytes(Data)
    case resize(cols: Int, rows: Int)
    /// Highest input frame the server has applied (prediction bookkeeping).
    case echoAck(UInt64)
}

/// `HostBuffers.HostMessage`: extensions hostbytes (2) wrapping
/// `HostBytes.hoststring` (4), resize (3) wrapping width (5) / height (6),
/// echoack (7) wrapping `EchoAck.echo_ack_num` (8).
enum MoshHostMessage {
    static func decode(_ data: Data) -> [MoshHostInstruction]? {
        var items: [MoshHostInstruction] = []
        var reader = MoshProto.Reader(data)
        do {
            while let (field, value) = try reader.next() {
                guard field == 1, case .bytes(let body) = value else { continue }
                var inner = MoshProto.Reader(body)
                while let (extField, extValue) = try inner.next() {
                    switch (extField, extValue) {
                    case (2, .bytes(let hostBytes)):
                        var bytesReader = MoshProto.Reader(hostBytes)
                        while let (f, v) = try bytesReader.next() {
                            if f == 4, case .bytes(let string) = v { items.append(.hostBytes(string)) }
                        }
                    case (3, .bytes(let resize)):
                        var cols = 0, rows = 0
                        var resizeReader = MoshProto.Reader(resize)
                        while let (f, v) = try resizeReader.next() {
                            if f == 5, case .varint(let w) = v { cols = Int(truncatingIfNeeded: w) }
                            if f == 6, case .varint(let h) = v { rows = Int(truncatingIfNeeded: h) }
                        }
                        items.append(.resize(cols: cols, rows: rows))
                    case (7, .bytes(let echo)):
                        var echoReader = MoshProto.Reader(echo)
                        while let (f, v) = try echoReader.next() {
                            if f == 8, case .varint(let num) = v { items.append(.echoAck(num)) }
                        }
                    default:
                        continue
                    }
                }
            }
        } catch {
            return nil
        }
        return items
    }

    /// Encode — client never sends one; feeds the unit tests' fake server.
    static func encode(_ items: [MoshHostInstruction]) -> Data {
        var out = Data()
        for item in items {
            var instruction = Data()
            switch item {
            case .hostBytes(let bytes):
                var hostBytes = Data()
                MoshProto.appendField(4, bytes: bytes, to: &hostBytes)
                MoshProto.appendField(2, bytes: hostBytes, to: &instruction)
            case .resize(let cols, let rows):
                var resize = Data()
                MoshProto.appendField(5, varint: UInt64(cols), to: &resize)
                MoshProto.appendField(6, varint: UInt64(rows), to: &resize)
                MoshProto.appendField(3, bytes: resize, to: &instruction)
            case .echoAck(let num):
                var echo = Data()
                MoshProto.appendField(8, varint: num, to: &echo)
                MoshProto.appendField(7, bytes: echo, to: &instruction)
            }
            MoshProto.appendField(1, bytes: instruction, to: &out)
        }
        return out
    }
}
