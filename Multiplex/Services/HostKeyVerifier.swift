import Foundation
import NIOCore
import NIOSSH
import os

/// Why a handshake was stopped at the host key.
enum HostKeyVerificationFailure: Error {
    /// The server presented something that isn't a well-formed key blob.
    case unreadableKey
    case refused(HostKeyRefusal)
}

/// Records what a single connection attempt decided about the server's key.
/// NIO fails the handshake with our error, but the error travels through the
/// channel pipeline and can reach `SSHClient.connect`'s caller wrapped in a
/// NIO type — so the verdict is also written here, where `SSHConnection` can
/// read it back without depending on how the failure was boxed.
final class HostKeyOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HostKeyRefusal?

    var refusal: HostKeyRefusal? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    fileprivate func record(_ refusal: HostKeyRefusal) {
        lock.lock()
        stored = refusal
        lock.unlock()
    }
}

/// Checks the key a server presents against what the app has recorded for
/// that host, and writes the key down the first time it sees one.
///
/// Runs on a NIO event loop, so it decides and returns — it never prompts.
/// The deck probes every host concurrently at launch on a ~5 s budget, and a
/// validator that awaited a modal would hold that many SSH handshakes open
/// behind it. A key that doesn't check out fails the connection and surfaces
/// as the host's error state, where the user can act on it out of band.
struct HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let hostID: UUID
    let pins: [HostKeyPin]
    let outcome: HostKeyOutcome
    let learn: @Sendable (UUID, HostKeyPin) -> Void

    private static let log = Logger(
        subsystem: "app.multiplexterm.multiplex", category: "hostkey"
    )

    func validateHostKey(
        hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>
    ) {
        // `write(to:)` emits the same blob that rides base64-encoded in a
        // `.pub` file, which is exactly what OpenSSH hashes for `SHA256:`.
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        hostKey.write(to: &buffer)
        guard let presented = HostKeyPin(keyBlob: Data(buffer.readableBytesView)) else {
            validationCompletePromise.fail(HostKeyVerificationFailure.unreadableKey)
            return
        }

        switch HostKeyPin.decide(presented: presented, against: pins) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .learn(let pin):
            Self.log.debug("host key learned on first use: \(pin.storage, privacy: .public)")
            learn(hostID, pin)
            validationCompletePromise.succeed(())
        case .refused(let refusal):
            Self.log.error(
                "host key refused: \(refusal.presented.storage, privacy: .public)"
            )
            outcome.record(refusal)
            validationCompletePromise.fail(HostKeyVerificationFailure.refused(refusal))
        }
    }
}

/// Where a first-use host key goes to be remembered.
///
/// The validator runs off the main actor inside NIO, while the host record
/// lives in `HostStore` on the main actor, and eight call sites build an
/// `SSHConnection` without either one in reach. So the app installs one sink
/// at startup and everything else calls `learn`. Mirrors
/// `SSHKeyPassphraseSession`'s lock-behind-an-enum shape.
enum HostKeyTrust {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var sink: (@Sendable (UUID, HostKeyPin) -> Void)?
    }

    private static let storage = Storage()

    /// Called once, where `HostStore` is created.
    static func install(_ sink: @escaping @Sendable (UUID, HostKeyPin) -> Void) {
        storage.lock.lock()
        storage.sink = sink
        storage.lock.unlock()
    }

    static func learn(hostID: UUID, pin: HostKeyPin) {
        storage.lock.lock()
        let sink = storage.sink
        storage.lock.unlock()
        sink?(hostID, pin)
    }

    /// The validator for one connection attempt, plus the box its verdict
    /// lands in. A host with no sink installed still verifies against what it
    /// has recorded — it just cannot learn anything new, which is the safe
    /// direction for a test or a harness that never wired one up.
    static func verifier(for host: Host) -> (HostKeyVerifier, HostKeyOutcome) {
        let outcome = HostKeyOutcome()
        let verifier = HostKeyVerifier(
            hostID: host.id,
            pins: HostKeyPin.parse(host.pinnedHostKeys),
            outcome: outcome,
            learn: { hostID, pin in HostKeyTrust.learn(hostID: hostID, pin: pin) }
        )
        return (verifier, outcome)
    }
}
