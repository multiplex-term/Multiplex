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
                    tmuxID: "$0"
                ),
            ],
            miniatures: ["main": ["$ make test", "ok"]]
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
        XCTAssertEqual(decoded.miniatures["main"], ["$ make test", "ok"])
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
        XCTAssertEqual(decoded.sessions[0].activeAgent, .codex)
        XCTAssertEqual(decoded.sessions[0].detectedAgents, [.codex])
        XCTAssertEqual(decoded.sessions[0].paneCount, 1)
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

    @MainActor
    func testModelRestorePrefillsOnlyBeforeFirstResult() {
        let host = Host(name: "devbox", hostname: "example.test", username: "dev")
        let model = HostConnectionModel(host: host)

        model.restore(from: sampleSnapshot())
        XCTAssertEqual(model.tmux.sessions.map(\.name), ["main"])
        XCTAssertEqual(model.miniatures["main"], ["$ make test", "ok"])
        // Liveness stays untouched: the rail still reads STANDBY, and
        // attention is re-earned by a live capture, never restored.
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.attention.isEmpty)

        // A second restore never overwrites a settled (or restored) state.
        model.restore(from: DeckSnapshot(sessions: [], miniatures: [:]))
        XCTAssertEqual(model.tmux.sessions.map(\.name), ["main"])
    }
}
