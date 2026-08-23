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

    func testSharedCommandMirrorsAndStaysEditableFromAnyAgent() throws {
        let claudeOnly = CustomAgentCommand(content: "/claude")
        let shared = CustomAgentCommand(
            content: "review everything",
            autoSubmit: true,
            showInBar: true,
            shared: true
        )
        var configuration = AgentCommandConfiguration()

        configuration.replace(
            [claudeOnly, shared],
            builtInPlacements: [:],
            for: .claudeCode
        )
        XCTAssertEqual(
            configuration.commands(for: .claudeCode),
            [claudeOnly, shared]
        )
        XCTAssertEqual(configuration.commands(for: .codex), [shared])
        XCTAssertEqual(configuration.commands(for: .pi), [shared])

        var editedFromPi = shared
        editedFromPi.content = "review and test everything"
        editedFromPi.autoSubmit = false
        configuration.replace(
            [editedFromPi],
            builtInPlacements: [:],
            for: .pi
        )

        XCTAssertEqual(
            configuration.commands(for: .claudeCode),
            [claudeOnly, editedFromPi]
        )
        XCTAssertEqual(configuration.commands(for: .codex), [editedFromPi])
        XCTAssertEqual(configuration.commands(for: .pi), [editedFromPi])

        let data = try JSONEncoder().encode(configuration)
        var relaunched = try JSONDecoder().decode(
            AgentCommandConfiguration.self,
            from: data
        )
        XCTAssertEqual(relaunched, configuration)

        var piOnly = editedFromPi
        piOnly.shared = false
        relaunched.replace(
            [piOnly],
            builtInPlacements: [:],
            for: .pi
        )
        XCTAssertEqual(relaunched.commands(for: .claudeCode), [claudeOnly])
        XCTAssertTrue(relaunched.commands(for: .codex).isEmpty)
        XCTAssertEqual(relaunched.commands(for: .pi), [piOnly])
    }

    func testSharedCommandReplacesEquivalentLocalActionAndDeletesFromAll() {
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
        var configuration = AgentCommandConfiguration()

        configuration.replace(
            [local],
            builtInPlacements: [:],
            for: .codex
        )
        configuration.replace(
            [shared],
            builtInPlacements: [:],
            for: .claudeCode
        )
        XCTAssertEqual(configuration.commands(for: .claudeCode), [shared])
        XCTAssertEqual(configuration.commands(for: .codex), [shared])
        XCTAssertEqual(configuration.commands(for: .pi), [shared])

        configuration.replace(
            [],
            builtInPlacements: [:],
            for: .pi
        )
        XCTAssertTrue(configuration.commands(for: .claudeCode).isEmpty)
        XCTAssertTrue(configuration.commands(for: .codex).isEmpty)
        XCTAssertTrue(configuration.commands(for: .pi).isEmpty)
        XCTAssertTrue(configuration.isEmpty)
    }

    func testConfigurationRepairsOneSidedSharedCommandOnInitialization() {
        let shared = CustomAgentCommand(content: "/shared", shared: true)
        let configuration = AgentCommandConfiguration(profiles: [
            .init(agent: .claudeCode, commands: [shared]),
        ])

        XCTAssertEqual(configuration.commands(for: .claudeCode), [shared])
        XCTAssertEqual(configuration.commands(for: .codex), [shared])
        XCTAssertEqual(configuration.commands(for: .pi), [shared])
        XCTAssertEqual(configuration.commands(for: .grok), [shared])
    }

    func testConfigurationPersistsOrderedProfilesAndNormalizedPlacements() throws {
        let claude = [
            CustomAgentCommand(content: "/review", autoSubmit: true),
            CustomAgentCommand(
                content: "continue with the review",
                autoSubmit: false,
                showInBar: false
            ),
        ]
        let codex = [CustomAgentCommand(content: "/status")]
        let pi = [CustomAgentCommand(content: "/tree")]
        let grok = [CustomAgentCommand(content: "/doctor")]
        let antigravity = [CustomAgentCommand(content: "/skills")]
        var configuration = AgentCommandConfiguration()

        configuration.replace(
            claude,
            builtInPlacements: [
                "/clear": .more,
                "/context": .bar,
                // Defaults and stale IDs must not fossilize in Host JSON.
                "/resume": .bar,
                "removed-command": .more,
            ],
            for: .claudeCode
        )
        configuration.replace(
            codex,
            builtInPlacements: [:],
            for: .codex
        )
        configuration.replace(
            pi,
            builtInPlacements: ["/tree": .more, "/session": .bar],
            for: .pi
        )
        configuration.replace(
            grok,
            builtInPlacements: [:],
            for: .grok
        )
        configuration.replace(
            antigravity,
            builtInPlacements: [:],
            for: .antigravity
        )

        let expectedPlacements: [String: AgentCommandPlacement] = [
            "/clear": .more,
            "/context": .bar,
        ]
        XCTAssertEqual(configuration.commands(for: .claudeCode), claude)
        XCTAssertEqual(configuration.commands(for: .codex), codex)
        XCTAssertEqual(configuration.commands(for: .pi), pi)
        XCTAssertEqual(configuration.commands(for: .grok), grok)
        XCTAssertEqual(configuration.commands(for: .antigravity), antigravity)
        XCTAssertEqual(configuration.profiles.map(\.agent), AgentKind.allCases)
        XCTAssertEqual(
            configuration.builtInPlacements(for: .claudeCode),
            expectedPlacements
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(
            AgentCommandConfiguration.self,
            from: data
        )
        XCTAssertEqual(decoded, configuration)
    }

    func testConfigurationSkipsProfilesForAgentsThisBuildDoesNotKnow() throws {
        // A newer app can sync a profile for a CLI this build has no case
        // for; the record must still decode with every known profile intact.
        let json = """
        {"profiles": [
          {"agent": "codex", "commands": [], "builtInPlacements": {"/compact": "bar"}},
          {"agent": "someFutureAgent", "commands": [], "builtInPlacements": {"/x": "bar"}},
          {"agent": "grok", "commands": [], "builtInPlacements": {"/plan": "bar"}}
        ]}
        """
        let decoded = try JSONDecoder().decode(
            AgentCommandConfiguration.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.profiles.map(\.agent), [.codex, .grok])
        XCTAssertEqual(decoded.builtInPlacements(for: .grok), ["/plan": .bar])

        // Leniency is for the agent name only — a known agent's corrupt
        // profile still fails the decode rather than vanishing silently.
        let corrupt = """
        {"profiles": [{"agent": "codex", "commands": "nope", "builtInPlacements": {}}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(
            AgentCommandConfiguration.self, from: Data(corrupt.utf8)))
    }

    func testHostRecordRoundTripCarriesCommandSetupForKeychainSync() throws {
        let custom = CustomAgentCommand(
            content: "review this host",
            autoSubmit: false,
            shared: true
        )
        var host = Host(
            name: "devbox",
            hostname: "dev.example.com",
            username: "dev"
        )
        host.agentCommandConfiguration.replace(
            [custom],
            builtInPlacements: ["/clear": .more],
            for: .claudeCode
        )

        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(Host.self, from: data)

        XCTAssertEqual(decoded, host)
        XCTAssertEqual(
            decoded.agentCommandConfiguration.commands(for: .claudeCode),
            [custom]
        )
        XCTAssertEqual(
            decoded.agentCommandConfiguration.commands(for: .codex),
            [custom]
        )
        XCTAssertEqual(
            decoded.agentCommandConfiguration.commands(for: .pi),
            [custom]
        )
        XCTAssertEqual(
            decoded.agentCommandConfiguration.builtInPlacements(
                for: .claudeCode
            ),
            ["/clear": .more]
        )
    }

    func testHostStoreSaveWritesLocalCacheAndSynchronizableMirror() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-command-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = Host(
            name: "sync-test",
            hostname: "sync.example.com",
            username: "dev"
        )
        defer { KeychainStore.deleteHostRecord(for: host.id) }
        let hostsURL = directory.appendingPathComponent("hosts.json")
        try JSONEncoder().encode([host]).write(to: hostsURL)

        let store = HostStore(directory: directory, knownMirroredIDs: [])
        let custom = CustomAgentCommand(
            content: "review from every device",
            autoSubmit: false
        )
        store.replaceAgentCommandConfiguration(
            [custom],
            builtInPlacements: ["/clear": .more],
            for: .claudeCode,
            hostID: host.id
        )

        let localHosts = try JSONDecoder().decode(
            [Host].self,
            from: Data(contentsOf: hostsURL)
        )
        XCTAssertEqual(
            localHosts[0].agentCommandConfiguration.commands(for: .claudeCode),
            [custom]
        )

        let mirrored = KeychainStore.hostRecords()
            .compactMap { try? JSONDecoder().decode(Host.self, from: $0) }
            .first { $0.id == host.id }
        let mirroredHost = try XCTUnwrap(mirrored)
        XCTAssertEqual(
            mirroredHost.agentCommandConfiguration.commands(for: .claudeCode),
            [custom]
        )
        XCTAssertEqual(
            mirroredHost.agentCommandConfiguration.builtInPlacements(
                for: .claudeCode
            ),
            ["/clear": .more]
        )
        XCTAssertGreaterThan(mirroredHost.updatedAt, host.updatedAt)
    }
}
