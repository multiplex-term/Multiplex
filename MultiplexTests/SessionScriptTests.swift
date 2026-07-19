import XCTest
@testable import Multiplex

final class SessionScriptTests: XCTestCase {
    func testNormalizedBodyStripsControlsKeepsNewlinesAndTabs() {
        let script = SessionScript(
            name: "setup",
            body: "  export A=1\r\n\tnvm use 20\u{02}\u{1B}\rsource .env  \n"
        )
        // CRLF/CR normalize, tabs and interior newlines survive, invisible
        // controls (including tmux's Ctrl-B, 0x02) are removed, and only the
        // outside is trimmed.
        XCTAssertEqual(script.normalizedBody, "export A=1\n\tnvm use 20\nsource .env")
    }

    func testDisplayNamePrefersTrimmedName() {
        let script = SessionScript(name: "  venv  ", body: "source .venv/bin/activate")
        XCTAssertEqual(script.displayName, "venv")
    }

    func testDisplayNameFallsBackToTruncatedFirstLine() {
        let script = SessionScript(
            name: "  ",
            body: "source \t .venv/bin/activate && export PATH=$HOME/.local/bin:$PATH\necho ready"
        )
        // First line only, whitespace collapsed, truncated with an ellipsis.
        XCTAssertEqual(
            script.displayName,
            "source .venv/bin/activate && export…"
        )

        let short = SessionScript(name: "", body: "nvm use 20")
        XCTAssertEqual(short.displayName, "nvm use 20")

        let empty = SessionScript(name: "", body: "")
        XCTAssertEqual(empty.displayName, "Script")
    }

    func testNormalizedDropsBodylessRowsAndKeepsIDs() {
        let keep = SessionScript(name: "keep", body: "  make dev  ")
        let nameOnly = SessionScript(name: "named but empty", body: "   ")
        let duplicateID = SessionScript(id: keep.id, name: "dupe", body: "echo hi")

        let normalized = SessionScript.normalized([keep, nameOnly, duplicateID])

        // A script with nothing to type is not a script, whatever its name;
        // ids stay unique and are never reminted (the remembered-selection
        // memory points at them).
        XCTAssertEqual(normalized.map(\.id), [keep.id])
        XCTAssertEqual(normalized.first?.body, "make dev")
    }

    func testDecodeToleratesMissingFieldsAndLegacyHostRecords() throws {
        // A record from a peer running a different schema must not drop the
        // host list: every script field is optional on decode.
        let bare = try JSONDecoder().decode(SessionScript.self, from: Data("{}".utf8))
        XCTAssertEqual(bare.name, "")
        XCTAssertEqual(bare.body, "")

        let legacyHost = Data(
            #"{"name": "devbox", "hostname": "devbox.example.com", "username": "dev"}"#.utf8
        )
        let host = try JSONDecoder().decode(Host.self, from: legacyHost)
        XCTAssertEqual(host.sessionScripts, [])
    }

    func testHostRoundTripsScriptsAndNormalizesOnDecode() throws {
        var host = Host(name: "devbox", hostname: "devbox.example.com", username: "dev")
        host.sessionScripts = [
            SessionScript(name: "venv", body: "source .venv/bin/activate"),
            SessionScript(name: "ghost", body: "   "),
        ]

        let decoded = try JSONDecoder().decode(
            Host.self, from: JSONEncoder().encode(host)
        )

        // The bodyless row written by this (hypothetically buggy) encoder
        // pass is dropped by the decode-side normalization.
        XCTAssertEqual(decoded.sessionScripts.map(\.name), ["venv"])
        XCTAssertEqual(decoded.sessionScripts, [host.sessionScripts[0]])
    }

    func testScriptEditsDoNotChangeConnectionModelIdentity() {
        var host = Host(name: "devbox", hostname: "devbox.example.com", username: "dev")
        var edited = host
        edited.sessionScripts = [SessionScript(name: "venv", body: "source .venv/bin/activate")]
        host.updatedAt = .now

        // Adding or editing scripts must not tear down the probe connection.
        XCTAssertTrue(host.hasSameConnectionModelConfiguration(as: edited))
    }
}
