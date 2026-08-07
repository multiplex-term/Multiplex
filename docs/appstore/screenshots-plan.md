# App Store screenshots & previews — design + capture plan

The design system, captions, and exact-size compositing live in
**`Tools/appstore/storyboard.html`** (open it in a browser — gallery mode
shows every frame with its staging notes; `compose.sh` renders the finals).
This doc is the *capture* side: what to stage, how to shoot it, what to
avoid. Final store sizes, one set per device class:

| Class | Size | Capture device |
| --- | --- | --- |
| Apple Vision Pro | 3840×2160 | Vision Pro sim, full framebuffer |
| iPad 13″ | 2752×2064 landscape | iPad Pro 13″ sim, native 1:1 |
| iPhone 6.9″ | 1320×2868 **portrait** | iPhone 17 Pro Max sim, native 1:1 |

iPad browses a terminal app in landscape; the iPhone shell is a portrait,
one-window app — shoot it the way it's held. ASC screenshot sets hang off a
platform version, so iPhone+iPad live in `fastlane/screenshots/ios/en-US/`
and Vision Pro in `fastlane/screenshots/visionos/en-US/`; the one lane runs
deliver per platform, inferring device class from pixel size within each.

## The frame idea (why these don't look like anyone else's)

Every store image is composed as **one monitor of the TALLY wall**: the raw
capture is the screen; a single opaque **UMD bar** (the app's own
under-monitor display idiom) carries the marketing copy — compressed-caps
headline on the left, captioned tally lamp + mono telemetry on the right,
restating the feature as broadcast telemetry (`2 HOSTS · 6 SESSIONS ● LIVE`).
No gradients, no floating device mockups, no emoji. On visionOS the UMD
floats as a slab in the lower third of the environment capture; on iPad the
capture sits inset in a chassis mat with the UMD beneath it — screens darker
than the chassis that frames them, same inversion as the app. Matted insets
keep the raw's exact aspect — uniform downscale, never a crop.

**iPhone is full-bleed with a floating UMD slab** (chosen 2026-08-07;
bake-off record in `Tools/appstore/redesign-iphone-frame.html`): the App
Store clips every iPhone 6.9″ screenshot into a device-shaped card (radius
≈ 14% of width, ~185 px at 1320) which ate the old square mat's corners
and ran the docked caption into the bottom curve — iPad and Vision Pro
cards are barely rounded and unaffected. So the iPhone raw is the poster at
native 1:1, the store mask is the device frame, and the stacked UMD
(headline row, telemetry + lamp row, larger type than the old bar) floats
as a rounded slab inset clear of the curve. Consequence for staging:
**iPhone captures must keep their money pixels out of the bottom slab
band** (~the lower sixth of the screen).

## Shot list — visionOS + iPad (order = store order; first three sell)

The v1.3 order (2026-08-07 re-plan, see history below):

| # | id | Stage | Headline (UMD left) | Telemetry (UMD right) |
| --- | --- | --- | --- | --- |
| 1 | `wall` | Deck, 2 hosts, ~6 live tiles, one LIVE lamp, agent glyph | EVERY TMUX SESSION, LIVE ON THE WALL | `2 HOSTS · 6 SESSIONS` ● LIVE |
| 2 | `windows` | 3 terminals around the room (visionOS) / Stage Manager scenes (iPad) | A SPATIAL WINDOW PER SESSION *(iPad: REAL SCENES, STAGE MANAGER READY)* | `3 WINDOWS` ● LIVE |
| 3 | `herdr` | **NEW** — the combo staging (V3 won the bake-off in `Tools/appstore/redesign-herdr-shot.html`, 2026-08-07): iPad = Stage Manager, the deck scene (mixed host — graphite tmux tiles beside mauve herdr tiles) beside one attached herdr workspace window (2 tabs / 3 panes, real claude in the agent pane); visionOS = deck at left + two workspace windows at depths | HERDR ON THE WALL — A WINDOW PER SESSION | iPad `DECK + 1 WINDOW` / visionOS `DECK + 2 WINDOWS` ● LIVE |
| 4 | `agents` | Wall with agent glyph + NEEDS YOU; notification banner in frame. Caption carries the v1.3 keep-alive angle | KNOW WHEN YOUR AGENT NEEDS YOU | `✳ CLAUDE CODE · EVEN AFTER YOU LEAVE` ● NEEDS YOU |
| 5 | `strip` | Real Claude Code, chip strip + one custom chip visible (**recapture — STOP chip withdrawn 2026-08-05**) | ONE-TAP AGENT COMMANDS — PLUS YOUR OWN | `/CLEAR · /COMPACT · /MODEL` |
| 6 | `launch` | New Session sheet over the wall: Claude Code selected, prompt + setup script + dir filled | START AN AGENT SESSION IN ONE STEP | `CLAUDE CODE · CODEX · PI` |
| 7 | `fileviewer` | **NEW** — ▤ file-viewer tab beside a live session: a code screen or git diff with line numbers, drawer visible; second ▤ tab in the tab row shows the v1.3 tabs | CODE, DIFFS, DOCS — BESIDE THE SESSION | `▤ CODE · DIFF · MARKDOWN` |
| 8 | `widgets` | Home Screen widgets (iPad) / widget pinned in the room (visionOS 26) | THE WALL, ON YOUR HOME SCREEN *(visionOS: PINNED IN YOUR SPACE)* | `WIDGETS · APP SHORTCUTS` |
| 9 | `keys` | iPad: docked keyboard raised, TALLY key rail + helper strip above it — **recapture: the window now wears the v1.3 title bar** / visionOS: ornament key cluster beside the UMD, floating keyboard below | REAL TERMINAL KEYS, ABOVE THE KEYBOARD *(visionOS: ESC, CTRL, TAB — ALWAYS IN REACH)* | `ESC · CTRL · TAB · ARROWS · RET · TMUX` / visionOS `ESC · CTRL · TAB` ● LIVE |
| 10 | `themes` | iPad: LIGHT appearance, Frost chassis + Tally Frost / visionOS: Settings on GLASS over the wall | iPad: LIGHT OR DARK — TEN THEMES, PLUS YOUR OWN / visionOS: GRAPHITE OR SMOKED GLASS | iPad `TALLY FROST · LIGHT` / visionOS `TALLY · GLASS` |

