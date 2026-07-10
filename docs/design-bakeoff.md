# Multiplex — identity bake-off (three directions)

Status: **TALLY won** (user decision, 2026-07-10). A throwaway SwiftUI
prototype of the winner is in `Multiplex/Prototype/` — see "Prototype
verdict" at the end of this file for how to run and judge it. Patch Bay and
Manifest are archived below for the record; the amber-on-ink identity
(DESIGN.md) is retired.

## Decisions that got us here (grill log, 2026-07-10)

1. **Goal**: full identity replacement, not evolution. The old identity's
   failure mode: it lived in the rationale (VT220 heritage, restraint rules)
   but rendered as generic dark-terminal-plus-orange-buttons. Governing law
   for every replacement: **identity must be structural — visible in any
   screenshot at a glance — never dependent on a backstory.**
2. **Survives the reset**: only the *window spine concept* (one cell per tmux
   window, active lit, activity flagged) — required in every direction,
   re-materialized as the card's **dominant** element, not a 22×14 pt garnish.
   Product voice (Attach · Detach · New Session · Shell) survives as
   vocabulary, not visual identity.
3. **Depth**: token system + hero surfaces (deck, terminal window, default
   terminal theme) per direction; sheets / first-run / icon as one-liners;
   the winner gets the full spec.
4. **Tally may assume**: live session content on the deck — the probe exec
   channel additionally runs `capture-pane` per session; auto-refresh (~5 s)
   while the deck window is visible, paused when backgrounded.
5. **Deck IA (all three)**: fleet-wide single surface; the hosts sidebar is
   retired. Every host probes concurrently (persona has 1–5 hosts);
   unreachable hosts render *in the composition* (NO SIGNAL / cold bay /
   NO ROUTE) instead of behind a selection.
6. **Patch Bay discipline**: restrained material depth — real SwiftUI
   layering/depth on visionOS, drawn geometry only, zero photoreal texture;
   iPad renders the identical geometry flat.
7. **Manifest boundary**: paper chrome follows into the terminal windows
   (folder-tab strip, paper ornament, filed-form overlays); terminal surface
   stays ink.
8. **Deliverable**: these specs + rendered visual boards; winner → throwaway
   SwiftUI prototype pass → implementation.

## Fixed across all directions

- Terminal *surface* colors remain user preference via `ThemeStore`; each
  direction ships its **default** `TerminalTheme` only. Chrome never re-skins
  with the terminal theme.
- Tabs/merge/split mechanics, focus arbiter, connection architecture:
  unchanged. This is a chrome + deck + defaults redesign.
- Accessibility floor: reduced motion respected, color never the sole state
  channel, body-text contrast ≥ 4.5:1.

---

## Direction 1 — TALLY (the operations wall)

**Thesis**: the deck stops describing sessions and starts *showing* them — a
broadcast multiviewer wall of live miniatures. Attached = a lit tally lamp.
Contemporary-industrial; zero nostalgia.

| Token | Value | Use |
| --- | --- | --- |
| `chassis` | `#17181A` | deck ground, window frames (warm graphite, not blue-black) |
| `bezel` | `#26282B` | tile frames, rails, controls |
| `screen` | `#0A0B0C` | miniature + terminal ground — the darkest thing, framed by lighter chassis |
| `tally` | `#E5484D` | attached/LIVE lamp + default cursor. State only, never decoration |
| `caution` | `#E0A33E` | bell/activity ticks only, small doses |
| `signalText` | `#F2F3F4` / `#9BA1A6` | primary / secondary chassis text |

- **Type**: SF Compressed caps (rail + UMD source labels), SF Mono (session
  names, telemetry, miniature content), SF Pro (body, buttons). Buttons are
  chassis-styled; color carries *state*, actions stay neutral.
- **Signature**: the live miniature tile. Card = monitor: screen area renders
  the session's last ~8 lines (dimmed), UMD strip below carries
  `MAIN · DEVBOX`, tally lamp, telemetry (`5 WIN · 1 CLIENT · 2d`).
- **Spine**: the tile's bottom bezel is segmented — one segment per tmux
  window with its name in compressed caps; active segment lit white,
  activity segment gets a caution tick.
- **Deck**: host rails (name, address, state) over tile grids; unreachable
  host = dark tile stamped `NO SIGNAL`; New Session = empty tile with `+`.
- **Terminal window**: thin chassis bezel; bottom ornament is a UMD —
  compressed-caps source label, tally lamp when attached, controls right.
  Tab strip = multiviewer source labels with per-tab tally dots.
- **Default theme "Tally"**: bg `#0A0B0C`, fg `#E6E9EA`, cursor `#E5484D`,
  ANSI tuned neutral with red/amber matching lamps.
- **Motion**: tally ignition (snap on, ~400 ms decay off); miniature updates
  crossfade 200 ms; wall power-up stagger 30 ms/tile. Reduced motion: fades only.
- **Tail**: sheets = chassis panels with engraved section labels; first-run =
  one dark tile awaiting signal (`ADD HOST`); icon = dark tile, red tally,
  one lit bezel segment.
