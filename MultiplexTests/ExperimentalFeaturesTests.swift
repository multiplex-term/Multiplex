import XCTest
@testable import Multiplex

/// The Rex backend is off until switched on, and the switch hides it without
/// touching a host's record.
final class ExperimentalFeaturesTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "ExperimentalFeaturesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testRexIsOffUntilSwitchedOn() {
        let defaults = makeDefaults()
        XCTAssertFalse(
            ExperimentalFeatures.isRexBackendEnabled(defaults: defaults, environment: [:]))
        ExperimentalFeatures.setRexBackendEnabled(true, defaults: defaults)
        XCTAssertTrue(
            ExperimentalFeatures.isRexBackendEnabled(defaults: defaults, environment: [:]))
        ExperimentalFeatures.setRexBackendEnabled(false, defaults: defaults)
        XCTAssertFalse(
            ExperimentalFeatures.isRexBackendEnabled(defaults: defaults, environment: [:]))
    }

    func testTheEnvironmentForcesRexOnWhateverIsStored() {
        let defaults = makeDefaults()
        XCTAssertTrue(ExperimentalFeatures.isRexBackendEnabled(
            defaults: defaults, environment: ["MULTIPLEX_REX": "1"]))
        XCTAssertFalse(ExperimentalFeatures.isRexBackendEnabled(
            defaults: defaults, environment: ["MULTIPLEX_REX": "0"]))
    }

    func testOnlyRexIsExperimental() {
        XCTAssertEqual(Host.SessionBackend.allCases.filter(\.isExperimental), [.rex])
        XCTAssertTrue(Host.SessionBackend.tmux.isAvailable(rexEnabled: false))
        XCTAssertTrue(Host.SessionBackend.herdr.isAvailable(rexEnabled: false))
        XCTAssertFalse(Host.SessionBackend.rex.isAvailable(rexEnabled: false))
        XCTAssertTrue(Host.SessionBackend.rex.isAvailable(rexEnabled: true))
    }

    func testAHostThatListsRexIsNotMonitoredForItWhileTheSwitchIsOff() throws {
        var host = Host(name: "devbox", hostname: "devbox.local", username: "dev")
        host.secondaryBackends = [.herdr, .rex]

        XCTAssertEqual(host.monitoredBackends(rexEnabled: true), [.tmux, .herdr, .rex])
        XCTAssertEqual(host.monitoredBackends(rexEnabled: false), [.tmux, .herdr])

        // The record is untouched: it syncs, and the switch is per device.
        XCTAssertEqual(host.secondaryBackends, [.herdr, .rex])
        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        XCTAssertEqual(decoded.secondaryBackends, [.herdr, .rex])
    }
}
