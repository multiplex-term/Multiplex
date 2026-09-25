# iPhone Duo

The foldable iPhone: display facts, the pose matrix, and the shell rules
that follow. Pose board link in `local-plan/iphone-duo.md`. Needs Xcode
27.1 (Duo simulator, reserved-region SDK).

## Device facts

Measured on the 27.1 simulator with `MULTIPLEX_DUO_PROBE=1` (log category
`duo`, `log stream` only).

- Outer display 466×678 pt: compact × regular portrait, compact × compact
  landscape. 84 pt system column on the trailing edge (leading in the
  other landscape), 34 pt home strip, no top inset. Keyboard 252 / 193.
- Inner display 951×669 (book) / 669×951 (laptop): regular × regular both
  ways; ignores `UISupportedInterfaceOrientations`. Landscape: 84 pt
  trailing column, no top inset, `verticalBarEdge` trailing. Portrait:
  82 pt top inset, no column. Keyboard 227 / 311.
- Fold band 40 pt centred at 455.5…495.5 on the 951 axis; pages 455.5,
  the page under the column keeps 371.5.
- `UIHingeInteraction`: `fullyOpen` at π, `partiallyOpen` ≈2.23 rad in the
  book pose, `closed` at 0.
- ⚠ `reservedRegions(kind: .division)` is empty in every pose on the
  simulator (view and window, `.includeInactive` included). The shell
  synthesises the band from the hinge status (`DuoFoldGeometry`) whenever
  the query is empty; drop the fallback once hardware reports regions.
- One scene, persisted across open/close. Multi-scene stays off on phones
  (`~iphone` manifest). Split View hands the app a compact-width half.
- App-owned bars are not moved by the system: the UMD rail's and the key
  rail's edge is our rule. APIs: `verticalBarEdge`, `reservedRegions`,
  `UIArrangementViewController`, `UIHingeInteraction`.
- Simulator: no simctl pose command; DeviceHub window group 1 buttons
  4 rotate / 5 closed / 6 book / 7 open via System Events. Outer display
  screenshots need `--display=<port UUID from simctl io enumerate>`.
  `./Tools/build.sh build duo -configuration Debug` (Release lands
  otherwise). DEBUG env: `MULTIPLEX_DUO_PROBE=1`, `MULTIPLEX_AUTO_HIDE_DECK=1`
  (◧ HIDE once), with the `SIMCTL_CHILD_` prefix.

## Rules (pure models, unit-tested)

