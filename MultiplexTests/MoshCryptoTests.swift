import XCTest
@testable import Multiplex

final class MoshCryptoTests: XCTestCase {
    // MARK: - RFC 7253 Appendix A (AEAD_AES_128_OCB_TAGLEN128)

    func testRFC7253SampleVectors() throws {
        let aead = try MoshAEAD(key: Data(hex: "000102030405060708090A0B0C0D0E0F"))
        // (nonce, associated data, plaintext, ciphertext||tag)
        let vectors: [(String, String, String, String)] = [
            ("BBAA99887766554433221100", "", "",
             "785407BFFFC8AD9EDCC5520AC9111EE6"),
            ("BBAA99887766554433221101", "0001020304050607", "0001020304050607",
             "6820B3657B6F615A5725BDA0D3B4EB3A257C9AF1F8F03009"),
            ("BBAA99887766554433221102", "0001020304050607", "",
             "81017F8203F081277152FADE694A0A00"),
            // The 2.5-block vector — the shape mosh datagrams actually take
            // (multi-block plaintext, no associated data).
            ("BBAA9988776655443322110F", "",
             "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F2021222324252627",
             "4412923493C57D5DE0D700F753CCE0D1D2D95060122E9F15A5DDBFC5787E50B5CC55EE507BCB084E479AD363AC366B95A98CA5F3000B1479"),
        ]
        for (n, a, p, c) in vectors {
            let nonce = [UInt8](Data(hex: n))
            let sealed = aead.seal(Data(hex: p), nonce: nonce, associatedData: Data(hex: a))
            XCTAssertEqual(sealed, Data(hex: c), "seal mismatch for nonce \(n)")
            let opened = aead.open(Data(hex: c), nonce: nonce, associatedData: Data(hex: a))
            XCTAssertEqual(opened, Data(hex: p), "open mismatch for nonce \(n)")
        }
    }

    /// The composite iteration vector: every plaintext/AD length 0–127,
    /// with and without AD. One expected value covers the whole algorithm.
    func testRFC7253CompositeIteration() throws {
        var key = Data(repeating: 0, count: 15)
        key.append(0x80) // num2str(TAGLEN, 8)
        let aead = try MoshAEAD(key: key)

        func nonce(_ value: Int) -> [UInt8] {
            var n = [UInt8](repeating: 0, count: 12)
            n[11] = UInt8(value & 0xFF)
            n[10] = UInt8((value >> 8) & 0xFF)
            return n
        }

        var c = Data()
        for i in 0 ... 127 {
            let s = Data(repeating: 0, count: i)
            c += aead.seal(s, nonce: nonce(3 * i + 1), associatedData: s)
            c += aead.seal(s, nonce: nonce(3 * i + 2))
            c += aead.seal(Data(), nonce: nonce(3 * i + 3), associatedData: s)
        }
        let output = aead.seal(Data(), nonce: nonce(385), associatedData: c)
        XCTAssertEqual(output, Data(hex: "67E944D23256C5E0B6C61FA22FDF1EA2"))
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let aead = try MoshAEAD(key: Data(hex: "000102030405060708090A0B0C0D0E0F"))
        let nonce = [UInt8](Data(hex: "BBAA99887766554433221100"))
        var sealed = aead.seal(Data("attack at dawn".utf8), nonce: nonce)

        var flipped = sealed
        flipped[0] ^= 0x01
        XCTAssertNil(aead.open(flipped, nonce: nonce))

        // Wrong nonce fails too.
        var otherNonce = nonce
        otherNonce[11] ^= 0x01
        XCTAssertNil(aead.open(sealed, nonce: otherNonce))

        // Truncated below tag length is rejected outright.
        sealed.removeLast(sealed.count - 8)
        XCTAssertNil(aead.open(sealed, nonce: nonce))
    }

    // MARK: - MoshKey

    func testMoshKeyParsesServerOutput() {
        // A key printed by a real mosh-server 1.4.0 run.
        let key = MoshKey(base64: "bmCuIRYJHSUF4dcm/qJt2w")
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.data.count, 16)
    }

    func testMoshKeyRejectsMalformedKeys() {
        XCTAssertNil(MoshKey(base64: "short"))
        XCTAssertNil(MoshKey(base64: "bmCuIRYJHSUF4dcm/qJt2w==")) // padding included
        XCTAssertNil(MoshKey(base64: "bmCuIRYJHSUF4dcm/qJt2!")) // bad alphabet
        // Non-canonical: nonzero bits past the 128th (mosh rejects these).
        XCTAssertNil(MoshKey(base64: "bmCuIRYJHSUF4dcm/qJt2x"))
    }
}
