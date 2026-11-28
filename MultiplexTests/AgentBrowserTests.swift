import WebKit
import XCTest
@testable import Multiplex

final class AgentBrowserTests: XCTestCase {
    private let host = Host(name: "devbox", hostname: "192.168.1.24", username: "dev")

    // MARK: Wire

    func testHelloRequestAndPongDecode() {
        XCTAssertEqual(
            AgentBrowserWire.decode(#"{"mpx":"browser-bridge","v":1,"socket":"/home/dev/.mpx/run/browser-pad.sock"}"#),
            .hello(version: 1, socket: "/home/dev/.mpx/run/browser-pad.sock")
        )
        XCTAssertEqual(AgentBrowserWire.decode(#"{"mpx":"missing"}"#), .missing)
        XCTAssertEqual(
            AgentBrowserWire.decode(
                #"{"id":7,"method":"open","params":{"url":"localhost:3000","newTab":false},"t":900,"ttl":60000}"#
            ),
            .request(.init(
                id: 7,
                method: "open",
                params: .object(["url": .string("localhost:3000"), "newTab": .bool(false)]),
                sentAt: 900,
                ttl: 60000
            ))
        )
        XCTAssertEqual(AgentBrowserWire.decode(#"{"pong":3,"t":12}"#), .pong(3, bridgeMs: 12))
        XCTAssertEqual(AgentBrowserWire.decode(#"{"cancel":12}"#), .cancel(12))
    }

    /// A login shell may print anything before the bridge's hello.
    func testShellChatterIsIgnored() {
        for line in ["Last login: Mon Oct 6", "", "{", "[1,2]", #"{"mpx":"other"}"#, #"{"id":1}"#] {
            XCTAssertEqual(AgentBrowserWire.decode(line), .ignored, line)
        }
    }

    func testAnswersAreSingleSortedLines() {
        let result = String(decoding: AgentBrowserWire.result(id: 4, .object(["tab": .string("t1")])), as: UTF8.self)
        XCTAssertEqual(result, #"{"id":4,"result":{"tab":"t1"}}"# + "\n")
        let error = String(decoding: AgentBrowserWire.error(id: 5, .noTab()), as: UTF8.self)
        XCTAssertTrue(error.hasPrefix(#"{"error":{"code":"no_tab","message":"#), error)
        XCTAssertTrue(error.hasSuffix(#""id":5}"# + "\n"), error)
        XCTAssertEqual(String(decoding: AgentBrowserWire.ping(9), as: UTF8.self), #"{"ping":9}"# + "\n")
    }

    /// A request read after a suspension is aged on the bridge's clock.
    func testBridgeClockAgesRequestsAcrossSuspension() {
        var clock = AgentBrowserWire.BridgeClock()
        let click = AgentBrowserWire.Request(id: 1, method: "click", params: .null, sentAt: 10_000, ttl: 3_000)
        XCTAssertFalse(clock.isStale(click, localMs: 999_999), "no pong yet: never stale")
        // Ping out at 400, pong (bridge 9 000) back at 600: bridge runs 8.5 s ahead.
        XCTAssertTrue(clock.learn(bridgeMs: 9_000, sentLocalMs: 400, receivedLocalMs: 600))
        XCTAssertFalse(clock.isStale(click, localMs: 2_000))  // bridge 10.5 s: 0.5 s old
        XCTAssertTrue(clock.isStale(click, localMs: 20_000))  // bridge 28.5 s: 18.5 s old
        let unstamped = AgentBrowserWire.Request(id: 2, method: "click", params: .null)
        XCTAssertFalse(clock.isStale(unstamped, localMs: 20_000))
        clock.reset()
        XCTAssertFalse(clock.isStale(click, localMs: 20_000), "a new bridge starts unknown")
    }

    /// A pong that sat in the pipe through a suspension must not teach the
    /// clock — it would make every queued request look fresh.
    func testDelayedPongIsNotTrusted() {
        var clock = AgentBrowserWire.BridgeClock()
        XCTAssertTrue(clock.learn(bridgeMs: 1_000, sentLocalMs: 900, receivedLocalMs: 1_100))
        XCTAssertFalse(clock.learn(bridgeMs: 1_000, sentLocalMs: 1_000, receivedLocalMs: 61_000))
        XCTAssertFalse(clock.learn(bridgeMs: 1_000, sentLocalMs: 2_000, receivedLocalMs: 1_000))
        let expired = AgentBrowserWire.Request(id: 3, method: "click", params: .null, sentAt: 2_000, ttl: 3_000)
        XCTAssertTrue(clock.isStale(expired, localMs: 61_001))
    }

    /// Valid JSON, absurd numbers: never a trap, never a request.
    func testOutOfRangeNumbersAreRejectedNotConverted() {
        XCTAssertEqual(AgentBrowserWire.decode(#"{"id":1e100,"method":"tabs"}"#), .ignored)
        XCTAssertEqual(AgentBrowserWire.decode(#"{"id":-1,"method":"tabs"}"#), .ignored)
        XCTAssertEqual(AgentBrowserWire.decode(#"{"id":1.5,"method":"tabs"}"#), .ignored)
        XCTAssertEqual(AgentBrowserWire.decode(#"{"pong":1e300}"#), .ignored)
        XCTAssertEqual(AgentBrowserWire.decode(#"{"cancel":-1e100}"#), .ignored)
        XCTAssertEqual(
            AgentBrowserWire.decode(#"{"mpx":"browser-bridge","v":1e100}"#),
            .hello(version: 0, socket: nil)
        )
        guard case .request(let request) = AgentBrowserWire.decode(
            #"{"id":2,"method":"tabs","t":-5,"ttl":1e100}"#
        ) else { return XCTFail("a valid id still makes a request") }
        XCTAssertNil(request.sentAt)
        XCTAssertNil(request.ttl)
        XCTAssertEqual(JSONValue.number(9_007_199_254_740_992).wireInteger, 9_007_199_254_740_992)
        XCTAssertNil(JSONValue.number(.infinity).wireInteger)
        XCTAssertNil(JSONValue.number(.nan).wireInteger)
    }

    func testLineBufferJoinsChunksAndDropsRunawayLines() {
        var buffer = AgentBrowserWire.LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\nnext\npart".utf8)), ["{\"a\":1}", "next"])
        XCTAssertEqual(buffer.append(Data("ial\n".utf8)), ["partial"])

        var runaway = AgentBrowserWire.LineBuffer()
        let huge = Data(repeating: 0x41, count: AgentBrowserWire.LineBuffer.maxLineBytes + 1)
        XCTAssertEqual(runaway.append(huge), [])
        XCTAssertEqual(runaway.append(Data("tail\nok\n".utf8)), ["ok"])
    }

    func testJSONValueRoundTripsNestedValues() throws {
        let value = JSONValue.object([
            "n": .number(1.5), "b": .bool(true), "s": .string("é"), "z": .null,
            "a": .array([.number(1), .string("x")]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        XCTAssertEqual(JSONValue.parse("true"), .bool(true))
        XCTAssertNil(JSONValue.parse("{"))
    }

    // MARK: Launch

    func testLaunchQuotesTheDeviceNameAndReportsMissingCLI() {
        let script = AgentBrowserLaunch.script(deviceName: "Jhen's iPad\n", installID: "3f2a9c1e")
        XCTAssertTrue(script.contains(#"bridge --device 'Jhen'\''s iPad' --id '3f2a9c1e'"#), script)
        XCTAssertTrue(script.contains(#"'{"mpx":"missing"}'"#), script)
        XCTAssertTrue(script.contains(#""$HOME/.cargo/bin/mpx""#), script)
        // The payload rides the same envelope as a tmux handoff.
        let payload = AgentBrowserLaunch.payload(deviceName: "Jhen's iPad", installID: "3f2a9c1e")
        XCTAssertTrue(payload.hasPrefix(":\nexec sh -c '"), payload)
        XCTAssertTrue(payload.hasSuffix("\n"))
    }

    /// iOS names devices generically ("iPad"); the install id keeps two of
    /// them on separate bridge sockets. Made once, kept, device-local.
    func testInstallIDIsStableHex() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentBrowserTests.installID"))
        defaults.removePersistentDomain(forName: "AgentBrowserTests.installID")
        let first = AgentBrowserLaunch.installID(in: defaults)
        XCTAssertEqual(first.count, 8)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))
        XCTAssertEqual(AgentBrowserLaunch.installID(in: defaults), first)
        defaults.set("not hex!", forKey: "agentBrowser.installID")
        XCTAssertNotEqual(AgentBrowserLaunch.installID(in: defaults), "not hex!")
        defaults.removePersistentDomain(forName: "AgentBrowserTests.installID")
    }

    /// Host route: loopback reaches the PHONE (never proxied), so only
    /// forwarded ports get through.
    func testLoopbackGuardLetsOnlyForwardedPortsThrough() throws {
        let json = AgentBrowserAddressPolicy.loopbackRuleListJSON(forwardedPorts: [5173, 80])
        let rules = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: String]]]
        )
        let blocks = rules.filter { $0["action"]?["type"] == "block" }.compactMap { $0["trigger"]?["url-filter"] }
        let allows = rules.filter { $0["action"]?["type"] == "ignore-previous-rules" }
            .compactMap { $0["trigger"]?["url-filter"] }
        XCTAssertEqual(blocks.count, 14, "seven loopback spellings, bare and behind userinfo")
        XCTAssertTrue(allows.contains("^[a-z][a-z0-9+.-]*://localhost:5173/"))
        XCTAssertTrue(allows.contains(#"^[a-z][a-z0-9+.-]*://127\.0\.0\.1:5173/"#))
        XCTAssertTrue(allows.contains("^http://localhost/"), "port 80 is the default for http")
        XCTAssertTrue(allows.contains("^ws://localhost/"))
        XCTAssertFalse(allows.contains { $0.contains("8000") })
        XCTAssertFalse((blocks + allows).contains { $0.contains("|") }, "url-filter has no alternation")
        // Before any forward: everything loopback is blocked.
        let none = AgentBrowserAddressPolicy.loopbackRuleListJSON(forwardedPorts: [])
        XCTAssertFalse(none.contains("ignore-previous-rules"))
    }

    /// WebKit's verdict for a URL under a rule list: rules apply in order,
    /// and `ignore-previous-rules` lifts the blocks before it.
    private func isBlocked(_ url: String, by json: String) throws -> Bool {
        let rules = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: String]]]
        )
        var blocked = false
        for rule in rules {
            let filter = try XCTUnwrap(rule["trigger"]?["url-filter"])
            let regex = try NSRegularExpression(pattern: filter, options: [.caseInsensitive])
            guard regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { continue }
            blocked = rule["action"]?["type"] == "block"
        }
        return blocked
    }

    /// A real device never proxies loopback, so these rules are all that
    /// stands between a page and another app's server on the phone — in
    /// every spelling a URL has for it.
    func testLoopbackGuardCoversEverySpellingOfLoopback() throws {
        let json = AgentBrowserAddressPolicy.loopbackRuleListJSON(forwardedPorts: [5173])
        for reachable in [
            "http://localhost:5173/", "ws://localhost:5173/hmr", "http://127.0.0.1:5173/a?b",
            "http://[::1]:5173/", "http://app.localhost:5173/",
            "https://example.com/", "http://192.168.1.24:9000/", "https://localhost.example.com/",
            "http://user@example.com/", "http://[2001:db8::1]/",
        ] {
            XCTAssertFalse(try isBlocked(reachable, by: json), reachable)
        }
        for blocked in [
            "http://localhost:9000/", "http://localhost/", "http://127.0.0.1:9000/", "http://127.8.8.8:9000/",
            "http://[::1]:9000/", "http://app.localhost:9000/", "http://0.0.0.0:9000/", "ws://localhost:9000/",
            "http://localhost.:9000/",
            // Userinfo sits between the scheme and the host.
            "http://x@127.0.0.1:9000/", "http://x:y@localhost:9000/", "http://x@[::1]:9000/",
            "http://x@localhost:5173/",
            // The unspecified address, and IPv4-mapped loopback.
            "http://[::]:9000/", "http://[::ffff:7f00:1]:9000/", "http://[::ffff:127.0.0.1]:9000/",
            "ws://[::ffff:7f00:1]:5173/",
        ] {
            XCTAssertTrue(try isBlocked(blocked, by: json), blocked)
        }
    }

    /// A rule list WebKit refuses to compile opens no agent tab at all (the
    /// fail-closed rule), so the patterns stay inside its url-filter syntax.
    @MainActor
    func testRuleListsCompileInWebKit() async throws {
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        for (name, json) in [
            ("loopback", AgentBrowserAddressPolicy.loopbackRuleListJSON(forwardedPorts: [80, 443, 5173])),
            ("device", AgentBrowserAddressPolicy.contentRuleListJSON(host: host)),
        ] {
            let identifier = "agent-browser-test-\(name)"
            let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
            XCTAssertNotNil(list, name)
            try await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    func testOutdatedCLIIsRecognized() {
        XCTAssertTrue(AgentBrowserLaunch.isOutdatedCLI(stderr: "error: unrecognized subcommand 'bridge'\n"))
        XCTAssertTrue(AgentBrowserLaunch.isOutdatedCLI(stderr: "error: unexpected argument '--id' found\n"))
        XCTAssertFalse(AgentBrowserLaunch.isOutdatedCLI(stderr: "Permission denied"))
    }

    // MARK: Skill install

    /// The button must find the `mpx` the bridge runs, so both go through
    /// one search — and the same login-shell envelope.
    func testSkillInstallSearchesForMpxTheWayTheBridgeDoes() {
        let script = AgentSkillInstall.script()
        XCTAssertTrue(script.contains(#"exec "$c" skill install --json;"#), script)
        XCTAssertTrue(script.contains(#"'{"mpx":"missing"}'"#), script)
        let bridge = AgentBrowserLaunch.script(deviceName: "iPad", installID: "3f2a9c1e")
        XCTAssertEqual(
            script.components(separatedBy: "; do ").first,
            bridge.components(separatedBy: "; do ").first,
            "the candidate list is shared"
        )
        let preferred = AgentSkillInstall.script(preferred: "/tmp/dev build/mpx")
        XCTAssertTrue(preferred.hasPrefix("for c in '/tmp/dev build/mpx' mpx multiplex "), preferred)
        XCTAssertTrue(AgentSkillInstall.payload().hasPrefix(":\nexec sh -c '"))
    }

    func testSkillInstallReadsOnlyTheAnswerLine() {
        // What a login shell prints around the command is not the answer.
        for noise in ["Welcome to Ubuntu 26.04 LTS", "", "[]", #"{"motd":"hi"}"#, #"{"skill":"multiplex"}"#] {
            XCTAssertNil(AgentSkillInstall.outcome(fromLine: noise), noise)
        }
        XCTAssertEqual(AgentSkillInstall.outcome(fromLine: #"{"mpx":"missing"}"#), .missingCLI)
        XCTAssertEqual(
            AgentSkillInstall.outcome(fromLine: """
                {"failed":[],"installed":["/home/u/.agents/skills/multiplex/SKILL.md",\
                "/home/u/.claude/skills/multiplex/SKILL.md"],"skill":"multiplex"}
                """),
            .installed([
                "/home/u/.agents/skills/multiplex/SKILL.md",
                "/home/u/.claude/skills/multiplex/SKILL.md",
            ])
        )
        XCTAssertEqual(
            AgentSkillInstall.outcome(fromLine: """
                {"skill":"multiplex","installed":["/home/u/.agents/skills/multiplex/SKILL.md"],\
                "failed":[{"dir":"/home/u/.claude/skills","error":"Not a directory (os error 20)"}]}
                """),
            .incomplete(
                installed: ["/home/u/.agents/skills/multiplex/SKILL.md"],
                refused: [.init(directory: "/home/u/.claude/skills", reason: "Not a directory (os error 20)")]
            )
        )
        // Nothing installed and nothing refused is not a success.
        XCTAssertEqual(
            AgentSkillInstall.outcome(fromLine: #"{"skill":"multiplex","installed":[],"failed":[]}"#),
            .incomplete(installed: [], refused: [])
        )
    }

    func testSkillInstallThatEndsWithoutAnAnswerSaysWhy() {
        // mpx 0.1 has no `skill`; a pre-release 0.2 had no `--json`.
        XCTAssertEqual(
            AgentSkillInstall.outcome(endedWith: nil, stderr: "error: unrecognized subcommand 'skill'\n"),
            .outdatedCLI
        )
        XCTAssertEqual(
            AgentSkillInstall.outcome(endedWith: nil, stderr: "error: unexpected argument '--json' found\n"),
            .outdatedCLI
        )
        XCTAssertEqual(
            AgentSkillInstall.outcome(endedWith: "eof", stderr: "mpx skill: HOME is not set\n"),
            .failed("mpx skill: HOME is not set")
        )
        XCTAssertEqual(AgentSkillInstall.outcome(endedWith: "channel closed", stderr: " \n"), .failed("channel closed"))
        XCTAssertEqual(AgentSkillInstall.outcome(endedWith: nil, stderr: ""), .failed(""))
    }

    func testSkillInstallFailuresAreWordedForThePersonWhoHasToFixThem() throws {
        let host = Host(name: "devbox", hostname: "devbox.local", username: "demo")
        XCTAssertNil(AgentSkillInstaller.failureMessage(for: .installed(["/x/SKILL.md"]), host: host))
        let missing = try XCTUnwrap(AgentSkillInstaller.failureMessage(for: .missingCLI, host: host))
        XCTAssertTrue(missing.contains("devbox.local"), missing)
        XCTAssertTrue(missing.contains("brew install multiplex-term/tap/mpx"), missing)
        let outdated = try XCTUnwrap(AgentSkillInstaller.failureMessage(for: .outdatedCLI, host: host))
        XCTAssertTrue(outdated.contains("0.2"), outdated)
        let refused = try XCTUnwrap(AgentSkillInstaller.failureMessage(
            for: .incomplete(
                installed: ["/home/u/.agents/skills/multiplex/SKILL.md"],
                refused: [.init(directory: "/home/u/.claude/skills", reason: "Not a directory")]
            ),
            host: host
        ))
        XCTAssertEqual(refused, "mpx couldn't write the skill into /home/u/.claude/skills: Not a directory")
        XCTAssertEqual(
            AgentSkillInstaller.failureMessage(for: .failed("mpx skill: HOME is not set"), host: host),
            "mpx on devbox.local couldn't install the skill: mpx skill: HOME is not set"
        )
        // Each outcome that is not a clean install has something to say.
        for outcome in [AgentSkillInstall.Outcome.failed(""), .silent, .incomplete(installed: [], refused: [])] {
            let message = try XCTUnwrap(AgentSkillInstaller.failureMessage(for: outcome, host: host))
            XCTAssertTrue(message.contains("devbox.local"), message)
        }
        XCTAssertEqual(
            AgentSkillInstaller.failureMessage(for: .unreachable("No route to devbox.local."), host: host),
            "No route to devbox.local."
        )
    }

    // MARK: Address policy

    func testAgentsReachTheInternetAndThisHostOnly() throws {
        let local = try AgentBrowserAddressPolicy.admit("localhost:5173/app", host: host).get()
        XCTAssertEqual(local.url.absoluteString, "http://192.168.1.24:5173/app")
        // The fully qualified spelling is the host's loopback too.
        XCTAssertEqual(
            try AgentBrowserAddressPolicy.admit("http://localhost.:8000/", host: host).get().url.host(),
            "192.168.1.24"
        )
        XCTAssertEqual(
            try AgentBrowserAddressPolicy.admit("https://example.com", host: host).get().url.host(),
            "example.com"
        )
        XCTAssertNoThrow(try AgentBrowserAddressPolicy.admit("http://192.168.1.24:8000", host: host).get())

        for blocked in [
            "http://192.168.1.1/", "10.0.0.8:80", "http://router/", "http://nas.local/",
            "http://nas.local./", "http://[fe90::1]/", "http://[febf::1]/",
        ] {
            guard case .failure(let error) = AgentBrowserAddressPolicy.admit(blocked, host: host) else {
                return XCTFail("\(blocked) was admitted")
            }
            XCTAssertEqual(error.code, "blocked", blocked)
        }
        guard case .failure(let error) = AgentBrowserAddressPolicy.admit("javascript:alert(1)", host: host) else {
            return XCTFail("javascript: was admitted")
        }
        XCTAssertEqual(error.code, "bad_request")
    }

    /// In-page navigations: loopback now means the DEVICE's own.
    func testNavigationsToDeviceLoopbackAreRefused() throws {
        XCTAssertFalse(AgentBrowserAddressPolicy.admits(try XCTUnwrap(URL(string: "http://127.0.0.1:8080/")), host: host))
        XCTAssertTrue(AgentBrowserAddressPolicy.admits(try XCTUnwrap(URL(string: "http://192.168.1.24/")), host: host))
        XCTAssertTrue(AgentBrowserAddressPolicy.admits(try XCTUnwrap(URL(string: "about:blank")), host: host))
    }

    func testContentRulesBlockPrivateRangesThenLetThisHostBackIn() throws {
        let json = AgentBrowserAddressPolicy.contentRuleListJSON(host: host)
        let rules = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: String]]]
        )
        let actions = rules.compactMap { $0["action"]?["type"] }
        XCTAssertEqual(actions.last, "ignore-previous-rules")
        XCTAssertTrue(actions.dropLast().allSatisfy { $0 == "block" })
        XCTAssertEqual(rules.last?["trigger"]?["url-filter"], #"^[a-z][a-z0-9+.-]*://192\.168\.1\.24[:/]"#)
        // WebKit's url-filter has no alternation.
        XCTAssertFalse(rules.contains { $0["trigger"]?["url-filter"]?.contains("|") == true })

        var ipv6 = host
        ipv6.hostname = "fd00::5"
        XCTAssertTrue(AgentBrowserAddressPolicy.contentRuleListJSON(host: ipv6).contains(#"\\[fd00::5\\][:/]"#))
    }

    // MARK: Host route

    private let credential = "mpx:s3cret"
    private var auth: String { "Proxy-Authorization: Basic " + Data(credential.utf8).base64EncodedString() + "\r\n" }

    func testProxyTunnelsConnectOnlyWithTheCredential() {
        let connect = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\(auth)\r\n"
        let (outcome, length) = AgentProxyHead.parse(Data(connect.utf8), credential: credential)
        XCTAssertEqual(outcome, .connect(host: "example.com", port: 443))
        XCTAssertEqual(length, connect.utf8.count)

        let anonymous = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"
        XCTAssertEqual(AgentProxyHead.parse(Data(anonymous.utf8), credential: credential).outcome, .unauthorized)
        let wrong = anonymous.replacingOccurrences(
            of: "\r\n\r\n", with: "\r\nProxy-Authorization: Basic eDp5\r\n\r\n"
        )
        XCTAssertEqual(AgentProxyHead.parse(Data(wrong.utf8), credential: credential).outcome, .unauthorized)

        let v6 = "CONNECT [::1]:8080 HTTP/1.1\r\n\(auth)\r\n"
        XCTAssertEqual(
            AgentProxyHead.parse(Data(v6.utf8), credential: credential).outcome,
            .connect(host: "::1", port: 8080)
        )
        XCTAssertEqual(AgentProxyHead.parse(Data("CONNECT exam".utf8), credential: credential).outcome, .incomplete)
        let huge = Data(repeating: 0x41, count: AgentProxyHead.maxHeadBytes + 1)
        XCTAssertEqual(AgentProxyHead.parse(huge, credential: credential).outcome, .tooLarge)
    }

    /// WebKit tunnels plain HTTP too; anything but CONNECT is refused.
    func testProxyRefusesAnythingButATunnel() {
        let get = "GET http://localhost:5173/ HTTP/1.1\r\nHost: localhost:5173\r\n\(auth)\r\n"
        XCTAssertEqual(AgentProxyHead.parse(Data(get.utf8), credential: credential).outcome, .notTunnel)
        let anonymous = "GET http://localhost:5173/ HTTP/1.1\r\nHost: localhost:5173\r\n\r\n"
        XCTAssertEqual(AgentProxyHead.parse(Data(anonymous.utf8), credential: credential).outcome, .unauthorized)
    }

    /// Device loopback is shared by every app: a forward admits only a
    /// first request carrying the agent tabs' cookie.
    func testForwardsAdmitOnlyTheAgentTabsCookie() {
        let secret = "c0ffee"
        func verdict(_ text: String) -> AgentProxyHead.ForwardVerdict {
            AgentProxyHead.forwardVerdict(Data(text.utf8), secret: secret)
        }
        XCTAssertEqual(
            verdict("GET / HTTP/1.1\r\nHost: localhost:5173\r\nCookie: theme=dark; __mpx_forward=c0ffee\r\n\r\n"),
            .allowed
        )
        XCTAssertEqual(
            verdict("GET /hmr HTTP/1.1\r\nUpgrade: websocket\r\ncookie: __mpx_forward=c0ffee\r\n\r\n"),
            .allowed,
            "WebSocket handshakes carry it too"
        )
        XCTAssertEqual(verdict("GET / HTTP/1.1\r\nHost: localhost:5173\r\n\r\n"), .refused)
        XCTAssertEqual(verdict("GET / HTTP/1.1\r\nCookie: __mpx_forward=wrong\r\n\r\n"), .refused)
        XCTAssertEqual(verdict("GET / HTTP/1.1\r\nCookie: x__mpx_forward=c0ffee\r\n\r\n"), .refused)
        XCTAssertEqual(verdict("GET / HTTP/1.1\r\nHost: loc"), .incomplete)
        XCTAssertEqual(AgentProxyHead.forwardVerdict(Data([0x16, 0x03, 0x01]), secret: secret), .notHTTP, "TLS")
        XCTAssertEqual(AgentProxyHead.forwardVerdict(Data(), secret: secret), .incomplete)
        let refusal = String(decoding: AgentProxyHead.forwardRefused, as: UTF8.self)
        let body = refusal.components(separatedBy: "\r\n\r\n").last ?? ""
        XCTAssertTrue(refusal.contains("Content-Length: \(body.utf8.count)\r\n"))
    }

    /// The AGENT mark is composed with the label, never patched in after.
    func testAgentTabsWearTheirMarkInTheLabel() {
        XCTAssertEqual(TerminalRoute.viewportLabel("http://localhost:5173/", agent: true), "⌗ AGENT 5173")
        XCTAssertEqual(TerminalRoute.viewportLabel("https://example.com/", agent: true), "⌗ AGENT example.com")
        XCTAssertEqual(TerminalRoute.viewportLabel("not a url", agent: true), "⌗ AGENT page")
        XCTAssertEqual(TerminalRoute.viewportLabel("http://localhost:5173/"), "⌗ 5173")
    }

    /// A real device never proxies loopback: these are the URLs whose port
    /// the host route forwards instead.
    func testLoopbackPortsAreTheOnesToForward() throws {
        func port(_ text: String) throws -> Int? {
            AgentBrowserAddressPolicy.loopbackPort(try XCTUnwrap(URL(string: text)))
        }
        XCTAssertEqual(try port("http://localhost:5173/app"), 5173)
        XCTAssertEqual(try port("http://127.0.0.1/"), 80)
        XCTAssertEqual(try port("https://dev.localhost/"), 443)
        XCTAssertEqual(try port("http://[::1]:8000/"), 8000)
        XCTAssertNil(try port("http://192.168.1.24:5173/"))
        XCTAssertNil(try port("https://example.com/"))
        XCTAssertNil(try port("about:blank"))
    }

    /// On the host route `localhost` is the host's own loopback — no rewrite.
    func testHostRouteKeepsLocalhost() throws {
        let local = try AgentBrowserAddressPolicy.admitViaHost("localhost:5173/app", host: host).get()
        XCTAssertEqual(local.url.absoluteString, "http://localhost:5173/app")
        XCTAssertEqual(
            try AgentBrowserAddressPolicy.admitViaHost("http://192.168.1.1/", host: host).get().url.host(),
            "192.168.1.1",
            "the host's own LAN — the device's is never on this path"
        )
        XCTAssertThrowsError(try AgentBrowserAddressPolicy.admitViaHost("javascript:alert(1)", host: host).get())
        XCTAssertTrue(AgentBrowserScript.noWebRTC.contains("RTCPeerConnection"))
    }

    // MARK: Focus

    func testFocusIsNeverTakenMidTypingAndOncePerCooldown() {
        var gate = AgentFocusGate()
        let other = UUID()
        XCTAssertEqual(gate.request(hostID: host.id, now: 100, userTyping: true), .userTyping)
        XCTAssertEqual(gate.request(hostID: host.id, now: 100, userTyping: false), .allow)
        XCTAssertEqual(gate.request(hostID: host.id, now: 110, userTyping: false), .coolingDown(20))
        // Hosts are rationed separately.
        XCTAssertEqual(gate.request(hostID: other, now: 110, userTyping: false), .allow)
        XCTAssertEqual(gate.request(hostID: host.id, now: 130, userTyping: false), .allow)
        // A refusal while typing does not spend the host's turn.
        XCTAssertEqual(gate.request(hostID: other, now: 150, userTyping: true), .userTyping)
        XCTAssertEqual(gate.request(hostID: other, now: 150, userTyping: false), .allow)
        XCTAssertNil(AgentFocusGate.Verdict.allow.refusalMessage)
        XCTAssertTrue(AgentFocusGate.Verdict.coolingDown(19.2).refusalMessage?.contains("in 20 s") == true)
    }

    // MARK: Forwards

    /// Forwards the next port from `port` up that this process can bind
    /// (another process may hold some), within a bounded number of tries.
    private func forwardNextFreePort(_ proxy: AgentBrowserProxy, from port: inout Int) async throws {
        for _ in 0..<200 {
            port += 1
            do {
                try await proxy.forward(port: port)
                return
            } catch is AgentBrowserProxy.PortBusy {}
        }
        XCTFail("no bindable loopback port near \(port)")
        throw AgentBrowserProxy.PortBusy()
    }

    /// Each forward is two listeners on the device, and a page can ask for
    /// one per loopback port it navigates a frame to.
    func testAHostHoldsABoundedNumberOfForwards() async throws {
        let proxy = AgentBrowserProxy(host: host)
        defer { proxy.stop() }
        var port = 40_000 + Int.random(in: 0..<10_000)
        for _ in 0..<AgentBrowserProxy.maxForwards {
            try await forwardNextFreePort(proxy, from: &port)
        }
        XCTAssertEqual(proxy.forwardedPorts.count, AgentBrowserProxy.maxForwards)
        do {
            try await proxy.forward(port: port + 1)
            XCTFail("a forward past the bound was bound")
        } catch is AgentBrowserProxy.TooManyForwards {}
        XCTAssertEqual(proxy.forwardedPorts.count, AgentBrowserProxy.maxForwards)
        // Asking again for one already held is not a new forward.
        try await proxy.forward(port: proxy.forwardedPorts[0])

        // The host's last agent tab closing releases them all.
        proxy.stopForwards()
        XCTAssertTrue(proxy.forwardedPorts.isEmpty)
        try await forwardNextFreePort(proxy, from: &port)
        XCTAssertEqual(proxy.forwardedPorts, [port])
    }

    /// A blocking loopback client: sends `request`, returns what came back
    /// until the other side closed.
    private func exchange(port: Int, _ request: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            received.append(buffer, count: count)
        }
        return String(decoding: received, as: UTF8.self)
    }

    /// A listener of someone else's on loopback, at `address`.
    private func foreignListener(on address: String, port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var bound = sockaddr_in()
        bound.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bound.sin_family = sa_family_t(AF_INET)
        bound.sin_port = in_port_t(port).bigEndian
        bound.sin_addr.s_addr = inet_addr(address)
        let result = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    /// A forward closes a refused client first, which leaves that
    /// connection in TIME_WAIT on the forward's port for half a minute.
    /// Closing the last tab and opening the port again inside that window
    /// answered `port_busy`.
    func testAForwardedPortCanBeForwardedAgainRightAfterItClosed() async throws {
        let proxy = AgentBrowserProxy(host: host)
        defer { proxy.stop() }
        var port = 40_000 + Int.random(in: 0..<10_000)
        try await forwardNextFreePort(proxy, from: &port)
        let answer = try exchange(port: port, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 403"), answer)

        proxy.stopForwards()
        try await proxy.forward(port: port)
        XCTAssertEqual(proxy.forwardedPorts, [port])
    }

    /// Binding through TIME_WAIT must not turn into binding over a port
    /// that is in use: the same address, or another app's wildcard listener.
    func testAPortSomeoneElseListensOnStaysBusy() async throws {
        let proxy = AgentBrowserProxy(host: host)
        defer { proxy.stop() }
        var port = 40_000 + Int.random(in: 0..<10_000)
        for address in ["127.0.0.1", "0.0.0.0"] {
            var listener: Int32?
            for _ in 0..<200 where listener == nil {
                port += 1
                listener = try? foreignListener(on: address, port: port)
            }
            let fd = try XCTUnwrap(listener)
            defer { close(fd) }
            do {
                try await proxy.forward(port: port)
                XCTFail("bound over a listener on \(address)")
            } catch is AgentBrowserProxy.PortBusy {}
            XCTAssertTrue(proxy.forwardedPorts.isEmpty)
        }
    }

    /// `--open` belongs to a forward: it cannot be set for a port that is
    /// not forwarded, where it would wait for whoever forwards it next.
    func testOnlyAForwardedPortCanBeOpened() async throws {
        let proxy = AgentBrowserProxy(host: host)
        defer { proxy.stop() }
        var port = 40_000 + Int.random(in: 0..<10_000)
        proxy.setOpen(port + 1, true)
        try await forwardNextFreePort(proxy, from: &port)
        XCTAssertEqual(proxy.openForwardedPorts, [], "opened before it was forwarded")
        proxy.setOpen(port, true)
        XCTAssertEqual(proxy.openForwardedPorts, [port])
        proxy.stopForwards()
        try await proxy.forward(port: port)
        XCTAssertEqual(proxy.openForwardedPorts, [], "the mode goes with the forward")
    }

    /// A revoked host's proxy binds nothing more: no listener, no forward.
    func testAStoppedProxyBindsNothing() async throws {
        let proxy = AgentBrowserProxy(host: host)
        _ = try await proxy.start()
        proxy.stop()
        XCTAssertNil(proxy.port)
        do {
            try await proxy.forward(port: 40_000 + Int.random(in: 0..<10_000))
            XCTFail("a stopped proxy bound a forward")
        } catch {}
        XCTAssertTrue(proxy.forwardedPorts.isEmpty)
        do {
            _ = try await proxy.start()
            XCTFail("a stopped proxy listened again")
        } catch {}
        XCTAssertNil(proxy.port)
    }

    // MARK: Docking

    /// A restored window for the agent's session can sit in the background;
    /// a tab docked there is invisible and laid out at zero size.
    @MainActor
    func testAgentTabsDockInAWindowOnScreenFirst() {
        let workspace = TerminalWorkspace()
        let restoredMain = TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main"))
        let visibleOther = TerminalRoute(hostID: host.id, mode: .attach(sessionName: "scratch"))
        func window(_ tab: TerminalRoute, foreground: Bool) -> TerminalWorkspace.WindowEntry {
            TerminalWorkspace.WindowEntry(
                id: UUID(), tabs: [tab], label: "terminal",
                reveal: { _ in }, surrender: { [] }, adopt: { _ in },
                activeTabID: { tab.id },
                isForeground: { foreground }
            )
        }
        workspace.registerWindow(window(restoredMain, foreground: false))
        workspace.registerWindow(window(visibleOther, foreground: true))

        let main = SessionKey(backend: .tmux, name: "main")
        XCTAssertEqual(workspace.agentDockTarget(hostID: host.id, session: main)?.anchorTabID, visibleOther.id)

        let visibleMain = TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main"))
        workspace.registerWindow(window(visibleMain, foreground: true))
        XCTAssertEqual(workspace.agentDockTarget(hostID: host.id, session: main)?.anchorTabID, visibleMain.id)

        XCTAssertNil(workspace.agentDockTarget(hostID: UUID(), session: main))
    }

    // MARK: Host record

    func testAgentBrowserIsOffForOldRecordsAndNeverRebuildsTheProbe() throws {
        let legacy = #"{"name":"a","hostname":"h","username":"u"}"#
        XCTAssertFalse(try JSONDecoder().decode(Host.self, from: Data(legacy.utf8)).agentBrowser)

        var switched = host
        switched.agentBrowser = true
        XCTAssertTrue(switched.hasSameConnectionModelConfiguration(as: host))
        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(switched))
        XCTAssertTrue(decoded.agentBrowser)
    }

    // MARK: Scripts

    func testEvalTriesExpressionThenStatements() {
        let bodies = AgentBrowserScript.evalBodies("document.title")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].hasPrefix("let __v;\ntry { __v = await (\ndocument.title\n); }"))
        XCTAssertTrue(bodies[1].contains("(async () => {\ndocument.title\n})()"))
        // What the code throws comes back as an answer, so only a body that
        // did not compile reaches the retry.
        for body in bodies {
            XCTAssertTrue(body.contains("catch (__e) { return JSON.stringify({ thrown: String(__e) }); }"))
        }
    }

    /// The load and `wait` polls sleep between looks. Cancelled, the sleep
    /// returns at once; a poll that ignored that span on the main actor
    /// until its deadline.
    func testACancelledPauseSaysSo() async {
        let paused = Task { await AgentBrowserDriver.pause(.seconds(60)) }
        paused.cancel()
        let finished = await paused.value
        XCTAssertFalse(finished)
        let slept = await AgentBrowserDriver.pause(.milliseconds(1))
        XCTAssertTrue(slept)
    }

    func testScriptsShareTheConsoleEventName() {
        let helper = AgentBrowserScript.helper(consoleEvent: "mpx-console-X")
        let hook = AgentBrowserScript.consoleHook(consoleEvent: "mpx-console-X")
        XCTAssertTrue(helper.contains(#"const EVENT = "mpx-console-X";"#))
        XCTAssertTrue(hook.contains(#"const EVENT = "mpx-console-X";"#))
        XCTAssertFalse(helper.contains("__MPX_EVENT__"))
        // Forged console events: levels allowlisted, detail size-checked,
        // a character budget on the buffer.
        XCTAssertTrue(helper.contains("LEVELS.has(level)"))
        XCTAssertTrue(helper.contains("e.detail.length > 8192"))
        XCTAssertTrue(helper.contains("consoleChars > MAX_CONSOLE_CHARS"))
        XCTAssertTrue(AgentBrowserScript.callBody.contains("> \(AgentBrowserScript.maxAnswerChars)"))
        XCTAssertTrue(AgentBrowserScript.evalBodies("1")[0].contains("tooLarge"))
        // No message handler anywhere: the page gets no bridge into the app.
        XCTAssertFalse(helper.contains("messageHandlers"))
        XCTAssertFalse(hook.contains("messageHandlers"))
    }
}
