# iPhone Duo

Split from AGENTS.md — the foldable iPhone's poses and the shell rules for
them. Pose board (every pose at true point size, the four new parts at 1:1):
see the "Duo pose board" link in `local-plan/iphone-duo.md`. Xcode 27.1
ships the Duo simulator and the reserved-region SDK; the pure rules below
are wired and tested, the UI that reads them is not.

## Device facts

Measured on the Xcode 27.1 simulator (27A9269, runtime 24A94401,
2026-09-23) with the `MULTIPLEX_DUO_PROBE=1` shell probe (category `duo`,
`log stream` only — `log show` never surfaces it). HIG "Designing for
iPhone Duo" (2026-09-09) and the four tech talks for the rules.

- Outer display 466×678 pt: compact × regular in portrait, compact ×
  compact in landscape. The system column is an 84 pt safe area on the
  trailing edge (leading in the other landscape), 34 pt home strip, no top
  inset. Keyboard 252 pt portrait, 193 landscape.
- Inner display 951×669 pt (hinge vertical, book) / 669×951 (hinge
  horizontal, laptop): regular × regular both ways, and it ignores
  `UISupportedInterfaceOrientations`. Landscape: 84 pt trailing column, no
  top inset, `verticalBarEdge` = trailing. Portrait: 82 pt top inset, no
  side column, `verticalBarEdge` = unspecified (horizontal bars). Keyboard
  227 pt landscape, 311 portrait. The press-derived 626×890 was wrong.
- The fold band is 40 pt, centred: 455.5…495.5 on the 951 axis. Pages are
  455.5 pt; the page under the system column keeps 371.5.
- `UIHingeInteraction` reports `fullyOpen` at π, `partiallyOpen` at ≈2.23
  rad in the book pose, `closed` at 0, with continuous angle updates.
- ⚠ `reservedRegions(kind: .division)` returns nothing in every pose on
  this simulator, `.includeInactive` included, on the view and the window
  (two independent probes confirm it). The system itself honours the fold
  (alerts displace to the trailing page). The shell therefore synthesises
  the band from the hinge status (`DuoFoldGeometry`) whenever the query is
  empty; re-check on hardware and drop the fallback when regions arrive.
- The scene persists and resizes on open/close. The Duo is the first iPhone
  with multiple scenes (inner display only); Multiplex keeps them off there
  (`~iphone` manifest). Split View multitasking hands the app a
  compact-width half; each app's bars sit on its own outer edge.
- App-owned bars are not moved by the system — the UMD rail and the key
  rail are both app-owned, so their edge is our rule. APIs:
  `traitCollection.verticalBarEdge`, `UIView.reservedRegions(kind:)`,
  `UIArrangementViewController`, `UIHingeInteraction` (iOS 27.1).
- Simulator: `xcrun simctl` has no pose command; DeviceHub's window exposes
  the pose buttons (group 1: 4 rotate, 5 closed, 6 book, 7 open) to System
  Events. `simctl io … screenshot` captures the inner display; the outer
  one needs `--display=<port UUID from simctl io enumerate>`. The Debug
  scheme trap applies: pass `-configuration Debug` or the Release product
  lands and the stale Debug bundle installs. `./Tools/build.sh … duo`.
  DEBUG hooks: `MULTIPLEX_DUO_PROBE=1` (geometry + hinge log, category
  `duo`), `MULTIPLEX_AUTO_HIDE_DECK=1` (◧ HIDE once, headless). Pass them
  in simctl's environment with the `SIMCTL_CHILD_` prefix.

## Rules (pure models, unit-tested)

- **Window model**: the single-scene Shell in every pose.
- **Expand** — `SingleWindowShellLayout.isExpanded(usableWidth:
  terminalAvailableWidthIfExpanded:idiom:)`. Phone: split only while the
  terminal beside the 316 pt deck rail keeps `phoneTerminalMinimumWidth`
  (390, the key rail's unlocked TMUX tier, measured after the terminal's
  own safe areas). Pad: 620 pt of usable width as before. Shipped
  consequences: iPhone 16e (410) and Pro Max (440) landscape unchanged; an
  SE-class 667-wide landscape (351) becomes single pane. Duo: closed
  landscape (278) and open portrait (353) stay single pane, open landscape
  (551) splits 316 | 635.
- **Fold** — `SingleWindowShellNativeLayout.resolve(…, division:)` takes
  the active division region in shell coordinates (nil when flat); the
  controller reads it from `reservedRegions` and falls back to
  `DuoFoldGeometry.syntheticDivision` while the hinge is `partiallyOpen`
  (wired and simulator-verified 2026-09-23). Vertical
  region: expanded regardless of width and of ◧ HIDE (the left page is never
  empty); deck = 0…`minX`, terminal from `maxX`, divider = the region.
  Horizontal region: single pane; the terminal takes the top region and
  `consoleFrame` is the bottom one — key rail pinned to the fold as the
  region's top edge, below it the first of: software keyboard, Talkback
  composer, ▤/⌗ panel, C/B or Key Commands slabs, else the deck rail. The
  deck wall itself may span the fold (scrolling content is not displaced).
