import Compression
import CryptoKit
import XCTest
@testable import Multiplex

final class RNNoiseWeightsTests: XCTestCase {
    // MARK: Blob header

    func testHeaderMatchesWriteWeightsLayout() {
        let header = RNNoiseWeightBlob.header(name: "conv1_bias", type: .float, byteCount: 500)
        XCTAssertEqual(header.count, 64)
        XCTAssertEqual(Array(header[0..<4]), Array("DNNw".utf8))
        XCTAssertEqual(int32(header, at: 4), 0)
        XCTAssertEqual(int32(header, at: 8), 0)
        XCTAssertEqual(int32(header, at: 12), 500)
        XCTAssertEqual(int32(header, at: 16), 512)
        XCTAssertEqual(Array(header[20..<30]), Array("conv1_bias".utf8))
        XCTAssertTrue(header[30...].allSatisfy { $0 == 0 })
    }

    func testHeaderTruncatesLongNamesLikeStrncpyWithAForcedTerminator() {
        let name = String(repeating: "n", count: 50)
        let header = RNNoiseWeightBlob.header(name: name, type: .int8, byteCount: 1)
        XCTAssertEqual(int32(header, at: 8), 3)
        XCTAssertEqual(Array(header[20..<63]), Array(repeating: UInt8(ascii: "n"), count: 43))
        XCTAssertEqual(header[63], 0)
    }

    func testBlockSizeRoundsUpToSixtyFourBytes() {
        XCTAssertEqual(RNNoiseWeightBlob.blockSize(for: 0), 0)
        XCTAssertEqual(RNNoiseWeightBlob.blockSize(for: 1), 64)
        XCTAssertEqual(RNNoiseWeightBlob.blockSize(for: 64), 64)
        XCTAssertEqual(RNNoiseWeightBlob.blockSize(for: 65), 128)
    }

    // MARK: C source

    func testParserEmitsEveryArrayInFileOrderAndIgnoresTheRest() throws {
        let blob = try parse(Self.source)
        var expected = RNNoiseWeightBlob.header(name: "a", type: .float, byteCount: 12)
        expected += bytes(Float(0.5)) + bytes(Float(-1.25)) + bytes(Float(9.382013377035037e-05))
        expected += zeros(52)
        expected += RNNoiseWeightBlob.header(name: "b", type: .int8, byteCount: 4)
        expected += [14, 212, 127, 128] + zeros(60)
        expected += RNNoiseWeightBlob.header(name: "c", type: .int, byteCount: 8)
        expected += bytes(Int32(96)) + bytes(Int32(-7)) + zeros(56)
        XCTAssertEqual(blob, expected)
    }

    func testFloatsRoundThroughDoubleLikeTheCompilerDoes() throws {
        // Just above the midpoint between 1.0 and its successor float, but
        // within half a double ulp of it: as a double it IS the midpoint,
        // which ties to even (1.0); `strtof` alone would round up.
        let literal = "1.00000005960464477625808767"
        XCTAssertNotEqual(strtof(literal, nil), 1.0)
        let blob = try parse("static const float f[1] = {\n    \(literal)\n};\n")
        XCTAssertEqual(Array(blob[64..<68]), bytes(Float(1.0)))
    }

    func testFewerInitializersThanDeclaredZeroFill() throws {
        let blob = try parse("static const float z[4] = {\n    1.0\n};\n")
        XCTAssertEqual(int32(blob, at: 12), 16)
        XCTAssertEqual(Array(blob[64..<80]), bytes(Float(1.0)) + zeros(12))
        XCTAssertEqual(blob.count, 128)
    }

    func testMoreInitializersThanDeclaredThrow() {
        XCTAssertThrowsError(try parse("static const int x[1] = {\n    1, 2\n};\n"))
    }

    func testOutOfRangeInt8Throws() {
        XCTAssertThrowsError(try parse("static const opus_int8 x[1] = {\n    128\n};\n"))
    }

    func testAStaticConstOfAnUnknownTypeThrowsRatherThanBeingSkipped() {
        XCTAssertThrowsError(try parse("static const double x[1] = {\n    1.0\n};\n"))
    }

    func testASourceCutOffInsideAnArrayFailsToFinish() {
        XCTAssertThrowsError(try parse("static const float x[2] = {\n    1.0,"))
    }

