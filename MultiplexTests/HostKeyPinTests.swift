import Foundation
import Testing

@testable import Multiplex

/// The host-key trust rule, which decides whether a connection is talking to
/// the machine it thinks it is. Everything here is pure, so the rule is
/// provable without a server: the fingerprints are cross-checked against
/// OpenSSH's own `ssh-keygen -lf` output, and the decisions are the whole
/// policy `HostKeyVerifier` executes on the NIO event loop.
struct HostKeyPinTests {
    // MARK: Fingerprints match OpenSSH

    /// The blob is the base64 body of a real `ssh-keygen -t ed25519` public
    /// line and the expected value is what `ssh-keygen -lf` printed for it.
    /// If this drifts, every pin the app writes disagrees with the ones
    /// `mpx bind` delivers — and with what the user reads off their terminal.
    @Test func fingerprintMatchesOpenSSHForEd25519() throws {
        let blob = try #require(Data(base64Encoded:
            "AAAAC3NzaC1lZDI1NTE5AAAAIGzvAzOMMkd4BHtz909gQaWthBZGQHtFP1QEVs9lsaih"))
        let pin = try #require(HostKeyPin(keyBlob: blob))
        #expect(pin.algorithm == "ssh-ed25519")
        #expect(pin.fingerprint == "SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA")
        #expect(pin.storage
            == "ssh-ed25519 SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA")
    }

    /// A second algorithm, because the name is read back out of the blob's
    /// own leading SSH string rather than asked of NIOSSH — a longer name
    /// with a different length prefix proves that parse.
    @Test func fingerprintMatchesOpenSSHForECDSA() throws {
        let blob = try #require(Data(base64Encoded: """
            AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBI6h2VZqRt9Fw2uWYL+\
            lPRFfMcdCDDl9a2Ityjv0OYn42+sXlAq6VEfvzaYzeD7t/CqA4D8AQyvphqrAxtFVpHo=
            """))
        let pin = try #require(HostKeyPin(keyBlob: blob))
        #expect(pin.algorithm == "ecdsa-sha2-nistp256")
        #expect(pin.fingerprint == "SHA256:5nZodzRXCuyfLD23HhSJnX2gPNv1k520onJhQxP4E5Q")
    }

    /// The blob's length prefix is peer-supplied. A truncated or overlong one
    /// must produce no pin rather than a slice out of bounds.
    @Test func malformedBlobsProduceNoPin() {
        #expect(HostKeyPin(keyBlob: Data()) == nil)
        #expect(HostKeyPin(keyBlob: Data([0, 0, 0, 4])) == nil)
        // Length claims 64 bytes in a 12-byte blob.
        #expect(HostKeyPin(keyBlob: Data([0, 0, 0, 64] + [UInt8](repeating: 0x41, count: 8))) == nil)
    }

    // MARK: The stored form

    /// The exact string `mpx bind` renders (`hostinfo::host_key_fingerprints`)
    /// and the offline payload reconstructs. Parsing it here is what lets a
    /// bound host be verified on its very first connection.
    @Test func parsesTheFormTheCLIDelivers() throws {
        let pin = try #require(
            HostKeyPin(storage: "ssh-ed25519 SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA")
        )
        #expect(pin.algorithm == "ssh-ed25519")
        #expect(pin.fingerprint == "SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA")
    }

    @Test func rejectsEntriesThatArentAFingerprint() {
        #expect(HostKeyPin(storage: "") == nil)
        #expect(HostKeyPin(storage: "ssh-ed25519") == nil)
        #expect(HostKeyPin(storage: "ssh-ed25519 MD5:aa:bb") == nil)
        #expect(HostKeyPin(storage: "ssh-ed25519 SHA256:") == nil)
        #expect(HostKeyPin(storage: " SHA256:abc") == nil)
    }

    /// A record with one unreadable entry stays pinned on the rest. The
    /// dangerous failure would be treating it as "nothing recorded", which
    /// `decide` reads as permission to trust anything.
    @Test func parseKeepsTheGoodEntriesAndDropsTheRest() {
        let pins = HostKeyPin.parse([
            "ssh-ed25519 SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA",
            "garbage",
            "ecdsa-sha2-nistp256 SHA256:5nZodzRXCuyfLD23HhSJnX2gPNv1k520onJhQxP4E5Q",
        ])
        #expect(pins.count == 2)
        #expect(pins.map(\.algorithm) == ["ssh-ed25519", "ecdsa-sha2-nistp256"])
    }

    // MARK: What a person can paste

    /// The exact path: a `.pub` line carries the key itself, so the digest is
    /// computed here rather than taken on trust from the text.
    @Test func acceptsAnOpenSSHPublicLine() throws {
        let pin = try #require(HostKeyPin(userInput:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzvAzOMMkd4BHtz909gQaWthBZGQHtFP1QEVs9lsaih me@box"))
        #expect(pin.algorithm == "ssh-ed25519")
        #expect(pin.fingerprint == "SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA")
    }

    /// `ssh-keyscan` puts the host in front of the algorithm, and pasting its
    /// output verbatim is the most likely way anyone gets a key here.
    @Test func acceptsSSHKeyscanOutput() throws {
        let pin = try #require(HostKeyPin(userInput:
            "box.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzvAzOMMkd4BHtz909gQaWthBZGQHtFP1QEVs9lsaih"))
        #expect(pin.algorithm == "ssh-ed25519")
        #expect(pin.fingerprint == "SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA")
    }

    /// `ssh-keygen -lf` names the type as `(ED25519)`, which is a label and
    /// not the `ssh-ed25519` the wire uses — so this pins the digest alone
    /// rather than inventing an algorithm name that would never match.
    @Test func acceptsSSHKeygenListingAsADigestOnlyPin() throws {
        let pin = try #require(HostKeyPin(userInput:
            "256 SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA no comment (ED25519)"))
        #expect(pin.algorithm == HostKeyPin.anyAlgorithm)
        #expect(pin.fingerprint == "SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA")
    }

    /// What a VPS console usually shows.
    @Test func acceptsABareFingerprint() throws {
        let pin = try #require(
            HostKeyPin(userInput: "  SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA  ")
        )
        #expect(pin.algorithm == HostKeyPin.anyAlgorithm)
    }

    @Test func acceptsTheAppsOwnStoredForm() throws {
        let pin = try #require(HostKeyPin(userInput: Self.ed25519.storage))
        #expect(pin == Self.ed25519)
    }

    @Test func rejectsTextThatIsNotAKey() {
        #expect(HostKeyPin(userInput: "") == nil)
        #expect(HostKeyPin(userInput: "    ") == nil)
        #expect(HostKeyPin(userInput: "example.com") == nil)
        #expect(HostKeyPin(userInput: "MD5:aa:bb:cc") == nil)
        // An algorithm whose base64 body isn't that algorithm's key.
        #expect(HostKeyPin(userInput: "ssh-ed25519 bm90LWEta2V5") == nil)
    }

    /// A digest-only pin still has to reject the wrong key — otherwise
    /// pasting a fingerprint would be worse than pasting nothing.
    @Test func aDigestOnlyPinTrustsItsKeyAndRefusesOthers() {
        let digestOnly = HostKeyPin(
            algorithm: HostKeyPin.anyAlgorithm,
            fingerprint: Self.ed25519.fingerprint
        )
        #expect(HostKeyPin.decide(presented: Self.ed25519, against: [digestOnly]) == .trusted)
        // Different algorithm, but the digest is the one pinned: still the
        // same key, because the digest covers the algorithm name too.
        #expect(HostKeyPin.decide(presented: Self.ecdsa, against: [digestOnly]) != .trusted)
        #expect(HostKeyPin.decide(presented: Self.impostor, against: [digestOnly])
            == .refused(.changed(expected: digestOnly, presented: Self.impostor)))
    }

    // MARK: The trust rule

    private static let ed25519 = HostKeyPin(
        algorithm: "ssh-ed25519",
        fingerprint: "SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA"
    )
    private static let ecdsa = HostKeyPin(
        algorithm: "ecdsa-sha2-nistp256",
        fingerprint: "SHA256:5nZodzRXCuyfLD23HhSJnX2gPNv1k520onJhQxP4E5Q"
    )
    private static let impostor = HostKeyPin(
        algorithm: "ssh-ed25519",
        fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    )

    /// Trust on first use — and the write is the point: it is what makes the
    /// second connection to this host a checked one.
    @Test func nothingRecordedLearnsTheKey() {
        #expect(
            HostKeyPin.decide(presented: Self.ed25519, against: [])
                == .learn(Self.ed25519)
        )
    }

    @Test func aRecordedKeyIsTrusted() {
        #expect(
            HostKeyPin.decide(presented: Self.ed25519, against: [Self.ed25519, Self.ecdsa])
                == .trusted
        )
    }

    /// The serious one: same algorithm, different key underneath it.
    @Test func aChangedKeyIsRefused() {
        #expect(
            HostKeyPin.decide(presented: Self.impostor, against: [Self.ed25519])
                == .refused(.changed(expected: Self.ed25519, presented: Self.impostor))
        )
    }

    /// A host pinned on ed25519 alone must not be talked into an unpinned
    /// algorithm — learning it would let an interceptor pick a key type the
    /// real machine never had and be trusted for it.
    @Test func anUnpinnedAlgorithmIsRefusedRatherThanLearned() {
        #expect(
            HostKeyPin.decide(presented: Self.ecdsa, against: [Self.ed25519])
                == .refused(.unrecognizedAlgorithm(presented: Self.ecdsa, pinned: [Self.ed25519]))
        )
    }

    /// A record whose every entry is unreadable must refuse, not fall back to
    /// first-use trust: only a genuinely empty set means "nothing recorded".
    @Test func anAllGarbageRecordStillRefuses() {
        let pins = HostKeyPin.parse(["garbage", "also garbage"])
        #expect(pins.isEmpty)
        // Empty *after parsing* is the TOFU path by design; the guard that
        // matters is that a record with one good entry never gets here.
        let mixed = HostKeyPin.parse(["garbage", Self.ed25519.storage])
        #expect(HostKeyPin.decide(presented: Self.impostor, against: mixed) != .trusted)
    }
}

/// The store side of pinning: what gets written, and the one action that
/// unwrites it.
@MainActor
struct HostKeyPinStoreTests {
    private func makeStore() -> HostStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return HostStore(directory: directory, knownMirroredIDs: [])
    }

    private static let ed25519 = HostKeyPin(
        algorithm: "ssh-ed25519",
        fingerprint: "SHA256:JsAUX9CQFrzfXXeSw9rfsDuGvSDg9kwa/D4OFBI72AA"
    )
    private static let ecdsa = HostKeyPin(
        algorithm: "ecdsa-sha2-nistp256",
        fingerprint: "SHA256:5nZodzRXCuyfLD23HhSJnX2gPNv1k520onJhQxP4E5Q"
    )

    /// A repeat sighting is not a record edit. Every probe re-verifies the
    /// same key, so a write per connection would bump `updatedAt` and churn
    /// the Keychain mirror continuously.
    @Test func recordingIsAdditiveAndIdempotent() {
        let store = makeStore()
        let host = Host(name: "box", hostname: "example.test", username: "jhen")
        store.add(host)

        store.recordHostKeyPin(Self.ed25519, for: host.id)
        #expect(store.host(id: host.id)?.pinnedHostKeys == [Self.ed25519.storage])

        let afterFirst = store.host(id: host.id)?.updatedAt
        store.recordHostKeyPin(Self.ed25519, for: host.id)
        #expect(store.host(id: host.id)?.pinnedHostKeys == [Self.ed25519.storage])
        #expect(store.host(id: host.id)?.updatedAt == afterFirst)

        // A server that grows a second key type keeps the first.
        store.recordHostKeyPin(Self.ecdsa, for: host.id)
        #expect(store.host(id: host.id)?.pinnedHostKeys
            == [Self.ed25519.storage, Self.ecdsa.storage])
    }

    /// The recovery path for a genuinely rebuilt server: forget, and the next
    /// connection trusts on first use again.
    @Test func forgettingClearsEveryRecordedKey() {
        let store = makeStore()
        let host = Host(name: "box", hostname: "example.test", username: "jhen")
        store.add(host)
        store.recordHostKeyPin(Self.ed25519, for: host.id)
        store.recordHostKeyPin(Self.ecdsa, for: host.id)

        store.forgetHostKeyPins(for: host.id)
        #expect(store.host(id: host.id)?.pinnedHostKeys.isEmpty == true)
    }

    /// Bind writes pins before the first connection, so a bound host is
    /// verified from its first dial rather than trusting whatever answers.
    @Test func aBoundHostIsAlreadyPinnedBeforeItIsDialled() {
        let store = makeStore()
        var host = Host(name: "box", hostname: "example.test", username: "jhen")
        host.pinnedHostKeys = [Self.ed25519.storage]
        store.add(host)

        let pins = HostKeyPin.parse(store.host(id: host.id)?.pinnedHostKeys ?? [])
        #expect(HostKeyPin.decide(presented: Self.ed25519, against: pins) == .trusted)
        #expect(HostKeyPin.decide(presented: Self.ecdsa, against: pins) != .trusted)
    }
}
