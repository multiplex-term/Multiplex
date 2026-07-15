import XCTest
@testable import Multiplex

final class LocalNetworkAccessTests: XCTestCase {
    func testDenialRecordsTheBlockedHost() {
        let hostID = UUID()
        var state = LocalNetworkPermissionState()

        state.recordDenied(hostID: hostID)

        XCTAssertTrue(state.isDenied)
        XCTAssertEqual(state.deniedHostID, hostID)
    }

    func testReachablePublicHostDoesNotClearAnotherHostsDenial() {
        let localHostID = UUID()
        let publicHostID = UUID()
        var state = LocalNetworkPermissionState()
        state.recordDenied(hostID: localHostID)

        state.recordReady(hostID: publicHostID)

        XCTAssertTrue(state.isDenied)
        XCTAssertEqual(state.deniedHostID, localHostID)
    }

    func testBlockedHostBecomingReadyClearsDenial() {
        let hostID = UUID()
        var state = LocalNetworkPermissionState()
        state.recordDenied(hostID: hostID)

        state.recordReady(hostID: hostID)

        XCTAssertFalse(state.isDenied)
        XCTAssertNil(state.deniedHostID)
    }

    func testRemovingBlockedHostClearsIrrelevantDenial() {
        let blockedHostID = UUID()
        let remainingHostID = UUID()
        var state = LocalNetworkPermissionState()
        state.recordDenied(hostID: blockedHostID)

        state.retainConfiguredHosts([remainingHostID])

        XCTAssertFalse(state.isDenied)
    }
}