Exactly 10 = the ASC cap. Re-plan history: the 2026-07-18 re-plan added
`history`, `drop`, `widgets` and retired the standalone `shortcuts` frame;
the 2026-07-21 re-plan swapped `history` (jump not stable enough to headline
yet — revive from git history once it is) for `launch`, and retired `tabs`
for `keys`. The **2026-08-07 re-plan (v1.3)**: `herdr` in at slot 3 (the
release headline earns a selling slot) and `fileviewer` in at 7; `mosh` and
`drop` out on iPad/visionOS — mosh's roaming pitch is strongest on iPhone,
where it stays, and file attach stays an iPhone shot for the Camera story.
`agents` caption gains the keep-alive angle; `strip` and iPad `keys` need
recapture (STOP chip withdrawn / the new title bar). If `widgets` proves
unstageable on the visionOS sim, ship visionOS with 9 or revive `shortcuts`
from git history as its 10th. `storyboard.html` + `compose.sh` carry this
order and the full-bleed iPhone frame as of 2026-08-07; compose.sh now
clears each platform's old numbered files before copying, since the
renumbering would otherwise push a set past ASC's cap of 10.

## Shot list — iPhone (portrait, 10 shots)

Same ids ⇒ same narrative, minus the multi-window `windows` shot (the phone
is deliberately a one-window shell); `keys` moves up to slot 2; the herdr
story is told as the **mixed deck** (a complete workspace doesn't read at
phone size). Every iPhone frame recomposes under the new full-bleed slab —
the existing raws are already native 1320×2868, so no recapture is needed
for the frame change alone (only where the slab band hides a shot's story):

| # | id | iPhone-specific staging |
| --- | --- | --- |
| 1 | `wall` | The shell's deck in portrait, both host rails in frame |
| 2 | `keys` | Attached session, **docked keyboard raised**, TALLY key rail above it — ESC / CTRL / TAB / arrows / TMUX. Headline A FULL TERMINAL, PHONE-SIZED · `ESC · CTRL · TAB · ARROWS · TMUX` ● LIVE |
| 3 | `agents` | NEEDS YOU tile + notification banner over the shell deck — the away-from-the-desk pitch; caption gains the keep-alive angle as on iPad |
| 4 | `herdr` | **NEW** — the shell deck with one host carrying both backends: graphite tmux tiles beside mauve herdr tiles, offer chip on a second rail if it fits. Headline TMUX AND HERDR, ONE WALL · `TMUX + HERDR` ● LIVE |
| 5 | `strip` | Chip strip above the key rail, keyboard hidden (**recapture — STOP chip withdrawn**) |
| 6 | `launch` | New Session sheet over the shell's deck — LAUNCH bar, prompt, RUNS FIRST, STARTS IN |
| 7 | `drop` | FILE menu with **Camera** / Photos / Files |
| 8 | `widgets` | Home Screen: Host Monitor (medium, SHELL/AGENT keys) + Fleet Wall (medium) |
| 9 | `mosh` | Host sheet MOSH toggle — the cellular/roaming story is strongest here |
| 10 | `themes` | LIGHT appearance: Frost chassis, Settings theme rows |

## Staging rules (what made the earlier dev captures unusable)

- **Simulator locale en_US** — kills the Japanese keyboard-hint bar seen in
  `docs/visionos-multiwindow.png`.
- **Status bar override** on iPhone/iPad before any capture:
  `xcrun simctl status_bar <UDID> override --time 9:41 --batteryState charged
  --batteryLevel 100 --cellularMode active --cellularBars 4 --operatorName ""`
  (visionOS has no status bar).
- **No other app windows behind Multiplex** on visionOS — Files ghosting
  through GLASS reads as clutter. The room itself is intentional material;
  use one consistent environment for the whole set (the day living room reads
  best).
- **No dev tells**: host must not read `jhen@127.0.0.1:2222`. Alias the
  harness: add `127.0.0.1 atlas.internal` to the Mac's `/etc/hosts` (the sim
  uses the Mac's resolver) and seed via `stage-sessions.sh`'s
  `store-seed.json` (`demo@atlas.internal:2222`). Session names: `main`,
  `build`, `logs`, `agent` — never `test`/`test2`. A second rail
  (`forge.internal`) can point at any real box — the Mac's own sshd with its
  own tmux server works — or fix shot 1's telemetry to a one-host truth
  (the numbers must be true of the pixels). Two hosts also *is* the free
  tier, which keeps the hero shot honest about the free download.
- **Software keyboard hidden** unless the shot is about typing (`keys` and
  nothing else; `debug.summon`/`debug.dismiss` drive it headlessly).
- **Miniature content is the texture of the whole wall** — stage it:
  - `main`: nvim/an editor + 2 more tmux windows so the spine shows segments
  - `build`: loop printing plausible compile lines with ✓ marks
  - `logs`: `tail -f` of a generated access log (timestamps, 200s)
  - `agent`: **real `claude` running in the harness pane** (real glyph, real
    strip, real NEEDS YOU when it asks — better than the fake for pictures)
- **Widget shots need a warm snapshot**: run the app against the staged
  fleet first (the App Group `widget-state.json` publishes off the live
  probe), then add widgets on a **plain dark wallpaper** Home Screen. SEEN
  stamps in frame are honest and deliberate — widgets never claim liveness.
- **Appearance shots** flip via the `debug.appearance` notification
  (SYSTEM → LIGHT → DARK → GLASS on visionOS, persisted). Stage `themes` on
  GLASS there, LIGHT on iPad, then restore SYSTEM after capture.
- **Pro surfaces** (`mosh`, custom themes) are live by default in DEBUG
  builds (`isPro` defaults true); the telemetry marks them `PRO` honestly.
  The chip strip is free (10 taps/day) and carries no PRO mark, and the
  `launch` sheet is free-tier plumbing — no PRO in its caption either.
- **The `launch` sheet needs seeded dirs + scripts**: its RUNS FIRST and
  STARTS IN pickers only render when the host carries `sessionScripts` /
  `workingDirs` — `stage-sessions.sh` injects plausible ones into
  `store-seed.json`. Stage with LAUNCH on CLAUDE CODE, a believable initial
  prompt typed, a script selected, and a repo dir chosen, so every field the
  caption claims is filled in the pixels.
- Drive content from the Mac: `tmux send-keys`, and
  `MULTIPLEX_AUTO_ATTACH=main,build` to open windows without hand-fiddling.

## Capture

- **visionOS**: `xcrun simctl io <UDID> screenshot` captures the full
  framebuffer including the environment. Save to
  `Tools/appstore/raw/visionos-<id>.png`.
- **iPad**: iPad Pro 13″ sim, landscape → `raw/ipad-<id>.png` (native
  2752×2064, used 1:1).
- **iPhone**: iPhone 17 Pro Max sim, portrait → `raw/iphone-<id>.png`
  (native 1320×2868, used 1:1). The shell is automatic on iPhone — no
  `MULTIPLEX_FORCE_SHELL` needed. Wait ≥12 s after a fresh boot before the
  first capture (iOS 27 first-frame delay).
- Then `Tools/appstore/compose.sh` → exact-size frames in
  `Tools/appstore/out/`, auto-copied into
  `fastlane/screenshots/<ios|visionos>/en-US/`,
  `bundle exec fastlane store_screenshots` to upload (one deliver per
  platform; device class inferred from pixel size within each).

## App Preview video (phase 2 — ship screenshots first)

15–30 s, no hands/devices, capture in-app footage only, first 3 s must work
muted (posters autoplay silently). Storyboard (visionOS, ~24 s):

| t | Shot |
| --- | --- |
| 0–4 s | The wall, tiles streaming; one tile's miniature visibly updates |
| 4–8 s | Tap `main` → window opens, LIVE lamp snaps on |
| 8–12 s | Second attach; drag windows apart in space |
| 12–16 s | `agent` tile flips to NEEDS YOU; notification banner lands |
| 16–20 s | Attach agent; chip strip; tap `/clear` — command lands in-session |
| 20–24 s | MERGE → tabs; end on the wall + app mark |

Record with `simctl io recordVideo` (or device capture), edit to
3840×2160 H.264 ≤ 500 MB, upload manually in ASC (deliver can't).
iPad preview: same script minus spatial placement, 1600×1200. iPhone
preview (886×1920 portrait): wall → attach → key rail typing → NEEDS YOU
banner → widget tap → back on the wall.