    func testOutputDoesNotDependOnChunkBoundaries() throws {
        var parser = RNNoiseWeightsSourceParser()
        var blob: [UInt8] = []
        for byte in Array(Self.source.utf8) {
            try [byte].withUnsafeBytes { try parser.feed($0) }
            parser.drain { blob.append(contentsOf: $0) }
        }
        try parser.finish()
        parser.drain { blob.append(contentsOf: $0) }
        XCTAssertEqual(blob, try parse(Self.source))
        XCTAssertEqual(parser.arrayCount, 3)
    }

    // MARK: Tar

    func testTarReaderNamesEntriesFromGNULongNamesPaxPathsAndThePrefix() throws {
        let longName = "src/" + String(repeating: "deep/", count: 25) + "weights.c"
        var archive: [UInt8] = []
        archive += Self.tarEntry(name: "././@LongLink", type: "L", content: Array(longName.utf8) + [0])
        archive += Self.tarEntry(name: "truncated", content: Array("one".utf8))
        archive += Self.tarEntry(name: "src", type: "5", content: [])
        let record = " path=pax/named.txt\n"
        let paxRecord = "\(record.utf8.count + 2)\(record)"
        archive += Self.tarEntry(name: "PaxHeader", type: "x", content: Array(paxRecord.utf8))
        archive += Self.tarEntry(name: "ignored", content: Array(String(repeating: "x", count: 600).utf8))
        archive += Self.tarEntry(name: "file.txt", content: [], prefix: "dir")
        archive += zeros(1024)

        for chunkSize in [archive.count, 7, 1] {
            var reader = TarStreamReader()
            var entries: [(path: String, content: [UInt8])] = []
            var ends = 0
            for start in stride(from: 0, to: archive.count, by: chunkSize) {
                let chunk = Array(archive[start..<min(start + chunkSize, archive.count)])
                try chunk.withUnsafeBytes { bytes in
                    try reader.feed(bytes) { event in
                        switch event {
                        case .begin(let path): entries.append((path: path, content: []))
                        case .content(let bytes): entries[entries.count - 1].content += bytes
                        case .end: ends += 1
                        }
                    }
                }
            }
            XCTAssertEqual(entries.map(\.path), [longName, "pax/named.txt", "dir/file.txt"])
            XCTAssertEqual(entries.map(\.content.count), [3, 600, 0])
            XCTAssertEqual(entries[0].content, Array("one".utf8))
            XCTAssertEqual(ends, 3)
            XCTAssertTrue(reader.isFinished)
        }
    }

    func testTarReaderRejectsACorruptHeader() {
        var archive = Self.tarEntry(name: "a.c", content: Array("x".utf8))
        archive[0] = UInt8(ascii: "b")
        var reader = TarStreamReader()
        XCTAssertThrowsError(try archive.withUnsafeBytes { try reader.feed($0) { _ in } })
    }

    // MARK: gzip

    func testGzipHeaderLengthCoversExtraNameCommentAndHeaderCRC() throws {
        let plain: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]
        XCTAssertEqual(try plain.withUnsafeBytes { try GzipHeader.length(of: $0) }, 10)

        let named = Self.gzipHeader(name: "rnnoise_data.tar")
        XCTAssertEqual(try named.withUnsafeBytes { try GzipHeader.length(of: $0) }, named.count)
        let short = Array(named.dropLast())
        XCTAssertNil(try short.withUnsafeBytes { try GzipHeader.length(of: $0) })

        // FEXTRA (2-byte length + 3 bytes) + FCOMMENT + FHCRC.
        let everything: [UInt8] = [0x1F, 0x8B, 8, 0x16, 0, 0, 0, 0, 0, 3]
            + [3, 0, 1, 2, 3] + Array("note".utf8) + [0] + [0xAA, 0xBB]
        XCTAssertEqual(try everything.withUnsafeBytes { try GzipHeader.length(of: $0) }, everything.count)