- **Named risk**: red-as-positive. Mitigation: the lamp is always captioned
  `LIVE`/`ON AIR`; errors never use tally red (they use caution amber + text).

## Direction 2 — PATCH BAY (multiplexing made physical)

**Thesis**: attaching is seating a cord. Hosts are engraved bay strips,
sessions are jack modules, tmux windows are the jacks themselves.

| Token | Value | Use |
| --- | --- | --- |
| `bakelite` | `#16120E` | deck ground (warm brown-black) |
| `module` | `#201A14` | raised strips/modules |
| `plate` | `#E8DFC8` | engraved traffolyte host plates, primary text |
| `tape` | `#F2ECD9` | typewritten session tape labels |
| `nickel` | `#B9BCB6` | jack rings, hardware (deliberately not brass — stays clear of the retired amber) |
| cords | oxblood `#8E3B3B` · cobalt `#3B5A8E` · moss `#5A7A4A` · slate `#5E6672` · mustard `#B8862F` | **cord color = host identity**, user-pickable per host |

- **Type**: SF Pro semibold wide-tracked caps “engraved” on plates (hosts);
  SF Mono on tape chips (session names, addresses — typewritten entries);
  SF Pro body.
- **Signature**: the seated cord. Attached session = a drawn bezier cord in
  the host's color, drooping with believable weight into the active window's
  jack. Attach = an empty labeled jack; tapping seats the cord (~350 ms
  spring). Detach = unplug.
- **Spine**: the jack row *is* the spine — one ~28 pt nickel-ring jack per
  tmux window, cord seated in the active one, faint host-color lamp above a
  jack with bell/activity.
- **Deck**: vertical stack of host bay strips; each strip = engraved plate +
  its session modules. Unreachable host = cold bay (plate legible, jacks
  dark, no lamps). New Session = free socket with blank tape; Shell = `AUX`
  jack on the strip.
- **Terminal window**: thin bakelite frame; ornament = tape label + host
  plate chip + a host-colored **grommet** at the edge where "the cord
  enters". Tabs = tape labels each with its host-color grommet dot; active
  tab's grommet lit.
- **Default theme "Bakelite"**: bg `#121009`, fg `#EFE7D2`, cursor `#E8DFC8`,
  warm-tuned ANSI.
- **Motion**: cord seat/unseat spring ~350 ms; lamp glow ease. Reduced
  motion: crossfade, cord appears seated.
- **Tail**: sheets = module panels with plate headers; first-run = one empty
  bay + free cord; icon = single jack with seated oxblood cord.
- **Named risks**: kitsch — held off by no-photoreal rule, nickel hardware,
  flat iPad rendering. Color-coded hosts — color is always redundant to the
  printed host name.

## Direction 3 — MANIFEST (the paper control surface)

**Thesis**: full figure-ground inversion — the control surface is printed
matter (a machine manifest: ruled ledger rows, typewritten entries, stamped
states); the work surface stays dark glass. Paper controls, ink work.

| Token | Value | Use |
| --- | --- | --- |
| `paper` | `#F2F0EA` | deck ground (cool archival white — not cream) |
| `well` | `#E9E6DE` | section wells, alternate rows, manila tabs `#EFE9DA` |
| `carbon` | `#1A1B1C` | text, rules, filled spine boxes |
| `rule` | `#C9C5BA` | hairlines |
| `stamp` | `#5B4B8A` | security-violet: state stamps (`ATTACHED`, `NO ROUTE`) + violet caret. The only accent, enforced |
| `pencil` | `#B5483A` | checker's-pencil error ticks, tiny doses |
| `terminalInk` | `#101113` | terminal ground |

- **Type**: SF Compressed black caps (masthead, column headers — timetable
  grotesque); SF Mono (all identity strings — typewritten entries); SF Pro
  body. **No serif anywhere** (dodges the AI cream-serif default).
- **Signature**: the ledger row + the stamp. Sessions are hairline-ruled rows
  (no cards, no rounded rects); state changes literally stamp (`ATTACHED` in
  violet, 150 ms stamp-down). Terminal tabs are manila folder tabs.
- **Spine**: printed platform diagram — large row of ruled boxes, one per
  window, active filled solid carbon, activity = pencil tick. Leading element
  of every row.
- **Deck**: one continuous manifest sheet — masthead (`MULTIPLEX · MACHINE
  MANIFEST`, date, host count), hosts as form sections with typewritten
  header rows, sessions as ledger rows. Unreachable host = section stamped
  `NO ROUTE`. New Session = a blank dotted ledger line (`add entry`).
- **Terminal window**: ink surface wearing paper fittings — manila folder-tab
  strip (active tab pulled forward), paper ornament strip with typewritten
  identity + stamp-styled buttons; status overlays are filed slips
  (`CONNECTION ENDED — [reason] — Reconnect`).
- **Default theme "Carbon"**: bg `#101113`, fg `#EDEAE2`, cursor `#7A68B8`
  (violet caret ties work surface to stamps), violet-tinted selection.
