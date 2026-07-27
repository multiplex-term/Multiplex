import CryptoKit
import Foundation
import Testing

@testable import Multiplex

/// The parts of enrollment that must be right before any socket opens: the
/// key material this device offers, the marker grammar `mpx unbind` matches,
/// host naming, and the rotation command that retires an offline payload's
/// transported key.
struct BindEnrollmentTests {
    // MARK: Key serialization

    /// The public line has to be exactly what OpenSSH writes, because the
    /// CLI parses it with ssh-key and re-emits its canonical form — a
    /// mismatch would silently enroll a different key than we hold.
    @Test func publicLineMatchesOpenSSHForAKnownSeed() throws {
        let seed = Data(repeating: 0x42, count: 32)
        let key = BindSSHKey.make(
            from: try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        )
        let publicRaw = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            .publicKey.rawRepresentation

        // ssh-ed25519 wire format: string("ssh-ed25519") ‖ string(32 bytes).
        var expected = Data()
        for field in [Data("ssh-ed25519".utf8), publicRaw] {
            expected.append(contentsOf: withUnsafeBytes(of: UInt32(field.count).bigEndian, Array.init))
            expected.append(field)
        }
        #expect(key.publicLine == "ssh-ed25519 \(expected.base64EncodedString())")
        #expect(key.publicB64 == expected.base64EncodedString())
        // No comment: the enrolling side owns the comment field (the marker).
        #expect(key.publicLine.split(separator: " ").count == 2)
    }

    @Test func privateKeyIsArmoredOpenSSHAndSelfDescribing() throws {
        let key = BindSSHKey.generate()
        #expect(key.privateOpenSSH.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        #expect(key.privateOpenSSH.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        // Every body line stays inside OpenSSH's wrap width.
        let body = key.privateOpenSSH.split(separator: "\n").filter { !$0.hasPrefix("-----") }
        #expect(body.allSatisfy { $0.count <= 70 })
    }

