import XCTest
@testable import Multiplex

final class FleetFeedIDTests: XCTestCase {
    func testPresentationOnlyHostEditsKeepTheSameFeedIdentity() {
        let host = makeHost()
        var edited = host
        edited.updatedAt = Date(timeIntervalSince1970: 1_000)
        edited.agentLaunchModels = [AgentKind.codex.rawValue: ["gpt-5.6"]]
        edited.newSessionTmuxConf = "mouse off"

        XCTAssertEqual(
            FleetFeedID(hosts: [host], active: true),
            FleetFeedID(hosts: [edited], active: true)
        )
    }

    func testConnectionEditChangesFeedIdentity() {
        let host = makeHost()
        var edited = host
        edited.hostname = "new.example.test"

        XCTAssertNotEqual(
            FleetFeedID(hosts: [host], active: true),
            FleetFeedID(hosts: [edited], active: true)
        )
    }

    func testActivationStateChangesFeedIdentity() {
        let host = makeHost()

        XCTAssertNotEqual(
            FleetFeedID(hosts: [host], active: true),
            FleetFeedID(hosts: [host], active: false)
        )
    }

    private func makeHost() -> Host {
        Host(
            id: UUID(uuidString: "AC159451-C02D-4638-B62B-A36F07CD0C1A")!,
            name: "devbox",
            hostname: "devbox.example.test",
            username: "multiplex"
        )
    }
}
