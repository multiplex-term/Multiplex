import Foundation
import LocalAuthentication
import Observation
import UIKit

/// Optional app lock: when enabled, the deck and every terminal window sit
/// behind an opaque chassis veil until the device owner authenticates —
/// Face ID / Touch ID / Optic ID, with the device passcode as the system
/// fallback (`.deviceOwnerAuthentication`), so losing biometric enrollment
/// never strands the user outside their own hosts.
///
/// The preference is device-local by design (UserDefaults, never the synced
/// keychain): the lock guards THIS device's screens, and a peer device
/// without biometrics must not inherit a requirement it cannot satisfy.
///
/// Locking rides `UIApplication.didEnterBackgroundNotification` — never
/// will-resign-active, which the system biometric prompt itself triggers (a
/// resign-active lock would re-lock the app in response to its own unlock
/// UI). Setting `isLocked` inside that notification also puts the veil in
/// place before the app-switcher snapshot is taken, so terminal content
/// never leaks into the switcher while the lock is on. Connections, probes,
/// and the wall keep running beneath the veil — this is a privacy screen,
/// not a data teardown.
@MainActor
@Observable
final class AppLockStore {
    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false

    /// One system prompt per lock, not per scene appearance: every window
    /// shows its own veil, and each would otherwise race an
    /// `evaluatePolicy` of its own. Manual retries (the UNLOCK chip) are
    /// never consumed.
    private var autoUnlockConsumed = false

    private let defaults: UserDefaults
    private let authenticate: (String) async -> Bool
    private nonisolated(unsafe) var backgroundObserver: NSObjectProtocol?
    private static let enabledKey = "MultiplexAppLockEnabled"

    /// `defaults`/`authenticate` are injectable for tests; the app uses the
    /// standard defaults and the LocalAuthentication check below.
    init(
        defaults: UserDefaults = .standard,
        authenticate: @escaping (String) async -> Bool = AppLockStore.deviceOwnerCheck
    ) {
        var authenticate = authenticate
        var enabled = defaults.bool(forKey: Self.enabledKey)
        #if DEBUG
        // Headless hooks (never persisted, like MULTIPLEX_PRO_LOCKED):
        // MULTIPLEX_APP_LOCK=1 starts this launch locked — the sim has no
        // passcode, so the real authenticator fails open and the veil
        // clears on the first automatic attempt, proving the unlock path.
        // MULTIPLEX_APP_LOCK=held refuses every authentication instead,
        // keeping the veil up for layout capture.
        switch ProcessInfo.processInfo.environment["MULTIPLEX_APP_LOCK"] {
        case "1": enabled = true
        case "held":
            enabled = true
            authenticate = { _ in false }
        default: break
        }
        #endif
        self.defaults = defaults
        self.authenticate = authenticate
        isEnabled = enabled
        isLocked = enabled
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    /// Engage the veil. Called on background; also the direct test seam.
    func lock() {
        guard isEnabled else { return }
        isLocked = true
        autoUnlockConsumed = false
    }

    /// The veil's automatic attempt when a scene becomes active — at most
    /// one system prompt per lock, so a cancelled prompt waits for the
    /// user's explicit UNLOCK tap instead of re-presenting in a loop.
    func autoUnlock() async {
        guard isLocked, !autoUnlockConsumed else { return }
        autoUnlockConsumed = true
        await attemptUnlock()
    }

    /// The UNLOCK chip's explicit attempt — always allowed while locked.
    func unlock() async {
        guard isLocked else { return }
        await attemptUnlock()
    }

    /// Enabling requires one successful authentication first: it confirms
    /// the device can actually satisfy the lock before the lock exists.
    /// Disabling is free — Settings is only reachable while unlocked, so
    /// the user has already authenticated this foreground.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        if enabled {
            guard await authenticate(
                "Confirm \(Self.methodName) to require it when Multiplex opens"
            ) else { return }
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { isLocked = false }
    }

    private func attemptUnlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await authenticate("Unlock Multiplex") {
            isLocked = false
        }
    }

    /// "Face ID" / "Touch ID" / "Optic ID", or the passcode fallback when
    /// no biometry is enrolled. `biometryType` is only valid after a
    /// `canEvaluatePolicy` call.
    nonisolated static var methodName: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: nil
        ) else { return "device passcode" }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "device passcode"
        }
    }

    /// The shipping authenticator. A device with no passcode cannot
    /// evaluate the policy at all; that fails OPEN — the alternative is
    /// permanent lockout, and a passcode-less device offers no secrecy for
    /// an app lock to extend.
    nonisolated static func deviceOwnerCheck(_ reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        else { return true }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication, localizedReason: reason
        )) ?? false
    }
}