        let notGzip: [UInt8] = [0x50, 0x4B, 3, 4, 0, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try notGzip.withUnsafeBytes { try GzipHeader.length(of: $0) })
    }

    func testInflaterStreamsAGzipFileFedInSmallChunks() throws {
        let original = Array(String(repeating: "static const float a[1] = { 0.5 };\n", count: 400).utf8)
        let file = Self.gzip(original)
        let inflater = try GzipInflater()
        var output: [UInt8] = []
        for start in stride(from: 0, to: file.count, by: 5) {
            let chunk = Array(file[start..<min(start + 5, file.count)])
            try chunk.withUnsafeBytes { bytes in
                try inflater.inflate(bytes) { output.append(contentsOf: $0) }
            }
        }
        XCTAssertEqual(output, original)
        XCTAssertTrue(inflater.isFinished)
    }

    func testConvertReadsOnlyTheSourceEntryOfAGzippedTarball() throws {
        var tar = Self.tarEntry(name: "src/other.c", content: Array("static const float q[1] = {".utf8))
        tar += Self.tarEntry(name: RNNoiseModelSource.sourceEntry, content: Array(Self.source.utf8))
        tar += zeros(1024)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnnoise-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("model.tar.gz")
        let blob = directory.appendingPathComponent("weights.bin")
        try Data(Self.gzip(tar)).write(to: archive)

        let sha256 = try RNNoiseWeightsInstaller.convert(archiveAt: archive, to: blob) { false }
        let expected = try parse(Self.source)
        XCTAssertEqual(try Array(Data(contentsOf: blob)), expected)
        XCTAssertEqual(sha256, RNNoiseWeightsInstaller.hex(SHA256.hash(data: expected)))
    }

    // MARK: Fixtures

    private static let source = """
        #ifdef HAVE_CONFIG_H
        #include "config.h"
        #endif

        #ifndef USE_WEIGHTS_FILE
        #define WEIGHTS_a_DEFINED
        #define WEIGHTS_a_TYPE WEIGHT_TYPE_float
        static const float a[3] = {
            0.5, -1.25, 9.382013377035037e-05
        };
        #endif /* USE_WEIGHTS_FILE */

        #ifndef USE_WEIGHTS_FILE
        #ifndef DISABLE_DEBUG_FLOAT
        static const opus_int8 b[4] = {
            14, -44, 127, -128
        };
        #endif /*DISABLE_DEBUG_FLOAT*/
        #endif /* USE_WEIGHTS_FILE */

        static const int c[2] = {
            96, -7
        };

        #ifndef USE_WEIGHTS_FILE
        const WeightArray rnnoise_arrays[] = {
        #ifdef WEIGHTS_a_DEFINED
            {"a",  WEIGHTS_a_TYPE, sizeof(a), a},
        #endif
            {NULL, 0, 0, NULL}
        };
        #endif /* USE_WEIGHTS_FILE */

        int init_rnnoise(RNNoise *model, const WeightArray *arrays) {
            if (linear_init(&model->conv1, arrays, "conv1_bias", NULL, 195, 128)) return 1;
            return 0;
        }

        """

    private func parse(_ source: String) throws -> [UInt8] {
        var parser = RNNoiseWeightsSourceParser()
        try Array(source.utf8).withUnsafeBytes { try parser.feed($0) }
        try parser.finish()
        var blob: [UInt8] = []
        parser.drain { blob.append(contentsOf: $0) }
        return blob
    }

    private func int32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | Int32($1) }
    }

    private func bytes(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init)
    }

    private func bytes(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    private func zeros(_ count: Int) -> [UInt8] {
        [UInt8](repeating: 0, count: count)
    }

    /// One tar entry: a checksummed 512-byte header — POSIX ustar when a
    /// prefix is given, GNU's magic otherwise — and the padded content.
    private static func tarEntry(
        name: String,
        type: Character = "0",
        content: [UInt8],
        prefix: String? = nil
    ) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) {
            let bytes = Array(text.utf8)
            header.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        put(name, at: 0)
        put("0000644\0", at: 100)
        put(String(format: "%011o\0", content.count), at: 124)
        put(String(type), at: 156)
        if let prefix {
            put("ustar\0" + "00", at: 257)
            put(prefix, at: 345)
        } else {
            put("ustar  \0", at: 257)
        }
        put("        ", at: 148)
        let checksum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o\0 ", checksum), at: 148)
        let padding = (512 - content.count % 512) % 512
        return header + content + [UInt8](repeating: 0, count: padding)
    }

    private static func gzipHeader(name: String) -> [UInt8] {
        [0x1F, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 3] + Array(name.utf8) + [0]
    }

    /// gzip = header + raw DEFLATE (Compression's `COMPRESSION_ZLIB`) + an
    /// 8-byte trailer the inflater never reads.
    private static func gzip(_ bytes: [UInt8]) -> [UInt8] {
        let capacity = bytes.count + 1024
        var deflated = [UInt8](repeating: 0, count: capacity)
        let count = compression_encode_buffer(
            &deflated, capacity, bytes, bytes.count, nil, COMPRESSION_ZLIB
        )
        return gzipHeader(name: "model.tar") + deflated.prefix(count) + [UInt8](repeating: 0xEE, count: 8)
    }
}
