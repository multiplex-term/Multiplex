import CryptoKit
import Foundation

/// The bind-v1 wire contract's client side — payload codec, discovery TXT
/// parse, and the sealed handshake session. Pure: the network lives in
/// `BindClient`, UI in the deck. The authoritative spec and the shared
/// vectors both live in the multiplex-cli repo (spec/bind-v1.md); the
/// vendored copy in MultiplexTests pins these types to `mpx`'s exact bytes.
enum BindWire {
    static let urlScheme = "multiplex"
    static let urlAuthority = "bind"
    static let hkdfSalt = Data("multiplex-bind-v1".utf8)
    static let pinInfo = Data("multiplex-bind-pin".utf8)
    static let maxFrame = 64 * 1024
    /// Bonjour service the CLI announces and `BindDiscovery` browses.
    static let bonjourType = "_multiplex-bind._tcp"
}

/// The one string QR, clipboard, and `multiplex://bind` opens all carry.
struct BindPayload: Equatable, Sendable {
    var addrs: [String]
    /// Handshake TCP listener; 0 in offline payloads (no listener at all).
    var port: UInt16
    var spub: Data
    var token: Data
    var name: String
    var sshUser: String
    var sshPort: UInt16
    var hostkeys: [String]
    /// Offline only: the OpenSSH private key the CLI already installed.
    var key: String?
    /// Offline only: a non-default authorized_keys path the CLI enrolled
    /// into (`--authorized-keys`) — rotate-on-first-connect must edit the
    /// same file the sshd actually reads.
    var akpath: String?

    var isOffline: Bool { key != nil }

    /// Accepts the canonical `multiplex://bind?v=1&d=…` string. Query-item
    /// parsing (not a prefix match) so a future param can ride alongside.
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == BindWire.urlScheme,
              components.host?.lowercased() == BindWire.urlAuthority
        else { return nil }
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "v" })?.value == "1",
              let encoded = items.first(where: { $0.name == "d" })?.value,
              let cbor = Data(base64URLNoPad: encoded)
        else { return nil }
        self.init(cbor: cbor)
    }

    init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        self.init(url: url)
    }

    init?(cbor: Data) {
        guard let value = try? BindCBOR.decode(cbor),
              value["v"]?.uintValue == 1,
              let port = value["port"]?.uintValue.flatMap(UInt16.init(exactly:)),
              let spub = value["spub"]?.bytesValue, spub.count == 32,
              let token = value["token"]?.bytesValue, token.count == 16,
              let name = value["name"]?.textValue,
              let ssh = value["ssh"],
              let sshUser = ssh["user"]?.textValue,
              let sshPort = ssh["port"]?.uintValue.flatMap(UInt16.init(exactly:))
        else { return nil }
        addrs = value["addrs"]?.textArrayValue ?? []
        self.port = port
        self.spub = spub
        self.token = token
        self.name = name
        self.sshUser = sshUser
        self.sshPort = sshPort
        hostkeys = ssh["hostkeys"]?.textArrayValue ?? []
        key = value["key"]?.textValue
        akpath = value["akpath"]?.textValue
    }
}

/// One machine currently offering to bind, parsed from the Bonjour TXT
/// record. Identity is the session public key — the same machine announcing
/// over several interfaces dedupes to one tile.
struct BindAnnouncement: Identifiable, Equatable, Sendable {
    var spub: Data
    var name: String
    var user: String
    var sshPort: UInt16
    var fingerprint: String?

    var id: String { spub.base64EncodedString() }

    init?(txt: [String: String]) {
        guard txt["v"] == "1",
              let spubText = txt["spub"],
              let spub = Data(base64URLNoPad: spubText), spub.count == 32,
              let name = txt["name"], !name.isEmpty
        else { return nil }
        self.spub = spub
        self.name = name
        user = txt["user"] ?? ""
        sshPort = txt["sshport"].flatMap { UInt16($0) } ?? 22
        fingerprint = txt["fp"]
    }
}

/// The host record OFFER carries — what the app saves.
struct BindOffer: Equatable, Sendable {
    var name: String
    var addrs: [String]
    var sshUser: String
    var sshPort: UInt16
    var hostkeys: [String]

    init?(value: BindCBOR.Value) {
        guard let name = value["name"]?.textValue,
              let ssh = value["ssh"],
              let sshUser = ssh["user"]?.textValue,
              let sshPort = ssh["port"]?.uintValue.flatMap(UInt16.init(exactly:))
        else { return nil }
        self.name = name
        addrs = value["addrs"]?.textArrayValue ?? []
        self.sshUser = sshUser
        self.sshPort = sshPort
        hostkeys = ssh["hostkeys"]?.textArrayValue ?? []
    }
}

struct BindDone: Equatable, Sendable {
    var ok: Bool
    var comment: String?
    var error: String?

    init?(value: BindCBOR.Value) {
        guard let ok = value["ok"]?.boolValue else { return nil }
        self.ok = ok
        comment = value["comment"]?.textValue
        error = value["err"]?.textValue
    }
}

/// Directional ChaCha20-Poly1305 keys + counters, derived exactly as the
/// spec's schedule: HKDF-SHA256(salt "multiplex-bind-v1", ikm = X25519
/// shared secret, info = epub‖spub) → key_c2s ‖ key_s2c. Nonce is 4 zero
/// bytes ‖ BE64(per-direction sequence). Wire frames are ciphertext‖tag.
struct BindChannel {
    private let keyC2S: SymmetricKey
    private let keyS2C: SymmetricKey
    private var seqC2S: UInt64 = 0
    private var seqS2C: UInt64 = 0

