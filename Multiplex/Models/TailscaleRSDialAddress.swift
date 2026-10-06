import Foundation

/// Pure classification of a Host's address for the tailscale-rs dial path.
/// tailscale-rs has no MagicDNS: a literal 100.x/IPv6 is parsed straight to
/// a sockaddr, while a hostname must be resolved to a peer IP via
/// `ts_peer_ipv4_addr` before dialing. This type decides which, and
/// normalizes the string the C layer parses — the actual `ts_*` calls stay
/// in the actor, so this stays module-free and unit-testable.
enum TailscaleRSDialAddress {
    enum Target: Equatable {
        /// A literal address `ts_parse_ip` can consume directly.
        case literalIP(String)
        /// A tailnet peer name to resolve via `ts_peer_ipv4_addr`. Any
        /// surrounding brackets are stripped — peer lookup wants the bare
        /// name.
        case peerName(String)
    }

    static func classify(hostname: String) -> Target {
        let trimmed = hostname.trimmingCharacters(in: .whitespaces)
        let unbracketed: String
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
            unbracketed = String(trimmed.dropFirst().dropLast())
        } else {
            unbracketed = trimmed
        }

        if isIPv4(unbracketed) || isIPv6(unbracketed) {
            return .literalIP(unbracketed)
        }
        return .peerName(unbracketed)
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            part.count >= 1 && part.count <= 3
                && part.allSatisfy(\.isNumber)
                && (Int(part).map { $0 >= 0 && $0 <= 255 } ?? false)
        }
    }

    static func isIPv6(_ s: String) -> Bool {
        // Loose but sufficient to tell a v6 literal from a hostname: hex
        // groups and at least one colon, no characters a DNS/tailnet name
        // would carry. `ts_parse_ip` is the real validator downstream.
        guard s.contains(":") else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

enum TailscaleNodeHostname {
    static func format(deviceName: String) -> String {
        var sanitized = ""
        var needsSeparator = false

        for scalar in deviceName.lowercased().unicodeScalars {
            let isLowercaseLetter = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            if isLowercaseLetter || isDigit {
                if needsSeparator, !sanitized.isEmpty {
                    sanitized.append("-")
                }
                sanitized.unicodeScalars.append(scalar)
                needsSeparator = false
            } else if !sanitized.isEmpty {
                needsSeparator = true
            }
        }

        return sanitized.isEmpty ? "multiplex" : "multiplex-\(sanitized)"
    }
}
