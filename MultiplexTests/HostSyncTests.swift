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
        // A record written before the deck switch existed is a host the user
        // expects to keep seeing on the wall.
        XCTAssertTrue(host.isEnabled)
        XCTAssertFalse(host.useMosh)
        XCTAssertNil(host.moshServerPath)
        XCTAssertNil(host.moshPorts)
        XCTAssertEqual(host.workingDirs, [])
        XCTAssertTrue(host.agentCommandConfiguration.isEmpty)
        XCTAssertEqual(host.agentLaunchModels, [:])
    }

    func testHostLaunchModelsRoundTripNormalizedAndKeepUnknownAgents() throws {
        var original = host("devbox", updatedAt: Date(timeIntervalSince1970: 1234))
        original.agentLaunchModels = [
            // Dupes collapse in order; a token the launch grammar rejects
            // can never ride a launch line, so it never becomes a picker row.
            "claudeCode": ["opus", "  opus  ", "sonnet[1m]", "not a model"],
            "codex": [],
            // A newer schema's agent must survive decode + re-encode here.
            "futureAgent": ["shiny-model"],
        ]
        original.agentLaunchModels = Host.normalizedLaunchModels(original.agentLaunchModels)
        XCTAssertEqual(
            original.agentLaunchModels,
            [
                "claudeCode": ["opus", "sonnet[1m]"],
                "futureAgent": ["shiny-model"],
            ]
        )
        XCTAssertEqual(original.launchModels(for: .claudeCode), ["opus", "sonnet[1m]"])
        XCTAssertEqual(original.launchModels(for: .codex), [])

        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
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

    func testProbeAndFeedIdentityIgnoreCommandSetupButChangeWithHostConfig() {
        let original = host("devbox")
        var commandsEdited = original
        commandsEdited.agentCommandConfiguration.replace(
            [CustomAgentCommand(content: "/review")],
            builtInPlacements: [:],
            for: .claudeCode
        )
        commandsEdited.newSessionTmuxConf = "mouse on\nhistory-limit 50000"
        commandsEdited.agentLaunchModels = ["claudeCode": ["opus"]]
        commandsEdited.updatedAt = .now

        XCTAssertTrue(
            original.hasSameConnectionModelConfiguration(as: commandsEdited)
        )
        XCTAssertEqual(
            FleetFeedID(hosts: [original], active: true),
            FleetFeedID(hosts: [commandsEdited], active: true)
        )

        var addressEdited = commandsEdited
        addressEdited.hostname = "new.example.com"
        XCTAssertFalse(
            original.hasSameConnectionModelConfiguration(as: addressEdited)
        )
        XCTAssertNotEqual(
            FleetFeedID(hosts: [original], active: true),
            FleetFeedID(hosts: [addressEdited], active: true)
        )
    }

    /// Switching a host off must reach the hub and the wall feed: both key
    /// off this identity, and dropping the live probe is what the restart
    /// does. It is also how a disable made on another device lands here.
    func testDisablingAHostChangesProbeAndFeedIdentity() {
        let original = host("devbox")
        var disabled = original
        disabled.isEnabled = false
        disabled.updatedAt = .now

        XCTAssertFalse(
            original.hasSameConnectionModelConfiguration(as: disabled)
        )
        XCTAssertNotEqual(
            FleetFeedID(hosts: [original], active: true),
            FleetFeedID(hosts: [disabled], active: true)
        )
    }

    func testDisabledHostRoundTripsThroughRecordEncoding() throws {
        var original = host("devbox", updatedAt: Date(timeIntervalSince1970: 1234))
        original.isEnabled = false

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.isEnabled)
    }

    /// The switch rides the synced record, so the newest edit wins across
    /// devices exactly like every other host field.
    func testNewerCloudDisableWinsWithTheHostRecord() {
        let local = host("devbox", updatedAt: Date(timeIntervalSince1970: 1000))
        var remote = local
        remote.isEnabled = false
        remote.updatedAt = Date(timeIntervalSince1970: 2000)

        let resolution = HostSync.merge(
            local: [local],
            cloud: [remote],
            mirrored: [local.id]
        )

        XCTAssertEqual(resolution.hosts, [remote])
        XCTAssertFalse(resolution.hosts[0].isEnabled)
        XCTAssertTrue(resolution.toPush.isEmpty)
    }

    @MainActor
    func testStoreSetEnabledPersistsLocallyAndMirrors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-enable-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let seeded = host("enable-test")
        let hostsURL = directory.appendingPathComponent("hosts.json")
        try JSONEncoder().encode([seeded]).write(to: hostsURL)

        // A mirror of the test's own: the write must reach the mirror, and
        // must not reach the simulator's real Keychain.
        let mirror = HostRecordMirror.inMemory()
        let store = HostStore(directory: directory, knownMirroredIDs: [], mirror: mirror)
        store.setEnabled(false, for: seeded.id)

        XCTAssertEqual(store.hosts.map(\.isEnabled), [false])

        let localHosts = try JSONDecoder().decode(
            [Host].self,
            from: Data(contentsOf: hostsURL)
        )
        XCTAssertFalse(localHosts[0].isEnabled)

        let mirrored = mirror.records()
            .compactMap { try? JSONDecoder().decode(Host.self, from: $0) }
            .first { $0.id == seeded.id }
        let mirroredHost = try XCTUnwrap(mirrored)
        XCTAssertFalse(mirroredHost.isEnabled)
        XCTAssertGreaterThan(mirroredHost.updatedAt, seeded.updatedAt)

        // Switching back on is the same one-field edit, not a re-add.
        store.setEnabled(true, for: seeded.id)
        XCTAssertEqual(store.hosts.map(\.isEnabled), [true])
        XCTAssertEqual(store.hosts.count, 1)
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

    // MARK: The mirror is inside the test boundary

    /// A store with an injected directory used to isolate `hosts.json` and
    /// still mirror every host into the simulator's real Keychain — which
    /// the app then adopted, a few more hosts per test run.
    @MainActor
    func testAStoreWithItsOwnDirectoryNeverWritesTheRealKeychain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostStore(directory: directory, knownMirroredIDs: [])
        let added = host("isolated")
        store.add(added)
        store.setEnabled(false, for: added.id)

        let leaked = KeychainStore.hostRecords()
            .compactMap { try? JSONDecoder().decode(Host.self, from: $0) }
            .contains { $0.id == added.id }
        XCTAssertFalse(leaked, "an isolated store reached the real Keychain mirror")
    }

    @MainActor
    func testTwoIsolatedStoresDoNotShareAMirror() async throws {
        func makeStore() -> (HostStore, URL) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HostSyncTests-\(UUID().uuidString)", isDirectory: true)
            return (HostStore(directory: directory, knownMirroredIDs: []), directory)
        }
        let (first, firstDirectory) = makeStore()
        let (second, secondDirectory) = makeStore()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        first.add(host("only-here"))
        // The second store's refresh reads ITS mirror: nothing to adopt.
        await second.refreshFromCloud()
        XCTAssertTrue(second.hosts.isEmpty)
        // And the first reads its own write back.
        await first.refreshFromCloud()
        XCTAssertEqual(first.hosts.map(\.name), ["only-here"])
    }

    /// The one test that touches the real Keychain, so the mirror's SecItem
    /// queries stay covered. Its payload is deliberately NOT a host record:
    /// the app decodes mirror records as `Host` and skips what does not
    /// parse, so even a run killed before the cleanup cannot add a host.
    @MainActor
    func testTheKeychainMirrorRoundTripsARecord() throws {
        let id = UUID()
        let payload = Data("multiplex-test-not-a-host-\(id.uuidString)".utf8)
        let mirror = HostRecordMirror.keychain
        defer { mirror.delete(id) }

        try XCTSkipUnless(
            mirror.set(payload, id), "this runner has no usable Keychain")
        XCTAssertTrue(mirror.records().contains(payload))
        XCTAssertThrowsError(try JSONDecoder().decode(Host.self, from: payload))

        mirror.delete(id)
        XCTAssertFalse(mirror.records().contains(payload))
    }
}
