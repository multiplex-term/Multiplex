import XCTest
@testable import Multiplex

@MainActor
final class CustomAgentCommandTests: XCTestCase {
    func testBarPlacementIsExplicitAndLongLabelsKeepOnlyNineCharacters() {
        XCTAssertEqual(
            CustomAgentCommand(content: "123456789", autoSubmit: false).barLabel,
            "123456789"
        )
        XCTAssertEqual(
            CustomAgentCommand(content: "1234567890").barLabel,
            "123456789..."
        )
        XCTAssertNil(
            CustomAgentCommand(content: "short", showInBar: false).barLabel
        )
        XCTAssertEqual(CustomAgentCommand(content: "one\ntwo").barLabel, "one↵two")
        XCTAssertEqual(CustomAgentCommand(content: "one\ttwo").barLabel, "one⇥two")
        XCTAssertNil(CustomAgentCommand(content: "   \n  ").barLabel)
    }

    func testRuntimeCommandPreservesMultilinePayloadAndSubmitChoice() {
        let custom = CustomAgentCommand(
            content: "  explain this\r\nthen test it  ",
            autoSubmit: false
        )
        let command = custom.agentCommand

        XCTAssertEqual(
            command.payload,
            Data("explain this\nthen test it".utf8)
        )
        XCTAssertFalse(command.submitsAfterPause)
        XCTAssertTrue(command.consumesSlashChipTaste)
        XCTAssertEqual(custom.menuLabel, "explain this …")
    }

    func testRuntimeCommandStripsInvisibleTerminalControls() {
        let custom = CustomAgentCommand(
            content: "safe\u{0002}\u{001B}\nnext\tvalue",
            autoSubmit: true
        )

        XCTAssertEqual(custom.normalizedContent, "safe\nnext\tvalue")
        XCTAssertFalse(custom.agentCommand.payload.contains(0x02))
        XCTAssertFalse(custom.agentCommand.payload.contains(0x1B))
    }

    func testNormalizationDropsBlankAndExactDuplicatesInOrder() {
        let first = CustomAgentCommand(content: "  /review  ", autoSubmit: true)
        let duplicate = CustomAgentCommand(content: "/review", autoSubmit: true)
        let typeOnly = CustomAgentCommand(content: "/review", autoSubmit: false)
        let multiline = CustomAgentCommand(content: "one\r\ntwo", autoSubmit: true)
        let blank = CustomAgentCommand(content: " \n ", autoSubmit: true)

        let resolved = CustomAgentCommand.normalized([
            first, duplicate, typeOnly, multiline, blank,
        ])

        XCTAssertEqual(resolved.map(\.content), ["/review", "/review", "one\ntwo"])
        XCTAssertEqual(resolved.map(\.autoSubmit), [true, false, true])
        XCTAssertEqual(resolved.first?.id, first.id)
    }

    func testDraftsIgnoreLateFocusedRowWriteAfterDeleteAndTrackMovesByID() {
        let first = CustomAgentCommand(content: "first")
        let second = CustomAgentCommand(content: "second")
        let drafts = CustomAgentCommandDrafts(commands: [first, second])

        drafts.remove(id: first.id)
        var lateFocusedWrite = first
        lateFocusedWrite.content = "stale edit"
        drafts.update(lateFocusedWrite, id: first.id)

        XCTAssertEqual(drafts.commands, [second])

        let third = drafts.appendBlank()
        drafts.move(id: third.id, offset: -1)
        XCTAssertEqual(drafts.commands.map(\.id), [third.id, second.id])
        XCTAssertEqual(drafts.command(id: second.id)?.content, "second")
    }

    func testStoreMigratesLegacyPlacementWithoutExpandingTheBar() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-commands-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let shortID = UUID()
        let longID = UUID()
        let tabID = UUID()
        let json = """
        [
          {
            "agent": "claudeCode",
            "commands": [
              {"id": "\(shortID)", "content": "/review", "autoSubmit": true},
              {"id": "\(longID)", "content": "explain this", "autoSubmit": false},
              {"id": "\(tabID)", "content": "one\\ttwo", "autoSubmit": true}
            ]
          }
        ]
        """
        try Data(json.utf8).write(to: file)

        let commands = CustomAgentCommandStore(fileURL: file)
            .commands(for: .claudeCode)