- **Window model** — the single-scene Shell in every pose.
- **Expand** — `SingleWindowShellLayout.isExpanded(…)`. Phone: split only
  while the terminal beside the 316 pt deck rail keeps 390
  (`phoneTerminalMinimumWidth`, the key rail's unlocked TMUX tier). Pad:
  620 of usable width. Consequence: SE-class 667-wide landscape drops to
  single pane. Duo: closed landscape and open portrait single, open
  landscape 316 | 635.
- **Fold** — `resolve(…, division:)` takes the active division region
  (nil when flat). Vertical: expanded regardless of width and ◧ HIDE (the
  left page is never empty); deck = 0…minX, terminal from maxX, the
  divider is the region. Horizontal: single pane, terminal in the top
  region, `consoleFrame` the bottom one — key rail on the fold, below it
  the first of keyboard, composer, ▤/⌗ panel, C/B or Key Commands slabs,
  else the deck rail.
- **Corner inset** — `cornerLeadingInset(…)`: 24 pt on the header row of
  the pane owning a bare display corner (inner landscape: no top inset,
  55 pt corners). Regular width only: the closed corner is 6 pt. Deck
  header (`headerCornerInset`) or UMD rail (`railCornerInset`), never the
  pane; ◧ HIDE hands the corner to the terminal. Never a top shift.
- **System glyph line** — `systemGlyphLine` 48: iOS draws the clock and
  radio glyphs 48 pt from the display edge, not at the centre of its strip
  or band. Column chips centre on `sideColumnCenterX` (edge − 48), band
  rows on `topBandRowCenter` (48). Align to measured glyphs, never to
  safe-area geometry.
- **Home strip** — `railAlwaysTakesBottomStrip`: a foldable (the shell saw
  a hinge) or iPad spends the 34 pt home strip under the key rail in every
  pose; a shipped iPhone in portrait keeps its backfill band.
- **Bare chrome** — `chromeIsBare` (foldable phone, every display): source
  strip and key rail drop the bezel slab and 1 pt rule; the shell's
  backfill bands above and below the terminal wear the pane's ground. On
  the Duo's dark ground the slabs read as grey bars. Geometry unchanged;
  shipped iPhones and iPad keep the slab.
- **Bare top padding** — `bareTopPadding` 8 pt on the content origin of
  the inner display with no top inset (the top edge itself was not
  reliably pressable); nothing on a compact layout.
- **Top band** — `topBandHeight(…)`: phone, regular × regular, top inset
  ≥ 60 (inner portrait, laptop top region): content starts at y 0, the
  band is content — the horizontal UMD rail and the deck header sit on the
  glyph line with a 128 pt trailing clearance for the clock cluster. The
  console deck below the fold gets no band. The corner inset and band
  travel as one `ShellHeaderChrome` per pane.
- **Rail edge** — `ShellRailPlacement.edge(…)`: a system-reported
  vertical-bar edge wins; else phone + regular × regular + landscape is
  `.leading`; a foldable phone in compact landscape (closed display, no
  system bar) takes the camera's safe strip, whichever side is wider. A
  shipped iPhone never moves. Resolved from live traits by
  `ShellRailPlacement.edge(traits:…)`, once in the shell (deck) and once
  in the terminal window. Shell presentation only.
- **Column** — on a side edge the UMD renders as
  `UMDBarStyle.verticalColumn`: 44 pt symbol-over-caption chips 4 pt
  apart, centred on the glyph line, ending above the keyboard. Placement
  (`RailFit.columnPlacement`): inner display starts 120 pt down (under the
  glyphs); closed portrait 160 (glyphs under the camera); closed landscape
  keeps 80 pt clear of the camera end (30…66 pt from the corner: top when
  leading, bottom when turned around) and 12 of the other, and the chips
  gather at the camera's end. The shell hands `displayIsLandscape` down
  (screen bounds lag a rotation's layout pass). Order: DECK, A−, A+,
  + TAB, FILE, TMUX (only when the key rail dropped it), ⋯, DETACH.
  `RailFit` (one rule for column and horizontal row) drops MERGE, GUIDE,
  A−, A+, + TAB, FILE, DETACH, TMUX in that order — A−/A+ together, DECK
  and ⋯ never — into the ⋯ menu. The row fits by measured widths, the
  column by whole chips (`capacity`), re-rendered only when the count
  changes. `UMDSourceStripView` (20 pt) over the pane carries the title
  and lamp. The key rail stays horizontal.
- **Deck action column** — `deckActionColumnEdge`: while the deck spans
  the display on a side edge, its + HOST / FAQ / SETTINGS chips stand in
  the strip (`FleetActionColumnView`, same placement as the UMD column)
  and the header keeps the title and summary. Beside a terminal the
  terminal's column owns the strip.
- **Panel home** — `SidePanelPresentationStyle.shellColumn`: regular
  width, terminal anchor, and a column on offer (`columnAvailable`:
  expanded, a book page, or the console region); else the tab road. The
  terminal hands its `SidePanelViewController` to the shell
  (`presentColumnPanel` / `dismissColumnPanel`), mounted in the deck
  column's frame over the hidden deck. ‹ DECK moves the panel into a tab;
  losing the column converts it to a tab. The iPad overlay is never used.
- **Console region** — a horizontal division with the terminal showing
  makes `deckFrame == consoleFrame` (`.shellRail`, two columns), or the
  column panel there. Deviation from the board: the composer stays docked
  above the key rail.
- **Deck** — the single-pane wall takes the rail's 12 pt padding on regular
  width so two 290 pt columns fit at 669.
- **Font** — `TerminalFontDefaults.pointSize`: 13 inner, 12 outer, 14 iPad,
  applied until the user touches A−/A+ in that window.
- **Continuity** — `continueAcrossBreakpoint(expanding:)`: to single pane
  shows the attached terminal (deck when nothing is attached); to two
  panes restores a hidden deck rail. Divider and key rail move on one
  spring; hinge angle drives nothing.

## Traps

- A fold-resized pane must invalidate its `TerminalSurfaceView` before the
  forced pass, or the key rail keeps its old width under the chip column.
  `TerminalKeyBar.narrowFloor` (32 pt faces below 375) and `keyFrames`
  stay inside the rail's bounds.
- Orientation comes from the display, not the pane: a laptop-pose pane is
  landscape-shaped on a portrait display.
- A header inset change must lay the row out itself (`applyPanelWidth`
  early-returns on an unchanged width).

## Still open

Hardware division regions (drop the hinge fallback then). No headless
route for ‹ DECK with a column panel up or the chip column's menus. The
composer below the fold in the laptop pose is designed, not built.
