import Foundation

/// Where an agent may point a browser that runs on the user's device. Pure.
///
/// Shipping (host route): pages load through the host, so `admitViaHost`
/// only gates the scheme and keeps `localhost` as the host's; what stays
/// on the device is loopback, which `loopbackPort` names for forwarding and
/// `loopbackRuleListJSON` guards.
///
/// DEBUG device route (`admit`, `admits`, `contentRuleListJSON`): the page
/// loads from the device's network, so a tab reaches the internet and THIS
/// host and no other private address — judged per main-frame navigation and
/// per subresource by content rules. Neither sees DNS: a public name that
/// resolves to a private address still loads, which is why the host route
/// ships.
enum AgentBrowserAddressPolicy {
    /// An agent-typed address → the URL the device will load, or why not.
    static func admit(_ input: String, host: Host) -> Result<ViewportOffer, AgentBrowserError> {
        guard let offer = ViewportOffer.fromTypedInput(input, host: host) else {
            return .failure(.badRequest("'\(input)' is not an http(s) address."))
        }
        guard admits(offer.url, host: host) else {
            return .failure(blockedError(offer.url))
        }
        return .success(offer)
    }

    /// The host route's admission: the page loads from the host's network,
    /// so every web address is the host's view — `localhost` stays the
    /// host's loopback (spelled `localhost`, no rewrite) and the device's
    /// LAN is unreachable by construction. Only the scheme gate applies.
    static func admitViaHost(_ input: String, host: Host) -> Result<ViewportOffer, AgentBrowserError> {
        // The typed-address path rewrites loopback to the host record's
        // address; a record whose address IS loopback keeps it as such.
        var asSeenByHost = host
        asSeenByHost.hostname = "localhost"
        guard let offer = ViewportOffer.fromTypedInput(input, host: asSeenByHost) else {
            return .failure(.badRequest("'\(input)' is not an http(s) address."))
        }
        return .success(offer)
    }

    /// The port a loopback web URL names (default 80/443), or nil when the
    /// URL is not loopback — the host route forwards exactly these.
    static func loopbackPort(_ url: URL) -> Int? {
        guard ViewportReach.classify(url) == .remoteLoopback,
              let scheme = url.scheme?.lowercased()
        else { return nil }
        return url.port ?? (scheme == "https" ? 443 : 80)
    }

    /// The per-navigation verdict for a URL already formed (link clicks,
    /// redirects, `location =`). Non-web schemes are the viewport gate's
    /// business and pass through here.
    static func admits(_ url: URL, host: Host) -> Bool {
        guard let reach = ViewportReach.classify(url) else { return true }
        switch reach {
        case .internet:
            return true
        case .lan, .remoteLoopback:
            // Loopback here is the DEVICE's own — admission already
            // rewrote the host's loopback to its address.
            return isThisHost(url, host: host)
        }
    }

    static func blockedError(_ url: URL) -> AgentBrowserError {
        .blocked(
            "\(url.host() ?? url.absoluteString) is a private address that is not this host — "
                + "agent tabs reach the internet and this machine only."
        )
    }

    private static func isThisHost(_ url: URL, host: Host) -> Bool {
        guard let target = url.host()?.lowercased() else { return false }
        let own = host.hostname.trimmingCharacters(in: .whitespaces).lowercased()
        return !own.isEmpty && (target == own || "[\(target)]" == own || target == "[\(own)]")
    }

    /// WebKit content-blocker rules: block private and loopback authorities
    /// for every resource type, then let this host back in. WebKit's
    /// url-filter has no alternation, hence one rule per range.
    static func contentRuleListJSON(host: Host) -> String {
        let authority = "^[a-z][a-z0-9+.-]*://"
        let privateAuthorities = [
            #"10\."#,
            #"192\.168\."#,
            #"172\.1[6-9]\."#,
            #"172\.2[0-9]\."#,
            #"172\.3[01]\."#,
            #"169\.254\."#,
            #"127\."#,
            #"0\.0\.0\.0"#,
            #"localhost\.?[:/]"#,
            #"[^/:]*\.localhost\.?[:/]"#,
            #"[^/:]*\.local\.?[:/]"#,
            // IPv6 literals: the ranges that matter (ULA, link-local,
            // loopback, mapped) cannot be told apart without alternation;
            // an agent has no need for a bracketed literal on the internet.
            #"\["#,
            // A single-label name resolves through the LAN's search domains.
            #"[^/:.]+\.?[:/]"#,
        ]
        var rules: [[String: Any]] = privateAuthorities.map { pattern in
            ["trigger": ["url-filter": authority + pattern], "action": ["type": "block"]]
        }
        var own = host.hostname.trimmingCharacters(in: .whitespaces).lowercased()
        // URLs bracket an IPv6 literal; a host record may not.
        if own.contains(":"), !own.hasPrefix("[") { own = "[\(own)]" }
        if !own.isEmpty {
            rules.append([
                "trigger": ["url-filter": authority + escapeRegex(own) + "[:/]"],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: options)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The host route's content rules. Pages load through the host, but a
    /// device never proxies loopback — so `localhost` reaches the PHONE,
    /// where other apps may listen. Every loopback authority is blocked
    /// except the ports forwarded to the host. Recompiled as forwards
    /// change; WebKit's url-filter has no alternation, hence one rule per
    /// spelling and scheme.
    static func loopbackRuleListJSON(forwardedPorts: [Int]) -> String {
        let anyScheme = "^[a-z][a-z0-9+.-]*://"
        let loopbackHosts = [
            #"localhost"#, #"127\.[0-9.]+"#, #"\[::1\]"#, #"[^/:]*\.localhost"#, #"0\.0\.0\.0"#,
        ]
        var rules: [[String: Any]] = loopbackHosts.map {
            ["trigger": ["url-filter": anyScheme + $0 + "\\.?[:/]"], "action": ["type": "block"]]
        }
        // Only the spellings a forward listens on (127.0.0.1 and ::1, which
        // `localhost` and `*.localhost` resolve to).
        let forwardedHosts = [#"localhost"#, #"127\.0\.0\.1"#, #"\[::1\]"#, #"[^/:]*\.localhost"#]
        for port in Set(forwardedPorts).sorted() {
            var prefixes = forwardedHosts.map { anyScheme + $0 + ":\(port)/" }
            let defaults: [Int: [String]] = [80: ["http", "ws"], 443: ["https", "wss"]]
            for scheme in defaults[port] ?? [] {
                prefixes += forwardedHosts.map { "^\(scheme)://" + $0 + "/" }
            }
            rules += prefixes.map { ["trigger": ["url-filter": $0], "action": ["type": "ignore-previous-rules"]] }
        }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: options)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func escapeRegex(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\^$.|?*+()[]{}".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
