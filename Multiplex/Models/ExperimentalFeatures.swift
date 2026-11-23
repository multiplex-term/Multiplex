import Foundation

/// Features that ship behind a switch in Settings ▸ Experimental, off until
/// the user turns them on.
///
/// The Rex backend is the first: it speaks a preview server's wire protocol
/// (`RexSession`), which has already moved under it between two measurements
/// a week apart, so nobody meets it by accident.
///
/// ⚠ The switch is a fact about THIS device, never about a host. A host's
/// record keeps `rex` in `secondaryBackends` whatever the switch says — the
/// record syncs, and another device may have the feature on — and the gate
/// is applied where the record is read (`Host.SessionBackend.isAvailable`,
/// which `Host.monitoredBackends` and `monitors(_:)` ask). Turning the
/// switch off therefore hides Rex everywhere and forgets nothing.
///
/// `MULTIPLEX_REX=1` forces it on regardless of the stored choice — harness
/// runs and the unit-test scheme set it (`project.yml`), so a test that
/// builds a Rex host never depends on a simulator's defaults.
enum ExperimentalFeatures {
    static let rexBackendKey = "MultiplexRexBackend"

    /// Read once: the environment cannot change under a running process, and
    /// `ProcessInfo.environment` builds a dictionary on every call — this is
    /// asked per tile per render.
    private static let rexBackendForced =
        isForced(environment: ProcessInfo.processInfo.environment)

    static var isRexBackendEnabled: Bool {
        rexBackendForced || UserDefaults.standard.bool(forKey: rexBackendKey)
    }

    static func isRexBackendEnabled(
        defaults: UserDefaults, environment: [String: String]
    ) -> Bool {
        isForced(environment: environment) || defaults.bool(forKey: rexBackendKey)
    }

    static func setRexBackendEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: rexBackendKey)
    }

    private static func isForced(environment: [String: String]) -> Bool {
        environment["MULTIPLEX_REX"] == "1"
    }
}
