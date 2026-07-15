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

    func testLegacyPlacementMigrationDoesNotExpandTheBar() throws {
        let hostID = UUID()
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

        let source = try XCTUnwrap(
            CustomAgentCommandMigration.decode(Data(json.utf8))
        )
        let commands = source.configuration(for: hostID).commands(
            for: .claudeCode
        )

        XCTAssertEqual(commands.map(\.showInBar), [true, false, false])
        XCTAssertEqual(commands.map(\.shared), [false, false, false])
        XCTAssertEqual(commands.map(\.barLabel), ["/review", nil, nil])
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

    func testConfigurationRepairsOneSidedSharedCommandOnDecode() throws {
        let shared = CustomAgentCommand(content: "/shared", shared: true)
        let configuration = AgentCommandConfiguration(profiles: [
            .init(agent: .claudeCode, commands: [shared]),
        ])

        XCTAssertEqual(configuration.commands(for: .claudeCode), [shared])
        XCTAssertEqual(configuration.commands(for: .codex), [shared])
        XCTAssertEqual(configuration.commands(for: .pi), [shared])
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

        let expectedPlacements: [String: AgentCommandPlacement] = [
            "/clear": .more,
            "/context": .bar,
        ]
        XCTAssertEqual(configuration.commands(for: .claudeCode), claude)
        XCTAssertEqual(configuration.commands(for: .codex), codex)
        XCTAssertEqual(configuration.commands(for: .pi), pi)
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

    func testPiProfileEncodingRemainsReadableByLegacyTwoAgentBuild() throws {
        let claude = CustomAgentCommand(content: "/review")
        let pi = CustomAgentCommand(content: "/tree")
        var configuration = AgentCommandConfiguration()
        configuration.replace(
            [claude],
            builtInPlacements: ["/clear": .more],
            for: .claudeCode
        )
        configuration.replace(
            [pi],
            builtInPlacements: ["/tree": .more],
            for: .pi
        )

        let data = try JSONEncoder().encode(configuration)
        let legacy = try JSONDecoder().decode(
            LegacyTwoAgentConfiguration.self,
            from: data
        )

        // Pi lives in a new ignored key, never in the strict legacy array.
        XCTAssertEqual(legacy.profiles.map(\.agent), [.claudeCode])
        XCTAssertEqual(legacy.profiles[0].commands, [claude])
        XCTAssertEqual(legacy.profiles[0].builtInPlacements, ["/clear": .more])

        // A real legacy save drops the unknown Pi keys. Current code must
        // recognize that round-trip as marker 0 rather than certifying an
        // intentionally empty Pi profile.
        let legacyRoundTrip = try JSONEncoder().encode(legacy)
        let recovered = try JSONDecoder().decode(
            AgentCommandConfiguration.self,
            from: legacyRoundTrip
        )
        XCTAssertEqual(recovered.piProfileVersion, 0)
        XCTAssertEqual(recovered.commands(for: .claudeCode), [claude])
        XCTAssertEqual(
            recovered.builtInPlacements(for: .claudeCode),
            ["/clear": .more]
        )
        XCTAssertTrue(recovered.commands(for: .pi).isEmpty)

        let current = try JSONDecoder().decode(
            AgentCommandConfiguration.self,
            from: data
        )
        XCTAssertEqual(current.commands(for: .pi), [pi])
        XCTAssertEqual(current.builtInPlacements(for: .pi), ["/tree": .more])
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
        XCTAssertEqual(decoded.agentCommandConfigurationVersion, 1)
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

    func testMigrationKeepsHostsIndependentAndScopedEmptyShadowsGlobal() throws {
        let studioID = UUID()
        let serverID = UUID()
        let clearedID = UUID()
        let legacy = CustomAgentCommand(content: "/legacy")
        let studio = CustomAgentCommand(content: "/studio", shared: true)
        let data = try JSONEncoder().encode([
            LegacyProfile(
                agent: .claudeCode,
                commands: [legacy],
                builtInPlacements: ["/clear": .more]
            ),
            LegacyProfile(
                hostID: studioID,
                agent: .claudeCode,
                commands: [studio],
                builtInPlacements: ["/context": .bar]
            ),
            // An explicit host-scoped empty profile means this host cleared
            // the former global setup and must not inherit it during migration.
            LegacyProfile(
                hostID: clearedID,
                agent: .claudeCode,
                commands: []
            ),
        ])
        let source = try XCTUnwrap(CustomAgentCommandMigration.decode(data))

        let studioConfiguration = source.configuration(for: studioID)
        XCTAssertEqual(
            studioConfiguration.commands(for: .claudeCode),
            [studio]
        )
        XCTAssertEqual(studioConfiguration.commands(for: .codex), [studio])
        XCTAssertEqual(studioConfiguration.commands(for: .pi), [studio])
        XCTAssertEqual(
            studioConfiguration.builtInPlacements(for: .claudeCode),
            ["/context": .bar]
        )

        let serverConfiguration = source.configuration(for: serverID)
        XCTAssertEqual(
            serverConfiguration.commands(for: .claudeCode),
            [legacy]
        )
        XCTAssertEqual(
            serverConfiguration.builtInPlacements(for: .claudeCode),
            ["/clear": .more]
        )
        XCTAssertTrue(source.configuration(for: clearedID).isEmpty)
    }

    func testMigrationFailsSoftOnMalformedJSON() {
        XCTAssertNil(CustomAgentCommandMigration.decode(Data("not json".utf8)))
    }

    private struct LegacyProfile: Codable {
        var hostID: UUID?
        var agent: AgentKind
        var commands: [CustomAgentCommand]
        var builtInPlacements: [String: AgentCommandPlacement]

        init(
            hostID: UUID? = nil,
            agent: AgentKind,
            commands: [CustomAgentCommand],
            builtInPlacements: [String: AgentCommandPlacement] = [:]
        ) {
            self.hostID = hostID
            self.agent = agent
            self.commands = commands
            self.builtInPlacements = builtInPlacements
        }
    }

    private enum LegacyTwoAgentKind: String, Codable {
        case claudeCode
        case codex
    }

    private struct LegacyTwoAgentProfile: Codable {
        var agent: LegacyTwoAgentKind
        var commands: [CustomAgentCommand]
        var builtInPlacements: [String: AgentCommandPlacement]
    }

    private struct LegacyTwoAgentConfiguration: Codable {
        var profiles: [LegacyTwoAgentProfile]
    }
}