    enum ChannelError: Error {
        case authenticationFailed
        case malformed
    }

    init(shared: Data, epub: Data, spub: Data) {
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: BindWire.hkdfSalt,
            info: epub + spub,
            outputByteCount: 64
        )
        let bytes = okm.withUnsafeBytes { Data($0) }
        keyC2S = SymmetricKey(data: bytes.prefix(32))
        keyS2C = SymmetricKey(data: bytes.suffix(32))
    }

    private static func nonce(_ seq: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        bytes.append(contentsOf: withUnsafeBytes(of: seq.bigEndian, Array.init))
        return try ChaChaPoly.Nonce(data: bytes)
    }

    mutating func sealC2S(_ plain: Data) -> Data {
        defer { seqC2S += 1 }
        // Sealing with a well-formed nonce cannot fail.
        let box = try! ChaChaPoly.seal(plain, using: keyC2S, nonce: Self.nonce(seqC2S))
        return box.ciphertext + box.tag
    }

    mutating func openS2C(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw ChannelError.malformed }
        let box = try ChaChaPoly.SealedBox(
            nonce: Self.nonce(seqS2C),
            ciphertext: sealed.dropLast(16),
            tag: sealed.suffix(16)
        )
        guard let plain = try? ChaChaPoly.open(box, using: keyS2C) else {
            throw ChannelError.authenticationFailed
        }
        seqS2C += 1
        return plain
    }

    // Server-side halves — exercised by the vector tests so this one type
    // proves both directions against mpx's bytes.
    mutating func sealS2C(_ plain: Data) -> Data {
        defer { seqS2C += 1 }
        let box = try! ChaChaPoly.seal(plain, using: keyS2C, nonce: Self.nonce(seqS2C))
        return box.ciphertext + box.tag
    }

    mutating func openC2S(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw ChannelError.malformed }
        let box = try ChaChaPoly.SealedBox(
            nonce: Self.nonce(seqC2S),
            ciphertext: sealed.dropLast(16),
            tag: sealed.suffix(16)
        )
        guard let plain = try? ChaChaPoly.open(box, using: keyC2S) else {
            throw ChannelError.authenticationFailed
        }
        seqC2S += 1
        return plain
    }

    /// The discovery path's proof: HKDF(salt = epub‖spub, ikm = PIN digits,
    /// info = "multiplex-bind-pin"). Transcript-bound, so a captured proof
    /// replays on no other connection.
    static func pinProof(pin: String, epub: Data, spub: Data) -> Data {
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)),
            salt: epub + spub,
            info: BindWire.pinInfo,
            outputByteCount: 32
        )
        return okm.withUnsafeBytes { Data($0) }
    }
}

/// One handshake attempt's frame builder/parser — pure message plumbing;
/// `BindClient` moves the bytes. Frame bodies only: the 4-byte big-endian
/// length prefix is transport framing and stays in the client.
struct BindClientSession {
    enum Credential {
        case token(Data)
        case pin(String)
    }

    enum SessionError: Error {
        case malformedOffer
        case malformedDone
    }

    let epub: Data
    private let spub: Data
    private let credential: Credential
    private var channel: BindChannel

    init(spub: Data, credential: Credential, ephemeralSeed: Data? = nil) throws {
        let ephemeral: Curve25519.KeyAgreement.PrivateKey
        if let ephemeralSeed {
            ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ephemeralSeed)
        } else {
            ephemeral = Curve25519.KeyAgreement.PrivateKey()
        }
        epub = ephemeral.publicKey.rawRepresentation
        self.spub = spub
        self.credential = credential
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: spub)
        )
        let sharedData = shared.withUnsafeBytes { Data($0) }
        channel = BindChannel(shared: sharedData, epub: epub, spub: spub)
    }

    /// The only cleartext frame body.
    func introBody() -> Data {
        let mode: String
        switch credential {
        case .token: mode = "token"
        case .pin: mode = "pin"
        }
        return BindCBOR.encode(.map([
            ("v", .uint(1)),
            ("epub", .bytes(epub)),
            ("mode", .text(mode)),
        ]))
    }

    mutating func helloBody() -> Data {
        let proof: Data
        switch credential {
        case .token(let token):
            proof = token
        case .pin(let pin):
            proof = BindChannel.pinProof(pin: pin, epub: epub, spub: spub)
        }
        return channel.sealC2S(BindCBOR.encode(.map([("proof", .bytes(proof))])))
    }

    mutating func parseOffer(_ sealed: Data) throws -> BindOffer {
        let plain = try channel.openS2C(sealed)
        guard let value = try? BindCBOR.decode(plain), let offer = BindOffer(value: value)
        else { throw SessionError.malformedOffer }
        return offer
    }

    mutating func enrollBody(publicKeyLine: String, device: String) -> Data {
        channel.sealC2S(BindCBOR.encode(.map([
            ("pubkey", .text(publicKeyLine)),
            ("device", .text(device)),
        ])))
    }

    mutating func parseDone(_ sealed: Data) throws -> BindDone {
        let plain = try channel.openS2C(sealed)
        guard let value = try? BindCBOR.decode(plain), let done = BindDone(value: value)
        else { throw SessionError.malformedDone }
        return done
    }
}

extension Data {
    /// base64url without padding — the payload/TXT encoding.
    init?(base64URLNoPad string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }
}
