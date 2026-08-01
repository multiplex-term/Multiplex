import XCTest
@testable import Multiplex

final class TerminalLinkTests: XCTestCase {
    // MARK: Openable

    func testResolvesWebLinks() {
        for target in [
            "https://multiplexterm.dev",
            "http://localhost:5173/",
            "https://github.com/jhen0409/multiplex-home/pull/3#issue-1",
            "https://[2001:db8::1]:8080/status",
        ] {
            guard case .openable(let url)? = TerminalLink.resolve(target)?.kind else {
                return XCTFail("expected \(target) to be openable")
            }
            XCTAssertEqual(url.absoluteString, target)
        }
    }

    func testResolvesMailto() {
        guard case .openable? = TerminalLink.resolve("mailto:dev@example.com")?.kind else {
            return XCTFail("expected a mailto link")
        }
    }

    func testSchemeMatchingIsCaseInsensitive() {
        guard case .openable? = TerminalLink.resolve("HTTPS://Example.com/A")?.kind else {
            return XCTFail("expected an uppercase scheme to resolve")
        }
    }

    func testTrimsSurroundingWhitespace() {
        // Implicit detection can carry the trailing spaces of an end-of-line
        // match into the target.
        XCTAssertEqual(
            TerminalLink.resolve("  https://example.com/x  ")?.raw,
            "https://example.com/x"
        )
    }

    // MARK: The host line

    func testHostIsTheRealAuthorityNotTheUserinfo() {
        // The defence against `https://github.com@evil.example/x` reading as
        // GitHub: the sheet shows this host on its own line.
        XCTAssertEqual(
            TerminalLink.resolve("https://github.com@evil.example/x")?.host,
            "evil.example"
        )
    }

    func testHostIsNilForEverythingNotOpenable() {
        XCTAssertNil(TerminalLink.resolve("ssh://box.example")?.host)
    }

    // MARK: Blocked schemes

    func testAppSchemeIsNeverOpenable() {
        // ExternalActionRouter accepts this as a widget-grade command, so pane
        // output must never be able to launch an agent on another host.
        guard case .blockedScheme("multiplex")? = TerminalLink.resolve(
            "multiplex://open?host=prod&action=agent&prompt=rm%20-rf"
        )?.kind else {
            return XCTFail("expected the app's own scheme to be blocked")
        }
    }

    func testNonWebSchemesAreReportedNotOpened() {
        for (target, scheme) in [
            ("file:///etc/shadow", "file"),
            ("ssh://root@box.example", "ssh"),
            ("tel:+15550100", "tel"),
            ("javascript:alert(1)", "javascript"),
            ("shortcuts://run-shortcut?name=Wipe", "shortcuts"),
        ] {
            guard case .blockedScheme(let found)? = TerminalLink.resolve(target)?.kind else {
                return XCTFail("expected \(target) to be blocked")
            }
            XCTAssertEqual(found, scheme)
        }
    }

    // MARK: Declined — not links at all

    func testFilesystemPathsAreDeclined() {
        // Implicit detection matches these as readily as URLs, and they are
        // everywhere in terminal output. Declining lets the long press fall
        // through to the selection menu.
        for target in [
            "./src/main.swift",
            "../Vendor/SwiftTerm",
            "/etc/hosts",
            "~/notes/todo.md",
            "Sources/Multiplex/Theme.swift",
        ] {
            XCTAssertNil(TerminalLink.resolve(target), "expected \(target) to be declined")
        }
    }

    func testEmptyAndOversizedTargetsAreDeclined() {
        XCTAssertNil(TerminalLink.resolve(""))
        XCTAssertNil(TerminalLink.resolve("   "))
        XCTAssertNil(
            TerminalLink.resolve("https://example.com/" + String(repeating: "a", count: 4096))
        )
    }

    func testControlCharactersAreDeclined() {
        // OSC 8 payloads arrive as raw remote bytes; a target that embeds a
        // newline or an escape is trying to change how it renders.
        XCTAssertNil(TerminalLink.resolve("https://example.com/a\nb"))
        XCTAssertNil(TerminalLink.resolve("https://example.com/\u{1B}[31m"))
        XCTAssertNil(TerminalLink.resolve("https://exam\u{7}ple.com"))
    }

    func testSchemeLikePrefixesThatAreNotSchemesAreDeclined() {
        // A leading digit is not a legal scheme, and prose that happens to
        // carry a colon is not a link — an OSC 8 payload is arbitrary remote
        // text, so both reach `resolve` even though implicit detection would
        // never match them.
        XCTAssertNil(TerminalLink.resolve("12:34:56"))
        XCTAssertNil(TerminalLink.resolve("warning: unused variable"))
        XCTAssertNil(TerminalLink.resolve("note: see the docs"))
        XCTAssertNil(TerminalLink.resolve("https://example.com/a b"))
    }

