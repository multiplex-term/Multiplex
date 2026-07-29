import CommonCrypto
import CryptoKit
import Foundation

/// Device-side ed25519 SSH keypair, serialized to the OpenSSH formats the
/// rest of the app already speaks: the public single line `mpx` appends to
/// authorized_keys, and the unencrypted openssh-key-v1 private text that
/// goes to `KeychainStore` exactly like a pasted key (Citadel parses it at
/// connect). Pure serialization — generation is one CryptoKit call.
struct BindSSHKey: Equatable, Sendable {
    var privateOpenSSH: String
    /// `ssh-ed25519 <base64>` — no comment; the enrolling side owns it.
    var publicLine: String
    /// Just the base64 field, the exact-match handle rotation greps by.
    var publicB64: String

    static let keyType = "ssh-ed25519"

    static func generate() -> BindSSHKey {
        make(from: Curve25519.Signing.PrivateKey())
    }

    static func make(from key: Curve25519.Signing.PrivateKey) -> BindSSHKey {
        let publicKey = key.publicKey.rawRepresentation
        let publicBlob = sshString(Data(keyType.utf8)) + sshString(publicKey)
        let publicB64 = publicBlob.base64EncodedString()
        let container = container(
            cipher: "none", kdf: "none", kdfOptions: Data(),
            publicBlob: publicBlob,
            privateSection: privateSection(
                key: key,
                checkint: UInt32.random(in: .min ... .max),
                // The "none" cipher's block size.
                blockSize: 8
            )
        )
        return BindSSHKey(
            privateOpenSSH: armor(container: container),
            publicLine: "\(keyType) \(publicB64)",
            publicB64: publicB64
        )
    }

    /// The container's private section: checkint ×2, key type, pub,
    /// seed‖pub, empty comment, then the 1,2,3… pad ramp the format
    /// prescribes (and readers verify after decrypting) up to the cipher's
    /// block size.
    private static func privateSection(
        key: Curve25519.Signing.PrivateKey, checkint: UInt32, blockSize: Int
    ) -> Data {
        let publicKey = key.publicKey.rawRepresentation
        var priv = Data()
        priv += uint32(checkint)
        priv += uint32(checkint)
        priv += sshString(Data(keyType.utf8))
        priv += sshString(publicKey)
        priv += sshString(key.rawRepresentation + publicKey)
        priv += sshString(Data())
        var pad: UInt8 = 1
        while priv.count % blockSize != 0 {
            priv.append(pad)
            pad += 1
        }
        return priv
    }

    /// openssh-key-v1: magic ‖ cipher ‖ kdf ‖ kdfoptions ‖ nkeys=1 ‖ public
    /// blob ‖ private section (already encrypted when the cipher says so).
    private static func container(
        cipher: String, kdf: String, kdfOptions: Data,
        publicBlob: Data, privateSection: Data
    ) -> Data {
        var payload = Data("openssh-key-v1\0".utf8)
        payload += sshString(Data(cipher.utf8))
        payload += sshString(Data(kdf.utf8))
        payload += sshString(kdfOptions)
        payload += uint32(1)
        payload += sshString(publicBlob)
        payload += sshString(privateSection)
        return payload
    }

    /// Wraps an openssh-key-v1 container in its PEM armor — base64, 70-char
    /// lines, the BEGIN/END fence. This is the only transform a
    /// passphrase-sealed container from an offline payload gets app-side:
    /// the bytes stay exactly the CLI's, and Citadel opens them at connect
    /// with the passphrase the person types.
    static func armor(container: Data) -> String {
        let body = container.base64EncodedString()
        var lines: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let end = body.index(index, offsetBy: 70, limitedBy: body.endIndex) ?? body.endIndex
            lines.append(String(body[index..<end]))
            index = end
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + lines.joined(separator: "\n")
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private static func sshString(_ data: Data) -> Data {
        uint32(UInt32(data.count)) + data
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data(withUnsafeBytes(of: value.bigEndian, Array.init))
    }

}

// MARK: - Passphrase sealing

extension BindSSHKey {
    /// ssh-keygen's own default; Citadel's reader additionally requires
    /// rounds < 32, so this is both standard and openable.
    static let sealRounds: UInt32 = 16

