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

    /// Per-transport Compression workspaces. Apple's one-shot buffer APIs
    /// allocate these internally when passed `nil`; keeping one context on each
    /// transport engine avoids that malloc/free pair on every datagram without
    /// sharing mutable codec storage between sessions.
    final class Context {
        private var encodeScratch: UnsafeMutableRawPointer?
        private var decodeScratch: UnsafeMutableRawPointer?

        deinit {
            encodeScratch?.deallocate()
            decodeScratch?.deallocate()
        }

        func compress(_ plain: Data) -> Data {
            MoshZlib.compress(plain, scratch: encodeScratchBuffer())
        }

        func decompress(
            _ compressed: Data,
            maxSize: Int = MoshZlib.maxDecompressedSize
        ) throws -> Data {
            try MoshZlib.decompress(
                compressed,
                maxSize: maxSize,
                scratch: decodeScratchBuffer()
            )
        }

        private func encodeScratchBuffer() -> UnsafeMutableRawPointer {
            if let encodeScratch { return encodeScratch }
            let size = compression_encode_scratch_buffer_size(COMPRESSION_ZLIB)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            encodeScratch = buffer
            return buffer
        }

        private func decodeScratchBuffer() -> UnsafeMutableRawPointer {
            if let decodeScratch { return decodeScratch }
            let size = compression_decode_scratch_buffer_size(COMPRESSION_ZLIB)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            decodeScratch = buffer
            return buffer
        }
    }

    /// Decompressed instructions are screen diffs; a full repaint of a huge
    /// terminal is tens of KB. Anything past this bound is hostile input.
    /// 4 MiB mirrors mosh's own Compressor::BUFFER_SIZE DoS limit.
    static let maxDecompressedSize = 2048 * 2048

    static func compress(_ plain: Data) -> Data {
        compress(plain, scratch: nil)
    }

    private static func compress(
        _ plain: Data,
        scratch: UnsafeMutableRawPointer?
    ) -> Data {
        var out = Data([0x78, 0x9C]) // deflate, 32K window, default level
        out.append(deflate(plain, scratch: scratch))
        var adler = adler32(plain).bigEndian
        withUnsafeBytes(of: &adler) { out.append(contentsOf: $0) }
        return out
    }

    static func decompress(_ compressed: Data, maxSize: Int = maxDecompressedSize) throws -> Data {
        try decompress(compressed, maxSize: maxSize, scratch: nil)
    }

    private static func decompress(
        _ compressed: Data,
        maxSize: Int,
        scratch: UnsafeMutableRawPointer?
    ) throws -> Data {
        let start = compressed.startIndex
        // Header: deflate method, header checksum multiple of 31, no preset
        // dictionary (mosh never sets one).
        guard compressed.count >= 6 else { throw Failure.corrupt }
        let flagsIndex = compressed.index(after: start)
        let method = compressed[start]
        let flags = compressed[flagsIndex]
        guard method & 0x0F == 8,
              (Int(method) << 8 | Int(flags)) % 31 == 0,
              flags & 0x20 == 0
        else { throw Failure.corrupt }

        let trailerStart = compressed.index(compressed.endIndex, offsetBy: -4)
        let rawStart = compressed.index(start, offsetBy: 2)
        let raw = compressed[rawStart ..< trailerStart]
        let expected = compressed[trailerStart...].reduce(UInt32(0)) {
            $0 << 8 | UInt32($1)
        }

        let plain = try inflate(raw, maxSize: maxSize, scratch: scratch)
        guard adler32(plain) == expected else { throw Failure.checksumMismatch }
        return plain
    }

    // MARK: - Raw DEFLATE via Compression

    private static func deflate(
        _ plain: Data,
        scratch: UnsafeMutableRawPointer?
    ) -> Data {
        // An empty deflate stream is one fixed-Huffman final block.
        guard !plain.isEmpty else { return Data([0x03, 0x00]) }
        let capacity = plain.count + plain.count / 2 + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            plain.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, plain.count,
                    scratch, COMPRESSION_ZLIB
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
        repeat {
            let chunk = min(65535, plain.count - offset)
            let final: UInt8 = offset + chunk >= plain.count ? 1 : 0
            out.append(final) // BTYPE=00 stored, BFINAL in bit 0
            out.append(UInt8(chunk & 0xFF))
            out.append(UInt8(chunk >> 8))
            out.append(UInt8(~chunk & 0xFF))
            out.append(UInt8((~chunk >> 8) & 0xFF))
            let start = plain.index(plain.startIndex, offsetBy: offset)
            let end = plain.index(start, offsetBy: chunk)
            out.append(contentsOf: plain[start ..< end])
            offset += chunk
        } while offset < plain.count
        return out
    }

    private static func inflate(
        _ raw: Data,
        maxSize: Int,
        scratch: UnsafeMutableRawPointer?
    ) throws -> Data {
        guard !raw.isEmpty else { throw Failure.corrupt }
        // Terminal repaints contain long repeated runs and routinely exceed an
        // 8x ratio. A 16 KiB / 32x first pass covers those common diffs without
        // approaching the 4 MiB hostile-input bound. A filled buffer is
        // indistinguishable from truncation, so retry until a spare byte
        // survives.
        var capacity = max(16_384, raw.count * 32)
        while true {
            capacity = min(capacity, maxSize + 1)
            let out = [UInt8](unsafeUninitializedCapacity: capacity) { dst, initializedCount in
                let written = raw.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                        scratch, COMPRESSION_ZLIB
                    )
                }
                initializedCount = written
            }
            let written = out.count
            if written == capacity {
                guard capacity < maxSize + 1 else { throw Failure.tooLarge }
                capacity *= 4
                continue
            }
            // written == 0 is either an empty stream or a decode error; the
            // adler32 check in decompress() is what tells them apart.
            return Data(out)
        }
    }

    // MARK: - adler32 (RFC 1950)

    static func adler32(_ data: Data) -> UInt32 {
        let modulus: UInt32 = 65521
        let nmax = 5552
        var a: UInt32 = 1
        var b: UInt32 = 0

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                // NMAX is the largest run before 32-bit overflow with
                // worst-case bytes; defer both modulos until the batch ends.
                let end = min(index + nmax, bytes.count)
                while index < end {
                    a &+= UInt32(bytes[index])
                    b &+= a
                    index += 1
                }
                a %= modulus
                b %= modulus
            }
        }
        return b << 16 | a
    }
}
