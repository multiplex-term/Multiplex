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

        let body = payload.base64EncodedString()
        var lines: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let end = body.index(index, offsetBy: 70, limitedBy: body.endIndex) ?? body.endIndex
            lines.append(String(body[index..<end]))
            index = end
        }
        let armored = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + lines.joined(separator: "\n")
            + "\n-----END OPENSSH PRIVATE KEY-----\n"

        return BindSSHKey(
            privateOpenSSH: armored,
            publicLine: "\(keyType) \(publicB64)",
            publicB64: publicB64
        )
    }

    /// Recovers the public base64 field from an unencrypted openssh-key-v1
    /// ed25519 private text — how rotation finds the transported key's exact
    /// authorized_keys line without ever re-shipping it.
    static func publicB64(fromPrivateOpenSSH text: String) -> String? {
        let body = text
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let payload = Data(base64Encoded: body) else { return nil }
        var reader = Reader(data: payload)
        guard reader.skip(Data("openssh-key-v1\0".utf8).count),
              let cipher = reader.string(), String(data: cipher, encoding: .utf8) == "none",
              reader.string() != nil,  // kdf name
              reader.string() != nil,  // kdf options
              let nkeys = reader.uint32(), nkeys == 1,
              let publicBlob = reader.string()
        else { return nil }
        return publicBlob.base64EncodedString()
    }

    private static func sshString(_ data: Data) -> Data {
        uint32(UInt32(data.count)) + data
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data(withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    private struct Reader {
        let data: Data
        var index: Data.Index

        init(data: Data) {
            self.data = data
            index = data.startIndex
        }

        mutating func skip(_ count: Int) -> Bool {
            guard let end = data.index(index, offsetBy: count, limitedBy: data.endIndex)
            else { return false }
            index = end
            return true
        }

        mutating func uint32() -> UInt32? {
            guard let end = data.index(index, offsetBy: 4, limitedBy: data.endIndex)
            else { return nil }
            let value = data.subdata(in: index..<end).reduce(0) { $0 << 8 | UInt32($1) }
            index = end
            return value
        }

        mutating func string() -> Data? {
            guard let length = uint32(),
                  let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex)
            else { return nil }
            defer { index = end }
            return data.subdata(in: index..<end)
        }
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
