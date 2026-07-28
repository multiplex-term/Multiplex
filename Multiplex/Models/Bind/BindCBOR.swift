import Foundation

/// The minimal CBOR subset the bind-v1 wire speaks: unsigned ints, byte
/// strings, text, arrays, text-keyed maps, and booleans — definite lengths
/// only. Encoding preserves the caller's key order and emits minimal-length
/// headers, which is what lets the shared vectors pin client frames to the
/// exact bytes `mpx`'s ciborium produces (multiplex-cli spec/bind-v1.md).
enum BindCBOR {
    indirect enum Value: Equatable {
        case uint(UInt64)
        case bytes(Data)
        case text(String)
        case array([Value])
        case map([(key: String, value: Value)])
        case bool(Bool)

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.uint(let a), .uint(let b)): a == b
            case (.bytes(let a), .bytes(let b)): a == b
            case (.text(let a), .text(let b)): a == b
            case (.array(let a), .array(let b)): a == b
            case (.bool(let a), .bool(let b)): a == b
            case (.map(let a), .map(let b)):
                a.count == b.count && zip(a, b).allSatisfy {
                    $0.0.key == $0.1.key && $0.0.value == $0.1.value
                }
            default: false
            }
        }

        subscript(key: String) -> Value? {
            guard case .map(let entries) = self else { return nil }
            return entries.first { $0.key == key }?.value
        }

        var uintValue: UInt64? {
            guard case .uint(let value) = self else { return nil }
            return value
        }

        var textValue: String? {
            guard case .text(let value) = self else { return nil }
            return value
        }

        var bytesValue: Data? {
            guard case .bytes(let value) = self else { return nil }
            return value
        }

        var boolValue: Bool? {
            guard case .bool(let value) = self else { return nil }
            return value
        }

        var textArrayValue: [String]? {
            guard case .array(let items) = self else { return nil }
            var result: [String] = []
            for item in items {
                guard let text = item.textValue else { return nil }
                result.append(text)
            }
            return result
        }
    }

    enum DecodeError: Error {
        case truncated
        case unsupported(UInt8)
        case invalidText
        case nonTextMapKey
    }

    // MARK: Encode

    static func encode(_ value: Value) -> Data {
        var out = Data()
        append(value, to: &out)
        return out
    }

    private static func append(_ value: Value, to out: inout Data) {
        switch value {
        case .uint(let number):
            appendHeader(major: 0, length: number, to: &out)
        case .bytes(let data):
            appendHeader(major: 2, length: UInt64(data.count), to: &out)
            out.append(data)
        case .text(let string):
            let utf8 = Data(string.utf8)
            appendHeader(major: 3, length: UInt64(utf8.count), to: &out)
            out.append(utf8)
        case .array(let items):
            appendHeader(major: 4, length: UInt64(items.count), to: &out)
            for item in items { append(item, to: &out) }
        case .map(let entries):
            appendHeader(major: 5, length: UInt64(entries.count), to: &out)
            for entry in entries {
                append(.text(entry.key), to: &out)
                append(entry.value, to: &out)
            }
        case .bool(let flag):
            out.append(flag ? 0xF5 : 0xF4)
        }
    }

    private static func appendHeader(major: UInt8, length: UInt64, to out: inout Data) {
        let base = major << 5
        switch length {
        case 0..<24:
            out.append(base | UInt8(length))
        case 24...0xFF:
            out.append(base | 24)
            out.append(UInt8(length))
        case 0x100...0xFFFF:
            out.append(base | 25)
            out.append(contentsOf: withUnsafeBytes(of: UInt16(length).bigEndian, Array.init))
        case 0x1_0000...0xFFFF_FFFF:
            out.append(base | 26)
            out.append(contentsOf: withUnsafeBytes(of: UInt32(length).bigEndian, Array.init))
        default:
            out.append(base | 27)
            out.append(contentsOf: withUnsafeBytes(of: length.bigEndian, Array.init))
        }
    }

    // MARK: Decode

    static func decode(_ data: Data) throws -> Value {
        var reader = Reader(data: data)
        let value = try reader.readValue()
        return value
    }

    private struct Reader {
        let data: Data
        var index: Data.Index

        init(data: Data) {
            self.data = data
            index = data.startIndex
        }

        mutating func readByte() throws -> UInt8 {
            guard index < data.endIndex else { throw DecodeError.truncated }
            defer { index = data.index(after: index) }
            return data[index]
        }

        mutating func readBytes(_ count: Int) throws -> Data {
            guard count >= 0,
                  let end = data.index(index, offsetBy: count, limitedBy: data.endIndex)
            else { throw DecodeError.truncated }
            defer { index = end }
            return data.subdata(in: index..<end)
        }

        mutating func readLength(additional: UInt8) throws -> UInt64 {
            switch additional {
            case 0..<24: return UInt64(additional)
            case 24: return UInt64(try readByte())
            case 25:
                let bytes = try readBytes(2)
                return bytes.reduce(0) { $0 << 8 | UInt64($1) }
            case 26:
                let bytes = try readBytes(4)
                return bytes.reduce(0) { $0 << 8 | UInt64($1) }
            case 27:
                let bytes = try readBytes(8)
                return bytes.reduce(0) { $0 << 8 | UInt64($1) }
            default:
                throw DecodeError.unsupported(additional)
            }
        }

        /// A length used as a byte or element *count*, checked against the
        /// bytes actually remaining before the Int conversion — which traps
        /// on a 64-bit claim, and a sealed frame's plaintext is still a
        /// peer's bytes. Elements cost at least one byte each, so remaining
        /// bytes bound element counts too (and keep `reserveCapacity` from
        /// pre-allocating a fiction).
        mutating func readCount(additional: UInt8) throws -> Int {
            let length = try readLength(additional: additional)
            guard length <= UInt64(data.distance(from: index, to: data.endIndex))
            else { throw DecodeError.truncated }
            return Int(length)
        }

        mutating func readValue() throws -> Value {
            let initial = try readByte()
            let major = initial >> 5
            let additional = initial & 0x1F
            switch major {
            case 0:
                return .uint(try readLength(additional: additional))
            case 2:
                return .bytes(try readBytes(try readCount(additional: additional)))
            case 3:
                let length = try readCount(additional: additional)
                guard let text = String(data: try readBytes(length), encoding: .utf8)
                else { throw DecodeError.invalidText }
                return .text(text)
            case 4:
                let count = try readCount(additional: additional)
                var items: [Value] = []
                items.reserveCapacity(count)
                for _ in 0..<count { items.append(try readValue()) }
                return .array(items)
            case 5:
                let count = try readCount(additional: additional)
                var entries: [(key: String, value: Value)] = []
                entries.reserveCapacity(count)
                for _ in 0..<count {
                    guard case .text(let key) = try readValue() else {
                        throw DecodeError.nonTextMapKey
                    }
                    entries.append((key, try readValue()))
                }
                return .map(entries)
            case 7 where additional == 20:
                return .bool(false)
            case 7 where additional == 21:
                return .bool(true)
            default:
                throw DecodeError.unsupported(initial)
            }
        }
    }
}
