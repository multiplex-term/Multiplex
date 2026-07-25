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
        // link. Implicit detection's path branches do match spaces, but those
        // have no scheme and are declined below anyway.
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        // No scheme means implicit detection matched a path branch
        // (`./src/main.swift`, `/etc/hosts`, `~/notes`) or a bare token.
        // Those are ordinary terminal output, not links.
        guard let scheme = scheme(of: trimmed) else { return nil }
        guard allowedSchemes.contains(scheme) else {
            return TerminalLink(raw: trimmed, kind: .blockedScheme(scheme))
        }
        guard let url = url(from: trimmed, scheme: scheme) else {
            return TerminalLink(raw: trimmed, kind: .malformed)
        }
        return TerminalLink(raw: trimmed, kind: .openable(url))
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
