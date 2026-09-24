import CryptoKit
import Foundation

/// One SSH host key identity as the app records it: the key's algorithm name
/// and OpenSSH's own `SHA256:<base64>` fingerprint of the key blob.
///
/// The string form is a cross-repo contract, not a local choice. `mpx bind`
/// renders exactly this shape into the OFFER (`hostinfo::host_key_fingerprints`),
/// the offline payload's raw 32-byte digest is rendered into it by
/// `BindPayload`, and it is what `Host.pinnedHostKeys` has stored since the
/// bind flow shipped. Parsing and rendering live here so the validator, the
/// bind flow, and Host Settings cannot disagree about it.
struct HostKeyPin: Equatable, Sendable {
    /// The SSH algorithm name exactly as it appears at the head of the key
    /// blob: `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`, …
    var algorithm: String
    /// OpenSSH's display form — the `SHA256:` prefix, base64, no padding.
    var fingerprint: String

    /// The `Host.pinnedHostKeys` form.
    var storage: String { "\(algorithm) \(fingerprint)" }

    init(algorithm: String, fingerprint: String) {
        self.algorithm = algorithm
        self.fingerprint = fingerprint
    }

    /// Reads a stored/OFFER-delivered entry. Anything that isn't
    /// `"<algorithm> SHA256:<base64>"` is rejected rather than coerced: a pin
    /// the app cannot parse must not silently weaken into "no pin recorded".
    init?(storage: String) {
        let parts = storage.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let (algorithm, fingerprint) = (parts[0], parts[1])
        guard !algorithm.isEmpty, fingerprint.hasPrefix("SHA256:"),
              fingerprint.count > "SHA256:".count
        else { return nil }
        self.algorithm = algorithm
        self.fingerprint = fingerprint
    }

    /// Derives the pin from an SSH public key blob — the same bytes that ride
    /// base64-encoded in a `.pub` file, which is what OpenSSH hashes for
    /// `SHA256:` and what `NIOSSHPublicKey.write(to:)` emits. The blob leads
    /// with its own algorithm name as an SSH string (`uint32` length ‖ bytes),
    /// so the name is read back out of the bytes rather than asked of NIOSSH,
    /// whose `keyPrefix` is internal — that keeps this vendor-patch-free.
    init?(keyBlob: Data) {
        let bytes = [UInt8](keyBlob)
        guard bytes.count > 4 else { return nil }
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        // A peer-supplied length: bound it against the blob before slicing.
        guard length > 0, length <= UInt32(bytes.count - 4),
              let algorithm = String(bytes: bytes[4..<(4 + Int(length))], encoding: .utf8),
              !algorithm.isEmpty
        else { return nil }
        self.algorithm = algorithm
        self.fingerprint = "SHA256:" + Data(SHA256.hash(data: keyBlob))
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    /// Stands in for the algorithm when a person supplied only a fingerprint
    /// — a provider console prints `SHA256:…` and nothing else. Never
    /// collides with a real SSH algorithm name, which is a lowercase
    /// identifier and never contains `*`.
    static let anyAlgorithm = "*"

    /// Reads what a person can actually get hold of and paste, rather than
    /// demanding one shape. Whitespace-tolerant; nil when nothing usable is
    /// in the text.
    ///
    /// Four sources cover the realistic ways someone learns a host key
    /// out of band:
    ///
    ///   - an OpenSSH public line, from `cat /etc/ssh/ssh_host_*_key.pub` or
    ///     `ssh-keyscan host` (which prefixes the hostname) — the exact path,
    ///     since the fingerprint is computed here from the key itself;
    ///   - this app's own stored form, so a pin can be copied between hosts;
    ///   - `ssh-keygen -lf …` output, `256 SHA256:… comment (ED25519)`;
    ///   - a bare `SHA256:…`, which is what most provider consoles show.
    ///
    /// The last two carry no SSH algorithm name — `(ED25519)` is a label, not
    /// the `ssh-ed25519` the wire uses — so they pin `anyAlgorithm`. Nothing
    /// is lost: the digest covers the whole blob, whose first field is the
    /// algorithm name, so matching the fingerprint settles the type too.
    init?(userInput: String) {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)

        // An OpenSSH public line: the algorithm followed by base64 key data.
        // `ssh-keyscan` puts the host first, so try each adjacent pair.
        for index in fields.indices.dropLast() {
            let (algorithm, encoded) = (fields[index], fields[index + 1])
            guard algorithm.contains("-"), !algorithm.hasPrefix("SHA256:"),
                  let blob = Data(base64Encoded: encoded),
                  let pin = HostKeyPin(keyBlob: blob),
                  pin.algorithm == algorithm
            else { continue }
            self = pin
            return
        }

        // Otherwise the text must carry a SHA256 digest somewhere.
        guard let digest = fields.first(where: { $0.hasPrefix("SHA256:") }),
              digest.count > "SHA256:".count
        else { return nil }
        // `<algorithm> SHA256:…` — this app's stored form.
        if let index = fields.firstIndex(of: digest), index > 0,
           fields[index - 1].contains("-") {
            self.init(algorithm: fields[index - 1], fingerprint: digest)
            return
        }
        self.init(algorithm: Self.anyAlgorithm, fingerprint: digest)
    }

