# Landing page bake-off record (2026-07-18)

The live multiplexterm.dev site (the App Store marketing URL and the privacy
policy) lives in its own repo, **multiplex-home**
(`github.com/jhen0409/multiplex-home`, Astro on Cloudflare Workers). This
directory keeps the design bake-off that produced it.

Three candidates were built as self-contained HTML pages, all on the TALLY
identity (`DESIGN.md` tokens, copy from `fastlane/metadata/en-US/`):

| Candidate | Direction |
| --- | --- |
| **Daylight** (chosen, now `src/pages/index.astro` in multiplex-home) | Frost light chassis, real screenshots forward, Apple-marketing calm. Refined after selection: SSH-terminal and multi-window copy, the Pro in-app purchase marked, and a hero device lineup (Vision Pro / 11-inch iPad / iPhone on one baseline at true relative physical scale; the headset is a transparent-background cutout of Apple's newsroom glass shot — an earlier multiply-blend approach was dropped because iOS Safari ignores `mix-blend-mode` combined with `filter` on one element). |
| `v1-monitor-wall.html` | Dark TALLY studio. The hero is a live CSS recreation of the deck (ticking logs, tally lamps, a NEEDS YOU flip); features as chassis modules. |
| `v3-signal-sheet.html` | Broadcast-equipment data sheet. Swiss print masthead, annotated "reading the wall" figure, capabilities ledger, rate card. Near-static. |

Preview an alternate with `open v1-monitor-wall.html`. `assets/` holds the
optimized screenshots the candidates reference (derived from `docs/*.png`
with `sips -Z 2400 -s format jpeg -s formatOptions 82` for the visionOS
shots); the same set ships in multiplex-home's `public/assets/`. The Carrier
mark in all candidates is drawn from the DESIGN.md geometry spec; the Apple
badge glyph is the Simple Icons path (CC0).

Maintenance: the live site is a customer-facing claim surface. When features,
pricing, platforms, or privacy behavior change, update multiplex-home in the
same change as `docs/store-metadata.md` and the fastlane metadata.