    // MARK: Schemeless

    func testSchemelessDomainsWithPathsResolve() {
        // Implicit detection hands these over through its bare-relative
        // *path* branch (the dotted lookahead guarantees the dot), so
        // without the schemeless reading they confirmed as files.
        for (target, expected) in [
            ("example.com/docs/setup", "https://example.com/docs/setup"),
            ("docs.rs/serde/latest", "https://docs.rs/serde/latest"),
            ("en.wikipedia.org/wiki/Tmux", "https://en.wikipedia.org/wiki/Tmux"),
            ("www.example.com/foo?q=1", "https://www.example.com/foo?q=1"),
        ] {
            guard case .openable(let url)? = TerminalLink.resolve(target)?.kind else {
                return XCTFail("expected \(target) to be openable")
            }
            XCTAssertEqual(url.absoluteString, expected)
        }
    }

    func testWWWIsEvidenceEnoughWithoutAPath() {
        guard case .openable(let url)? = TerminalLink.resolve("www.example.com")?.kind else {
            return XCTFail("expected www.example.com to be openable")
        }
        XCTAssertEqual(url.absoluteString, "https://www.example.com")
    }

    func testSchemelessSchemeFollowsReach() {
        // The viewport's typed-input rule: dev servers are cleartext, so
        // LAN/loopback addresses default http; everything else https.
        for (target, expected) in [
            ("192.168.1.5:3000/app", "http://192.168.1.5:3000/app"),
            ("devbox.local/status", "http://devbox.local/status"),
            ("127.0.0.1:5173/", "http://127.0.0.1:5173/"),
            ("example.com:8080/x", "https://example.com:8080/x"),
        ] {
            XCTAssertEqual(
                TerminalLink.resolve(target)?.openableURL?.absoluteString,
                expected,
                "for \(target)"
            )
        }
    }

    func testSchemelessTrailingPunctuationIsTrimmed() {
        // Path-branch matches keep sentence punctuation the URL branch's
        // own guard would have dropped.
        XCTAssertEqual(
            TerminalLink.resolve("example.com/foo.")?.raw,
            "example.com/foo"
        )
    }

    func testBareDottedWordsStayDeclined() {
        // A markdown link's `setup.md` is a sibling document, not a URL —
        // the file viewer's relative navigation depends on this. A dot is
        // not evidence; a path, query, or `www.` is.
        for target in [
            "setup.md",
            "example.com",
            "v1.2/notes",
            "a.b/c.d",
            "node_modules/.bin/tsc",
        ] {
            XCTAssertNil(TerminalLink.resolve(target), "expected \(target) to be declined")
        }
    }

    func testSchemelessUserinfoIsDeclined() {
        // `github.com@evil.example/x` without a scheme must not become a
        // link whose label reads as GitHub.
        XCTAssertNil(TerminalLink.resolve("github.com@evil.example/x"))
    }

    func testSchemelessSingleLabelsAndBadPortsAreDeclined() {
        XCTAssertNil(TerminalLink.resolve("localhost/x"))
        XCTAssertNil(TerminalLink.resolve("build/output.js"))
        XCTAssertNil(TerminalLink.resolve("example.com:99999/x"))
        XCTAssertNil(TerminalLink.resolve("example.com:80a/x"))
    }

    // MARK: Malformed

    func testHostlessWebLinksAreMalformed() {
        for target in ["https://", "http:///path"] {
            guard case .malformed? = TerminalLink.resolve(target)?.kind else {
                return XCTFail("expected \(target) to be malformed")
            }
        }
    }

    func testEmptyMailtoIsMalformed() {
        guard case .malformed? = TerminalLink.resolve("mailto:")?.kind else {
            return XCTFail("expected an addressless mailto to be malformed")
        }
    }

    func testMalformedAndBlockedLinksExposeNoURL() {
        XCTAssertNil(TerminalLink.resolve("mailto:")?.openableURL)
        XCTAssertNil(TerminalLink.resolve("file:///tmp/x")?.openableURL)
    }

    // MARK: Identity

    func testIdentityIsTheResolvedTarget() {
        // `.sheet(item:)` re-presents when this changes, so two activations of
        // the same link must not thrash the sheet.
        XCTAssertEqual(
            TerminalLink.resolve("https://example.com/a")?.id,
            TerminalLink.resolve("https://example.com/a  ")?.id
        )
        XCTAssertNotEqual(
            TerminalLink.resolve("https://example.com/a")?.id,
            TerminalLink.resolve("https://example.com/b")?.id
        )
    }
}
