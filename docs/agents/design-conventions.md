# Design conventions

Split from AGENTS.md — the TALLY identity in code. Visual rationale: DESIGN.md.

- Bundle id `app.multiplexterm.multiplex`; device families are iPhone +
  iPad + Vision Pro in every configuration (one universal iOS binary —
  iPhone always runs the single-window shell). Min visionOS 1.0 / iOS 17.
- Design tokens live in `Theme.swift` — the TALLY identity: graphite
  chassis `#17181A`, screens darker than frames `#0A0B0C`, tally red
  `#E5484D` spent ONLY on live state and always captioned. Use tokens;
  **color is state, never decoration** (actions are neutral chips). Every
  token is appearance-dynamic (`Color(light:dark:)`): light is the Frost
  chassis `#E4E8EE`, screens *brighter* than frames (DESIGN.md
  "Daylight"). `chassis` stays an asset color so the launch screen hands
  off in either polarity. The appearance choice (`ThemeStore.appearance`:
  SYSTEM/LIGHT/DARK everywhere, plus GLASS on visionOS in every build) is
  applied by `UIKitSceneRootViewController.applyAppearance` through each
  scene window's `overrideUserInterfaceStyle` — never a mechanism that stops
  at presentation boundaries (SwiftUI's `preferredColorScheme` did). GLASS
  pins dark traits, shares DARK's terminal-theme slot, and independently
  rides `GlassAppearanceTrait`; `GlassSelectionState` mirrors it only where
  SwiftUI ornament/glass hosts cannot inherit that custom trait. Three
  traps: a visionOS sheet/popover hosts in its own window and misses an
  override already in place; a presented controller's own override beats
  its window's; and visionOS can retain a `UILabel`'s previously resolved
  dynamic ink after an in-place override. Presented chassis surfaces adopt
  `AppAppearanceFollowing` (`followAppAppearance(themes)` in
  Chassis.swift; a presenter with no store seeds from the scene window's
  applied style), and every override writer schedules
  `refreshDynamicTextColorsAfterTraitPropagation()` after trait delivery.
  Never write `.unspecified` over a scene window carrying a pinned override.
  Components in `Chassis.swift`: `ChassisLabel`
  (compressed caps), `ChassisChip`/`ChassisBadge` (square actions),
  `TallyLamp` (captioned state lamp), `ChassisSwitch` +
  `TallyFormBoolField` (monochrome switches — never the system green
  pill). `Font.mono` is the identity/data voice; body copy stays SF Pro.
- **Fixed-size chrome type always goes through `Font.mono` / `Font.ui`,
  never raw `.system(size:)`**: iOS-on-Mac paints the iPad point grid at
  77% with no opt-out, so both roles multiply by `Theme.typeScale` (1.3
  there, 1.0 everywhere else); `ChassisLabel` scales size + kerning
  together, type-locked accents ride the same scale, and control geometry
  deliberately stays authored. Semantic styles keep Dynamic Type
  (`preferredFont(forTextStyle:)` PLUS
  `adjustsFontForContentSizeCategory = true` in UIKit) and get the Mac
  boost once at the scene root (`traitOverrides
  .preferredContentSizeCategory`); the two mechanisms never compound.
  One recorded exception to "geometry stays authored": the hold-CTRL Key
  Commands panel scales its keycap faces, row buttons, steppers, switches,
  and fields by `Theme.typeScale` too (`KeyCommandMetrics`) — a 26-pt
  keycap holding a scaled glyph read as a toy part on the Mac
  (2026-08-16); the agent editor's shared switch/arrow controls keep the
  authored size unless handed a `scale`.
- **visionOS hover**: set `hoverStyle` (square `.rect(cornerRadius: 2)`)
  on every custom button/menu — on the CONTROL itself, never a
  subview/label (a label-level shape is silently ignored and you get the
  default rounded platter).
- **Terminal surface colors are user preference, not identity**: they come
  from the selected `TerminalTheme`, never `Theme` tokens. Each
  appearance keeps its own selection (`ThemeStore.selected(for:)`; the
  dark slot keeps the legacy UserDefaults key and defaults to `.tally`,
  light defaults to `.tallyFrost` — the light trio is contrast-tested in
  `TerminalThemeTests`). Open terminals re-skin live, and a scheme flip
  re-resolves through the pane's traits (`TerminalPaneUIKit`).
  `keyboardAppearance` stays `.default` — the keyboard belongs to the
  chassis appearance, not the terminal theme. tmux's own status line is
  left to the user's config (no `status-style` injection).
- Secrets never touch disk in plaintext — always `KeychainStore`, keyed by
  host UUID.
- Platform splits use `#if os(visionOS)`; iPad sits on chassis with a
  neutral `signal` tint, visionOS keeps native glass for system controls.
  SYSTEM/LIGHT/DARK keep form sheets, wall, and terminal chrome on opaque
  TALLY chassis. The visionOS-only GLASS choice instead paints exactly one
  smoked material ground per window/sheet, clears full-bleed intermediates,
  and uses strata/line/open-pane tokens above it; never stack smoke layers.
  The app-lock veil remains opaque in every appearance.
