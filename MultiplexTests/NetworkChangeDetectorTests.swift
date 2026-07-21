import XCTest
@testable import Multiplex

final class NetworkChangeDetectorTests: XCTestCase {
    private func snapshot(
        satisfied: Bool = true,
        interfaces: [String] = ["en0"],
        gateways: [String] = ["192.168.1.1"]
    ) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            isSatisfied: satisfied,
            interfaces: interfaces,
            gateways: gateways
        )
    }

    func testFirstSnapshotIsBaselineNotChange() {
        var detector = NetworkChangeDetector()
        XCTAssertFalse(detector.register(snapshot()))
    }

    func testUnchangedPathNeverFires() {
        var detector = NetworkChangeDetector()
        _ = detector.register(snapshot())
        XCTAssertFalse(detector.register(snapshot()))
        XCTAssertFalse(detector.register(snapshot()))
    }

    func testInterfaceMoveFires() {
        var detector = NetworkChangeDetector()
        _ = detector.register(snapshot(interfaces: ["en0"]))
        XCTAssertTrue(detector.register(
            snapshot(interfaces: ["pdp_ip0"], gateways: ["10.0.0.1"])
        ))
    }

    func testGatewayOnlyChangeFires() {
        var detector = NetworkChangeDetector()
        _ = detector.register(snapshot(gateways: ["192.168.1.1"]))
        XCTAssertTrue(detector.register(snapshot(gateways: ["192.168.4.1"])))
    }

    func testLosingConnectivityRecordsButNeverFires() {
        var detector = NetworkChangeDetector()
        _ = detector.register(snapshot())
        XCTAssertFalse(detector.register(
            snapshot(satisfied: false, interfaces: [], gateways: [])
        ))
    }

    func testConnectivityReturningToSamePathFires() {
        // The blip severed the sockets even though the settled path is
        // identical to the one before it.
        var detector = NetworkChangeDetector()
        _ = detector.register(snapshot())
        _ = detector.register(
            snapshot(satisfied: false, interfaces: [], gateways: [])
        )
        XCTAssertTrue(detector.register(snapshot()))
    }

    func testFirstSnapshotAfterOfflineBaselineFires() {
        var detector = NetworkChangeDetector()
        _ = detector.register(
            snapshot(satisfied: false, interfaces: [], gateways: [])
        )
        XCTAssertTrue(detector.register(snapshot()))
    }

    func testVPNToggleFires() {
        var detector = NetworkChangeDetector()
        _ = detector.register(snapshot(interfaces: ["en0"]))
        XCTAssertTrue(detector.register(
            snapshot(interfaces: ["en0", "utun3"])
        ))
        XCTAssertFalse(detector.register(
            snapshot(interfaces: ["en0", "utun3"])
        ))
        XCTAssertTrue(detector.register(snapshot(interfaces: ["en0"])))
    }
}
