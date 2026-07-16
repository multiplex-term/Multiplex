import Foundation

/// mosh transport fragmentation: an Instruction (zlib-compressed protobuf)
/// is sliced into datagram-sized fragments. Wire header is 10 bytes —
/// instruction id (BE64) then final-bit<<15 | fragment number (BE16).
/// Pure — exercised directly by unit tests.
enum MoshFragmentWire {
    static let headerLength = 10

    static func encode(id: UInt64, number: UInt16, final: Bool, contents: Data) -> Data {
        var out = Data()
        var idBE = id.bigEndian
        withUnsafeBytes(of: &idBE) { out.append(contentsOf: $0) }
        var numBE = ((final ? UInt16(0x8000) : 0) | number).bigEndian
        withUnsafeBytes(of: &numBE) { out.append(contentsOf: $0) }
        out.append(contents)
        return out
    }

    static func decode(_ data: Data) -> (id: UInt64, number: UInt16, final: Bool, contents: Data)? {
        guard data.count >= headerLength else { return nil }
        let start = data.startIndex
        let idEnd = data.index(start, offsetBy: 8)
        let id = data[start ..< idEnd].reduce(UInt64(0)) {
            $0 << 8 | UInt64($1)
        }
        let numberEnd = data.index(idEnd, offsetBy: 2)
        let combined = UInt16(data[idEnd]) << 8
            | UInt16(data[data.index(after: idEnd)])
        return (
            id,
            combined & 0x7FFF,
            combined & 0x8000 != 0,
            data[numberEnd...]
        )
    }
}

/// Sender side: slice one compressed instruction into fragments. A fresh id
/// per instruction send keeps reassembly unambiguous — the receiver drops
/// any partial assembly when a new id arrives.
struct MoshFragmenter {
    private var nextID: UInt64 = 0

    /// `budget` is the datagram payload budget for this instruction, i.e.
    /// path MTU minus the packet layer's 28 bytes of nonce/timestamps/tag;
    /// the 10-byte fragment header comes out of it here.
    mutating func fragments(of compressedInstruction: Data, budget: Int) -> [Data] {
        let chunkSize = max(budget - MoshFragmentWire.headerLength, 1)
        let id = nextID
        nextID &+= 1

        var out: [Data] = []
        var offset = 0
        let bytes = compressedInstruction
        repeat {
            let end = min(offset + chunkSize, bytes.count)
            let final = end == bytes.count
            out.append(MoshFragmentWire.encode(
                id: id,
                number: UInt16(out.count),
                final: final,
                contents: bytes[
                    bytes.index(bytes.startIndex, offsetBy: offset)
                        ..< bytes.index(bytes.startIndex, offsetBy: end)
                ]
            ))
            offset = end
        } while offset < bytes.count
        return out
    }
}

/// Receiver side: reassemble fragments back into one compressed
/// instruction. Keyed by instruction id; a fragment bearing a different id
/// abandons the partial assembly in progress (mosh does the same).
struct MoshFragmentAssembly {
    /// Bounds hostile input: mosh instructions decompress to ≤ 4 MiB, so a
    /// compressed assembly beyond that is garbage.
    static let maxAssembledSize = 4 * 1024 * 1024

    private var currentID: UInt64?
    private var pieces: [UInt16: Data] = [:]
    private var total: Int?
    private var bytesHeld = 0

    /// Feed one fragment; returns the whole compressed instruction once
    /// every piece has arrived.
    mutating func add(_ fragment: Data) -> Data? {
        guard let (id, number, final, contents) = MoshFragmentWire.decode(fragment) else { return nil }

        if id != currentID {
            reset()
            currentID = id
        }

        // Almost every mosh instruction fits one datagram. Return its payload
        // slice directly instead of inserting it into a dictionary and copying
        // it straight back out into an assembly buffer.
        if number == 0, final {
            reset()
            return contents
        }

        if pieces.updateValue(contents, forKey: number) == nil {
            bytesHeld += contents.count
        }
        if final { total = Int(number) + 1 }
        guard bytesHeld <= Self.maxAssembledSize, pieces.count <= 0x8000 else {
            reset()
            return nil
        }

        guard let total, pieces.count == total else { return nil }
        var assembled = Data(capacity: bytesHeld)
        for i in 0 ..< total {
            guard let piece = pieces[UInt16(i)] else {
                reset()
                return nil
            }
            assembled.append(piece)
        }
        reset()
        return assembled
    }

    private mutating func reset() {
        currentID = nil
        pieces = [:]
        total = nil
        bytesHeld = 0
    }
}
