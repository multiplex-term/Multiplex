import XCTest
@testable import Multiplex

final class ViewportReachTests: XCTestCase {
    private func classify(_ target: String) -> ViewportReach? {
        guard let url = URL(string: target) else {
            XCTFail("unparseable test URL \(target)")
            return nil
        }
        return ViewportReach.classify(url)
    }

    // MARK: Classification

    func testPublicAddressesAreInternet() {
        for target in [
            "https://vercel.com/docs",
            "http://example.com",
            "https://93.184.216.34/status",
            "http://intranet.example.internal:8080/",
        ] {
            XCTAssertEqual(classify(target), .internet, target)
        }
    }

    func testPrivateRangesAreLAN() {
        for target in [
            "http://192.168.1.68:5173/",
            "http://10.0.0.5/",
            "http://172.16.0.1:3000/",
            "http://172.31.255.254/",
            "http://169.254.10.10/",
            "http://devbox.local:8080/",
            "http://[fe80::1]:9090/",
            "http://[fd12:3456::1]/",
        ] {
            XCTAssertEqual(classify(target), .lan, target)
        }
    }

    func testIPv4MappedPrivateAddressesKeepTheirIPv4Reach() {
        XCTAssertEqual(classify("http://[::ffff:192.168.1.68]:5173/"), .lan)
        XCTAssertEqual(classify("http://[::ffff:10.0.0.5]/"), .lan)
        XCTAssertEqual(classify("http://[::ffff:127.0.0.1]:8080/"), .remoteLoopback)
        XCTAssertEqual(classify("http://[::ffff:8.8.8.8]/"), .internet)
    }

    func testUnqualifiedSingleLabelIsLAN() {
        // A bare machine name resolves through the local network's search
        // domains — LAN by construction.
        XCTAssertEqual(classify("http://devbox:3000/"), .lan)
    }

    func test172RangeBoundariesAreExact() {
        // Only 172.16/12 is private; its dotted neighbors are internet.
        XCTAssertEqual(classify("http://172.15.0.1/"), .internet)
        XCTAssertEqual(classify("http://172.32.0.1/"), .internet)
    }

    func testLoopbackSpellings() {
        for target in [
            "http://localhost:5173/",
            "http://sub.localhost/",
            "http://127.0.0.1:9090/metrics",
            "http://127.5.3.1/",
            "http://0.0.0.0:3000/",
            "http://[::1]:8080/",
        ] {
            XCTAssertEqual(classify(target), .remoteLoopback, target)
        }
    }

    func testNonWebSchemesDoNotClassify() {
        XCTAssertNil(classify("mailto:dev@example.com"))
        XCTAssertNil(classify("file:///etc/hosts"))
        XCTAssertNil(classify("multiplex://open?host=devbox"))
    }

    // MARK: Offers

    private var devbox: Host {
        Host(name: "devbox", hostname: "100.84.2.19", username: "demo")
    }

    private func offer(_ target: String, host: Host?) -> ViewportOffer? {
        guard let link = TerminalLink.resolve(target) else {
            XCTFail("expected \(target) to resolve")
            return nil
        }
        return ViewportOffer.make(for: link, host: host)
    }

    func testDirectAddressesPassThroughUnchanged() {
        let lan = offer("http://192.168.1.68:5173/", host: devbox)
        XCTAssertEqual(lan?.url.absoluteString, "http://192.168.1.68:5173/")
        XCTAssertEqual(lan?.reach, .lan)
        XCTAssertNil(lan?.viaHostName)
        XCTAssertEqual(lan?.reachTag, "LAN")

        let net = offer("https://vercel.com/docs", host: nil)
        XCTAssertEqual(net?.url.absoluteString, "https://vercel.com/docs")
        XCTAssertEqual(net?.reach, .internet)
        XCTAssertEqual(net?.reachTag, "NET")
    }

    func testLoopbackRewritesToTheHostsDialledAddress() {
        let rewritten = offer("http://localhost:5173/app?tab=1", host: devbox)
        XCTAssertEqual(
            rewritten?.url.absoluteString,
            "http://100.84.2.19:5173/app?tab=1"
        )
        XCTAssertEqual(rewritten?.reach, .remoteLoopback)
        XCTAssertEqual(rewritten?.viaHostName, "devbox")
        XCTAssertEqual(rewritten?.reachTag, "VIA DEVBOX")
    }

    func testLoopbackRewriteKeepsSchemeAndOmittedPort() {
        let rewritten = offer("https://127.0.0.1/metrics", host: devbox)
        XCTAssertEqual(
            rewritten?.url.absoluteString,
            "https://100.84.2.19/metrics"
        )
    }

    func testLoopbackWithoutAHostRecordIsNotOffered() {
        XCTAssertNil(offer("http://localhost:5173/", host: nil))
    }

