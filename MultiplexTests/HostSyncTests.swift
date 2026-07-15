import XCTest
@testable import Multiplex

final class HostSyncTests: XCTestCase {
    private func host(_ name: String, updatedAt: Date = .distantPast) -> Host {
        var host = Host(name: name, hostname: "\(name).example.com", username: "dev")
        host.updatedAt = updatedAt
        return host
    }

    func testLocalOnlyHostIsPushedNotDropped() {
        let local = host("devbox")
        let resolution = HostSync.merge(local: [local], cloud: [], mirrored: [])

        XCTAssertEqual(resolution.hosts, [local])
        XCTAssertEqual(resolution.toPush, [local])
        XCTAssertTrue(resolution.removedIDs.isEmpty)
    }

    func testCloudOnlyHostIsAdopted() {
        let remote = host("studio")
        let resolution = HostSync.merge(local: [], cloud: [remote], mirrored: [])

        XCTAssertEqual(resolution.hosts, [remote])
        XCTAssertTrue(resolution.toPush.isEmpty)
    }

    func testMirroredHostMissingFromCloudWasDeletedByPeer() {
        let deleted = host("devbox")
        let resolution = HostSync.merge(local: [deleted], cloud: [], mirrored: [deleted.id])

        XCTAssertTrue(resolution.hosts.isEmpty)
        XCTAssertTrue(resolution.toPush.isEmpty)
        XCTAssertEqual(resolution.removedIDs, [deleted.id])
    }

    func testNewerLocalEditWinsAndRepublishes() {
        var local = host("devbox", updatedAt: Date(timeIntervalSince1970: 2000))
        var remote = local
        remote.name = "stale"
        remote.updatedAt = Date(timeIntervalSince1970: 1000)
        local.name = "renamed"

        let resolution = HostSync.merge(local: [local], cloud: [remote], mirrored: [local.id])

        XCTAssertEqual(resolution.hosts, [local])
        XCTAssertEqual(resolution.toPush, [local])
    }

    func testNewerCloudEditWinsWithoutPush() {
        var local = host("devbox", updatedAt: Date(timeIntervalSince1970: 1000))
        var remote = local
        remote.name = "renamed-elsewhere"
        remote.updatedAt = Date(timeIntervalSince1970: 2000)
        local.name = "stale"

        let resolution = HostSync.merge(local: [local], cloud: [remote], mirrored: [local.id])

        XCTAssertEqual(resolution.hosts, [remote])
        XCTAssertTrue(resolution.toPush.isEmpty)
    }

    func testEqualTimestampsAreSteadyState() {
        let stamp = Date(timeIntervalSince1970: 1500)
        let local = host("devbox", updatedAt: stamp)

        let resolution = HostSync.merge(local: [local], cloud: [local], mirrored: [local.id])

        XCTAssertEqual(resolution.hosts, [local])
        XCTAssertTrue(resolution.toPush.isEmpty)
        XCTAssertTrue(resolution.removedIDs.isEmpty)
    }

    func testAdoptedHostsAppendAfterLocalSortedByName() {
        let localHost = host("zeta")
        let adoptedB = host("beta")
        let adoptedA = host("alpha")

        let resolution = HostSync.merge(
            local: [localHost],
            cloud: [adoptedB, adoptedA],
            mirrored: []
        )

        XCTAssertEqual(resolution.hosts.map(\.name), ["zeta", "alpha", "beta"])
    }

    func testHostDecodesRecordsWrittenBeforeUpdatedAtExisted() throws {
        let legacy = Data("""
        {
          "id": "6F1E9A3C-4B4C-4B7B-9A57-2B9E2E64A111",
          "name": "devbox",
          "hostname": "10.0.1.12",
          "port": 22,
          "username": "dev",
          "authMethod": "password"
        }
        """.utf8)

        let host = try JSONDecoder().decode(Host.self, from: legacy)
        XCTAssertEqual(host.name, "devbox")
        XCTAssertEqual(host.updatedAt, .distantPast)
        XCTAssertFalse(host.useMosh)
        XCTAssertNil(host.moshServerPath)
        XCTAssertNil(host.moshPorts)
        XCTAssertEqual(host.workingDirs, [])
        XCTAssertTrue(host.agentCommandConfiguration.isEmpty)
        XCTAssertEqual(host.agentCommandConfigurationVersion, 0)
    }

