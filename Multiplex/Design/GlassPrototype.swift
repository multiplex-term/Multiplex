import Observation
import UIKit

/// PROTOTYPE(GLASS): the SMOKE winner of the visionOS TALLY-on-glass
/// bake-off, offered as an **independent appearance choice** — GLASS sits
/// beside SYSTEM/LIGHT/DARK in Settings on visionOS, derives from the dark
/// palette (dark traits + dark terminal-theme slot), and leaves DARK itself
/// as opaque graphite. The spec and rollout live in
/// `local-plan/visionos-glass.md`; the frozen material numbers come from the
/// REV 4 mock in `local-plan/visionos-glass-bakeoff/`. Every gated call site
/// retains the `PROTOTYPE(GLASS)` lineage marker so the material system remains
/// auditable as a unit — the TALLY-prototype discipline
/// (`docs/design-bakeoff.md`).
///
/// Selection rides a custom trait: `UIKitSceneRootViewController
/// .applyAppearance` writes `GlassAppearanceTrait` onto the scene window,
/// and because the trait affects color appearance, every material below
/// re-resolves live — no view rebuilds, no relaunch. Modals apply too
/// (user direction): `pinHostingWindow` carries the trait onto each
/// sheet's own window, whose root paints `sheetGround` over the sheet
/// platter. Only the app-lock shield stays opaque (privacy veil).
///
/// The terminal WINDOW keeps its shipping GEOMETRY under GLASS (user
/// direction 2026-08-02: the padded 46pt platter-matching clip read as
/// "padding too large"): the 24pt bordered silhouette, the compact grid
/// gutter, and the hidden system platter all stay exactly as shipped.
/// Its REAL glass comes from `TerminalGlassWindowShell` — the scene root
/// mounts the window content inside a SwiftUI hierarchy owning a smoked
/// `glassBackgroundEffect` in the silhouette's shape, because system
/// glass renders behind UIKit content only from INSIDE its hierarchy (a
/// sibling effect composites OVER the window — verified 2026-08-02).
/// Do not rebuild the platter re-admission or a flat alpha-only tint.
struct GlassAppearanceTrait: UITraitDefinition {
    static let defaultValue = false
    static let affectsColorAppearance = true
}

/// SwiftUI-visible mirror of the selection for the ornament island —
/// custom UIKit traits are not relied on to cross `UIHostingOrnament`.
@MainActor
@Observable
final class GlassSelectionState {
    static let shared = GlassSelectionState()
    var isGlass = false
}

enum GlassPrototype {
    /// Whether the GLASS choice exists at all: every visionOS build offers it.
    /// iOS/iPadOS keep the three baseline choices and compile these materials
    /// only as inert fallbacks for shared source.
    #if os(visionOS)
    static let enabled = true
    #else
    static let enabled = false
    #endif

    /// The material switch: GLASS selected (and dark traits, which the
    /// selection pins) gets the glass recipe; every other appearance gets
    /// exactly the baseline color the site replaced — DARK stays opaque
    /// graphite, LIGHT stays opaque Frost, and flips happen live.
    static func material(_ glass: UIColor, fallback: UIColor) -> UIColor {
        UIColor { traits in
            traits[GlassAppearanceTrait.self] && traits.userInterfaceStyle == .dark
                ? glass.resolvedColor(with: traits)
                : fallback.resolvedColor(with: traits)
        }
    }

    // Raw dark-glass recipes — the REV 4 mock's frozen §2 numbers.
    /// The one window ground: smoke over the system glass platter. Painted
    /// exactly once per scene (the scene root); every full-bleed layer
    /// above it goes clear so the tint never stacks.
    static let smokeMaterial = UIColor(
        red: 20 / 255, green: 21 / 255, blue: 24 / 255, alpha: 0.55
    )
    /// Raised chrome — tiles, rails, slabs, chips, keys (replaces `bezel`).
    static let strataMaterial = UIColor(white: 1, alpha: 0.05)
    /// The same strata step, tinted with Catppuccin Mocha Mauve — a herdr
    /// tile on a host showing both backends (`TallyPalette.herdrBezel`
    /// carries the rationale and the opaque renditions). Mauve is darker
    /// than white, so 0.10 of it lifts about as much as white at 0.07: one
    /// step, in a different hue, rather than a brighter tile.
    static let herdrStrataMaterial = UIColor(
        red: 203 / 255, green: 166 / 255, blue: 247 / 255, alpha: 0.10
    )
    /// Hairlines and resting borders (replaces `bezelHi`).
    static let lineMaterial = UIColor(white: 1, alpha: 0.11)
    /// Active borders (lit spine segment, active tab). Part of the frozen
    /// spec; adopted by surfaces as their active-state passes land.
    static let lineHiMaterial = UIColor(white: 1, alpha: 0.22)
    /// Screens are open glass panes: ~10% smoke of their own, the room does
    /// the rest (replaces opaque `screen`).
    static let screenGlassMaterial = UIColor(
        red: 10 / 255, green: 11 / 255, blue: 12 / 255, alpha: 0.10
    )
    /// NO SIGNAL / AWAITING SIGNAL hatch: etched white stripes on the shared
    /// pane — coldness is the hatch and the absent lamp, not the material.
    static let hatchStripeMaterial = UIColor(white: 1, alpha: 0.04)
    /// Secondary-ink alpha ramp (the mock's §2 `--signal2`/`--signal3`):
    /// the light ink at reduced alpha over the smoke. The opaque dim grays
    /// were tuned for opaque chassis and go muddy-warm on glass (first
    /// seen on Command Setup's annotations).
    static let signal2Material = UIColor(
        red: 238 / 255, green: 242 / 255, blue: 245 / 255, alpha: 0.60
    )
    static let signal3Material = UIColor(
        red: 238 / 255, green: 242 / 255, blue: 245 / 255, alpha: 0.36
    )
    /// The terminal ground is the *selected theme's* background at this
    /// alpha, so a Gruvbox screen becomes Gruvbox-tinted smoke.
    static let screenAlpha: CGFloat = 0.10

