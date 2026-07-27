import CryptoKit
import Foundation
import Testing

@testable import Multiplex

/// Cross-implementation conformance: every expectation here is a byte string
/// produced by the Rust CLI (`cargo run --example gen_vectors`) and vendored
/// as Fixtures/bind-v1.json. If the Swift client and `mpx` ever disagree
/// about the wire, these fail instead of a bind failing in the field.
struct BindProtocolTests {
    // MARK: Vectors

    struct Vectors {
        let root: [String: Any]

        init() throws {
            let url = try #require(
                Bundle(for: BindVectorAnchor.self)
                    .url(forResource: "bind-v1", withExtension: "json"),
                "bind-v1.json must ship as a test resource"
            )
            let data = try Data(contentsOf: url)
            root = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
        }

        func section(_ name: String) throws -> [String: Any] {
            try #require(root[name] as? [String: Any], "missing section \(name)")
        }

        func string(_ section: String, _ key: String) throws -> String {
            try #require(try self.section(section)[key] as? String, "missing \(section).\(key)")
        }

        /// `Data(hex:)` is the shared test helper defined in MoshZlibTests.
        func data(_ section: String, _ key: String) throws -> Data {
            Data(hex: try string(section, key))
        }
    }

    /// Anchor for `Bundle(for:)` — the fixture lives in the test bundle.
    final class BindVectorAnchor {}

    // MARK: Payload

    @Test func payloadDecodesTheCLIsBytes() throws {
        let vectors = try Vectors()
        let url = try vectors.string("payload", "url")
        let payload = try #require(BindPayload(string: url))
        let record = try vectors.section("record")

        #expect(payload.name == record["name"] as? String)
        #expect(payload.addrs == record["addrs"] as? [String])
        #expect(payload.port == 41337)
        #expect(payload.sshUser == record["ssh_user"] as? String)
        #expect(payload.sshPort == 2222)
        #expect(payload.hostkeys == record["hostkeys"] as? [String])
        let expectedSpub = try vectors.data("derived", "spub_hex")
        #expect(payload.spub == expectedSpub)
        let expectedToken = try vectors.data("inputs", "token_hex")
        #expect(payload.token == expectedToken)
        #expect(payload.key == nil)
        #expect(!payload.isOffline)
    }

    @Test func offlinePayloadCarriesItsKey() throws {
        let vectors = try Vectors()
        let payload = try #require(
            BindPayload(string: try vectors.string("payload_offline", "url"))
        )
        #expect(payload.isOffline)
        #expect(payload.key?.contains("OPENSSH PRIVATE KEY") == true)
        #expect(payload.port == 0)
    }

    @Test func payloadRejectsWrongSchemeVersionAndGarbage() throws {
        let vectors = try Vectors()
        let good = try vectors.string("payload", "url")
        let encoded = try #require(good.split(separator: "=").last).description

        #expect(BindPayload(string: "https://example.com/x") == nil)
        #expect(BindPayload(string: "multiplex://open?host=devbox&action=shell") == nil)
        #expect(BindPayload(string: "multiplex://bind?v=2&d=\(encoded)") == nil)
        #expect(BindPayload(string: "multiplex://bind?v=1&d=%%%") == nil)
        #expect(BindPayload(string: "") == nil)
    }

    /// The deck's own scheme must never be re-parsed as a bind offer, and a
    /// bind URL must never resolve to an action that launches anything.
    @Test func bindAndActionURLsStayDisjoint() throws {
        let vectors = try Vectors()
        let bindURL = try #require(URL(string: try vectors.string("payload", "url")))
        #expect(ExternalActionURL.action(from: bindURL) == nil)

        let actionURL = ExternalActionURL.url(
            for: .openShell(host: .named("devbox"), sessionName: nil)
        )
        #expect(BindPayload(url: actionURL) == nil)
    }

    // MARK: Key schedule

    @Test func channelMatchesTheCLIsKeySchedule() throws {
        let vectors = try Vectors()
        let epub = try vectors.data("derived", "epub_hex")
        let spub = try vectors.data("derived", "spub_hex")
        let shared = try vectors.data("derived", "shared_hex")

        // The app seals HELLO/ENROLL and opens OFFER/DONE; running both
        // halves against mpx's recorded frames proves the whole schedule.
        var channel = BindChannel(shared: shared, epub: epub, spub: spub)
        let hello = try vectors.data("frames", "hello_sealed_hex")
        #expect(channel.sealC2S(BindCBOR.encode(.map([
            ("proof", .bytes(try vectors.data("inputs", "token_hex"))),
        ]))) == hello)

        let offer = try #require(
            BindOffer(value: try BindCBOR.decode(
                channel.openS2C(try vectors.data("frames", "offer_sealed_hex"))
            ))
        )
        #expect(offer.name == "devbox")
        #expect(offer.sshUser == "jhen")
        #expect(offer.sshPort == 2222)
        #expect(offer.addrs == ["192.168.1.24", "10.0.5.2"])
        #expect(offer.hostkeys.first?.hasPrefix("ssh-ed25519 SHA256:") == true)

        let enroll = channel.sealC2S(BindCBOR.encode(.map([
            ("pubkey", .text(try vectors.string("inputs", "enroll_pubkey"))),
            ("device", .text(try vectors.string("inputs", "device"))),
        ])))
        let expectedEnrollSealed = try vectors.data("frames", "enroll_sealed_hex")
        #expect(enroll == expectedEnrollSealed)

        let done = try #require(
            BindDone(value: try BindCBOR.decode(
                channel.openS2C(try vectors.data("frames", "done_sealed_hex"))
            ))
        )
        #expect(done.ok)
        #expect(done.comment == "multiplex:bind:9f3a1c2e:jhen-s-vision-pro")
    }

    @Test func x25519AgreementMatchesTheCLI() throws {
        let vectors = try Vectors()
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try vectors.data("inputs", "eph_seed_hex")
        )
        let expectedEpub = try vectors.data("derived", "epub_hex")
        #expect(ephemeral.publicKey.rawRepresentation == expectedEpub)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: try vectors.data("derived", "spub_hex")
            )
        )
        let expectedShared = try vectors.data("derived", "shared_hex")
        #expect(shared.withUnsafeBytes { Data($0) } == expectedShared)
    }

    @Test func pinProofMatchesTheCLI() throws {
        let vectors = try Vectors()
        let proof = BindChannel.pinProof(
            pin: try vectors.string("inputs", "pin"),
            epub: try vectors.data("derived", "epub_hex"),
            spub: try vectors.data("derived", "spub_hex")
        )
        let expectedPinProof = try vectors.data("derived", "pin_proof_hex")
        #expect(proof == expectedPinProof)
    }

    /// The proof is bound to both public keys, so it can only ever
    /// authenticate the connection it was made for.
    @Test func pinProofIsTranscriptBound() {
        let base = BindChannel.pinProof(
            pin: "482163", epub: Data(repeating: 1, count: 32), spub: Data(repeating: 2, count: 32))
        let otherServer = BindChannel.pinProof(
            pin: "482163", epub: Data(repeating: 1, count: 32), spub: Data(repeating: 3, count: 32))
        let otherPIN = BindChannel.pinProof(
            pin: "482164", epub: Data(repeating: 1, count: 32), spub: Data(repeating: 2, count: 32))
        #expect(base != otherServer)
        #expect(base != otherPIN)
    }

    @Test func introBodyMatchesTheCLIsExpectation() throws {
        let vectors = try Vectors()
        var session = try BindClientSession(
            spub: try vectors.data("derived", "spub_hex"),
            credential: .token(try vectors.data("inputs", "token_hex")),
            ephemeralSeed: try vectors.data("inputs", "eph_seed_hex")
        )
        let expectedIntro = try vectors.data("frames", "intro_hex")
        #expect(session.introBody() == expectedIntro)
        let expectedHelloSealed = try vectors.data("frames", "hello_sealed_hex")
        #expect(session.helloBody() == expectedHelloSealed)
    }

    /// A tampered or wrong-key frame must fail closed, not decode to junk.
    @Test func sealedFramesFailClosed() throws {
        let vectors = try Vectors()
        var channel = BindChannel(
            shared: try vectors.data("derived", "shared_hex"),
            epub: try vectors.data("derived", "epub_hex"),
            spub: try vectors.data("derived", "spub_hex")
        )
        _ = channel.sealC2S(Data())  // advance c2s past HELLO like a real run
        var tampered = try vectors.data("frames", "offer_sealed_hex")
        tampered[tampered.startIndex] ^= 0x01
        #expect(throws: (any Error).self) { try channel.openS2C(tampered) }
    }

    // MARK: Announcement (Bonjour TXT)

    @Test func announcementParsesTheCLIsTXT() throws {
        let vectors = try Vectors()
        let spub = try vectors.data("derived", "spub_hex")
        let announcement = try #require(BindAnnouncement(txt: [
            "v": "1",
            "name": "devbox",
            "spub": spub.base64URLNoPadString,
            "user": "jhen",
            "sshport": "2222",
            "fp": "ssh-ed25519 SHA256:abc",
        ]))
        #expect(announcement.spub == spub)
        #expect(announcement.name == "devbox")
        #expect(announcement.user == "jhen")
        #expect(announcement.sshPort == 2222)
        #expect(announcement.id == spub.base64EncodedString())
    }

    @Test func announcementRejectsIncompleteRecords() {
        #expect(BindAnnouncement(txt: [:]) == nil)
        #expect(BindAnnouncement(txt: ["v": "1", "name": "devbox"]) == nil)
        // Wrong-length session key: not a usable offer.
        #expect(BindAnnouncement(txt: [
            "v": "1", "name": "devbox",
            "spub": Data(repeating: 9, count: 16).base64URLNoPadString,
        ]) == nil)
        // A future version is not silently treated as v1.
        #expect(BindAnnouncement(txt: [
            "v": "2", "name": "devbox",
            "spub": Data(repeating: 9, count: 32).base64URLNoPadString,
        ]) == nil)
    }

    @Test func announcementDefaultsPortWhenAbsent() throws {
        let announcement = try #require(BindAnnouncement(txt: [
            "v": "1", "name": "devbox",
            "spub": Data(repeating: 9, count: 32).base64URLNoPadString,
        ]))
        #expect(announcement.sshPort == 22)
        #expect(announcement.fingerprint == nil)
    }

    // MARK: CBOR

    @Test func cborRoundTripsEveryShapeTheWireUses() throws {
        let value = BindCBOR.Value.map([
            ("v", .uint(1)),
            ("small", .uint(23)),
            ("byte", .uint(200)),
            ("wide", .uint(70000)),
            ("huge", .uint(5_000_000_000)),
            ("bytes", .bytes(Data(repeating: 7, count: 40))),
            ("text", .text("π - harness")),
            ("array", .array([.text("a"), .text("b")])),
            ("nested", .map([("ok", .bool(true)), ("no", .bool(false))])),
        ])
        let decoded = try BindCBOR.decode(BindCBOR.encode(value))
        #expect(decoded == value)
        #expect(decoded["huge"]?.uintValue == 5_000_000_000)
        #expect(decoded["nested"]?["ok"]?.boolValue == true)
    }

    @Test func cborRejectsTruncatedInput() throws {
        let encoded = BindCBOR.encode(.map([("bytes", .bytes(Data(repeating: 1, count: 32)))]))
        #expect(throws: (any Error).self) { try BindCBOR.decode(encoded.dropLast(4)) }
    }
}

// MARK: - Helpers

extension Data {
    var base64URLNoPadString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