    func testNonWebLinksAreNotOffered() {
        XCTAssertNil(offer("mailto:dev@example.com", host: devbox))
    }

    func testBlockedAndMalformedLinksAreNotOffered() {
        for target in ["file:///etc/shadow", "ssh://root@evil.example"] {
            guard let link = TerminalLink.resolve(target) else {
                XCTFail("expected \(target) to resolve as blocked")
                continue
            }
            XCTAssertNil(ViewportOffer.make(for: link, host: devbox), target)
        }
    }

    // MARK: Typed rail input

    private func typed(_ input: String, host: Host? = nil) -> ViewportOffer? {
        ViewportOffer.fromTypedInput(input, host: host)
    }

    func testTypedInputDefaultsSchemeByReach() {
        // Dev servers are cleartext — LAN/loopback default http; names on
        // the internet default https.
        XCTAssertEqual(
            typed("192.168.1.68:3000")?.url.absoluteString,
            "http://192.168.1.68:3000"
        )
        XCTAssertEqual(
            typed("devbox:8080")?.url.absoluteString,
            "http://devbox:8080"
        )
        XCTAssertEqual(
            typed("vercel.com/docs")?.url.absoluteString,
            "https://vercel.com/docs"
        )
    }

    func testTypedInputRewritesLoopbackViaTheHost() {
        let offer = typed("localhost:5173", host: devbox)
        XCTAssertEqual(offer?.url.absoluteString, "http://100.84.2.19:5173")
        XCTAssertEqual(offer?.reach, .remoteLoopback)
        XCTAssertEqual(offer?.viaHostName, "devbox")
        // Without a host record there is nothing to rewrite via.
        XCTAssertNil(typed("localhost:5173"))
    }

    func testTypedInputKeepsAnExplicitWebScheme() {
        XCTAssertEqual(
            typed("https://192.168.1.68/x")?.url.absoluteString,
            "https://192.168.1.68/x"
        )
        XCTAssertEqual(
            typed("HTTP://example.com")?.reach,
            .internet
        )
    }

    func testTypedInputRefusesNonWebInput() {
        for input in [
            "file:///etc/hosts",
            "ssh://root@evil.example",
            "javascript:alert(1)",
            "mailto:dev@example.com",
            "multiplex://open?host=devbox",
            "",
            "   ",
            "two words",
        ] {
            XCTAssertNil(typed(input, host: devbox), input)
        }
    }

    func testTypedInputRefusesUserinfoPaddedAuthorities() {
        // `http://mailto:dev@example.com` parses "mailto:dev" as userinfo —
        // the trick the link sheet renders a HOST line to expose. Typed
        // input never needs userinfo, so it is refused outright.
        for input in [
            "https://mailto:dev@example.com",
            "https://github.com@evil.example/x",
            "user:pass@10.0.0.5:9090",
        ] {
            XCTAssertNil(typed(input, host: devbox), input)
        }
        // The colon-digits rule still admits ordinary host:port forms.
        XCTAssertNotNil(typed("localhost:5173", host: devbox))
    }

    func testTypedInputTrimsWhitespace() {
        XCTAssertEqual(
            typed("  10.0.0.5:9090  ")?.url.absoluteString,
            "http://10.0.0.5:9090"
        )
    }

    // MARK: Viewport routes

    func testViewportRouteIsNotATerminal() {
        let route = TerminalRoute(
            hostID: UUID(),
            mode: .viewport(urlString: "http://192.168.1.68:5173/")
        )
        XCTAssertTrue(route.isViewport)
        XCTAssertNil(route.remoteCommand)
        XCTAssertNil(route.moshRemoteCommand)
        XCTAssertNil(route.sessionName)
        XCTAssertEqual(route.viewportURL?.absoluteString, "http://192.168.1.68:5173/")
    }

    func testViewportLabelPrefersThePort() {
        XCTAssertEqual(
            TerminalRoute.viewportLabel("http://192.168.1.68:5173/"),
            "⌗ 5173"
        )
        XCTAssertEqual(
            TerminalRoute.viewportLabel("https://vercel.com/docs"),
            "⌗ vercel.com"
        )
    }

    func testViewportRouteRoundTripsThroughCodable() throws {
        // The scene value carries viewport tabs like any other tab; the
        // no-persistence rule lives in syncTabs (a restored viewport tab has
        // no controller and is stripped), not in the codec.
        let route = TerminalRoute(
            hostID: UUID(),
            mode: .viewport(urlString: "http://localhost:5173/")
        )
        let decoded = try JSONDecoder().decode(
            TerminalRoute.self,
            from: JSONEncoder().encode(route)
        )
        XCTAssertEqual(decoded, route)
        XCTAssertTrue(decoded.isViewport)
    }
}