    // Trait-resolved tokens for the common replacements.
    static let windowGround = material(smokeMaterial, fallback: TallyPalette.chassis)
    static let strata = material(strataMaterial, fallback: TallyPalette.bezel)
    static let herdrStrata = material(
        herdrStrataMaterial, fallback: TallyPalette.herdrBezel
    )
    static let line = material(lineMaterial, fallback: TallyPalette.bezelHi)
    static let lineHi = material(lineHiMaterial, fallback: TallyPalette.bezelHi)
    static let screenGlass = material(screenGlassMaterial, fallback: TallyPalette.screen)
    static let hatchStripe = material(
        hatchStripeMaterial, fallback: TallyPalette.screenHatch
    )
    static let signal2 = material(signal2Material, fallback: TallyPalette.signal2)
    static let signal3 = material(signal3Material, fallback: TallyPalette.signal3)
    /// Full-bleed layers above the window ground and bordered-only controls:
    /// clear on glass, their original opaque paint everywhere else.
    static let clearedChassis = material(.clear, fallback: TallyPalette.chassis)
    static let clearedScreen = material(.clear, fallback: TallyPalette.screen)
    /// Full-panel interior washes whose baseline is bezel (popover panel
    /// bodies): clear on glass so the root's smoke is the ONE ground and
    /// controls sit exactly one strata step above it — the Settings-sheet
    /// contrast the deck established. A bezel wash between smoke and
    /// controls lightened the whole panel and crushed button contrast.
    static let clearedBezel = material(.clear, fallback: TallyPalette.bezel)
    /// Sheets and modal hosts (user direction 2026-08-01: "all modals need
    /// apply"): each presented window's own platter carries the glass — the
    /// root paints one smoke layer, interiors clear over it.
    static let sheetGround = material(smokeMaterial, fallback: TallyPalette.chassis)
    /// Chassis-grounded controls (buttons, badges, switch tracks, pills)
    /// become strata over the smoke, like chips.
    static let strataChassis = material(strataMaterial, fallback: TallyPalette.chassis)

    /// Chrome that floats directly OVER live terminal content — the Select
    /// Text / Copy Mode / dictation block. Unlike every other strata
    /// surface, nothing carries the window smoke beneath it: the pane below
    /// is the theme tint at `screenAlpha` over real glass, so a 5% strata
    /// step leaves the block reading as scrolling text with chips over it.
    /// It brings its own ground — the window smoke recipe, dense enough
    /// that the content behind stops competing, still a material and not
    /// opaque graphite.
    static let floatingChromeMaterial = UIColor(
        red: 20 / 255, green: 21 / 255, blue: 24 / 255, alpha: 0.92
    )
    static let floatingChrome = material(
        floatingChromeMaterial, fallback: TallyPalette.bezel
    )

    /// Popover content roots (tmux shortcuts, Command Setup, agent HISTORY,
    /// the ctrl-combo slab): a popover hosts in its own window over its own
    /// bright platter, so the root paints the smoke there — the sheet
    /// recipe, popover-shaped — and interiors resolve strata over it once
    /// the presenter mirrors the trait across. Exact baseline otherwise.
    static func popoverGround(fallback: UIColor) -> UIColor {
        enabled ? material(smokeMaterial, fallback: fallback) : fallback
    }

    /// Terminal layers that must NOT tint: the pane wrapper below the
    /// surface and the grid's own layer go clear on glass (the surface
    /// wrapper carries the one tint); the opaque theme ground otherwise.
    static func terminalWrapperGround(themeBackground: UIColor) -> UIColor {
        enabled ? material(.clear, fallback: themeBackground) : themeBackground
    }

    /// The one pane tint — theme background at `screenAlpha` on glass,
    /// opaque otherwise. Carried by the terminal SURFACE wrapper, which
    /// spans the whole silhouette, so the tint reaches the window border
    /// instead of stopping at the inset grid.
    static func terminalGround(themeBackground: UIColor) -> UIColor {
        guard enabled else { return themeBackground }
        return material(
            themeBackground.withAlphaComponent(screenAlpha),
            fallback: themeBackground
        )
    }

    /// What the fork's `nativeBackgroundColor` receives: keep its own
    /// transparent-cell invariant on glass, the opaque ground otherwise.
    static func terminalNativeGround(themeBackground: UIColor) -> UIColor {
        enabled ? material(.clear, fallback: themeBackground) : themeBackground
    }
}