- **Corner inset** — `SingleWindowShellLayout.cornerLeadingInset(
  topSafeArea:leadingSafeArea:idiom:horizontalSizeClass:)`: 24 pt on the
  HEADER ROW of the pane that owns a bare display corner (the Duo's inner
  landscape poses: status column trailing, no top inset; inner corners
  measure 55 pt). Regular width only: the closed display's corner is 6 pt
  and its strip title sits flush with the pane (Jhen, 2026-09-25). The deck
  wall's header (`headerCornerInset`) or the terminal's UMD rail
  (`railCornerInset`, never the pane) — ◧ HIDE hands the corner to the
  terminal. Never a top shift: that spends a dead band across the shell.
- **System glyph line** — `SingleWindowShellLayout.systemGlyphLine` 48:
  iOS draws its clock and radio glyphs 48 pt from the display edge, not
  at the centre of its 84 pt strip (903 on the 951 display) or its 82 pt
  band. Column chips centre on `sideColumnCenterX(stripWidth:
  trailingEdge:)` (edge − 48) and band rows on `topBandRowCenter(
  bandHeight:)` (48). The band is one bezel slab across the full width
  under the system's clock, hairline at its bottom.
- **Home strip** — `SingleWindowShellLayout.railAlwaysTakesBottomStrip`:
  on a foldable (the shell saw a hinge) the key rail spends the 34 pt
  home strip in every pose, as it does on iPad and on any compact-height
  phone; a shipped iPhone in portrait keeps the backfill band under its
  rail. Otherwise the rail floated above the display edge in the book pose
  and on the closed display (Jhen, 2026-09-25).
- **Bare chrome** — `SingleWindowShellLayout.chromeIsBare` (foldable
  phone, every display): the source strip and the key rail drop the bezel
  slab and their 1 pt rule; on the Duo's dark ground they read as grey bars
  around the pane. The shell's backfill bands above and below the terminal
  (the 8 pt bare-top padding, the home strip) wear the pane's ground for
  the same reason, under a live tab or the empty view. Geometry unchanged;
  shipped iPhones and iPad keep the slab.
- **Bare top padding** — `SingleWindowShellLayout.bareTopPadding` 8 pt on
  the shell's content origin on the inner display (regular × regular)
  when it has no top inset (the top edge itself was not reliably
  pressable); nothing where a status inset exists, and nothing on a
  compact layout — a shipped iPhone in landscape and the closed display
  keep their flush chrome (Jhen, 2026-09-25).