- **Motion**: stamps stamp (scale 1.15→1.0, 150 ms) on state change; folder
  tab pull-forward 200 ms; zero ambient motion. Reduced motion: opacity only.
- **Tail**: sheets = continuation forms (`FORM S-2 · HOST RECORD`);
  first-run = a blank manifest with one dotted row; icon = manila tab +
  violet stamp mark on paper.
- **Named risks**: light chrome polarizes terminal people (that's its job —
  it's the challenger pole). Dark rooms on visionOS: system auto-dimming +
  ink terminals keep the room calm; the deck is the only paper object.

---

## Prototype verdict (TALLY)

**Question the prototype answers:** does the Tally identity hold up in the
real material — visionOS glass, real SSH/tmux data, real density — and is
the live wall technically viable over the existing control connection?

**What was built** (all throwaway, DEBUG-only, deletable as a unit):

- `Multiplex/Prototype/` — tokens + switcher (`TallyPrototypeKit`), the
  capture-pane miniature poller (`TallyWallModel`), the fleet wall
  (`TallyWallDeck`), terminal chrome (`TallyTerminalChrome`).
- Marked `PROTOTYPE(TALLY)` gates in `DeckWindow`, `TerminalWindowRoot`,
  `HostConnectionModel` (`debugExec`), and a DEBUG-only "Tally (Prototype)"
  built-in `TerminalTheme`.
- Flip variants live with the floating pill on the deck (CURRENT ⇄ TALLY),
  or force at launch: `SIMCTL_CHILD_MULTIPLEX_PROTOTYPE=tally`.

**Observed against the harness** (screenshots in `DerivedData/proto-*.png`):

- The wall renders five live tiles; miniatures update within one ~5 s poll
  (a line injected via `tmux send-keys` appeared on the scratch tile; the
  demo server log advanced between shots). One exec round-trip per host.
- Attached sessions wear the captioned red LIVE lamp; spines render as
  segmented bezels with the active window lit; `+ NEW SESSION` and rail
  SHELL/telemetry all work through the production routes.
- Terminal window: source-label tabs with per-tab tally dots, opaque UMD
  ornament (DECK · MAIN · DEVBOX · LIVE · KBD A− A+ · DETACH), Tally default
  theme (screen `#0A0B0C`, red cursor). Unit tests pass; both platforms build.

**Production notes captured while prototyping:**

- tmux's own status line inside the pane colors itself from the ANSI
  palette; decide whether a shipped Tally sets `status-style` on attach or
  leaves user config alone (miniatures are unaffected — capture-pane
  excludes it).
- Inactive segment labels at signal3 are near-invisible at small tile
  sizes; production should try signal2.
- NO SIGNAL tile exists in code but wasn't exercised (harness host is
  always reachable) — verify with a dead host before shipping.
- `TmuxSession` should carry the client *count* (probe already receives it)
  for `N CLIENTS` telemetry.
- Simulator-only: writing the theme selection headlessly needs
  `simctl spawn defaults write <container-path-domain>` — plain
  `defaults write <bundle-id>` lands in the wrong domain and cfprefsd
  caches over direct plist edits.

**USER VERDICT: ADOPTED** (2026-07-10), after one prototype iteration — the
visionOS gaze-hover platter had to be squared (`chassisHover`: shape must be
declared on the Button, not its label; found only because the prototype ran
on-device — HTML boards can't show hover).

## Production adoption (done, 2026-07-10)

- `Theme.swift` re-tokened; components in `Design/Chassis.swift`
  (`ChassisLabel`/`ChassisChip`/`ChassisBadge`/`TallyLamp`/`chassisHover`).
- Deck = `FleetWall` (sidebar, `HostDetailView`, `SessionCard`, `WindowSpine`
  deleted); terminal chrome = source-label tabs + `UMDBar`.
- Miniatures productionized: `TmuxProbe.captureCommand/parseCaptures` (pure,
  unit-tested; targets tmux session *ids*, markers carry indexes so names
  can't break framing) + `HostConnectionModel.captureTails()`; FleetWall
  polls ~5 s while frontmost. Background re-probes no longer surface
  `.probing` (the wall was crossfading tiles against ACQUIRING every tick).
- Prototype notes all addressed: inactive segment labels → `signal2`;
  `TmuxSession.clientCount` (probe already had the count) → `N CLIENTS`
  telemetry; NO SIGNAL exercised for real (sshd stopped mid-run: hatched
  tile + UNREACHABLE rail + terminal ENDED overlay, then self-recovery on
  restart); tmux status line left to user config (documented in DESIGN.md).
- `TerminalTheme.tally` promoted to first built-in and app default; amber
  "Multiplex" kept as an optional theme.
- `Multiplex/Prototype/` and every PROTOTYPE(TALLY) gate deleted. Unit tests
  (16, incl. 4 new capture tests) pass; both platforms build; E2E verified
  on the visionOS 27 simulator.

Archived losers: Patch Bay, Manifest (specs above; rendered boards at the
Artifact from the bake-off session).
