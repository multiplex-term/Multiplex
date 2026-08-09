# Vendored packages (SwiftTerm fork, SSH pins)

Load-bearing decisions split from AGENTS.md — read before touching `Vendor/`,
input encoding, or terminal rendering.

- **Vendored packages, both same-identity local overrides** (`Vendor/`):
  - `swift-nio-ssh` — Citadel 0.12.0's resolved fork (`Joannis` 0.3.5),
    patched to declare the `NIO` product it imports (Xcode 27 rejects the
    undeclared import); also freezes the SSH transport supply chain.
  - `SwiftTerm` — 1.15.0 (rev `dd2fb8a`), patched in twelve behavior groups
    (marked `Multiplex patch`):
    - `keyboardType` settable; kept `.default` so the user's language and
      multistage IME survive.
    - Pans scroll the *remote* (`performRemoteScroll`): wheel events under
      mouse tracking, DECCKM-aware arrows in the alternate screen with mouse
      off; plain-shell tabs keep native local scrollback.
    - The single→double→triple tap failure chain is decided PER TOUCH by a
      gesture-delegate method, never static `require(toFail:)`
      (`remoteOwnsImmediateTaps`): while the client reports mouse (tmux
      `mouse on`, the app's premise) every physical tap fires immediately as
      its own click — the old static chain bought ~350 ms latency and folded
      a remote double-click into ONE click. A double gesture of ANY input
      kind — finger, Pencil, visionOS gaze/pinch, or a pointer's
      double-click — now ALSO raises the app's selection block after its two
      immediate remote clicks; only double waits for
      triple, so single-tap latency and three-click semantics stay intact.
      Mouse-off —
      and a held hardware Shift bypassing reporting — keeps the old chain so
      local word/line selection still works.
    - A tap while a local selection **or its context menu** is present
      dismisses it and is consumed (`dismissLocalSelectionUI`, checked
      before link opening and mouse reporting, mirrored into the
      double/triple-tap branches). The menu check is independent of
      `selection.active` — a long press opens the menu without a selection.
    - `hasText` always answers true: the terminal's document is the remote
      screen, never the `textInputStorage` mirror (does NOT fix
      held-backspace — see the input-filler known limit in
      `input-and-windows.md`).
    - Marked text stays local in a caret-anchored overlay until commit, with
      honest candidate-window geometry and cleanup — merged with upstream's
      Korean resyllabification transaction, not replacing it.
    - Fully obscured tabs keep parsing bytes but suppress UIKit,
      accessibility, and Metal invalidations until visible (one full
      refresh then).
    - iOS/visionOS output damage invalidates a padded row STRIP, not the
      whole viewport (`damagedRowStrip`; the CG renderer is the live path
      — nothing calls `setUseMetal`). `drawTerminalContents` narrows its
      row loop only for a well-formed sub-viewport rect
      (`partialRedrawRows`, pure + app-tested); anomalous rects — UIKit's
      scroll-coalesced y=0 shapes, viewport-spanning unions, the
      `setNeedsDisplay(frame)` legacy callers — keep the full-screen
      redraw, so the contentOffset workaround's semantics are unchanged.
      Why it exists: a one-row keystroke echo used to re-run CoreText for
      every visible row and hand the compositor the entire translucent
      surface to re-blend over live glass — the measured cause of GLASS
      typing jank on real Vision Pro (2026-08-05), and wasted CPU on
      every appearance. Glyph overhang is covered by the ±1-row pad;
      partial repaints stay correct because `clearsContextBeforeDrawing`
      (default true) clears the strip before `draw(_:)` refills it.
    - iOS-app-on-Mac: hardware Escape is claimed by a priority no-op
      `UIKeyCommand` (stops Cocoa's `cancelOperation:` resigning focus).
      Ctrl+character chords need the separate `GCKeyboard` HID bridge —
      UIKit drops them at the Cocoa key-binding table before ANY responder
      path runs; the bridge sends the control byte (kitty-encoded when flags
      are on) to the first responder and never installs on real iPads. A
      bridged Ctrl+B/fallback key carries a short duplicate receipt because OS
      revisions can also surface it through UIKit. Ctrl+B additionally arms
      ONE printable follow-up (with no app-authored timeout — the remote owns
      that state): UIKit gets 60 ms to provide the layout-resolved key; if
      Cocoa swallows it, HID supplies the ANSI fallback. The follow-up MUST be
      encoded as a Kitty KEY when flags are active — a raw `v` is a text event,
      which herdr inserts into the pane while leaving PREFIX armed. This is
      what keeps physical `Ctrl+B`, then `v` working as a multiplexer chord on
      the Mac without taking ordinary typing away from the IME.
    - Hardware Shift+Enter is a first-class newline: `pressesBegan` claims
      Return (all three HID usages); kitty flags → `CSI 13;2u`, else LF
      0x0A (verified against Claude Code / Codex / Pi / tmux 3.6a
      2026-07-24; unmodified Return keeps the UIKit path for IME). On Mac,
      Cocoa strips Shift first, so `commitTextInput` rewrites a bare "\n"
      by polling the physical Shift keys at the HID layer — real hardware
      only (synthetic keystrokes never reach HID, so neither Mac path can
      be driven headlessly).
    - Link activation is touch-reachable and app-answerable:
      `linkActivationIgnoresHighlight` (upstream needed pointer hover),
      `linkActivationHandler` (the app can decline a match), one
      `activateLink` for both gestures — `singleTap` skips links while the
      remote wants the tap; `longPress` resolves one before its menu.
    - The visible screen's links are enumerable (`Terminal
      .visibleLinkMatches` + `TerminalView.visibleLinkRegions`, the inverse
      of `calculateTapHit`) — what visionOS gaze hover stands on.

    Sample apps trimmed. When bumping either package, re-apply the patches
    and diff before trusting it.
- **Citadel pinned to exactly 0.12.0**: 0.12.1 moved its swift-nio-ssh dep
  to an unaudited personal fork. Don't bump without review — this is the
  transport.