    func testHostRoundTripsThroughRecordEncoding() throws {
        let original = host("devbox", updatedAt: Date(timeIntervalSince1970: 1234))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testNewerCloudCommandSetupWinsWithTheHostRecord() {
        var local = host("devbox", updatedAt: Date(timeIntervalSince1970: 1000))
        var remote = local
        let remoteCommand = CustomAgentCommand(content: "/from-ipad")
        remote.agentCommandConfiguration.replace(
            [remoteCommand],
            builtInPlacements: ["/clear": .more],
            for: .claudeCode
        )
        remote.updatedAt = Date(timeIntervalSince1970: 2000)

        let resolution = HostSync.merge(
            local: [local],
            cloud: [remote],
            mirrored: [local.id]
        )

        XCTAssertEqual(resolution.hosts, [remote])
        XCTAssertEqual(
            resolution.hosts[0].agentCommandConfiguration.commands(
                for: .claudeCode
            ),
            [remoteCommand]
        )
        XCTAssertTrue(resolution.toPush.isEmpty)
    }

    func testNewerLegacyCloudEditCannotEraseLocalCommandSetup() {
        var local = host("devbox", updatedAt: Date(timeIntervalSince1970: 1000))
        let command = CustomAgentCommand(content: "/keep-me")
        local.agentCommandConfiguration.replace(
            [command],
            builtInPlacements: ["/clear": .more],
            for: .claudeCode
        )

        var legacyRemote = local
        legacyRemote.name = "renamed-on-old-ipad"
        legacyRemote.agentCommandConfiguration = AgentCommandConfiguration()
        legacyRemote.agentCommandConfigurationVersion = 0
        legacyRemote.updatedAt = Date(timeIntervalSince1970: 2000)

        let resolution = HostSync.merge(
            local: [local],
            cloud: [legacyRemote],
            mirrored: [local.id]
        )

        XCTAssertEqual(resolution.hosts[0].name, "renamed-on-old-ipad")
        XCTAssertEqual(
            resolution.hosts[0].agentCommandConfiguration.commands(
                for: .claudeCode
            ),
            [command]
        )
        XCTAssertEqual(resolution.hosts[0].agentCommandConfigurationVersion, 1)
        XCTAssertEqual(resolution.toPush, resolution.hosts)
    }

    func testNewerLegacyLocalEditMergesCloudCommandsBeforeRepublishing() {
        var remote = host("devbox", updatedAt: Date(timeIntervalSince1970: 1000))
        let command = CustomAgentCommand(content: "/from-vision-pro")
        remote.agentCommandConfiguration.replace(
            [command],
            builtInPlacements: [:],
            for: .codex
        )

        var legacyLocal = remote
        legacyLocal.hostname = "edited-by-old-build.example.com"
        legacyLocal.agentCommandConfiguration = AgentCommandConfiguration()
        legacyLocal.agentCommandConfigurationVersion = 0
        legacyLocal.updatedAt = Date(timeIntervalSince1970: 2000)

        let resolution = HostSync.merge(
            local: [legacyLocal],
            cloud: [remote],
            mirrored: [remote.id]
        )

        XCTAssertEqual(
            resolution.hosts[0].hostname,
            "edited-by-old-build.example.com"
        )
        XCTAssertEqual(
            resolution.hosts[0].agentCommandConfiguration.commands(for: .codex),
            [command]
        )
        XCTAssertEqual(resolution.toPush, resolution.hosts)
    }

    func testNewerOldPeerEditCannotErasePiProfile() {
        var local = host("devbox", updatedAt: Date(timeIntervalSince1970: 1000))
        let piCommand = CustomAgentCommand(content: "/tree")
        local.agentCommandConfiguration.replace(
            [piCommand],
            builtInPlacements: ["/tree": .more],
            for: .pi
        )

        var oldPeer = local
        oldPeer.hostname = "edited-on-old-ipad.example.com"
        let newerClaudeCommand = CustomAgentCommand(content: "/from-old-ipad")
        oldPeer.agentCommandConfiguration = AgentCommandConfiguration(
            profiles: [
                .init(agent: .claudeCode, commands: [newerClaudeCommand]),
            ],
            // Simulates a build that ignored and then dropped the Pi keys.
            piProfileVersion: 0
        )
        oldPeer.updatedAt = Date(timeIntervalSince1970: 2000)

        let resolution = HostSync.merge(
            local: [local],
            cloud: [oldPeer],
            mirrored: [local.id]
        )

        let merged = resolution.hosts[0]
        XCTAssertEqual(merged.hostname, "edited-on-old-ipad.example.com")
        XCTAssertEqual(
            merged.agentCommandConfiguration.commands(for: .claudeCode),
            [newerClaudeCommand]
        )
        XCTAssertEqual(
            merged.agentCommandConfiguration.commands(for: .pi),
            [piCommand]
        )
        XCTAssertEqual(
            merged.agentCommandConfiguration.builtInPlacements(for: .pi),
            ["/tree": .more]
        )
        XCTAssertEqual(merged.agentCommandConfiguration.piProfileVersion, 1)
        XCTAssertEqual(resolution.toPush, resolution.hosts)
    }

    func testCurrentClaudeEditOfLegacyRecordStillRecoversPiFromPeer() {
        var survivor = host("devbox", updatedAt: Date(timeIntervalSince1970: 1000))
        let piCommand = CustomAgentCommand(content: "/tree")
        survivor.agentCommandConfiguration.replace(
            [piCommand],
            builtInPlacements: ["/tree": .more],
            for: .pi
        )

        var editedLegacy = survivor
        editedLegacy.agentCommandConfiguration = AgentCommandConfiguration(
            profiles: [],
            piProfileVersion: 0
        )
        editedLegacy.agentCommandConfiguration.replace(
            [CustomAgentCommand(content: "/from-current-device")],
            builtInPlacements: [:],
            for: .claudeCode
        )
        XCTAssertEqual(
            editedLegacy.agentCommandConfiguration.piProfileVersion,
            0
        )
        editedLegacy.updatedAt = Date(timeIntervalSince1970: 2000)

        let resolution = HostSync.merge(
            local: [survivor],
            cloud: [editedLegacy],
            mirrored: [survivor.id]
        )

        let configuration = resolution.hosts[0].agentCommandConfiguration
        XCTAssertEqual(
            configuration.commands(for: .claudeCode).map(\.content),
            ["/from-current-device"]
        )
        XCTAssertEqual(configuration.commands(for: .pi), [piCommand])
        XCTAssertEqual(configuration.piProfileVersion, 1)
        XCTAssertEqual(resolution.toPush, resolution.hosts)
    }

    func testOldPeerDeletionDoesNotResurrectPiSharedCopy() {
        var local = host("devbox", updatedAt: Date(timeIntervalSince1970: 1000))
        let shared = CustomAgentCommand(content: "/review", shared: true)
        local.agentCommandConfiguration.replace(
            [shared],
            builtInPlacements: [:],
            for: .claudeCode
        )

        var oldPeer = local
        oldPeer.agentCommandConfiguration = AgentCommandConfiguration(
            profiles: [],
            piProfileVersion: 0
        )
        oldPeer.updatedAt = Date(timeIntervalSince1970: 2000)

        let resolution = HostSync.merge(
            local: [local],
            cloud: [oldPeer],
            mirrored: [local.id]
        )

        XCTAssertTrue(resolution.hosts[0].agentCommandConfiguration.isEmpty)
        XCTAssertEqual(
            resolution.hosts[0].agentCommandConfiguration.piProfileVersion,
            1
        )
        XCTAssertEqual(resolution.toPush, resolution.hosts)
    }

    func testOldPeerUnshareDoesNotReshareFromPiCopy() {
        var local = host("devbox", updatedAt: Date(timeIntervalSince1970: 1000))
        let shared = CustomAgentCommand(content: "/review", shared: true)
        local.agentCommandConfiguration.replace(
            [shared],
            builtInPlacements: [:],
            for: .claudeCode
        )

        var codexOnly = shared
        codexOnly.shared = false
        var oldPeer = local
        oldPeer.agentCommandConfiguration = AgentCommandConfiguration(
            profiles: [
                .init(agent: .codex, commands: [codexOnly]),
            ],
            piProfileVersion: 0
        )
        oldPeer.updatedAt = Date(timeIntervalSince1970: 2000)

        let resolution = HostSync.merge(
            local: [local],
            cloud: [oldPeer],
            mirrored: [local.id]
        )

        let configuration = resolution.hosts[0].agentCommandConfiguration
        XCTAssertTrue(configuration.commands(for: .claudeCode).isEmpty)
        XCTAssertEqual(configuration.commands(for: .codex), [codexOnly])
        XCTAssertTrue(configuration.commands(for: .pi).isEmpty)
        XCTAssertEqual(configuration.piProfileVersion, 1)
        XCTAssertEqual(resolution.toPush, resolution.hosts)
    }

    func testCommandSetupDoesNotChangeProbeConnectionConfiguration() {
        let original = host("devbox")
        var commandsEdited = original
        commandsEdited.agentCommandConfiguration.replace(
            [CustomAgentCommand(content: "/review")],
            builtInPlacements: [:],
            for: .claudeCode
        )
        commandsEdited.updatedAt = .now

        XCTAssertTrue(
            original.hasSameConnectionModelConfiguration(as: commandsEdited)
        )

        var addressEdited = commandsEdited
        addressEdited.hostname = "new.example.com"
        XCTAssertFalse(
            original.hasSameConnectionModelConfiguration(as: addressEdited)
        )
    }

    func testHostMoshFieldsRoundTripThroughRecordEncoding() throws {
        var original = host("devbox", updatedAt: Date(timeIntervalSince1970: 1234))
        original.useMosh = true
        original.moshServerPath = "/opt/homebrew/bin/mosh-server"
        original.moshPorts = "60000:61000"

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.useMosh)
        XCTAssertEqual(decoded.moshServerPath, "/opt/homebrew/bin/mosh-server")
        XCTAssertEqual(decoded.moshPorts, "60000:61000")
    }
}
