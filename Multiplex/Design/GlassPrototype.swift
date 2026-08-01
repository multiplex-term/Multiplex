import UIKit

/// PROTOTYPE(GLASS): the SMOKE winner of the visionOS TALLY-on-glass
/// bake-off, staged behind a DEBUG launch flag. Spec and rollout live in
/// `local-plan/visionos-glass.md`; the frozen material numbers come from the
/// REV 4 mock in `local-plan/visionos-glass-bakeoff/`. Every gated call site
/// is marked `PROTOTYPE(GLASS)` so the experiment deletes as a unit — the
/// TALLY-prototype discipline (docs/design-bakeoff.md).
enum GlassPrototype {
    #if os(visionOS) && DEBUG
    /// Launch-constant. `SIMCTL_CHILD_MULTIPLEX_GLASS=smoke` through simctl;
    /// never persisted, unreachable in Release and on iOS/iPadOS.
    static let active =
        ProcessInfo.processInfo.environment["MULTIPLEX_GLASS"] == "smoke"
    #else
    static let active = false
    #endif

    /// The one window ground: smoke over the system glass platter. Painted
    /// exactly once per scene (the scene root); every full-bleed layer above
    /// it goes clear so the tint never stacks.
    static let smokeTint = UIColor(
        red: 20 / 255, green: 21 / 255, blue: 24 / 255, alpha: 0.55
    )
    /// Raised chrome — tiles, rails, slabs, chips, keys (replaces `bezel`).
    static let strata = UIColor(white: 1, alpha: 0.05)
    /// Hairlines and resting borders (replaces `bezelHi`).
    static let line = UIColor(white: 1, alpha: 0.11)
    /// Active borders (lit spine segment, active tab). Part of the frozen
    /// spec; adopted by surfaces as their active-state passes land.
    static let lineHi = UIColor(white: 1, alpha: 0.22)
    /// Screens are open glass panes: ~10% smoke of their own, the room does
    /// the rest (replaces opaque `screen`).
    static let screenGlass = UIColor(
        red: 10 / 255, green: 11 / 255, blue: 12 / 255, alpha: 0.10
    )
    /// The terminal ground is the *selected theme's* background at this
    /// alpha, so a Gruvbox screen becomes Gruvbox-tinted smoke.
    static let screenAlpha: CGFloat = 0.10
    /// NO SIGNAL / AWAITING SIGNAL hatch: etched white stripes on the shared
    /// pane — coldness is the hatch and the absent lamp, not the material.
    static let hatchStripe = UIColor(white: 1, alpha: 0.04)
}