    /// An offline payload ships 32 raw seed bytes instead of ~370 bytes of
    /// armored text, so the same seed must rebuild the same public half on
    /// both sides — that identity is what the rotation's exact-match removal
    /// depends on.
    @Test func seedRebuildsTheSamePublicHalf() throws {
        let seed = Data(repeating: 0x55, count: 32)
        let first = try #require(BindSSHKey(seed: seed))
        let second = try #require(BindSSHKey(seed: seed))
        #expect(first.publicB64 == second.publicB64)
        #expect(first.publicLine == second.publicLine)
        #expect(
            first.publicLine
                == BindSSHKey.make(
                    from: try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                ).publicLine
        )
        // A wrong-length seed is not a key.
        #expect(BindSSHKey(seed: Data(repeating: 1, count: 16)) == nil)
    }

    // MARK: Marker grammar (shared with the CLI)

    @Test func markerSlugMatchesTheCLIsRules() {
        #expect(BindMarker.slug("Jhen's Vision Pro") == "jhen-s-vision-pro")
        #expect(BindMarker.slug("iPad Pro 13\"") == "ipad-pro-13")
        #expect(BindMarker.slug("   ") == "device")
        #expect(BindMarker.slug("") == "device")
        #expect(BindMarker.slug("A very long device display name here")
            == "a-very-long-device-displ")
    }

    @Test func markerCommentUsesTheSharedPrefix() {
        let comment = BindMarker.comment(id8: "9f3a1c2e", device: "Jhen's Vision Pro")
        #expect(comment == "multiplex:bind:9f3a1c2e:jhen-s-vision-pro")
        #expect(comment.hasPrefix(BindMarker.prefix))
        let id = BindMarker.randomID8()
        #expect(id.count == 8)
        let isHex = id.allSatisfy { $0.isHexDigit }
        #expect(isHex)
    }

    // MARK: Host naming

    @Test func boundHostNamesNeverCollideWithExistingOnes() {
        #expect(BindController.uniqueName("devbox", taken: []) == "devbox")
        #expect(BindController.uniqueName("devbox", taken: ["devbox"]) == "devbox 2")
        #expect(BindController.uniqueName("devbox", taken: ["devbox", "devbox 2"]) == "devbox 3")
        // Case-insensitive: two records called DEVBOX and devbox would be
        // indistinguishable on the rail.
        #expect(BindController.uniqueName("devbox", taken: ["DEVBOX"]) == "devbox 2")
        #expect(BindController.uniqueName("  ", taken: []) == "host")
    }

    // MARK: Which address the bound host dials

    /// The machine's own address list wins over wherever its bind listener
    /// happened to answer: those differ for a host behind NAT, a tunnel, or
    /// `mpx bind --addr`, and only the machine knows where its SSH lives.
    @Test func boundHostPrefersTheAddressTheMachineStates() {
        let offer = BindOffer(value: .map([
            ("name", .text("devbox")),
            ("addrs", .array([.text("127.0.0.1")])),
            ("ssh", .map([("user", .text("jhen")), ("port", .uint(2222))])),
        ]))!
        // Bonjour resolved the service on a LAN interface, but the machine
        // says its SSH is reachable at the address it published.
        #expect(BindController.hostname(
            for: offer, connectedTo: "10.187.1.225", payload: nil) == "127.0.0.1")
    }

    /// When the address we reached IS endorsed, prefer it — it is proven
    /// reachable, unlike an arbitrary first entry.
    @Test func boundHostPrefersTheProvenAddressWhenEndorsed() {
        let offer = BindOffer(value: .map([
            ("name", .text("devbox")),
            ("addrs", .array([.text("10.0.5.2"), .text("192.168.1.24")])),
            ("ssh", .map([("user", .text("jhen")), ("port", .uint(22))])),
        ]))!
        #expect(BindController.hostname(
            for: offer, connectedTo: "192.168.1.24", payload: nil) == "192.168.1.24")
        // Nothing endorsed and nothing reached: the name is the last resort,
        // never an empty hostname.
        let bare = BindOffer(value: .map([
            ("name", .text("devbox")),
            ("ssh", .map([("user", .text("jhen")), ("port", .uint(22))])),
        ]))!
        #expect(BindController.hostname(for: bare, connectedTo: nil, payload: nil) == "devbox")
        #expect(BindController.hostname(
            for: bare, connectedTo: "10.0.0.9", payload: nil) == "10.0.0.9")
    }

    // MARK: Rotation command

    @Test func rotationAddsBeforeRemovingAndPreservesTheFile() throws {
        let command = BindRotationStore.rotateCommand(
            authorizedKeysPath: nil,
            removingPublicB64: "OLDKEYB64",
            addingLine: "ssh-ed25519 NEWKEYB64 multiplex:bind:aabbccdd:ipad"
        )
        let appendIndex = try #require(command.range(of: "printf")).lowerBound
        let removeIndex = try #require(command.range(of: "grep -v -F")).lowerBound
        // Order is the safety property: a failure between the two steps must
        // leave a working key behind, never none.
        #expect(appendIndex < removeIndex)
        // cat-into-place keeps authorized_keys' inode, owner and mode; mv
        // would replace them.
        #expect(command.contains("cat \"$t\" > \"$f\""))
        #expect(!command.contains("mv "))
        #expect(command.contains("MPX_ROTATE_OK"))
        #expect(command.contains("chmod 600"))
        #expect(command.contains("chmod 700"))
        // The default target must expand $HOME, so it cannot be single-quoted.
        #expect(command.contains("\"$HOME/.ssh/authorized_keys\""))
    }

    @Test func rotationQuotesEveryUntrustedField() {
        let command = BindRotationStore.rotateCommand(
            authorizedKeysPath: "/etc/ssh/keys/$(whoami); rm -rf /",
            removingPublicB64: "OLD'; rm -rf /",
            addingLine: "ssh-ed25519 X `id`"
        )
        // Nothing the payload supplied may reach the shell unquoted.
        #expect(!command.contains("$(whoami)'"))
        #expect(command.contains("'/etc/ssh/keys/$(whoami); rm -rf /'"))
        #expect(!command.contains("rm -rf /\""))
        #expect(command.contains("'ssh-ed25519 X `id`'"))
    }

    @Test func rotationStoreRemembersUntilCleared() {
        let store = BindRotationStore()
        let hostID = UUID()
        defer { store.clear(for: hostID) }

        #expect(store.request(for: hostID) == nil)
        store.record(
            BindRotationStore.Request(
                transportedPublicB64: "OLDKEY",
                authorizedKeysPath: "/tmp/ak"
            ),
            for: hostID
        )
        #expect(store.request(for: hostID)?.transportedPublicB64 == "OLDKEY")
        #expect(store.pendingHostIDs.contains(hostID))
        store.clear(for: hostID)
        #expect(store.request(for: hostID) == nil)
        #expect(!store.pendingHostIDs.contains(hostID))
    }

    // MARK: Host record

    @Test func pinnedHostKeysRideTheSyncedRecord() throws {
        var host = Host(name: "devbox", hostname: "192.168.1.24", username: "jhen")
        host.pinnedHostKeys = ["ssh-ed25519 SHA256:abc", "ssh-rsa SHA256:def"]
        let decoded = try JSONDecoder().decode(
            Host.self, from: try JSONEncoder().encode(host)
        )
        #expect(decoded.pinnedHostKeys == host.pinnedHostKeys)

        // A record written before the field existed decodes to empty, not nil
        // and not a failure.
        let legacy = #"{"name":"old","hostname":"h","username":"u"}"#
        let old = try JSONDecoder().decode(Host.self, from: Data(legacy.utf8))
        #expect(old.pinnedHostKeys.isEmpty)
    }
}
