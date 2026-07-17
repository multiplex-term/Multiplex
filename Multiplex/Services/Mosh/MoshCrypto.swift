import CommonCrypto
import Foundation

/// One 128-bit AES block with big-endian byte semantics (`hi` = bytes 0–7).
/// GF(2^128) doubling and XOR are what OCB spends its time on.
struct Block128: Equatable {
    var hi: UInt64 = 0
    var lo: UInt64 = 0

    static let zero = Block128()

    init() {}

    init(_ bytes: ArraySlice<UInt8>) {
        precondition(bytes.count == 16)
        var hi: UInt64 = 0, lo: UInt64 = 0
        let base = bytes.startIndex
        for i in 0 ..< 8 { hi = hi << 8 | UInt64(bytes[base + i]) }
        for i in 8 ..< 16 { lo = lo << 8 | UInt64(bytes[base + i]) }
        self.hi = hi
        self.lo = lo
    }

    init(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
        precondition(offset >= 0 && offset + 16 <= bytes.count)
        var hi: UInt64 = 0, lo: UInt64 = 0
        for i in 0 ..< 8 { hi = hi << 8 | UInt64(bytes[offset + i]) }
        for i in 8 ..< 16 { lo = lo << 8 | UInt64(bytes[offset + i]) }
        self.hi = hi
        self.lo = lo
    }

    var bytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0 ..< 8 { out[i] = UInt8(truncatingIfNeeded: hi >> (56 - 8 * i)) }
        for i in 0 ..< 8 { out[8 + i] = UInt8(truncatingIfNeeded: lo >> (56 - 8 * i)) }
        return out
    }

    /// Append without materializing the temporary 16-byte array returned by
    /// `bytes`. OCB emits one block after another, so this removes two tiny
    /// heap candidates per full block on the packet hot path.
    func appendBytes(to out: inout [UInt8]) {
        for i in 0 ..< 8 {
            out.append(UInt8(truncatingIfNeeded: hi >> (56 - 8 * i)))
        }
        for i in 0 ..< 8 {
            out.append(UInt8(truncatingIfNeeded: lo >> (56 - 8 * i)))
        }
    }

    func byte(at index: Int) -> UInt8 {
        precondition((0 ..< 16).contains(index))
        if index < 8 {
            return UInt8(truncatingIfNeeded: hi >> (56 - 8 * index))
        }
        return UInt8(truncatingIfNeeded: lo >> (56 - 8 * (index - 8)))
    }

    mutating func setByte(_ byte: UInt8, at index: Int) {
        precondition((0 ..< 16).contains(index))
        let laneIndex = index < 8 ? index : index - 8
        let shift = UInt64(56 - 8 * laneIndex)
        let mask = UInt64(0xFF) << shift
        if index < 8 {
            hi = (hi & ~mask) | UInt64(byte) << shift
        } else {
            lo = (lo & ~mask) | UInt64(byte) << shift
        }
    }

    func write(to buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        precondition(offset >= 0 && offset + 16 <= buffer.count)
        for i in 0 ..< 16 { buffer[offset + i] = byte(at: i) }
    }

    func xor(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) {
        precondition(offset >= 0 && offset + 16 <= buffer.count)
        for i in 0 ..< 16 { buffer[offset + i] ^= byte(at: i) }
    }

    static func ^ (a: Block128, b: Block128) -> Block128 {
        var out = Block128()
        out.hi = a.hi ^ b.hi
        out.lo = a.lo ^ b.lo
        return out
    }

    static func ^= (a: inout Block128, b: Block128) {
        a.hi ^= b.hi
        a.lo ^= b.lo
    }

    /// Doubling in GF(2^128): shift left one bit, fold the carry back in
    /// through the field polynomial (0x87).
    var doubled: Block128 {
        var out = Block128()
        let carry = hi >> 63
        out.hi = hi << 1 | lo >> 63
        out.lo = lo << 1 ^ (carry &* 0x87)
        return out
    }
}

