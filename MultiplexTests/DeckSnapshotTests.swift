import XCTest
@testable import Multiplex

final class DeckSnapshotTests: XCTestCase {
    private func sampleSnapshot() -> DeckSnapshot {
        DeckSnapshot(
            sessions: [
                TmuxSession(
                    name: "main",
                    windows: [
                        TmuxWindow(
                            index: 0, name: "editor", isActive: true,
                            hasBell: false, hasActivity: true,
                            agent: .claudeCode, paneTitle: "✳ Claude Code",
                            panes: [
                                TmuxPane(
                                    index: 0, isActive: true, tmuxID: "%0",
                                    pid: 42, tty: "/dev/pts/0", command: "claude",
                                    title: "✳ Claude Code", agent: .claudeCode
                                ),
                                TmuxPane(
                                    index: 1, isActive: false, tmuxID: "%1",
                                    pid: 43, tty: "/dev/pts/1", command: "codex",
                                    title: "repo", agent: .codex
                                ),
                                TmuxPane(
                                    index: 2, isActive: false, tmuxID: "%2",
                                    pid: 44, tty: "/dev/pts/2", command: "node",
                                    title: "π - repo", agent: .pi
                                ),
                            ]
                        ),
                    ],
                    clientCount: 2,
                    created: Date(timeIntervalSince1970: 1_751_500_000),
                    tmuxID: "$0",
                    serverHost: "Demo-MBPr14.local"
                ),
            ],
            miniatures: ["tmux:main": ["$ make test", "ok"]]
        )
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let snapshot = sampleSnapshot()
        let decoded = try JSONDecoder().decode(
            DeckSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        // The bits the wall renders from cache survive verbatim.
        XCTAssertEqual(decoded.sessions[0].activeAgent, .claudeCode)
        XCTAssertEqual(decoded.sessions[0].detectedAgents, [.claudeCode, .codex, .pi])
        XCTAssertEqual(decoded.sessions[0].paneCount, 3)
        XCTAssertTrue(decoded.sessions[0].isAttached)
        XCTAssertEqual(decoded.miniatures["tmux:main"], ["$ make test", "ok"])
        XCTAssertEqual(decoded.sessionBackend, .tmux)
        XCTAssertEqual(decoded.sessions[0].backend, .tmux)
        // Every file this build writes claims backend-keyed miniatures, so
        // reading one back never re-runs the legacy migration. The claim is
        // written by the encoder, never held as a property a caller could
        // set false.
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertEqual(json["keysCarryBackend"] as? Bool, true)
        // A cold launch must still be able to tell a real pane title from
        // tmux's seeded hostname, so the server host rides the snapshot.
        XCTAssertEqual(decoded.sessions[0].serverHost, "Demo-MBPr14.local")
        // This window carries three panes, so the active pane's title is not
        // the window's to advertise — the spine shows its pane count instead.
        XCTAssertEqual(decoded.sessions[0].windows[0].paneCount, 3)
        XCTAssertNil(
            decoded.sessions[0].windows[0].displayPaneTitle(
                serverHost: decoded.sessions[0].serverHost)
        )
    }

    func testSnapshotWrittenBeforePaneInventoryStillDecodes() throws {
        let json = """
        {
          "sessions": [{
            "name": "main",
            "windows": [{
              "index": 0,
              "name": "editor",
              "isActive": true,
              "hasBell": false,
              "hasActivity": false,
              "agent": "codex",
              "paneTitle": "repo"
            }],
            "clientCount": 0,
            "created": -978307200,
            "tmuxID": "$0"
          }],
          "miniatures": {}
        }
        """
        let decoded = try JSONDecoder().decode(DeckSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sessionBackend, .tmux,
                       "snapshots from before herdr support are tmux caches")
        XCTAssertEqual(decoded.sessions[0].activeAgent, .codex)
        XCTAssertEqual(decoded.sessions[0].detectedAgents, [.codex])
        XCTAssertEqual(decoded.sessions[0].paneCount, 1)
        // No serverHost was ever written, so suppression fails open rather
        // than hiding this session's titles until the next live probe.
        XCTAssertEqual(decoded.sessions[0].serverHost, "")
        XCTAssertEqual(
            decoded.sessions[0].windows[0].displayPaneTitle(serverHost: ""),
            "repo"
        )
    }

    @MainActor
    func testStorePersistsAcrossInstances() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-snapshot-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let hostID = UUID()

        let store = DeckSnapshotStore(fileURL: file)
        store.update(sampleSnapshot(), for: hostID)
        store.flush()

        let reloaded = DeckSnapshotStore(fileURL: file)
        XCTAssertEqual(reloaded.snapshot(for: hostID), sampleSnapshot())

        // A settled "nothing there" clears the entry…
        reloaded.update(nil, for: hostID)
        reloaded.flush()
        XCTAssertNil(DeckSnapshotStore(fileURL: file).snapshot(for: hostID))
    }

