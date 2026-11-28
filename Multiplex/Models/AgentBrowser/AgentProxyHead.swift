import Foundation

/// The agent browser's host route: WebKit sends an agent tab's traffic to an
/// HTTP proxy on the device's loopback, and every connection it asks for is
/// opened BY THE HOST over SSH (direct-tcpip). This parses what WebKit sends
/// the proxy — a `CONNECT host:port` tunnel request, for plain HTTP as much
/// as HTTPS (measured: Network.framework's CONNECT proxy tunnels both, and
/// keep-alive then happens inside the tunnel) — and checks the proxy
/// credential (any app on the device can reach loopback; only WebKit was
/// given the password). Pure.
enum AgentProxyHead {
    static let maxHeadBytes = 32 * 1024

    enum Outcome: Equatable {
        /// Keep reading.
        case incomplete
        case tooLarge
        case malformed
        /// No or wrong `Proxy-Authorization`; answer 407.
        case unauthorized
        /// Open a tunnel and answer `200 Connection Established`.
        case connect(host: String, port: Int)
        /// Anything but CONNECT (an absolute-form request): WebKit never
        /// sends one through this proxy; answer 501.
        case notTunnel
    }

    /// `credential` is the expected `user:password` (Basic). Returns the
    /// outcome and how many bytes of `bytes` the head took.
    static func parse(_ bytes: Data, credential: String) -> (outcome: Outcome, headLength: Int) {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = bytes.range(of: terminator) else {
            return (bytes.count > maxHeadBytes ? .tooLarge : .incomplete, 0)
        }
        let headLength = end.upperBound - bytes.startIndex
        guard headLength <= maxHeadBytes,
              let text = String(data: bytes[bytes.startIndex..<end.lowerBound], encoding: .utf8)
        else { return (.malformed, headLength) }
        guard let (method, target, headers) = requestHead(text) else { return (.malformed, headLength) }
        let expected = "Basic " + Data(credential.utf8).base64EncodedString()
        guard headers.contains(where: { $0.name.lowercased() == "proxy-authorization" && $0.value == expected })
        else { return (.unauthorized, headLength) }

        if method.uppercased() == "CONNECT" {
            guard let (host, port) = authority(target) else { return (.malformed, headLength) }
            return (.connect(host: host, port: port), headLength)
        }
        return (.notTunnel, headLength)
    }

    typealias Header = (name: String, value: String)

    /// Method, target, and headers of a head without its blank line.
    static func requestHead(_ text: String) -> (String, String, [Header])? {
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3 else { return nil }
        var headers: [Header] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers.append((
                String(line[..<colon]),
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            ))
        }
        return (String(requestLine[0]), String(requestLine[1]), headers)
    }

    /// `host:port` / `[v6]:port` → (host without brackets, port).
    static func authority(_ text: String) -> (String, Int)? {
        guard let colon = text.lastIndex(of: ":"),
              let port = Int(text[text.index(after: colon)...]), (1...65535).contains(port)
        else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        return (host, port)
    }

    static func response(_ status: String, extra: String = "", body: String = "") -> Data {
        let type = body.isEmpty ? "" : "Content-Type: text/plain\r\n"
        return Data(
            "HTTP/1.1 \(status)\r\n\(extra)\(type)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                .utf8
        )
    }

    static let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
    static let authenticationRequired = response(
        "407 Proxy Authentication Required",
        extra: "Proxy-Authenticate: Basic realm=\"multiplex\"\r\n"
    )
}

extension AgentProxyHead {
    /// The cookie that proves a forward's client is this app's WebKit.
    static let forwardCookieName = "__mpx_forward"

    enum ForwardVerdict: Equatable {
        case incomplete
        /// The first request carries this app's forward cookie: tunnel it.
        case allowed
        /// HTTP without the cookie — another app on the device, or a
        /// request the page made without credentials. Answer 403.
        case refused
        /// Not HTTP (TLS first bytes, garbage): nothing to check; close.
        case notHTTP
    }

    /// A loopback forward is reachable by every app on the device; only a
    /// connection whose first request carries the secret cookie (set
    /// HttpOnly in the agent tab's own cookie store) gets to the host.
    static func forwardVerdict(_ bytes: Data, secret: String) -> ForwardVerdict {
        guard let first = bytes.first else { return .incomplete }
        // A TLS record (0x16) or anything not starting like a method token.
        guard (0x41...0x5A).contains(first) else { return .notHTTP }
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            return bytes.count > maxHeadBytes ? .refused : .incomplete
        }
        guard end.upperBound - bytes.startIndex <= maxHeadBytes,
              let text = String(data: bytes[bytes.startIndex..<end.lowerBound], encoding: .utf8),
              let (_, _, headers) = requestHead(text)
        else { return .notHTTP }
        let expected = "\(forwardCookieName)=\(secret)"
        let presented = headers
            .filter { $0.name.lowercased() == "cookie" }
            .flatMap { $0.value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
        return presented.contains(expected) ? .allowed : .refused
    }

    static let forwardRefused = response(
        "403 Forbidden",
        body: "Multiplex forwards this port only for its agent tabs' own credentialed loads"
    )
}
