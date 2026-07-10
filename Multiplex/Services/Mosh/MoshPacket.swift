import Foundation

/// The mosh datagram layer for one session: seals/opens UDP payloads,
/// tracks nonce sequence numbers in both directions, echoes peer
/// timestamps, and keeps the RTT estimate the retransmit timers feed on.
///
/// Wire layout (everything big-endian):
///   datagram  = direction<<63|seq (8B) ‖ OCB3(key, nonce, plaintext) ‖ tag (16B)
///   nonce     = 4 zero bytes ‖ the same 8 prefix bytes
///   plaintext = timestamp (2B) ‖ timestamp_reply (2B) ‖ payload
struct MoshPacketLayer {
    enum Direction {
        case client // sends TO_SERVER (bit clear), receives TO_CLIENT
        case server // the inverse; exists for the unit tests' fake server

        fileprivate var sendBit: UInt64 { self == .server ? 1 << 63 : 0 }
        fileprivate var receiveBit: UInt64 { self == .server ? 0 : 1 << 63 }
    }

    /// The "no timestamp" sentinel.
    private static let noTimestamp: UInt16 = 0xFFFF
    private static let sequenceMask: UInt64 = ~(UInt64(1) << 63)

    private let aead: MoshAEAD
    private let direction: Direction

    private var nextSequence: UInt64 = 0
    private var expectedReceiverSequence: UInt64 = 0

    /// Peer timestamp waiting to be echoed back, and when it arrived.
    private var savedTimestamp: UInt16?
    private var savedTimestampArrival: UInt64 = 0

    /// RFC 6298-shaped smoothed RTT, seeded like mosh (1000 ± 500 ms).
    private(set) var srtt: Double = 1000
    private(set) var rttvar: Double = 500
    private var haveRTTSample = false

    init(key: MoshKey, direction: Direction = .client) throws {
        aead = try MoshAEAD(key: key.data)
        self.direction = direction
    }

    /// Retransmission timeout in ms: SRTT + 4·RTTVAR clamped to [50, 1000].
    var rto: UInt64 {
        UInt64((srtt + 4 * rttvar).rounded(.up).clamped(to: 50 ... 1000))
    }

    // MARK: - Seal

    mutating func seal(_ payload: Data, now: UInt64) -> Data {
        var reply = Self.noTimestamp
        if let saved = savedTimestamp, now - savedTimestampArrival < 1000 {
            // Echo advanced by hold time; each received timestamp is
            // replied to at most once.
            reply = saved &+ UInt16(truncatingIfNeeded: now - savedTimestampArrival)
            savedTimestamp = nil
        }

        let nonceValue = direction.sendBit | (nextSequence & Self.sequenceMask)
        nextSequence += 1

        var plaintext = Data()
        var tsBE = Self.timestamp16(now).bigEndian
        withUnsafeBytes(of: &tsBE) { plaintext.append(contentsOf: $0) }
        var replyBE = reply.bigEndian
        withUnsafeBytes(of: &replyBE) { plaintext.append(contentsOf: $0) }
        plaintext.append(payload)

        var out = Data()
        var prefixBE = nonceValue.bigEndian
        withUnsafeBytes(of: &prefixBE) { out.append(contentsOf: $0) }
        out.append(aead.seal(plaintext, nonce: Self.nonceBytes(nonceValue)))
        return out
    }

    // MARK: - Open

    struct Opened {
        var payload: Data
        /// False for replayed/reordered datagrams: the payload is still
        /// processed (state sync is idempotent) but timestamps and liveness
        /// must not trust it.
        var isNew: Bool
    }

    mutating func open(_ datagram: Data, now: UInt64) -> Opened? {
        // 8 nonce + 16 tag + 4 timestamps is the smallest honest packet.
        guard datagram.count >= 28 else { return nil }
        let bytes = [UInt8](datagram)
        let nonceValue = bytes[0 ..< 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }

        // Reject our own reflected packets before paying for the AEAD.
        guard nonceValue & ~Self.sequenceMask == direction.receiveBit else { return nil }

        guard let plaintext = aead.open(
            Data(bytes[8...]), nonce: Self.nonceBytes(nonceValue)
        ), plaintext.count >= 4 else { return nil }

        let plain = [UInt8](plaintext)
        let timestamp = UInt16(plain[0]) << 8 | UInt16(plain[1])
        let reply = UInt16(plain[2]) << 8 | UInt16(plain[3])

        let sequence = nonceValue & Self.sequenceMask
        let isNew = sequence >= expectedReceiverSequence
        if isNew {
            expectedReceiverSequence = sequence + 1
            if timestamp != Self.noTimestamp {
                savedTimestamp = timestamp
                savedTimestampArrival = now
            }
            if reply != Self.noTimestamp {
                let sample = Double(Self.timestamp16(now) &- reply)
                // Ignore wild samples (peer was stopped), like mosh.
                if sample < 5000 {
                    if haveRTTSample {
                        rttvar = 0.75 * rttvar + 0.25 * abs(srtt - sample)
                        srtt = 0.875 * srtt + 0.125 * sample
                    } else {
                        srtt = sample
                        rttvar = sample / 2
                        haveRTTSample = true
                    }
                }
            }
        }

        return Opened(payload: Data(plain[4...]), isNew: isNew)
    }

    // MARK: - Helpers

    private static func nonceBytes(_ value: UInt64) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 12)
        for i in 0 ..< 8 { nonce[4 + i] = UInt8(truncatingIfNeeded: value >> (56 - 8 * i)) }
        return nonce
    }

    /// Milliseconds mod 2^16, dodging the 0xFFFF "none" sentinel.
    static func timestamp16(_ now: UInt64) -> UInt16 {
        let ts = UInt16(truncatingIfNeeded: now)
        return ts == noTimestamp ? 0 : ts
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
