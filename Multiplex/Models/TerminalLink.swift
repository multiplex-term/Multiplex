import Foundation

/// A link resolved from terminal content — either an explicit OSC 8 hyperlink
/// target or a URL SwiftTerm detected in the rendered text.
///
/// Terminal bytes are attacker-controlled in the ordinary case, not just the
/// adversarial one: an SSH host's MOTD, a build log, a `cat`-ed README, or a
/// CLI agent's tool output all print whatever they like, and an OSC 8
/// hyperlink's visible label is independent of its target. Two consequences
/// shape this type:
///
/// - **The allowlist is the gate.** Only schemes the system can open
///   harmlessly resolve to `.openable`. Everything else is reported, not
///   opened — including `multiplex:`, which `ExternalActionRouter` would
///   otherwise accept as a widget-grade command (`open?host=…&action=agent&
///   prompt=…`), letting pane output launch an agent on another host.
/// - **The target is what gets shown.** The confirmation surface renders
///   `raw` and `host` from this model, never the text the user tapped, so a
///   label that reads `docs.example.com` cannot hide a different destination.
struct TerminalLink: Equatable, Identifiable {
    enum Kind: Equatable {
        /// An allowlisted scheme that parsed into a URL the system can open.
        case openable(URL)
        /// A well-formed link whose scheme Multiplex will not hand to the
        /// system. Carries the lowercased scheme so the sheet can name it.
        case blockedScheme(String)
        /// An allowlisted scheme that did not survive parsing — no host on an
        /// http(s) URL, no address on a `mailto:`, or characters no encoding
        /// rescues. Offered for copy, never opened.
        case malformed
    }

    /// The resolved target, trimmed. This is the string the user is shown.
    let raw: String
    let kind: Kind

    var id: String { raw }

    /// The authority an `.openable` link actually resolves to. Shown on its
    /// own line because userinfo hides the real destination inside an
    /// otherwise ordinary-looking URL: `https://github.com@evil.example/x`
    /// reads as GitHub until the host is spelled out separately.
    var host: String? {
        guard case .openable(let url) = kind else { return nil }
        return url.host()
    }

    var openableURL: URL? {
        guard case .openable(let url) = kind else { return nil }
        return url
    }
}

extension TerminalLink {
    /// Schemes Multiplex hands to the system. Deliberately short: every
    /// addition is a new way for remote output to reach another app. `file:`
    /// and `ssh:` are excluded because a link naming a *local* resource, from
    /// a *remote* host, is meaningless at best; `tel:` because a tap that
    /// starts dialling from a build log is not a trade worth making.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Longer than any URL worth confirming, and a bound on what the sheet
    /// has to render. Real targets sit far below it.
    static let maxLength = 2048

