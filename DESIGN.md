# Multiplex — Design

A spatial terminal for people who live inside remote tmux sessions.
visionOS first, iPadOS alongside. The app's single job: **get you attached to a
remote tmux session, each in its own floating window, fast.**

The name is the thesis — tmux is a terminal *multiplexer*; Multiplex multiplies
terminals into space.

## Voice

Plain verbs, user-side vocabulary: **Attach · Detach · New Session · Shell ·
Add Host**. An action keeps its name through the whole flow. Errors say what
happened and what to do next; they never apologize and never say "oops".

## Color

Terminal heritage without the hacker-green cliché. The accent is the amber of
real P3 phosphor hardware (VT220, Wyse 50), floating on a deep blue-black ink —
warm signal on cool ground. One accent, spent in one place.

| Token           | Value       | Use                                                    |
| --------------- | ----------- | ------------------------------------------------------ |
| `ink`           | `#0C0E13`   | terminal surface, card ground, iPad window ground      |
| `inkRaised`     | `#141823`   | raised card body, ornament fills                       |
| `line`          | `#262C3D`   | hairlines, spine cell strokes                          |
| `phosphor`      | `#FFB000`   | THE accent: active spine cell, caret, live badges, CTA |
| `phosphorDim`   | `#8F6A1D`   | secondary amber (attached-elsewhere, pressed)          |
| `textPrimary`   | `#E9E4D8`   | warm paper-white body text on ink                      |
| `textSecondary` | `#98A1B4`   | cool gray-blue chrome text                             |

Terminal ANSI palette: 16 tuned colors that sit well against `ink`, foreground
`textPrimary`, cursor `phosphor`. This is the **Multiplex** terminal theme —
the default of several the user can pick (or build) in Settings. Themes recolor
the terminal surface only; deck, ornaments, and chrome never leave amber-on-ink.

## Type

Monospace is the app's *identity voice*, not wallpaper: host names, session
names, counts, and addresses are always monospaced (SF Mono via
`design: .monospaced`). Labels, buttons, and captions stay SF Pro — fighting
the platform face on visionOS glass harms legibility and wins nothing.
Eyebrows are small-caps SF Pro with wide tracking: `HOSTS`, `TMUX SESSIONS`.

## Signature — the window spine

Each tmux session card renders its windows as a row of small cells: the active
window amber-lit, activity flagged with a dot, one cell per window. It is the
tmux status line materialized as a physical object — every pixel encodes real
state (window count, active index, activity), nothing is decoration.

```
┌────────────────────────────────────────────┐
│ main                        ● attached     │
│ ▰ ▱ ▱ ▱ ▱   5 windows · created 2d ago     │
│                                 [ Attach ] │
└────────────────────────────────────────────┘
```

## Composition

**Deck window (launcher).** Native visionOS glass; the dark objects on it are
the session cards — small ink screens floating on glass. NavigationSplitView:
hosts sidebar, host detail with the session cards, `New Session` and `Shell`
beneath. On iPad the same layout sits on ink (dark UI), toolbar instead of
ornaments.

```
┌──────────────────────────────────────────────────────────┐
│  MULTIPLEX                                       [+ Add] │
│ ┌───────────┐  ┌─────────────────────────────────────┐   │
│ │ HOSTS     │  │ devbox   jhen@10.0.1.12:22   ● ssh  │   │
│ │ ▸ devbox  │  │ TMUX SESSIONS              ↻        │   │
│ │   prod-a  │  │ ┌─────────────────────────────────┐ │   │
│ │   pi      │  │ │ main    ▰▱▱▱▱  5 win  ●attached │ │   │
│ │           │  │ │                        [Attach] │ │   │
│ │           │  │ ├─────────────────────────────────┤ │   │
│ │           │  │ │ scratch ▰      1 win            │ │   │
│ │           │  │ │                        [Attach] │ │   │
│ │           │  │ └─────────────────────────────────┘ │   │
│ │           │  │ [ New Session ]  [ Shell ]          │   │
│ └───────────┘  └─────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

**Terminal windows.** Each attach opens its own scene
(`WindowGroup(for: TerminalRoute.self)` + `openWindow`) — the user places them
around the room on visionOS; on iPadOS they are real multiple scenes (Stage
Manager / split screen). The window is fully ink — it *is* the screen — with a
bottom ornament (visionOS) / toolbar (iPad) carrying session name, spine, and
Detach.

## Motion & restraint

visionOS hover effects and system window animations do the work; the only
custom motion is a slow amber pulse on the empty-state caret. Reduced motion
disables it. No scanlines, no CRT curvature, no glow shaders — the amber and
the spine carry the identity.

## Self-critique (anti-template pass)

The generic AI answer for "terminal app" is pure black + neon green + mono
everywhere + scanline kitsch. Rejected: amber-on-blue-black from real hardware
heritage; mono reserved for identity; labels stay platform-native; zero fake
CRT effects. The generic visionOS answer is "glass window with a list."
Rejected: the signature spine cells and ink-cards-on-glass composition encode
tmux state physically, something only this subject could produce.
