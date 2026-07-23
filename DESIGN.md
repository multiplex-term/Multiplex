# Multiplex — Design (TALLY)

A spatial terminal for people who live inside remote tmux sessions.
visionOS first, iPadOS alongside. The app's single job: **get you attached to a
remote tmux session, each in its own floating window, fast.**

The identity is **Tally** — the deck is a broadcast monitor wall. It doesn't
*describe* your sessions, it *shows* them: every session is a live miniature
of its actual screen, and being attached is a lit, captioned tally lamp — the
"on air" light. The identity is structural: any screenshot of the wall could
not be mistaken for another app. (The previous amber-on-ink identity and the
bake-off that retired it are recorded in `docs/design-bakeoff.md`.)

## Voice

Plain verbs, user-side vocabulary: **Attach · Detach · New Session · Shell ·
Add Host**. An action keeps its name through the whole flow. Errors say what
happened and what to do next in broadcast language where it genuinely fits
(`NO SIGNAL` on an unreachable host) and plain words everywhere else.

## Color

Graphite chassis, not blue-black; screens darker than the chassis that frames
them — that inversion (dark screens *inside* lighter hardware) is what makes
the wall read as a wall. **Color is state, never decoration**: actions are
neutral chips; if something is red it is live, if something is amber it wants
attention.

| Token      | Value     | Use                                                        |
| ---------- | --------- | ---------------------------------------------------------- |
| `chassis`  | `#17181A` | window ground                                              |
| `bezel`    | `#26282B` | raised: tiles, rails, the UMD bar                          |
| `bezelHi`  | `#33363A` | borders, dividers, inactive bezel segments                 |
| `screen`   | `#0A0B0C` | the darkest thing: miniature + terminal grounds            |
| `tally`    | `#E5484D` | live/attached lamp — always captioned, never used for errors |
| `caution`  | `#E0A33E` | bell/activity ticks, connecting lamps. Small doses         |
| `ok`       | `#7FBF9A` | connected dot on host rails                                |
| `signal`   | `#F2F3F4` | primary text                                               |
| `signal2`  | `#9BA1A6` | secondary text, inactive segment labels                    |
| `signal3`  | `#5C6166` | tertiary/disabled                                          |
| `miniText` | `#C8D2D6` | mono text inside miniatures (rendered at ~78 % opacity)    |

**Red as a positive is the identity's named risk.** It is held by captioning:
the lamp always reads `LIVE`/`ENDED`/`LINK`, and errors never use tally red —
they use words and caution amber.

### Daylight — the light appearance

Every rule above survives with the studio lights on; one inverts. Dark: screens
are the darkest thing, sunk inside lighter chassis. Light: **screens read as
paper — brighter than the chassis that frames them** — and the visible line
(`bezelHi`) flips from the brightest chassis value to the darkest. Raised
surfaces stay raised in both. State colors deepen so their captions keep the
dark chassis's contrast (tally holds ~4.5:1 in both worlds); they are shared
across any light chassis hue, because color is state, never decoration.

The light chassis is **Frost** — cool platinum (hue ≈ 216°), chosen 2026-07-17
from a three-way hue bake-off (Paper `#E9EAEC` neutral and Ivory `#ECE8DF`
warm are the recorded alternates; swapping is one token block in `Theme.swift`
plus the `AppBackground` asset). All values are WCAG-checked against the same
hierarchy the dark chassis ships.

| Token      | Dark      | Light (Frost) | Light contrast on chassis |
| ---------- | --------- | ------------- | ------------------------- |
| `chassis`  | `#17181A` | `#E4E8EE`     | —                         |
| `bezel`    | `#26282B` | `#F0F3F7`     | raised                    |
| `bezelHi`  | `#33363A` | `#CDD3DC`     | the visible line          |
| `screen`   | `#0A0B0C` | `#F9FBFD`     | brightest surface         |
| `tally`    | `#E5484D` | `#C13439`     | 4.5:1                     |
| `caution`  | `#E0A33E` | `#966618`     | 3.8:1                     |
| `ok`       | `#7FBF9A` | `#3E7C58`     | 4.0:1                     |
| `signal`   | `#F2F3F4` | `#191E25`     | 13.6:1                    |
| `signal2`  | `#9BA1A6` | `#515C69`     | 5.5:1                     |
| `signal3`  | `#5C6166` | `#87919E`     | 2.6:1                     |
| `miniText` | `#C8D2D6` | `#3A434E`     | 9.7:1 on `screen`         |

The appearance is a Settings choice — SYSTEM (follows the device; the default),
LIGHT, DARK — applied per window, so the wall, terminal chrome, forms, and
keyboard flip together. Terminal surfaces stay user preference: each appearance
keeps its own theme slot, dark defaulting to Tally and light to **Tally
Frost**; **Tally Paper** (neutral, tally-red cursor) and **Tally Ivory** (warm,
amber cursor quoting the retired Multiplex identity) ship alongside as the
rest of the light trio. The keyboard follows the chassis appearance, never the
terminal theme — a light theme in a dark studio is a lit monitor, not a lit
room.