/// AES-128-OCB3 (RFC 7253) with 96-bit nonces and 128-bit tags — the AEAD
/// mosh datagrams are sealed with. Associated data is always empty in mosh,
/// so it isn't modeled. Not thread-safe; owned by one session actor.
final class MoshAEAD {
    enum Failure: Error {
        case badKey
        case cryptorFailure
    }

    private let encryptor: CCCryptorRef
    private let decryptor: CCCryptorRef
    private let lStar: Block128
    private let lDollar: Block128
    /// L_i table indexed by ntz — 64 entries covers any datagram-sized message.
    private let l: [Block128]

    init(key: Data) throws {
        guard key.count == kCCKeySizeAES128 else { throw Failure.badKey }
        func makeCryptor(_ op: CCOperation) throws -> CCCryptorRef {
            var cryptor: CCCryptorRef?
            let status = key.withUnsafeBytes {
                CCCryptorCreate(
                    op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    $0.baseAddress, key.count, nil, &cryptor
                )
            }
            guard status == kCCSuccess, let cryptor else { throw Failure.cryptorFailure }
            return cryptor
        }
        encryptor = try makeCryptor(CCOperation(kCCEncrypt))
        decryptor = try makeCryptor(CCOperation(kCCDecrypt))

        lStar = Self.transform(encryptor, .zero)
        lDollar = lStar.doubled
        var table = [lDollar.doubled]
        for _ in 1 ..< 64 { table.append(table.last!.doubled) }
        l = table
    }

    deinit {
        CCCryptorRelease(encryptor)
        CCCryptorRelease(decryptor)
    }

    /// Seal: returns ciphertext || 16-byte tag. mosh never sends associated
    /// data; the parameter exists so RFC 7253's composite test vector can
    /// exercise the full algorithm.
    func seal(_ plaintext: Data, nonce: [UInt8], associatedData: Data = Data()) -> Data {
        let initial = initialOffset(nonce: nonce)
        return plaintext.withUnsafeBytes { source in
            let fullBlocks = plaintext.count / 16
            let fullBytes = fullBlocks * 16
            let remainder = plaintext.count - fullBytes
            let input = transformedInput(
                source,
                fullBlocks: fullBlocks,
                initialOffset: initial
            )

            return Self.uninitializedData(count: plaintext.count + 16) { output in
                if fullBytes > 0 {
                    input.withUnsafeBytes {
                        Self.transform(encryptor, input: $0, output: output)
                    }
                }

                // Offset_i is deterministic, so walking it again is cheaper
                // than retaining a payload-sized block/offset representation.
                // Unmask the AES output in place and checksum the matching
                // plaintext block during the same pass.
                var offset = initial
                var checksum = Block128.zero
                for blockIndex in 0 ..< fullBlocks {
                    let blockNumber = blockIndex + 1
                    let byteOffset = blockIndex * 16
                    offset ^= l[blockNumber.trailingZeroBitCount]
                    offset.xor(into: output, at: byteOffset)
                    checksum ^= Block128(source, at: byteOffset)
                }

                if remainder > 0 {
                    offset ^= lStar
                    let pad = encrypt(offset)
                    var padded = Block128.zero
                    for i in 0 ..< remainder {
                        let byte = source[fullBytes + i]
                        output[fullBytes + i] = byte ^ pad.byte(at: i)
                        padded.setByte(byte, at: i)
                    }
                    padded.setByte(0x80, at: remainder)
                    checksum ^= padded
                }

                var tag = encrypt(checksum ^ offset ^ lDollar)
                tag ^= hash(associatedData)
                tag.write(to: output, at: plaintext.count)
            }
        }
    }

