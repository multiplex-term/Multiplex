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
        let seed = key.rawRepresentation
        let publicKey = key.publicKey.rawRepresentation
        let publicBlob = sshString(Data(keyType.utf8)) + sshString(publicKey)
        let publicB64 = publicBlob.base64EncodedString()

        // openssh-key-v1: magic ‖ cipher "none" ‖ kdf "none" ‖ kdfoptions ""
        // ‖ nkeys=1 ‖ public blob ‖ private section (checkint ×2, key type,
        // pub, seed‖pub, comment, pad 1,2,3… to the "none" blocksize of 8).
        var payload = Data("openssh-key-v1\0".utf8)
        payload += sshString(Data("none".utf8))
        payload += sshString(Data("none".utf8))
        payload += sshString(Data())
        payload += uint32(1)
        payload += sshString(publicBlob)

        var priv = Data()
        let check = UInt32.random(in: .min ... .max)
        priv += uint32(check)
        priv += uint32(check)
        priv += sshString(Data(keyType.utf8))
        priv += sshString(publicKey)
        priv += sshString(seed + publicKey)
        priv += sshString(Data())
        var pad: UInt8 = 1
        while priv.count % 8 != 0 {
            priv.append(pad)
            pad += 1
        }
        payload += sshString(priv)

        return BindSSHKey(
            privateOpenSSH: armor(container: payload),
            publicLine: "\(keyType) \(publicB64)",
            publicB64: publicB64
        )
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