    /// Classifies a raw activation target. Returns nil when the match is not
    /// a link Multiplex should say anything about — a filesystem path, a bare
    /// word, or bytes that cannot be a URL. `SwiftTermView` declines those, so
    /// the gesture falls through to normal selection handling.
    ///
    /// Pure: no URL is opened here and nothing is logged.
    static func resolve(_ target: String) -> TerminalLink? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        // Controls and line breaks are never part of a legitimate target, and
        // a target that embeds them is trying to change how it renders. OSC 8
        // payloads reach us as raw remote bytes, so this is the entry check.
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.newlines.contains($0)
        }) else { return nil }
        // A URI has no raw spaces, and interior whitespace is what separates
        // an actual target from ordinary prose that happens to carry a colon:
        // `warning: unused variable` otherwise classifies as a `warning:`
        // link. Implicit detection's path branches do match spaces; those
        // belong to `TerminalPathTarget`, never here.
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        let scheme = scheme(of: trimmed)
        if let scheme, allowedSchemes.contains(scheme) {
            guard let url = url(from: trimmed, scheme: scheme) else {
                return TerminalLink(raw: trimmed, kind: .malformed)
            }
            return TerminalLink(raw: trimmed, kind: .openable(url))
        }
        // No allowlisted scheme: before declining (or reporting a blocked
        // scheme), try the schemeless reading — `example.com/docs` printed
        // in a pane is a URL to a person, but implicit detection hands it
        // over through a *path* branch, and `example.com:8080/x` parses as
        // scheme "example.com" under RFC 3986 (dots are scheme characters).
        if let link = schemelessLink(from: trimmed) { return link }
        // A real scheme that is neither allowlisted nor a host:port shape
        // keeps today's answer: reported, never opened. A *dotted* scheme
        // candidate is a hostname that failed the reading above, not a
        // scheme anyone registered — reporting it as one ("A example.com:
        // link…") is nonsense, so it declines instead.
        if let scheme, !scheme.contains(".") {
            return TerminalLink(raw: trimmed, kind: .blockedScheme(scheme))
        }
        // A path branch match (`./src/main.swift`, `/etc/hosts`, `~/notes`)
        // or a bare token — ordinary terminal output, not a link.
        return nil
    }

    /// RFC 3986 scheme: an ASCII letter followed by letters, digits, `+`,
    /// `-`, or `.`, up to the first colon. Hand-parsed rather than asking
    /// `URL` — classification must not depend on how lenient the parser feels
    /// about the rest of the string.
    private static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[text.startIndex..<colon]
        guard let first = candidate.first, first.isASCII, first.isLetter else {
            return nil
        }
        guard candidate.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }) else {
            return nil
        }
        return candidate.lowercased()
    }

    /// The schemeless reading of a target: `example.com/docs`,
    /// `www.example.com`, `docs.rs/serde`, `192.168.1.5:3000/app`. Implicit
    /// detection's bare-relative *path* branch is what hands these over (its
    /// dotted lookahead guarantees a dot), so without this they confirmed as
    /// files instead of links.
    ///
    /// The gate is deliberately narrow, because everything here is also a
    /// legal filename:
    /// - The authority must be domain-shaped — ≥2 ASCII labels, the last one
    ///   alphabetic and ≥2 chars (TLD-shaped) — or a dotted-quad IPv4.
    /// - There must be URL evidence beyond the dot: a path/query/fragment
    ///   (`/`, `?`, `#`) or a `www.` prefix. A bare dotted word stays what it
    ///   is — `setup.md` in a markdown link is a sibling document, not a
    ///   Moldovan site, and the file viewer's relative navigation depends on
    ///   that staying declined.
    /// - Userinfo is rejected outright: `github.com@evil.example/x` is the
    ///   exact lie the host line exists to expose, and a schemeless target
    ///   has no business carrying credentials.
    ///
    /// The scheme is defaulted the way the viewport's typed input does it:
    /// `http` where the address lives on a LAN or loopback (dev servers are
    /// cleartext) and `https` everywhere else.
    private static func schemelessLink(from text: String) -> TerminalLink? {
        var candidate = text
        // Path-branch matches carry sentence punctuation the URL branch's
        // own guard would have stripped ("visit example.com/foo.").
        while let last = candidate.last, ".,;".contains(last) {
            candidate.removeLast()
        }
        guard !candidate.isEmpty else { return nil }
        let restStart = candidate.firstIndex(where: { "/?#".contains($0) })
            ?? candidate.endIndex
        let authority = candidate[candidate.startIndex..<restStart]
        guard !authority.isEmpty, !authority.contains("@") else { return nil }

        var host = authority
        if let colon = authority.firstIndex(of: ":") {
            let port = authority[authority.index(after: colon)...]
            guard (1...5).contains(port.count),
                  port.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(port), (1...65535).contains(value)
            else { return nil }
            host = authority[authority.startIndex..<colon]
        }
        let lowered = host.lowercased()
        guard restStart < candidate.endIndex || lowered.hasPrefix("www.") else {
            return nil
        }
        guard isDomainShaped(lowered) || isIPv4(lowered) else { return nil }

        guard let probe = URL(string: "http://" + candidate, encodingInvalidCharacters: true),
              let reach = ViewportReach.classify(probe)
        else { return nil }
        let prefix = reach == .internet ? "https://" : "http://"
        guard let url = URL(string: prefix + candidate, encodingInvalidCharacters: true),
              let urlHost = url.host(), !urlHost.isEmpty
        else { return nil }
        return TerminalLink(raw: candidate, kind: .openable(url))
    }

    /// ≥2 DNS-shaped ASCII labels with an alphabetic, ≥2-char final label.
    /// ASCII only on purpose: a non-ASCII first segment in terminal output
    /// is far more likely a filename than an IDN worth guessing at.
    private static func isDomainShaped(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1...63).contains(label.count),
                  label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return false }
        }
        guard let tld = labels.last else { return false }
        return tld.count >= 2 && tld.allSatisfy { $0.isASCII && $0.isLetter }
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part)
            else { return false }
            return (0...255).contains(value)
        }
    }

    private static func url(from text: String, scheme: String) -> URL? {
        // iOS 17 made `URL(string:)` reject invalid characters outright;
        // encoding them keeps a URL with a stray brace or a non-ASCII path
        // usable while still failing on genuine nonsense.
        guard let url = URL(string: text, encodingInvalidCharacters: true) else {
            return nil
        }
        switch scheme {
        case "http", "https":
            // A hostless http URL cannot be opened and is a strong sign the
            // text was never a link (`http://` alone, `https:///path`).
            guard let host = url.host(), !host.isEmpty else { return nil }
            return url
        case "mailto":
            // Everything after the scheme is the address list; empty means
            // there is nothing to mail.
            let address = text.dropFirst(scheme.count + 1)
            guard !address.isEmpty else { return nil }
            return url
        default:
            return url
        }
    }
}
