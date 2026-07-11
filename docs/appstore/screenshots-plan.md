# App Store screenshots & previews — design + capture plan

The design system, captions, and exact-size compositing live in
**`Tools/appstore/storyboard.html`** (open it in a browser — gallery mode
shows every frame with its staging notes; `compose.sh` renders the finals).
This doc is the *capture* side: what to stage, how to shoot it, what to
avoid. Final store sizes: **Vision Pro 3840×2160**, **iPad 13″ 2752×2064**
(landscape — a terminal app is browsed and used in landscape).

## The frame idea (why these don't look like anyone else's)

Every store image is composed as **one monitor of the TALLY wall**: the raw
capture is the screen; a single opaque **UMD bar** (the app's own
under-monitor display idiom) carries the marketing copy — compressed-caps
headline on the left, captioned tally lamp + mono telemetry on the right,
restating the feature as broadcast telemetry (`2 HOSTS · 6 SESSIONS ● LIVE`).
No gradients, no floating device mockups, no emoji. On visionOS the UMD
floats as a slab in the lower third of the environment capture; on iPad the
capture sits inset in a chassis mat with the UMD beneath it — screens darker
than the chassis that frames them, same inversion as the app.

## Shot list (order = store order; first three do the selling)

| # | id | Stage | Headline (UMD left) | Telemetry (UMD right) |
| --- | --- | --- | --- | --- |
| 1 | `wall` | Deck, 2 hosts, ~6 live tiles, one LIVE lamp, one NEEDS YOU tick | EVERY TMUX SESSION, LIVE ON THE WALL | `2 HOSTS · 6 SESSIONS` ● LIVE |
| 2 | `windows` | 3 terminals placed around the room (visionOS) / Stage Manager scenes (iPad) | A SPATIAL WINDOW PER SESSION *(iPad: REAL SCENES, STAGE MANAGER READY)* | `3 WINDOWS` ● LIVE |
| 3 | `agents` | Wall with agent glyph + NEEDS YOU badge; notification banner visible | KNOW WHEN YOUR AGENT NEEDS YOU | `✳ CLAUDE CODE` ● NEEDS YOU |
| 4 | `strip` | Terminal running Claude Code, Pro chip strip visible | ONE-TAP AGENT COMMANDS | `/CLEAR · /COMPACT · STOP` · PRO |
| 5 | `mosh` | Host sheet with MOSH toggle on + attached session behind | MOSH BUILT IN — ROAM, SLEEP, RESUME | `UDP · RTT 18 MS` ● LIVE |
| 6 | `tabs` | One window, 3 tabs in the source-label strip | MERGE WINDOWS — SHELLS STAY LIVE | `3 TABS · 1 WINDOW` ● LIVE |
| 7 | `themes` | Settings theme picker + a Gruvbox-skinned terminal behind | SEVEN THEMES, PLUS YOUR OWN | `GRUVBOX DARK` · THEME |

Same narrative on both platforms (capture both per shot). 7 ≤ 10 ✓.

## Staging rules (what made the current dev captures unusable)

- **Simulator locale en_US** — kills the Japanese keyboard-hint bar seen in
  `docs/visionos-multiwindow.png`.
- **Nothing behind the app** on visionOS — the Files window ghosting through
  glass in `docs/visionos-deck.png` reads as clutter. One consistent
  environment for the whole set (the day living room reads best).
- **No dev tells**: host must not read `jhen@127.0.0.1:2222`. Alias the
  harness: add `127.0.0.1 atlas.internal` to the Mac's `/etc/hosts` (the sim
  uses the Mac's resolver) and add the host in-app as `atlas.internal`,
  port 2222, user `demo`. Session names: `main`, `build`, `logs`, `agent` —
  never `test`/`test2`. A second rail (`forge.internal`) can point at any
  real box you have; a one-host wall is fine too (fix shot 1's telemetry to
  match reality — the numbers must be true of the pixels).
- **Software keyboard hidden** unless the shot is about typing.
- **Miniature content is the texture of the whole wall** — stage it:
  - `main`: nvim/an editor + 2 more tmux windows so the spine shows segments
  - `build`: loop printing plausible compile lines with ✓ marks
  - `logs`: `tail -f` of a generated access log (timestamps, 200s)
  - `agent`: **real `claude` running in the harness pane** (real glyph, real
    strip, real NEEDS YOU when it asks — better than the fake for pictures)
- Drive content from the Mac: `tmux -L … send-keys`, and
  `MULTIPLEX_AUTO_ATTACH=main,build` to open windows without hand-fiddling.

## Capture

- **visionOS**: `xcrun simctl io <UDID> screenshot wall.png` captures the
  full framebuffer including the environment (matches the existing docs
  shots). Save to `Tools/appstore/raw/visionos-<id>.png`.
- **iPad**: iPad Pro 13″ sim, landscape →
  `raw/ipad-<id>.png` (native 2752×2064 — used 1:1).
- Then `Tools/appstore/compose.sh` → exact-size frames in
  `Tools/appstore/out/`, auto-copied into `fastlane/screenshots/en-US/`,
  `bundle exec fastlane store_screenshots` to upload.

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
iPad preview: same script minus spatial placement, 1600×1200.