    @MainActor
    func testStoreRemoveDropsHost() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-snapshot-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let hostID = UUID()

        let store = DeckSnapshotStore(fileURL: file)
        store.update(sampleSnapshot(), for: hostID)
        store.remove(for: hostID)
        store.flush()
        XCTAssertNil(DeckSnapshotStore(fileURL: file).snapshot(for: hostID))
    }

    /// A file written before mixed hosts carries one whole-file backend,
    /// session records with no `backend` key, and BARE-name miniature keys.
    /// Read literally, a herdr host's cache would paint tmux-labelled tiles
    /// with no miniatures until the first live probe — so the decoder
    /// migrates it forward instead.
    func testALegacySingleBackendSnapshotMigratesForward() throws {
        let legacy = """
        {
          "sessions": [{
            "name": "mpx-demo",
            "windows": [],
            "clientCount": 0,
            "created": 763000000,
            "tmuxID": "mpx-demo"
          }],
          "miniatures": { "mpx-demo": ["$ herdr", "ok"] },
          "sessionBackend": "herdr"
        }
        """
        let decoded = try JSONDecoder().decode(
            DeckSnapshot.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.sessionBackend, .herdr)
        XCTAssertEqual(decoded.sessions.map(\.backend), [.herdr])
        XCTAssertEqual(decoded.sessions[0].id, SessionKey(backend: .herdr, name: "mpx-demo"))
        XCTAssertEqual(decoded.miniatures["herdr:mpx-demo"], ["$ herdr", "ok"])
        XCTAssertNil(decoded.miniatures["mpx-demo"])
        // Migration runs exactly once: rewriting the file marks it, so the
        // next read must not stamp `herdr:` onto an already-stamped key.
        let rewritten = try JSONDecoder().decode(
            DeckSnapshot.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(rewritten, decoded)
        XCTAssertEqual(rewritten.miniatures["herdr:mpx-demo"], ["$ herdr", "ok"])
    }

    /// The overwhelmingly common legacy file: a tmux host. It must land on
    /// exactly what it always meant, with no key rewriting visible.
    func testALegacyTmuxSnapshotDecodesUnchanged() throws {
        let legacy = """
        {
          "sessions": [{
            "name": "main",
            "windows": [],
            "clientCount": 1,
            "created": 763000000,
            "tmuxID": "$0"
          }],
          "miniatures": { "main": ["$ make test"] }
        }
        """
        let decoded = try JSONDecoder().decode(
            DeckSnapshot.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.sessionBackend, .tmux)
        XCTAssertEqual(decoded.sessions[0].id, SessionKey(backend: .tmux, name: "main"))
        XCTAssertEqual(decoded.miniatures["tmux:main"], ["$ make test"])
    }

    @MainActor
    func testModelNeverRestoresAnotherBackendsCache() {
        var host = Host(name: "devbox", hostname: "example.test", username: "dev")
        host.sessionBackend = .herdr
        let model = HostConnectionModel(host: host)

        model.restore(from: sampleSnapshot())

        XCTAssertEqual(model.tmux, .unknown)
        XCTAssertTrue(model.miniatures.isEmpty)
    }

    @MainActor
    func testModelRestorePrefillsOnlyBeforeFirstResult() {
        let host = Host(name: "devbox", hostname: "example.test", username: "dev")
        let model = HostConnectionModel(host: host)

        model.restore(from: sampleSnapshot())
        XCTAssertEqual(model.tmux.sessions.map(\.name), ["main"])
        XCTAssertEqual(
            model.miniatures[SessionKey(backend: .tmux, name: "main")],
            ["$ make test", "ok"]
        )
        // Liveness stays untouched: the rail still reads STANDBY, and
        // attention is re-earned by a live capture, never restored.
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.attention.isEmpty)

        // A second restore never overwrites a settled (or restored) state.
        model.restore(from: DeckSnapshot(sessions: [], miniatures: [:]))
        XCTAssertEqual(model.tmux.sessions.map(\.name), ["main"])
    }
}