    /// Open: returns the plaintext, or nil when authentication fails.
    func open(_ box: Data, nonce: [UInt8], associatedData: Data = Data()) -> Data? {
        guard box.count >= 16 else { return nil }
        let cipherCount = box.count - 16
        let initial = initialOffset(nonce: nonce)
        let (plain, expected, received) = box.withUnsafeBytes { source in
            let fullBlocks = cipherCount / 16
            let fullBytes = fullBlocks * 16
            let remainder = cipherCount - fullBytes
            let input = transformedInput(
                source,
                fullBlocks: fullBlocks,
                initialOffset: initial
            )

            var offset = initial
            var checksum = Block128.zero
            let plain = Self.uninitializedData(count: cipherCount) { output in
                if fullBytes > 0 {
                    input.withUnsafeBytes {
                        Self.transform(decryptor, input: $0, output: output)
                    }
                }

                // Decryption produces AES^-1(C_i xor Offset_i). Remove the
                // same deterministic offset in place and fold each recovered
                // plaintext block into the checksum immediately.
                for blockIndex in 0 ..< fullBlocks {
                    let blockNumber = blockIndex + 1
                    let byteOffset = blockIndex * 16
                    offset ^= l[blockNumber.trailingZeroBitCount]
                    offset.xor(into: output, at: byteOffset)
                    checksum ^= Block128(UnsafeRawBufferPointer(output), at: byteOffset)
                }

                if remainder > 0 {
                    offset ^= lStar
                    let pad = encrypt(offset)
                    var padded = Block128.zero
                    for i in 0 ..< remainder {
                        let byte = source[fullBytes + i] ^ pad.byte(at: i)
                        output[fullBytes + i] = byte
                        padded.setByte(byte, at: i)
                    }
                    padded.setByte(0x80, at: remainder)
                    checksum ^= padded
                }
            }

            var expected = encrypt(checksum ^ offset ^ lDollar)
            expected ^= hash(associatedData)
            return (plain, expected, Block128(source, at: cipherCount))
        }
        guard (expected.hi ^ received.hi) | (expected.lo ^ received.lo) == 0
        else { return nil }
        return plain
    }

    /// Build the AES input body directly from contiguous source bytes. This is
    /// the only payload-sized buffer besides the final output.
    private func transformedInput(
        _ source: UnsafeRawBufferPointer,
        fullBlocks: Int,
        initialOffset: Block128
    ) -> Data {
        Self.uninitializedData(count: fullBlocks * 16) { input in
            var offset = initialOffset
            for blockIndex in 0 ..< fullBlocks {
                let blockNumber = blockIndex + 1
                let byteOffset = blockIndex * 16
                offset ^= l[blockNumber.trailingZeroBitCount]
                (Block128(source, at: byteOffset) ^ offset).write(to: input, at: byteOffset)
            }
        }
    }

    /// Foundation's `Data(count:)` zero-fills. Allocate raw storage, initialize
    /// every byte in the body, then transfer ownership to Data without another
    /// payload copy.
    private static func uninitializedData(
        count: Int,
        initialize: (UnsafeMutableRawBufferPointer) -> Void
    ) -> Data {
        guard count > 0 else { return Data() }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        initialize(UnsafeMutableRawBufferPointer(start: storage, count: count))
        return Data(
            bytesNoCopy: storage,
            count: count,
            deallocator: .custom { pointer, _ in pointer.deallocate() }
        )
    }

    /// HASH(K, A) — the associated-data accumulator (RFC 7253 §4.1).
    private func hash(_ associatedData: Data) -> Block128 {
        guard !associatedData.isEmpty else { return .zero }
        let a = [UInt8](associatedData)
        var sum = Block128.zero
        var offset = Block128.zero

        let fullBlocks = a.count / 16
        var fullInputs: [Block128] = []
        fullInputs.reserveCapacity(fullBlocks)
        for i in 1 ... max(fullBlocks, 1) where fullBlocks > 0 {
            offset ^= l[i.trailingZeroBitCount]
            fullInputs.append(Block128(a[(i - 1) * 16 ..< i * 16]) ^ offset)
        }
        for encrypted in Self.transform(encryptor, fullInputs) {
            sum ^= encrypted
        }

        let remainder = a.count % 16
        if remainder > 0 {
            offset ^= lStar
            var padded = [UInt8](repeating: 0, count: 16)
            for i in 0 ..< remainder { padded[i] = a[fullBlocks * 16 + i] }
            padded[remainder] = 0x80
            sum ^= encrypt(Block128(padded[...]) ^ offset)
        }
        return sum
    }

