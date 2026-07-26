#if !os(visionOS)
import Foundation
import GameController

/// Whether a physical keyboard is attached to this device right now.
///
/// GameController is the only public API that answers the question directly.
/// UIKit cannot: keyboard-frame notifications describe the *software*
/// keyboard, and a hardware keyboard suppresses that entirely — so "no
/// frames" is indistinguishable from "the user dismissed it". `GCKeyboard`
/// reports at the HID layer instead, which covers every iPad case alike
/// (Magic Keyboard, Smart Keyboard Folio, Bluetooth), and is the same layer
/// SwiftTerm's iOS-on-Mac control-key bridge already listens on.
///
/// The key rail uses this to decide what its rightmost key does. With a
/// hardware keyboard attached the software keyboard cannot be summoned at
/// all, so the keyboard toggle has nothing to toggle; the rail offers
/// dictation there instead — the one input affordance the hardware keyboard
/// itself does not carry.
///
/// ⚠ Simulator: Xcode's DeviceHub always bridges the Mac keyboard as a
/// *hardware* keyboard (CoreDevice HID), so this reads true in every
/// simulator run. That is correct — it is genuinely a hardware keyboard —
/// but it means the mic key, not the keyboard key, is what screenshot runs
/// capture.
@Observable
@MainActor
final class HardwareKeyboardMonitor {
    static let shared = HardwareKeyboardMonitor()

    private(set) var isConnected = false
    private var observing = false

    private init() {}

    /// Idempotent: every key rail calls this, only the first one installs.
    func startIfNeeded() {
        guard !observing else { return }
        observing = true
        isConnected = GCKeyboard.coalesced != nil
        for name in [Notification.Name.GCKeyboardDidConnect,
                     Notification.Name.GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func refresh() {
        apply(GCKeyboard.coalesced != nil)
        // The disconnect notification can arrive before GameController has
        // rebuilt `coalesced`, and a second keyboard may still be attached.
        // Settle on the next turn so the rail never latches a stale answer.
        DispatchQueue.main.async { [weak self] in
            self?.apply(GCKeyboard.coalesced != nil)
        }
    }

    private func apply(_ connected: Bool) {
        guard isConnected != connected else { return }
        isConnected = connected
    }
}
#endif
