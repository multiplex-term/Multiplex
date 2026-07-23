import SwiftTerm
import SwiftUI

/// Mounts on every scene root (`configuredRoot`): while the app lock is
/// engaged, an opaque chassis veil covers the scene — deck and terminal
/// windows alike — and the content beneath is disabled so surfaces the veil
/// cannot physically cover (visionOS ornaments: the UMD row, the key
/// cluster) cannot deliver input to a locked terminal.
/// The store arrives as a stored property, not `@Environment`: this modifier
/// sits OUTSIDE `configuredRoot`'s `.environment(...)` chain (like
/// `PlatformChrome`), where an environment lookup is a fatal miss.
struct AppLockGate: ViewModifier {
    var lock: AppLockStore

    func body(content: Content) -> some View {
        content
            .disabled(lock.isLocked)
            .overlay {
                if lock.isLocked {
                    AppLockVeil(lock: lock)
                }
            }
            .onChange(of: lock.isLocked, initial: true) { _, locked in
                // A first responder behind an overlay still receives every
                // hardware keystroke, and scene restoration can re-summon a
                // hidden responder while foregrounding — suppressing at the
                // arbiter (the app's one focus chokepoint) closes both.
                // View layer's job: the store cannot reach the arbiter
                // (Views → Services, never back).
                TerminalFocusArbiter.inputSuppressed = locked
            }
    }
}

/// The lock screen itself: chassis identity, a captioned caution lamp (color
/// is state), and one neutral action. Authentication is attempted once
/// automatically when the scene becomes active; after a cancelled or failed
/// prompt the UNLOCK chip retries explicitly.
private struct AppLockVeil: View {
    var lock: AppLockStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.chassis
            VStack(spacing: 20) {
                TallyLamp(caption: "LOCKED", color: Theme.caution)
                VStack(spacing: 6) {
                    ChassisLabel("MULTIPLEX", size: 15)
                    Text("\(AppLockStore.methodName.uppercased()) REQUIRED")
                        .font(.mono(9, weight: .medium))
                        .kerning(1.2)
                        .foregroundStyle(Theme.signal3)
                }
                ChassisChip("UNLOCK", prominent: true) {
                    Task { await lock.unlock() }
                }
                .disabled(lock.isAuthenticating)
            }
        }
        .ignoresSafeArea()
        .task {
            if scenePhase == .active { await lock.autoUnlock() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await lock.autoUnlock() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Multiplex is locked. Unlock with \(AppLockStore.methodName).")
    }
}

#if DEBUG
#Preview("App Lock Veil") {
    AppLockVeil(lock: AppLockStore(
        defaults: UserDefaults(suiteName: "preview.applock")!,
        authenticate: { _ in false }
    ))
    .frame(width: 700, height: 480)
    .preferredColorScheme(.dark)
}
#endif