- **Top band** — `SingleWindowShellLayout.topBandHeight(…)`: on the phone
  idiom with regular × regular traits and a top inset ≥ 60 (inner portrait
  and the laptop pose's top region, 82 pt) the shell's content starts at
  y 0 and the band is content: the horizontal UMD rail and the deck's
  header row sit on the glyph line inside it with a 128 pt trailing clearance
  for the clock and radio cluster, the pane and wall start at the band's
  bottom. Elsewhere unchanged. The corner inset and the band travel as one
  `ShellHeaderChrome` per pane from `resolve` to the deck header, the UMD
  rail, and a column panel's header; the clearance and the row's centre
  line derive from it.
- **Rail edge** — `ShellRailPlacement.edge(…)`: a system-reported
  vertical-bar edge wins (`.top` included); without one, phone + regular
  × regular + landscape is `.leading`, and a `foldable` phone (the shell
  saw a hinge) in a compact landscape — the closed display, where the
  system draws no bar at all — puts the column in the camera's safe strip
  (~90 pt, whichever side is wider). A shipped iPhone never moves. Wired
  (`resolvedRailEdge`, shell presentation only; classic windows, iPad,
  visionOS untouched): when the edge is leading/trailing the UMD renders
  as `UMDBarStyle.verticalColumn` — 44 pt symbol-over-caption chips, 4 pt
  apart, one x and one width centred on the system glyph line (edge −
  48, the clock's own centre — and the camera's), starting 120 pt down on
  the inner display (under the clock and radio glyphs), ending above the
  keyboard obstruction. The closed display's portrait stacks its glyphs
  under the camera on the trailing edge (the system reports that edge),
  so the column starts 160 pt down there; in landscape it draws no
  glyphs, and the camera sits in the strip's end nearest the device's
  corner (30…66 pt: top when the strip is leading, bottom when the device
  is turned around and it is trailing), so the column keeps 80 pt clear
  of that end and 12 of the other, and its chips gather at the camera's
  end (`RailFit.columnPlacement.anchoredToBottom`: the stack hangs from
  the bottom when the camera is there — Jhen, 2026-09-25). The shell
  hands the display's
  orientation down
  (`displayIsLandscape`): the screen's bounds lag a rotation's layout pass
  and left a column on the closed portrait display. Order top→bottom: DECK
  (‹ DECK / ◧ HIDE / ◧ DECK), A−, A+, + TAB, FILE, TMUX (only when the key
  rail has dropped it — same `keyRailContentWidth` rule), ⋯, DETACH.
  `RailFit` (pure, tested; one rule for the column and the horizontal
  shell row, iPhone included) drops MERGE, GUIDE, A−, A+, + TAB, FILE,
  DETACH, TMUX in that order — A−/A+ leave together, DECK and ⋯ never —
  and the dropped chips move into the ⋯ menu, which is then kept. The row
  fits by measured chip widths (cached per caption), the column by whole
  chips (`RailFit.capacity`), and the column re-renders only when that
  count changes. The title is text-only,
  so `UMDSourceStripView` (20 pt) over the pane carries `MAIN · DEVBOX ·
  ● LIVE` while the rail is vertical. The key rail stays horizontal above
  the keyboard in every pose.
- **Deck action column** — `SingleWindowShellLayout.deckActionColumnEdge`:
  while the deck spans the display (`.shellCompact`) on a side rail edge
  — the closed display in either orientation — its + HOST / FAQ /
  SETTINGS chips stand in the system's strip as `UMDColumnChip`s
  (`FleetActionColumnView`, same insets and glyph-line centre as the UMD
  column) and the header row keeps the title and summary (Jhen,
  2026-09-25). Beside a terminal the terminal's column owns the strip, so
  the chips stay in the deck rail's header. The shell resolves the edge
  once (`ShellRailPlacement.edge(traits:…)`, shared with the terminal
  window) and hands it down as `actionColumnEdge`.
- **Panel home** — `SidePanelPresentationStyle.shellColumn`: admitted on
  regular width for a terminal anchor AND only while the shell offers a
  column (`columnAvailable`: expanded, a book page, or the console region);
  otherwise the existing tab road. The terminal window hands its
  `SidePanelViewController` to the shell (`presentColumnPanel` /
  `dismissColumnPanel` on `TerminalWindowShellConfiguration`), which mounts
  it in the deck column's frame (316, the 455.5 page, or the console) with
  the deck hidden beneath; the header row takes the corner inset
  (`updateHeaderCornerInset`). Terminal width never changes. ‹ DECK while a
  column panel is up moves the panel into a tab and shows the deck; losing
  the column (close, inner portrait) converts it to a tab the way the iPad
  overlay does. No stored width. The iPad overlay is never used on the Duo.
- **Console region** — a horizontal division with the terminal showing
  makes `deckFrame == consoleFrame`, deck visible and interactive
  (`.shellRail`, two columns), or the column panel there instead. The
  keyboard covers the region when up. Deviation from the board: the
  Talkback composer stays docked above the key rail inside the top region.
- **Deck** — the single-pane wall takes the rail's 12 pt padding on
  regular width so two 290 pt columns fit at 669. No even-column rule: no
  shipped layout lets the wall span a vertical fold (book pose is always
  two pages).
- **Font** — `TerminalFontDefaults.pointSize(…)`: 13 on the inner display,
  12 on the outer, 14 on iPad, applied on layout/trait change only until
  the user touches A−/A+ in that window (`userAdjustedFont`); a size the
  user set is never shrunk.
- **Continuity** — `continueAcrossBreakpoint(expanding:)` in the shell
  controller: crossing to single pane shows the attached terminal (the deck
  only when nothing is attached); crossing to two panes restores a hidden
  deck rail. The divider and key rail move on one spring; the rail flips
  only when the system's bars do; hinge angle drives nothing.

## Traps (2026-09-23)

- A fold-resized pane must invalidate its inner `TerminalSurfaceView`
  before the forced pass: the shell's spring writes the container's frame,
  but the surface's constraint children don't re-solve on a parent frame
  write alone — the key rail stayed 635 pt wide inside a 455 pt page and
  painted under the chip column. `TerminalKeyBar` also gained a
  `narrowFloor` tier (32 pt faces below 375 pt) and `keyFrames` never
  leaves the rail's bounds.
- `resolvedRailEdge` reads orientation from the scene's screen, not the
  pane: a laptop-pose pane is landscape-shaped on a portrait display.
- A header inset change must lay the row out itself (`applyPanelWidth`
  early-returns on an unchanged width).

## Still open

Hardware: whether division regions arrive (drop the hinge fallback then).
Headless routes do not exist for the ‹ DECK tap with a column panel up or
for the chip column's menus; both are wired, neither was exercised. The
composer below the fold in the laptop pose is designed, not built.
