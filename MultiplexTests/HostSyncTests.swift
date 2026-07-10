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
    }

    func testHostRoundTripsThroughRecordEncoding() throws {
        let original = host("devbox", updatedAt: Date(timeIntervalSince1970: 1234))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