    /// Parses a `Host.pinnedHostKeys` array, dropping entries that don't
    /// parse. An unparsable entry is not a reason to connect unpinned — as
    /// long as one entry survives the host stays pinned, and a host whose
    /// every entry is malformed refuses rather than falls back, because
    /// `decide` only trusts an empty set as "nothing recorded yet".
    static func parse(_ stored: [String]) -> [HostKeyPin] {
        stored.compactMap(HostKeyPin.init(storage:))
    }
}

/// What to do with the key a server just presented.
enum HostKeyDecision: Equatable, Sendable {
    /// The presented key is one this host already had recorded.
    case trusted
    /// Nothing is recorded for this host: trust on first use and write this
    /// down, so every later connection is checked against it.
    case learn(HostKeyPin)
    /// Fail the connection. Never a prompt: the deck probes every host
    /// concurrently at launch, and a validator that blocked on UI would hold
    /// N SSH handshakes open behind a modal.
    case refused(HostKeyRefusal)
}

/// Why a key was refused. Both outcomes fail closed; they are separated so
/// the message can be, because crying "possible attack" at a server that
/// merely grew a second key type teaches people to click through the one
/// warning that matters.
enum HostKeyRefusal: Equatable, Sendable {
    /// This host has a pin for that algorithm and the key underneath it
    /// changed. The serious one.
    case changed(expected: HostKeyPin, presented: HostKeyPin)
    /// The host offered an algorithm none of its pins cover — a reinstalled
    /// or reconfigured server, or an interception using a key type the real
    /// host never had.
    case unrecognizedAlgorithm(presented: HostKeyPin, pinned: [HostKeyPin])

    var presented: HostKeyPin {
        switch self {
        case .changed(_, let presented): presented
        case .unrecognizedAlgorithm(let presented, _): presented
        }
    }
}

extension HostKeyPin {
    /// The whole trust rule, kept pure so it is testable without a server.
    ///
    /// An empty pin set is the only path that trusts blindly, and it is also
    /// the only path that writes — which is what makes the *second*
    /// connection to a host checked. `mpx bind` hosts skip it entirely: the
    /// OFFER records every one of the machine's key fingerprints before the
    /// app has dialled it once, so their first connection is already verified
    /// against a set the machine itself vouched for.
    static func decide(presented: HostKeyPin, against pins: [HostKeyPin]) -> HostKeyDecision {
        guard !pins.isEmpty else { return .learn(presented) }
        // The fingerprint alone is the identity. SHA-256 is taken over the
        // whole key blob, whose first field is the algorithm name, so a digest
        // match settles the type as well — comparing the digest rather than
        // the pair is identical for a pin that names its algorithm, and is
        // what lets a person pin the bare `SHA256:…` a console showed them.
        if pins.contains(where: { $0.fingerprint == presented.fingerprint }) { return .trusted }
        if let expected = pins.first(where: {
            $0.algorithm == presented.algorithm || $0.algorithm == anyAlgorithm
        }) {
            return .refused(.changed(expected: expected, presented: presented))
        }
        return .refused(.unrecognizedAlgorithm(presented: presented, pinned: pins))
    }
}