## Type

Three voices:

- **Compressed caps** (`ChassisLabel`: SF, bold, `.width(.compressed)`, +9 %
  tracking) — the multiviewer source-label voice: app mark, host rails, tile
  names, tab labels, UMD titles.
- **Monospace** (`Font.mono`) — identity and data: addresses, telemetry,
  chip labels, miniature content, and everything inside a screen.
- **SF Pro** — body copy, form labels, footers. Sheets stay platform-native.

## Signature — the live wall

The deck is one fleet-wide surface (no sidebar): every host probes
concurrently under a thin **rail** (name, address, state, `SHELL` chip), and
every session is a **tile** — a monitor on the wall:

```
┌──────────────────────────────┐
│ ┌──────────────────────────┐ │
│ │ $ pnpm build             │ │  ← screen: real capture-pane bytes,
│ │ ✓ 214 modules · 3.2s     │ │    refreshed ~5 s while deck is visible
│ └──────────────────────────┘ │
│ MAIN  ● LIVE   3 WIN·1 CLIENT·2d │  ← UMD row: name, lamp, telemetry
│ [0 editor][1 server*][2 logs]│  ← spine = segmented lower bezel
└──────────────────────────────┘
```

- **Miniatures** ride the host's existing control connection — one exec
  round-trip per host (`TmuxProbe.captureCommand`), fetched only while the
  deck is frontmost. Background re-probes are silent (no state flicker).
- **The spine** (one cell per tmux window, the surviving idea from v1) is the
  tile's segmented lower bezel: active window's segment lit `signal`, names
  in tiny mono caps, a `caution` tick on bell/activity.
- **Whole tile = Attach.** Attached sessions wear the captioned tally lamp;
  unattached ones a neutral `ATTACH` badge.
- **Failure is part of the composition**: unreachable host → hatched
  `NO SIGNAL` tile with `RECONNECT`; probing → `ACQUIRING SIGNAL`; no tmux →
  plain words. First run is one dark monitor `AWAITING SIGNAL` + `ADD HOST`.

## Composition

**Deck window.** Full-bleed chassis (the wall is an object, not a glass
panel). Header: `MULTIPLEX`, fleet stats (`2 HOSTS · 5 SESSIONS`), `+ HOST`
and `SETTINGS` chips. Host rails carry a context menu (Edit/Remove Host).

