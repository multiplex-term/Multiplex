import Citadel
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
        // Addresses ride as raw bytes and come back as text — that encoding
        // is most of why the QR now fits a terminal.
        #expect(payload.addrs == record["addrs"] as? [String])
        #expect(payload.port == 41337)
        let expectedSpub = try vectors.data("derived", "spub_hex")
        #expect(payload.spub == expectedSpub)
        let expectedToken = try vectors.data("inputs", "token_hex")
        #expect(payload.token == expectedToken)
        // The handshake payload deliberately carries no SSH user and no
        // fingerprints: the sealed OFFER delivers those.
        #expect(payload.offline == nil)
        #expect(!payload.isOffline)
    }

    /// The whole reason for the compact format: this string has to be
    /// drawable as a QR code in a plain terminal. The CBOR format it replaced
    /// was 547 characters and rendered 97 columns wide.
    @Test func handshakePayloadStaysQrSized() throws {
        let vectors = try Vectors()
        let url = try vectors.string("payload", "url")
        #expect(
            url.count <= 120,
            "payload was \(url.count) characters — a QR version 6 at EC level L holds 134"
        )
    }

    @Test func offlinePayloadCarriesItsKeyAsASeed() throws {
        let vectors = try Vectors()
        let payload = try #require(
            BindPayload(string: try vectors.string("payload_offline", "url"))
        )
        #expect(payload.isOffline)
        #expect(payload.port == 0)
        let offline = try #require(payload.offline)
        let expectedSeed = try vectors.data("payload_offline", "seed_hex")
        guard case .seed(let seed) = offline.secret else {
            Issue.record("a plain offline payload must carry a raw seed")
            return
        }
        #expect(seed == expectedSeed)
        #expect(offline.sshUser == "jhen")
        #expect(offline.sshPort == 2222)
        // The digest renders as OpenSSH's display form, so a pin from an
        // offline payload is indistinguishable from one the OFFER delivered.
        let digest = try vectors.data("payload_offline", "hostkey_sha256_hex")
        #expect(offline.pinnedHostKey
            == "ssh-ed25519 SHA256:" + digest.base64EncodedString()
                .replacingOccurrences(of: "=", with: ""))
        // And the seed rebuilds a usable key.
        let key = try #require(BindSSHKey(seed: seed))
        #expect(key.publicLine.hasPrefix("ssh-ed25519 "))
        #expect(key.privateOpenSSH.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
    }

    /// A passphrase-sealed offline payload (flag bit 1) carries the CLI's
    /// openssh-key-v1 container verbatim; the app only armors it. The
    /// decisive check runs the container through Citadel — the parser that
    /// will open it at connect time — with the vector passphrase, and the
    /// key inside must be the very key the plain vector spells as a seed.
    @Test func sealedOfflinePayloadOpensWithTheVectorPassphrase() throws {
        let vectors = try Vectors()
        let payload = try #require(
            BindPayload(string: try vectors.string("payload_offline_encrypted", "url"))
        )
        let offline = try #require(payload.offline)
        guard case .encryptedKey(let container) = offline.secret else {
            Issue.record("bit 1 must decode as a sealed container")
            return
        }
        let expectedContainer = try vectors.data("payload_offline_encrypted", "container_hex")
        #expect(container == expectedContainer)

        let armored = BindSSHKey.armor(container: container)
        #expect(OpenSSHPrivateKeyEnvelope.encryption(in: armored) == .encrypted)

        let passphrase = try vectors.string("payload_offline_encrypted", "passphrase")
        let key = try Curve25519.Signing.PrivateKey(
            sshEd25519: armored,
            decryptionKey: Data(passphrase.utf8)
        )
        let publicLine = try vectors.string("payload_offline_encrypted", "public_openssh")
        #expect(BindSSHKey.make(from: key).publicLine == publicLine)
        // Same key both ways: the sealed container and the plain seed vector
        // describe one identity.
        let seed = try vectors.data("payload_offline", "seed_hex")
        #expect(BindSSHKey(seed: seed)?.publicLine == publicLine)

        #expect(throws: (any Error).self) {
            try Curve25519.Signing.PrivateKey(
                sshEd25519: armored,
                decryptionKey: Data("not the passphrase".utf8)
            )
        }
    }

    /// The connect path's contract for sealed keys: no passphrase on file →
    /// the typed "needs a passphrase" error (which is what raises the
    /// key-unlock prompt), wrong one → "incorrect", right one → a built auth
    /// method with no network involved.
    @Test func sealedKeyDefersToTheConnectTimePrompt() throws {
        let vectors = try Vectors()
        let container = try vectors.data("payload_offline_encrypted", "container_hex")
        let armored = BindSSHKey.armor(container: container)
        let passphrase = try vectors.string("payload_offline_encrypted", "passphrase")
        var host = Host(name: "sealed", hostname: "example.invalid", username: "jhen")
        host.authMethod = .privateKey

        func attempt(_ passphrase: String?) throws {
            _ = try SSHConnection.makeAuthenticationMethod(
                host: host,
                secrets: HostSecrets(
                    password: nil, privateKey: armored, passphrase: passphrase
                )
            )
        }
        let missing = #expect(throws: SSHConnectionError.self) { try attempt(nil) }
        #expect(missing?.keyPassphraseReason == .required)
        let wrong = #expect(throws: SSHConnectionError.self) { try attempt("wrong") }
        #expect(wrong?.keyPassphraseReason == .incorrect)
        #expect(throws: Never.self) { try attempt(passphrase) }
    }

    /// Flag bits are layout switches: bit 1 without bit 0, any unknown bit,
    /// an empty container, one past the size cap, and every truncation must
    /// all refuse to parse rather than misread key material.
    @Test func sealedPayloadRejectsMalformedFlagsAndLengths() throws {
        let vectors = try Vectors()
        let bytes = try vectors.data("payload_offline_encrypted", "bytes_hex")
        #expect(BindPayload(bytes: bytes) != nil)

        var sealedWithoutOffline = bytes
        sealedWithoutOffline[sealedWithoutOffline.startIndex + 1] = 0x02
        #expect(BindPayload(bytes: sealedWithoutOffline) == nil)

        var futureBit = bytes
        futureBit[futureBit.startIndex + 1] |= 0x04
        #expect(BindPayload(bytes: futureBit) == nil)

        var plainWithFutureBit = try vectors.data("payload", "bytes_hex")
        plainWithFutureBit[plainWithFutureBit.startIndex + 1] |= 0x04
        #expect(BindPayload(bytes: plainWithFutureBit) == nil)

        for cut in 1..<bytes.count {
            #expect(
                BindPayload(bytes: bytes.prefix(cut)) == nil,
                "a sealed payload truncated to \(cut) bytes decoded"
            )
        }

        // Hand-built offline block: user "" ‖ port 2222 ‖ container length N
        // with N bytes of filler ‖ default path ‖ no digest. Only the length
        // rule distinguishes the two cases below, so both must fail on it.
        func offlinePayload(containerLength: Int, filler: Int) -> Data {
            var bytes = Data([2, 0x03])
            bytes += Data(repeating: 0, count: 48)  // spub ‖ token
            bytes += Data([0, 0, 0, 0, 0])  // port, no addrs, empty name, empty user
            bytes += Data([0x08, 0xAE])  // ssh port 2222
            bytes += Data([UInt8(containerLength >> 8), UInt8(containerLength & 0xFF)])
            bytes += Data(repeating: 0xAB, count: filler)
            bytes += Data([0, 0])  // default path, no digest
            return bytes
        }
        #expect(BindPayload(bytes: offlinePayload(containerLength: 0, filler: 0)) == nil)
        #expect(BindPayload(bytes: offlinePayload(containerLength: 5000, filler: 5000)) == nil)
    }

    @Test func payloadRejectsWrongSchemeVersionAndGarbage() throws {
        let vectors = try Vectors()
        var bytes = try vectors.data("payload", "bytes_hex")
        #expect(BindPayload(bytes: bytes) != nil)

        // A future format version must not be read as this one.
        bytes[bytes.startIndex] = 3
        #expect(BindPayload(bytes: bytes) == nil)

        #expect(BindPayload(string: "https://example.com/x") == nil)
        #expect(BindPayload(string: "multiplex://open?host=devbox&action=shell") == nil)
        #expect(BindPayload(string: "multiplex://b/!!!") == nil)
        #expect(BindPayload(string: "multiplex://b/") == nil)
        #expect(BindPayload(string: "") == nil)
    }

    /// Every truncation of a valid payload must fail closed rather than
    /// producing a half-read offer.
    @Test func payloadRejectsEveryTruncation() throws {
        let vectors = try Vectors()
        let bytes = try vectors.data("payload", "bytes_hex")
        for cut in 1..<bytes.count {
            #expect(
                BindPayload(bytes: bytes.prefix(cut)) == nil,
                "a payload truncated to \(cut) bytes decoded"
            )
        }
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

    /// A sealed frame's plaintext is still a peer's bytes: a header claiming
    /// more than the input holds must throw, never trap in the Int
    /// conversion or pre-allocate the claim.
    @Test func cborRejectsLengthsLargerThanTheInput() {
        // A byte string claiming 2⁶³ bytes, in a nine-byte input.
        var hugeBytes = Data([0x5B])
        hugeBytes.append(contentsOf: withUnsafeBytes(of: (UInt64(1) << 63).bigEndian, Array.init))
        #expect(throws: (any Error).self) { try BindCBOR.decode(hugeBytes) }

        // An array claiming four billion elements, in five bytes.
        var hugeArray = Data([0x9A])
        hugeArray.append(contentsOf: withUnsafeBytes(of: UInt32.max.bigEndian, Array.init))
        #expect(throws: (any Error).self) { try BindCBOR.decode(hugeArray) }

        // Text one byte longer than what follows it.
        #expect(throws: (any Error).self) { try BindCBOR.decode(Data([0x62, 0x61])) }
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
