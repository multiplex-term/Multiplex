import XCTest
@testable import Multiplex

/// `SessionKey` is what stops a tmux `main` and a herdr `main` on one host
/// from being the same identity. Its storage form is load-bearing in three
/// files written by older builds — `deck-snapshots.json`, the App Group's
/// `widget-state.json`, and `MultiplexSessionOrders` in UserDefaults — so
/// the round trip and the legacy read are pinned here.
final class SessionKeyTests: XCTestCase {
    func testStorageKeyRoundTrips() {
        for backend in Host.SessionBackend.allCases {
            for name in ["main", "mpx-demo", "a.b_c-d", "0"] {
                let key = SessionKey(backend: backend, name: name)
                XCTAssertEqual(SessionKey(storageKey: key.storageKey), key)
            }
        }
    }

    func testABareNameReadsAsTmux() {
        // Every legacy file holds bare names, and every legacy file was
        // written for a single-backend host whose records decode to tmux.
        XCTAssertEqual(
            SessionKey(storageKey: "main"),
            SessionKey(backend: .tmux, name: "main")
        )
        XCTAssertEqual(
            SessionKey(storageKey: ""),
            SessionKey(backend: .tmux, name: "")
        )
    }

    func testOnlyAKnownBackendPrefixIsHonored() {
        // tmux session names may contain colons; herdr's grammar forbids
        // them. An unknown prefix must stay part of the NAME rather than
        // drop the record — losing a tile's saved slot is recoverable,
        // losing the tile is not.
        XCTAssertEqual(
            SessionKey(storageKey: "build:release"),
            SessionKey(backend: .tmux, name: "build:release")
        )
        XCTAssertEqual(
            SessionKey(storageKey: "zellij:main"),
            SessionKey(backend: .tmux, name: "zellij:main")
        )
        // Only the FIRST separator splits, so a tmux name with a colon
        // survives behind a real prefix.
        XCTAssertEqual(
            SessionKey(storageKey: "tmux:build:release"),
            SessionKey(backend: .tmux, name: "build:release")
        )
        XCTAssertEqual(
            SessionKey(storageKey: "herdr:main"),
            SessionKey(backend: .herdr, name: "main")
        )
    }

    func testSessionIDCarriesTheRecordsOwnBackend() {
        var session = TmuxSession(name: "main", windows: [], created: .distantPast)
        XCTAssertEqual(session.id, SessionKey(backend: .tmux, name: "main"))
        session.backend = .herdr
        XCTAssertEqual(session.id, SessionKey(backend: .herdr, name: "main"))
        // The whole point: same name, two identities.
        XCTAssertNotEqual(
            SessionKey(backend: .tmux, name: "main"),
            SessionKey(backend: .herdr, name: "main")
        )
    }

    func testTerminalRoutesCarryTheirCompleteSessionIdentity() {
        let hostID = UUID()
        XCTAssertEqual(
            TerminalRoute(hostID: hostID, mode: .attach(sessionName: "main")).sessionKey,
            SessionKey(backend: .tmux, name: "main")
        )
        XCTAssertEqual(
            TerminalRoute(hostID: hostID, mode: .herdrAttach(sessionName: "work")).sessionKey,
            SessionKey(backend: .herdr, name: "work")
        )
        XCTAssertNil(TerminalRoute(hostID: hostID, mode: .shell).sessionKey)
        XCTAssertNil(
            TerminalRoute(hostID: hostID, mode: .fileViewer(path: "/tmp")).sessionKey
        )
    }

    func testDictionaryReKeyingRoundTrips() {
        let byKey: [SessionKey: [String]] = [
            SessionKey(backend: .tmux, name: "main"): ["a"],
            SessionKey(backend: .herdr, name: "main"): ["b"],
        ]
        XCTAssertEqual(byKey.storageKeyed, ["tmux:main": ["a"], "herdr:main": ["b"]])
        XCTAssertEqual(byKey.storageKeyed.sessionKeyed, byKey)
        // A legacy map's bare names all land in tmux space, distinctly.
        XCTAssertEqual(
            ["main": ["a"], "scratch": ["b"]].sessionKeyed,
            [
                SessionKey(backend: .tmux, name: "main"): ["a"],
                SessionKey(backend: .tmux, name: "scratch"): ["b"],
            ]
        )
    }

    // MARK: The crash this type exists to prevent

    func testOrderingSurvivesTheSameNameOnBothBackends() {
        // `SessionOrdering.ordered` used to build a
        // `Dictionary(uniqueKeysWithValues:)` over session NAMES, which
        // TRAPS on a duplicate key — a fatal error on the deck's render path
        // for any mixed host with a saved tile order. Every other name-keyed
        // map merely lost data; this one crashed.
        var tmuxMain = TmuxSession(name: "main", windows: [], created: Date(timeIntervalSince1970: 1))
        var herdrMain = TmuxSession(name: "main", windows: [], created: Date(timeIntervalSince1970: 2))
        tmuxMain.tmuxID = "$0"
        herdrMain.backend = .herdr
        herdrMain.tmuxID = "main"

        let ordered = SessionOrdering.ordered(
            [tmuxMain, herdrMain],
            saved: ["herdr:main", "tmux:main"]
        )
        XCTAssertEqual(ordered.map(\.id), [herdrMain.id, tmuxMain.id])

        // And with no saved order at all — newest first, both kept.
        XCTAssertEqual(
            SessionOrdering.ordered([tmuxMain, herdrMain], saved: nil).map(\.id),
            [herdrMain.id, tmuxMain.id]
        )
    }

    func testALegacyBareNameOrderStillPlacesTmuxSessions() {
        let main = TmuxSession(name: "main", windows: [], created: Date(timeIntervalSince1970: 1))
        let scratch = TmuxSession(name: "scratch", windows: [], created: Date(timeIntervalSince1970: 2))
        var herdrMain = TmuxSession(name: "main", windows: [], created: Date(timeIntervalSince1970: 3))
        herdrMain.backend = .herdr

        // The saved list is what a pre-mixed build wrote: bare names. They
        // must still order the tmux tiles, and must NOT claim the herdr
        // namesake — which therefore leads as a new session.
        let ordered = SessionOrdering.ordered(
            [main, scratch, herdrMain],
            saved: ["scratch", "main"]
        )
        XCTAssertEqual(ordered.map(\.id), [herdrMain.id, scratch.id, main.id])
    }
}
