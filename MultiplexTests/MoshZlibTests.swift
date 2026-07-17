import XCTest
@testable import Multiplex

/// Goldens generated with CPython's zlib (`zlib.compress`, level 6) — the
/// same library mosh links, so decoding these proves interop with what
/// mosh-server actually sends.
final class MoshZlibTests: XCTestCase {
    func testDecompressesLibZlibOutput() throws {
        let golden = Data(hex: "789ccb48cdc9c957c8cd2fce0000158403ec")
        XCTAssertEqual(try MoshZlib.decompress(golden), Data("hello mosh".utf8))
    }

    func testDecompressesEmptyStream() throws {
        let golden = Data(hex: "789c030000000001")
        XCTAssertEqual(try MoshZlib.decompress(golden), Data())
    }

    func testDecompressesRepetitiveAndBinaryPayloads() throws {
        let aThousand = Data(hex: "789c4b4c1c05a360140c770000f9d87af8")
        XCTAssertEqual(try MoshZlib.decompress(aThousand), Data(repeating: 0x61, count: 1000))

        let allBytes = Data(
            hex: "789c010001fffe" + (0 ..< 256).map { String(format: "%02x", $0) }.joined() + "adf67f81"
        )
        XCTAssertEqual(try MoshZlib.decompress(allBytes), Data((0 ..< 256).map(UInt8.init)))
    }

    func testRoundTrip() throws {
        let cases: [Data] = [
            Data(),
            Data("x".utf8),
            Data("the quick brown fox".utf8),
            Data((0 ..< 100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }),
        ]
        for plain in cases {
            XCTAssertEqual(try MoshZlib.decompress(MoshZlib.compress(plain)), plain)
        }
    }

    func testReusableContextMatchesStaticAPI() throws {
        let context = MoshZlib.Context()
        let cases: [Data] = [
            Data(),
            Data("hello mosh".utf8),
            Data(repeating: 0x61, count: 100_000),
        ]
        for plain in cases {
            let compressed = context.compress(plain)
            XCTAssertEqual(compressed, MoshZlib.compress(plain))
            XCTAssertEqual(try context.decompress(compressed), plain)
        }
    }

    func testAdler32() {
        XCTAssertEqual(MoshZlib.adler32(Data()), 1)
        XCTAssertEqual(MoshZlib.adler32(Data("hello mosh".utf8)), 0x1584_03EC)
        XCTAssertEqual(MoshZlib.adler32(Data(repeating: 0x61, count: 1000)), 0xF9D8_7AF8)
        XCTAssertEqual(MoshZlib.adler32(Data((0 ..< 256).map(UInt8.init))), 0xADF6_7F81)
    }

    func testRejectsCorruptHeaderAndChecksum() {
        XCTAssertThrowsError(try MoshZlib.decompress(Data(hex: "aabbccddeeff")))
        // Valid stream, last checksum byte flipped.
        XCTAssertThrowsError(try MoshZlib.decompress(Data(hex: "789ccb48cdc9c957c8cd2fce0000158403ed")))
    }

    func testDecompressBoundIsEnforced() {
        let big = MoshZlib.compress(Data(repeating: 0, count: 100_000))
        XCTAssertThrowsError(try MoshZlib.decompress(big, maxSize: 1024)) { error in
            XCTAssertEqual(error as? MoshZlib.Failure, .tooLarge)
        }
    }
}

extension Data {
    /// Test helper: build Data from a hex string.
    init(hex: String) {
        self.init()
        var iterator = hex.unicodeScalars.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            append(UInt8(String(high) + String(low), radix: 16)!)
        }
    }
}