        XCTAssertEqual(commands.map(\.showInBar), [true, false, false])
        XCTAssertEqual(commands.map(\.shared), [false, false, false])
        XCTAssertEqual(commands.map(\.barLabel), ["/review", nil, nil])
    }

    func testSharedCommandMirrorsAndStaysEditableFromEitherAgent() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-commands-shared-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let claudeOnly = CustomAgentCommand(content: "/claude")
        let shared = CustomAgentCommand(
            content: "review everything",
            autoSubmit: true,
            showInBar: true,
            shared: true
        )
        let store = CustomAgentCommandStore(fileURL: file)

        store.replace([claudeOnly, shared], for: .claudeCode)
        XCTAssertEqual(store.commands(for: .claudeCode), [claudeOnly, shared])
        XCTAssertEqual(store.commands(for: .codex), [shared])

        var editedFromCodex = shared
        editedFromCodex.content = "review and test everything"
        editedFromCodex.autoSubmit = false
        store.replace([editedFromCodex], for: .codex)

        XCTAssertEqual(
            store.commands(for: .claudeCode),
            [claudeOnly, editedFromCodex]
        )
        XCTAssertEqual(store.commands(for: .codex), [editedFromCodex])

        let relaunched = CustomAgentCommandStore(fileURL: file)
        XCTAssertEqual(
            relaunched.commands(for: .claudeCode),
            [claudeOnly, editedFromCodex]
        )
        XCTAssertEqual(relaunched.commands(for: .codex), [editedFromCodex])

        var codexOnly = editedFromCodex
        codexOnly.shared = false
        relaunched.replace([codexOnly], for: .codex)
        XCTAssertEqual(relaunched.commands(for: .claudeCode), [claudeOnly])
        XCTAssertEqual(relaunched.commands(for: .codex), [codexOnly])
    }

    func testSharedCommandReplacesEquivalentLocalActionAndDeletesFromBoth() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-commands-shared-delete-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let local = CustomAgentCommand(
            content: "/review",
            autoSubmit: true,
            showInBar: false
        )
        let shared = CustomAgentCommand(
            content: "/review",
            autoSubmit: true,
            showInBar: true,
            shared: true
        )
        let store = CustomAgentCommandStore(fileURL: file)

        store.replace([local], for: .codex)
        store.replace([shared], for: .claudeCode)
        XCTAssertEqual(store.commands(for: .claudeCode), [shared])
        XCTAssertEqual(store.commands(for: .codex), [shared])

        store.replace([], for: .codex)
        XCTAssertTrue(store.commands(for: .claudeCode).isEmpty)
        XCTAssertTrue(store.commands(for: .codex).isEmpty)
    }

    func testStoreRepairsOneSidedSharedCommandOnLoad() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-commands-shared-load-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let shared = CustomAgentCommand(content: "/shared", shared: true)
        let data = try JSONEncoder().encode([
            LegacyProfile(agent: .claudeCode, commands: [shared]),
        ])
        try data.write(to: file)

        let store = CustomAgentCommandStore(fileURL: file)
        XCTAssertEqual(store.commands(for: .claudeCode), [shared])
        XCTAssertEqual(store.commands(for: .codex), [shared])
    }

    func testStorePersistsSeparateOrderedProfiles() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-commands-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let claude = [
            CustomAgentCommand(content: "/review", autoSubmit: true),
            CustomAgentCommand(
                content: "continue with the review",
                autoSubmit: false,
                showInBar: false
            ),
        ]
        let codex = [
            CustomAgentCommand(content: "/status", autoSubmit: true),
        ]

        let store = CustomAgentCommandStore(fileURL: file)
        store.replace(claude, for: .claudeCode)
        store.replace(codex, for: .codex)

        let relaunched = CustomAgentCommandStore(fileURL: file)
        XCTAssertEqual(relaunched.commands(for: .claudeCode), claude)
        XCTAssertEqual(relaunched.commands(for: .codex), codex)

        relaunched.replace([], for: .claudeCode)
        let afterDelete = CustomAgentCommandStore(fileURL: file)
        XCTAssertTrue(afterDelete.commands(for: .claudeCode).isEmpty)
        XCTAssertEqual(afterDelete.commands(for: .codex), codex)
    }

    func testStorePersistsBuiltInPlacementOverridesWithoutCustomCommands() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-command-placements-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = CustomAgentCommandStore(fileURL: file)
        store.replace(
            [],
            builtInPlacements: [
                "/clear": .more,
                "/context": .bar,
                // Stock choices and stale IDs should not fossilize in JSON.
                "/resume": .bar,
                "removed-command": .more,
            ],
            for: .claudeCode
        )

        let expected: [String: AgentCommandPlacement] = [
            "/clear": .more,
            "/context": .bar,
        ]
        XCTAssertEqual(store.builtInPlacements(for: .claudeCode), expected)
        XCTAssertTrue(store.commands(for: .claudeCode).isEmpty)
        XCTAssertTrue(store.builtInPlacements(for: .codex).isEmpty)

        let relaunched = CustomAgentCommandStore(fileURL: file)
        XCTAssertEqual(relaunched.builtInPlacements(for: .claudeCode), expected)

        // A custom-only save must retain the independently configured stock
        // layout rather than silently restoring defaults.
        let custom = CustomAgentCommand(content: "/review")
        relaunched.replace([custom], for: .claudeCode)
        XCTAssertEqual(relaunched.commands(for: .claudeCode), [custom])
        XCTAssertEqual(relaunched.builtInPlacements(for: .claudeCode), expected)

        relaunched.replace(
            [custom],
            builtInPlacements: [:],
            for: .claudeCode
        )
        let reset = CustomAgentCommandStore(fileURL: file)
        XCTAssertTrue(reset.builtInPlacements(for: .claudeCode).isEmpty)
        XCTAssertEqual(reset.commands(for: .claudeCode), [custom])
    }

    func testStoreFailsSoftOnMalformedJSON() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-commands-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)

        let store = CustomAgentCommandStore(fileURL: file)
        XCTAssertTrue(store.commands(for: .claudeCode).isEmpty)
        XCTAssertTrue(store.commands(for: .codex).isEmpty)
    }

    private struct LegacyProfile: Codable {
        var agent: AgentKind
        var commands: [CustomAgentCommand]
    }
}