**Terminal windows.** A chassis-framed screen: `bezelHi` hairline border,
terminal surface edge to edge in the user's theme. Below, the **UMD**
(under-monitor display — the label strip every broadcast monitor wears) as an
opaque ornament on visionOS / toolbar equivalents on iPad. visionOS wraps
the monitor in a console instead of one long row: the bottom stack hangs
from the window's bottom edge with its leading row straddling the bezel —
the detected agent's helper strip first (when one runs; the UMD takes the
straddle otherwise), then the UMD title row: `DECK` chip, source label
(`MAIN · DEVBOX`), status lamp (`LIVE`/`LINK`/`ENDED`), `A− · A+`, and
`+ TAB · FILE · TMUX · MERGE · DETACH`, then a key row: `ESC · CTRL · TAB`,
the DECCKM-aware autorepeat arrows, `RET`, and the keyboard toggle (the
floating visionOS keyboard has none of these — arrows + `RET` drive a CLI
agent's option picker without summoning it). The iPad toolbar keeps the
full chip set: `DECK`,
source label, lamp, then
`A− · A+ · + TAB · FILE · TMUX · MERGE · DETACH` chips; the keyboard
toggle lives on the bottom key rail. On an
SSH-backed tmux tab, `FILE` opens Camera (iPad/iPhone), Photos, and Files
pickers and rejoins the terminal's existing SFTP drop path; mosh and plain
shell tabs omit it. `TMUX` opens a custom square-grid TALLY dropdown
listing the stock command, friendly action, and default `⌃B` binding; iPad and
iPhone carry the same dropdown immediately after the keyboard control in the
bottom key rail. Below 390 pt, the iPhone rail's essentials-only tier moves
`TMUX` to a dedicated trailing control in the top UMD instead; opening it
briefly yields the software keyboard's region to the downward popover, then
restores terminal input on dismissal. Connection overlays are chassis panels
with the same lamp anatomy.

**Agent commands.** The detected agent's helper rail uses the same square
chassis language. MORE opens an anchored TALLY editor: a collapsed Built-in
accordion reveals compact Bar/More choices, followed by ordered multiline
custom rows with Submit, Bar, and Shared switches. Each host retains an
independent setup that follows its host through iCloud Keychain; Shared keeps
one custom command synchronized in that host's Claude Code, Codex, and Pi rails
without changing another host. Commands opted into a rail use `customCommand`,
a warm neutral that marks provenance without
borrowing the red/amber/green state vocabulary. Their labels keep the first
nine characters and append `...` when truncated (newlines and tabs render as
`↵` / `⇥`);
commands kept off the rail remain in MORE.

**Tabs.** Multiviewer source labels on an opaque chassis slab (top ornament
on visionOS, top row on iPad, only when a window holds >1 tab): square cells,
compressed-caps names, one tally dot per tab (red = that shell is live).

**Sheets** (Add Host, Settings, theme editor) stay platform-native with mono
identity fields and eyebrow section labels — transient chrome doesn't wear
the chassis. Full-width boolean settings use a 48-point field row: SF Pro title
left, a regular monochrome TALLY switch right, and the entire row as the press
and hover target. Compact captioned switches remain for dense inline controls.

## App icon — the Carrier mark

Logo bake-off R1 ran three concepts: **Monitor** (one wall tile distilled —
screen, captioned lamp, spine; risks reading generic-monitor-app without the
spine), **Wall** (asymmetric multiviewer, one feed on air; busiest at favicon
scale), and **Carrier** (chosen). Carrier won because it is the only mark
that survives 16 px, works everywhere the brand lives (icon, chrome, empty
states, a README badge), and carries the name's actual meaning.

**The mark:** one continuous signal trace enters on the baseline, draws the
M, and exits on the same wire — many sessions over one connection — with a
bare tally node at the live joint. Bare (uncaptioned) is the tab-cell
precedent; lockups caption it. Chassis ground, `signal` trace, `tally` node:
red stays state — the node *is* the attached state, and the mark must also
stand without it (detached contexts drop the node, never recolor it).

**Geometry** (1024 grid): wire y 654–722; posts 68 wide at x 262/694 with
flat tops at y 284; V = polyline (296,304)→(512,600)→(728,304), stroke 68,
butt caps, miter joins. Four same-fill shapes union seamlessly — the posts
absorb the V's butt ends, and the vertex miter just kisses the wire. Node
r 40 at (512,600), no ring: depth (glass + shadow), not a painted gap, does
the separation.

**Source of truth is `AppIcon.icon`** (repo root), a hand-authored Icon
Composer package: `fill` = chassis; layer `carrier`, plus layer `node` in
its own front group (glass + specular + neutral shadow 0.5) so the lamp
reads as a bead casting onto the trace. Compiles clean with Xcode 27
`actool`, which also bakes the flattened pre-26 fallbacks. Icon Composer
covers the square formats only. `Assets.xcassets/AppIcon.solidimagestack`
provides the visionOS circular icon as three 1024 px layers: opaque chassis
back, carrier middle, and tally-node front. Both representations are named
`AppIcon`; `actool` selects the platform-appropriate source at build time.

The stack layers are generated — `swift Tools/bake-vision-icon.swift`
re-bakes them from `AppIcon.icon` (run it after any icon edit). It renders
the document's circle format (artwork auto-scaled 0.94x into the disc, all
glass baked, 16-bit Display P3) via Icon Composer's own `ictool`, then
splits the render into layers by unblending fill-only, fill+carrier, and
full passes, so the flattened stack matches the Icon Composer rendering
pixel-for-pixel while visionOS still gets real depth. Layer assignment is
deliberate: the disc's edge lighting lives only in the back layer and the
bead + its cast shadow ride the front layer whole, so parallax never
double-exposes an edge or splits the lamp across planes.

## Terminal themes

Terminal surface colors are user preference, never identity. The default is
**Tally** (`screen` ground, `signal` text, tally-red cursor, ANSI tuned so
red/amber match the chrome's lamp semantics); the previous amber-on-ink ships
as the optional "Multiplex" theme alongside Gruvbox/Dracula/Nord/Solarized.
Chrome never re-skins with the theme.

**tmux's own status line is left alone.** It styles itself from the user's
tmux config and the theme's ANSI palette; Multiplex does not inject
`status-style`. Deliberate: the app owns the chrome, the user owns the
session.

## Motion & restraint

- Tally lamps: snap on, soft decay off (shadow glow only — no pulsing).
- Miniature/tile changes crossfade 300 ms; background re-probes never flip
  state, so the wall doesn't flicker.
- Everything else is system motion. Reduced Motion disables the crossfade.

## Hover (visionOS)

The default gaze-hover platter is heavily rounded and fights the square
chassis. Every interactive element uses `chassisHover(_:)` —
`buttonBorderShape` + `contentShape(.hoverEffect, …)` + `.hoverEffect(.highlight)`
applied **to the Button, not its label** (the system resolves hover shape at
the level the effect attaches; a label-level shape is silently ignored).

## Self-critique (anti-template pass)

The generic AI answer for "terminal app" is pure black + neon green + mono
everywhere + CRT kitsch; the generic dark-dashboard answer is near-black with
one acid accent. Rejected: graphite chassis with screens darker than their
frames; red spent only on LIVE; labels in compressed caps, not mono
wallpaper; zero scanlines. The identity is carried by structure — live
miniatures, segmented bezels, captioned lamps — visible in any thumbnail,
dependent on no backstory.