    /// The same key, sealed in OpenSSH's standard encrypted container
    /// (bcrypt-pbkdf ‖ aes256-ctr — byte-compatible with `ssh-keygen -p`).
    /// This is what a bind stores when the person typed a KEY PASSPHRASE:
    /// the vendored bcrypt derives 48 bytes (32 AES key ‖ 16 IV), the
    /// private section is padded to the AES block and encrypted, and
    /// Citadel — whose bcrypt is an independent compilation — opens it at
    /// connect. `salt`/`checkint` are injectable for deterministic tests
    /// only; nil means fresh randomness. Returns nil only if a CommonCrypto
    /// call fails, and callers must treat that as "do not store anything",
    /// never as "store it plain".
    static func sealedPrivateOpenSSH(
        key: Curve25519.Signing.PrivateKey,
        passphrase: String,
        salt fixedSalt: Data? = nil,
        checkint fixedCheckint: UInt32? = nil
    ) -> String? {
        guard !passphrase.isEmpty else { return nil }
        let salt = fixedSalt ?? Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let check = fixedCheckint ?? UInt32.random(in: .min ... .max)

        var derived = [UInt8](repeating: 0, count: 48)
        let pass = Array(passphrase.utf8)
        let saltBytes = [UInt8](salt)
        guard mpxbind_bcrypt_pbkdf(
            pass, pass.count, saltBytes, saltBytes.count,
            &derived, derived.count, sealRounds
        ) == 0 else { return nil }
        let aesKey = Array(derived[0..<32])
        let iv = Array(derived[32..<48])

        let publicKey = key.publicKey.rawRepresentation
        let publicBlob = sshString(Data(keyType.utf8)) + sshString(publicKey)

        // aes256-ctr's block is 16, so the pad ramp fills to that here.
        let priv = privateSection(key: key, checkint: check, blockSize: 16)
        guard let ciphertext = aes256ctr(priv, key: aesKey, iv: iv) else { return nil }

        return armor(container: container(
            cipher: "aes256-ctr", kdf: "bcrypt",
            kdfOptions: sshString(salt) + uint32(sealRounds),
            publicBlob: publicBlob,
            privateSection: ciphertext
        ))
    }

    /// One-shot AES-256-CTR (CommonCrypto). CTR is a stream mode, so the
    /// output length equals the input's and no padding happens here — the
    /// openssh-key-v1 ramp above is the only padding in the container.
    private static func aes256ctr(_ input: Data, key: [UInt8], iv: [UInt8]) -> Data? {
        var cryptor: CCCryptorRef?
        let create = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR),
            CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
            iv, key, key.count, nil, 0, 0, 0, &cryptor
        )
        guard create == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                CCCryptorUpdate(
                    cryptor,
                    inBytes.baseAddress, inBytes.count,
                    outBytes.baseAddress, outBytes.count,
                    &moved
                )
            }
        }
        guard status == kCCSuccess, moved == input.count else { return nil }
        return output.prefix(moved)
    }
}

// The seed initializer lives in an extension so the memberwise initializer
// survives — declaring it inside the struct would suppress it (same reason
// Host's decoding init is an extension).
extension BindSSHKey {
    /// Rebuilds the key an offline payload carried as a raw 32-byte seed.
    /// The public half is a pure function of the seed — which is what makes
    /// the rotation's exact-match removal work — while the armored private
    /// text may differ from the CLI's byte-for-byte, since OpenSSH's
    /// `checkint` is arbitrary padding either side is free to choose.
    init?(seed: Data) {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else { return nil }
        self = Self.make(from: key)
    }
}

/// Marker grammar shared with `mpx` — `multiplex:bind:<8 hex>:<slug>` in the
/// key line's own comment field. The app authors one during rotation.
enum BindMarker {
    static let prefix = "multiplex:bind:"

    static func comment(id8: String, device: String) -> String {
        "\(prefix)\(id8):\(slug(device))"
    }

    static func randomID8() -> String {
        (0..<4).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// Mirror of the CLI's slug: lowercase alnum runs joined by single
    /// dashes, trimmed, ≤24 chars, never empty.
    static func slug(_ display: String) -> String {
        var slug = ""
        var lastDash = true
        for character in display.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
                lastDash = false
            } else if !lastDash {
                slug.append("-")
                lastDash = true
            }
            if slug.count >= 24 { break }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "device" : trimmed
    }
}
