import Foundation

/// Where a URL printed in a terminal pane actually lives, from this device's
/// point of view.
///
/// A pane runs on the host, so `localhost` printed there names the *host's*
/// loopback — an address this device cannot dial. A LAN address usually can
/// be. The viewport (the inline browser) therefore classifies every candidate
/// URL and shows the verdict instead of guessing silently; the one rewrite it
/// offers — remote loopback → the host's own dialled address — is performed
/// in the open, on the confirmation sheet, never behind the user's back.
///
/// Pure: no networking here, only address classification. The classification
/// is honest about what it cannot know — a LAN verdict means "this device may
/// reach it, network permitting", and the viewport's error panel says which
/// network the address lives on when it doesn't.
enum ViewportReach: Equatable {
    /// A public name or address — reachable from the device's own network.
    case internet
    /// RFC 1918 / link-local / mDNS `.local` / unqualified single-label —
    /// reachable when the device shares the host's network.
    case lan
    /// `localhost`, `127.*`, `0.0.0.0`, `::1`, `::` — the host's loopback,
    /// not the device's. Openable only via the rewrite below.
    case remoteLoopback

    /// Classifies an http(s) URL's authority. Non-web schemes return nil —
    /// the viewport renders web pages only (mailto stays a system handoff).
    static func classify(_ url: URL) -> ViewportReach? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host(), !rawHost.isEmpty
        else { return nil }
        let host = rawHost.lowercased()
        if isLoopback(host) { return .remoteLoopback }
        if isLAN(host) { return .lan }
        return .internet
    }

    /// The host's own loopback spellings, including `0.0.0.0`/`::` — a
    /// bind-all server banner prints those, and they name "this machine"
    /// exactly as loopback does. `*.localhost` resolves loopback per RFC 6761.
    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "0.0.0.0" || host == "::" || host == "::1" { return true }
        if let octets = ipv4Octets(host) { return octets[0] == 127 }
        return false
    }

    private static func isLAN(_ host: String) -> Bool {
        if let octets = ipv4Octets(host) {
            if octets[0] == 10 { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 172, (16...31).contains(octets[1]) { return true }
            if octets[0] == 169, octets[1] == 254 { return true }
            return false
        }
        // IPv6 unique-local (fc00::/7) and link-local (fe80::/10).
        if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") {
            return host.contains(":")
        }
        if host.hasSuffix(".local") { return true }
        // An unqualified single-label name resolves through the local
        // network's search domains — LAN by construction.
        if !host.contains(".") && !host.contains(":") { return true }
        return false
    }

    /// The four octets of a dotted-quad IPv4 literal, or nil for anything
    /// else (names, IPv6, malformed quads).
    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }
}

/// A confirmed viewport target: the URL exactly as the device will dial it,
/// plus the classification that admitted it. Built once, on the confirmation
/// sheet — the rail carries `reachTag` for the life of the page so the
/// verdict stays visible.
struct ViewportOffer: Equatable {
    /// The final URL — rewritten for remote loopback, verbatim otherwise.
    var url: URL
    var reach: ViewportReach
    /// The host's display name when `url` was rewritten to reach it.
    var viaHostName: String?

    /// The rail's compact verdict: NET / LAN / VIA DEVBOX.
    var reachTag: String {
        switch reach {
        case .internet: "NET"
        case .lan: "LAN"
        case .remoteLoopback: "VIA \((viaHostName ?? "HOST").uppercased())"
        }
    }

    /// Offers a viewport for a confirmed link, or nil when the link is not a
    /// web page (mailto, blocked, malformed — those keep today's answers).
    ///
    /// Remote loopback rewrites the authority to `host.hostname` — by
    /// definition the address this device already reaches the host by (it is
    /// what SSH dials) — keeping port, path, and query. That works when the
    /// server listens beyond loopback; a truly loopback-only server fails in
    /// the viewport's error panel, which says so. No host record → no rewrite
    /// → no offer.
    static func make(for link: TerminalLink, host: Host?) -> ViewportOffer? {
        guard let url = link.openableURL, let reach = ViewportReach.classify(url)
        else { return nil }
        switch reach {
        case .internet, .lan:
            return ViewportOffer(url: url, reach: reach, viaHostName: nil)
        case .remoteLoopback:
            guard let host, let rewritten = rewrite(url, toHost: host.hostname)
            else { return nil }
            return ViewportOffer(
                url: rewritten,
                reach: .remoteLoopback,
                viaHostName: host.name
            )
        }
    }

    private static func rewrite(_ url: URL, toHost hostname: String) -> URL? {
        let trimmed = hostname.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.host = trimmed
        return components.url
    }
}
