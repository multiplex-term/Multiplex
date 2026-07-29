import Foundation

/// Pure naming and address-election policy for saving a bound host, kept
/// beside the other bind models so tests reach it without the controller.
enum BindNaming {
    /// What a candidate row shows under the machine's name before a
    /// handshake has told us anything more.
    static func addressSummary(for payload: BindPayload) -> String {
        let port = payload.offline?.sshPort
        let suffix = port.map { "ssh :\($0)" } ?? "ssh"
        guard let addr = payload.addrs.first else { return suffix }
        return "\(addr) · \(suffix)"
    }

    /// Which address the saved host dials. The machine's own list is
    /// authoritative — where its *SSH* lives is not necessarily where its
    /// bind listener answered (a Bonjour resolve reports the interface the
    /// service was found on, while `mpx bind --addr` exists precisely so a
    /// machine behind NAT, a tunnel, or a port forward can name the address
    /// that actually works). So prefer the address we reached only when the
    /// machine also endorses it: that one is proven reachable *and* stated.
    static func hostname(
        for offer: BindOffer,
        connectedTo connected: String?,
        payload: BindPayload?
    ) -> String {
        let stated = offer.addrs.isEmpty ? (payload?.addrs ?? []) : offer.addrs
        if let connected, stated.contains(connected) { return connected }
        if let first = stated.first { return first }
        return connected ?? offer.name
    }

    /// Two machines can genuinely be called "devbox". Suffix rather than
    /// merge — a bind never edits a host the user already had.
    static func uniqueName(_ name: String, taken: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "host" : trimmed
        guard taken.contains(where: { $0.caseInsensitiveCompare(base) == .orderedSame })
        else { return base }
        var suffix = 2
        while taken.contains(where: {
            $0.caseInsensitiveCompare("\(base) \(suffix)") == .orderedSame
        }) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }
}
