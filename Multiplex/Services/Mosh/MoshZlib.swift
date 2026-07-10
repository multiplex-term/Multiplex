import Compression
import Foundation

/// zlib-wrapped DEFLATE (RFC 1950), the framing zlib's `compress()` emits —
/// mosh wraps every transport instruction in it. Apple's Compression
/// framework speaks raw DEFLATE only (its `COMPRESSION_ZLIB` constant is
/// headerless), so the 2-byte header and the adler32 trailer live here.
/// Pure — exercised directly by unit tests.
enum MoshZlib {
    enum Failure: Error, Equatable {
        case corrupt
        case checksumMismatch
        case tooLarge
    }

    /// Decompressed instructions are screen diffs; a full repaint of a huge
    /// terminal is tens of KB. Anything past this bound is hostile input.
    /// 4 MiB mirrors mosh's own Compressor::BUFFER_SIZE DoS limit.
    static let maxDecompressedSize = 2048 * 2048

    static func compress(_ plain: Data) -> Data {
        var out = Data([0x78, 0x9C]) // deflate, 32K window, default level
        out.append(deflate(plain))
        var adler = adler32(plain).bigEndian
        withUnsafeBytes(of: &adler) { out.append(contentsOf: $0) }
        return out
    }

    static func decompress(_ compressed: Data, maxSize: Int = maxDecompressedSize) throws -> Data {
        let bytes = [UInt8](compressed)
        // Header: deflate method, header checksum multiple of 31, no preset
        // dictionary (mosh never sets one).
        guard bytes.count >= 6,
              bytes[0] & 0x0F == 8,
              (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0,
              bytes[1] & 0x20 == 0
        else { throw Failure.corrupt }

        let raw = Data(bytes[2 ..< bytes.count - 4])
        let expected = bytes[(bytes.count - 4)...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

        let plain = try inflate(raw, maxSize: maxSize)
        guard adler32(plain) == expected else { throw Failure.checksumMismatch }
        return plain
    }

    // MARK: - Raw DEFLATE via Compression

    private static func deflate(_ plain: Data) -> Data {
        // An empty deflate stream is one fixed-Huffman final block.
        guard !plain.isEmpty else { return Data([0x03, 0x00]) }
        let capacity = plain.count + plain.count / 2 + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            plain.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, plain.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else {
            // Incompressible input can overflow the estimate: fall back to
            // stored blocks, which DEFLATE guarantees fit in n + n/65535*5 + 5.
            return storedDeflate(plain)
        }
        out.removeSubrange(written...)
        return out
    }

    /// DEFLATE "stored" (uncompressed) blocks — the always-valid fallback.
    private static func storedDeflate(_ plain: Data) -> Data {
        var out = Data()
        var offset = 0
        let bytes = [UInt8](plain)
        repeat {
            let chunk = min(65535, bytes.count - offset)
            let final: UInt8 = offset + chunk >= bytes.count ? 1 : 0
            out.append(final) // BTYPE=00 stored, BFINAL in bit 0
            out.append(UInt8(chunk & 0xFF))
            out.append(UInt8(chunk >> 8))
            out.append(UInt8(~chunk & 0xFF))
            out.append(UInt8((~chunk >> 8) & 0xFF))
            out.append(contentsOf: bytes[offset ..< offset + chunk])
            offset += chunk
        } while offset < bytes.count
        return out
    }

    private static func inflate(_ raw: Data, maxSize: Int) throws -> Data {
        guard !raw.isEmpty else { throw Failure.corrupt }
        // Typical packets inflate to a few KB; grow on demand rather than
        // zero-filling the worst-case bound for every datagram. A filled
        // buffer is indistinguishable from truncation, so retry one size up
        // until a spare byte survives.
        var capacity = max(4096, raw.count * 8)
        while true {
            capacity = min(capacity, maxSize + 1)
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written == capacity {
                guard capacity < maxSize + 1 else { throw Failure.tooLarge }
                capacity *= 4
                continue
            }
            // written == 0 is either an empty stream or a decode error; the
            // adler32 check in decompress() is what tells them apart.
            out.removeSubrange(written...)
            return out
        }
    }

    // MARK: - adler32 (RFC 1950)

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var pending = 0
        for byte in data {
            a &+= UInt32(byte)
            b &+= a
            pending += 1
            // Largest run before 32-bit overflow with worst-case bytes.
            if pending == 5552 {
                a %= 65521
                b %= 65521
                pending = 0
            }
        }
        return (b % 65521) << 16 | (a % 65521)
    }
}