    // MARK: - RFC 7253 offset schedule

    /// Offset_0 for a 96-bit nonce and 128-bit tag: the top 7 bits encode
    /// TAGLEN·8 mod 128 = 0, a 1-bit marker precedes the nonce, and the
    /// bottom 6 bits index into the 24-byte "stretch".
    private func initialOffset(nonce: [UInt8]) -> Block128 {
        precondition(nonce.count == 12)
        var block = [UInt8](repeating: 0, count: 16)
        block[3] = 0x01
        for i in 0 ..< 12 { block[4 + i] = nonce[i] }
        let bottom = Int(block[15] & 0x3F)
        block[15] &= 0xC0

        let ktop = encrypt(Block128(block[...])).bytes
        var stretch = ktop
        for i in 0 ..< 8 { stretch.append(ktop[i] ^ ktop[i + 1]) }

        let byteShift = bottom / 8
        let bitShift = bottom % 8
        var offset = [UInt8](repeating: 0, count: 16)
        for i in 0 ..< 16 {
            if bitShift == 0 {
                offset[i] = stretch[i + byteShift]
            } else {
                offset[i] = stretch[i + byteShift] << bitShift
                    | stretch[i + byteShift + 1] >> (8 - bitShift)
            }
        }
        return Block128(offset[...])
    }

    // MARK: - AES block primitive

    private func encrypt(_ block: Block128) -> Block128 { Self.transform(encryptor, block) }
    private func decrypt(_ block: Block128) -> Block128 { Self.transform(decryptor, block) }

    private static func transform(_ cryptor: CCCryptorRef, _ block: Block128) -> Block128 {
        transform(cryptor, [block])[0]
    }

    /// Transform a contiguous full-block body in one CommonCrypto update.
    private static func transform(
        _ cryptor: CCCryptorRef,
        input: UnsafeRawBufferPointer,
        output: UnsafeMutableRawBufferPointer
    ) {
        guard !input.isEmpty else { return }
        var moved = 0
        let status = CCCryptorUpdate(
            cryptor,
            input.baseAddress,
            input.count,
            output.baseAddress,
            output.count,
            &moved
        )
        precondition(
            status == kCCSuccess && moved == input.count,
            "AES-ECB block transform failed"
        )
    }

    /// Fixed-size adapter for scalar AES operations and associated-data HASH.
    private static func transform(
        _ cryptor: CCCryptorRef,
        _ blocks: [Block128]
    ) -> [Block128] {
        guard !blocks.isEmpty else { return [] }
        var input: [UInt8] = []
        input.reserveCapacity(blocks.count * 16)
        for block in blocks { block.appendBytes(to: &input) }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let outputCapacity = output.count
        let status = CCCryptorUpdate(
            cryptor,
            &input,
            input.count,
            &output,
            outputCapacity,
            &moved
        )
        precondition(
            status == kCCSuccess && moved == outputCapacity,
            "AES-ECB block transform failed"
        )
        var result: [Block128] = []
        result.reserveCapacity(blocks.count)
        for offset in stride(from: 0, to: output.count, by: 16) {
            result.append(Block128(output[offset ..< offset + 16]))
        }
        return result
    }
}

/// mosh's printable session key: 22 base64 characters (128 bits, the
/// trailing `==` implied), as printed on the `MOSH CONNECT` line.
struct MoshKey: Equatable {
    let data: Data

    init?(base64 string: String) {
        guard string.count == 22,
              let decoded = Data(base64Encoded: string + "=="),
              decoded.count == 16,
              // Reject non-canonical trailing bits, like mosh's Base64Key.
              decoded.base64EncodedString().hasPrefix(string)
        else { return nil }
        data = decoded
    }
}
