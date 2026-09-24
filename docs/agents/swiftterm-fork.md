# Vendored packages (SwiftTerm fork, SSH pins)

Load-bearing decisions split from AGENTS.md — read before touching `Vendor/`,
input encoding, or terminal rendering.

- **Vendored packages, both same-identity local overrides** (`Vendor/`):
  - `swift-nio-ssh` — Citadel 0.12.0's resolved fork (`Joannis` 0.3.5),
    patched to declare the `NIO` product it imports (Xcode 27 rejects the
    undeclared import); also freezes the SSH transport supply chain.
  - `SwiftTerm` — 1.18.0 (rev `7691f85`; bumped from 1.15.0 on 2026-08-16 by
    reconstructing the patch set as a commit on the old rev and 3-way merging
    it onto the new tag — do the same next time), patched in fourteen behavior
    groups plus a remote-input hardening set (all marked `Multiplex patch`).
    Three hardening patches were retired at 1.18.0 because upstream now
    carries the fix (CSI parameter cap + guard-before-arithmetic digit
    accumulation, `CSI 1 J` bottom-row trap); `appendingDecimalDigit`
    survives only for the Sixel field parser. Upstream 1.18.0 also added
    `implicitLinkCouldBeVisible`, an early-out that skips implicit link
    detection when the highlight mode would discard the match — it must
    honour `linkActivationIgnoresHighlight` or every touch-activated path
    link disappears (patched at the merge). Behavior groups:
    - `keyboardType` settable; kept `.default` so the user's language and
      multistage IME survive.
    - On-device intelligence is pinned OFF and `replace()` is tail-guarded:
      `inlinePredictionType` / `writingToolsBehavior` /
      `mathExpressionCompletionType` are computed `.no`/`.none` (upstream never
      set them, so the system decided per device/OS — the 2026-08 TestFlight
      "cursor jumps, mangled sentences" report on M5 AVP + visionOS 27 beta,
      absent on M2). Backstop: `replace(_:withText:)` drops any edit whose
      range doesn't reach the document end (backspaces can only delete at the
      remote cursor; a mid-document correction would eat the newest
      characters) and drops whole any non-empty range that addressed the
      backspace filler (its insert half alone would duplicate text). The
      traits are computed `@available` properties because their types
      postdate the package's own deployment floor.
    - Pans scroll the *remote* (`performRemoteScroll`): wheel events under
      mouse tracking, DECCKM-aware arrows in the alternate screen with mouse
      off; plain-shell tabs keep native local scrollback. Wheel coordinates
      are pinned to the pan's START location (`remoteScrollAnchor`): the live
      location drifts with the drag (visionOS: gaze hit + unbounded hand
      translation) and the row clamp pins overshoot to row 0 — herdr's tab
      bar, which switches tabs on wheel events (herdr changelog: "Scrolling
      over the tab bar now switches tabs directly"). tmux's status line has
      the same wheel-switches-windows exposure.
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
    - **App-authored key chords** (`iOS/iOSKeyChord.swift`, the fourteenth
      group): `TerminalKeyChord` (⌃ ⇧ ⌥ + enter/tab/escape/backspace/space/
      arrows/one character) and `TerminalView.bytes(for:)` / `send(chord:)`.
      The app's Key Commands panel names the chord and the view encodes it
      through the SAME `KittyKeyboardEncoder` a hardware press uses, plus
      the three rules the legacy `pressesBegan` path decides for itself
      (Shift+Enter → LF, Option+Left/Right → `ESC b`/`ESC f`, Ctrl+Shift+char
      → Ctrl+char). Never re-derive chord bytes app-side — they would drift
      from the hardware path the moment a remote toggles kitty flags.
      Pinned by `KeyChordEncodingTests` (legacy, DECCKM, and `CSI > 1 u`).
    - Link activation is touch-reachable and app-answerable:
      `linkActivationIgnoresHighlight` (upstream needed pointer hover),
      `linkActivationHandler` (the app can decline a match; carries the
      pressed buffer `Position` so the app can name the pane under the
      finger), one `activateLink` for both gestures — `singleTap`
      resolves one BEFORE mouse reporting at any mouse mode (a claimed
      target outranks the remote click; declined cells fall through and
      still report); `longPress` resolves one before its menu.
    - Implicit link detection is split-pane-aware (`paneSegment` /
      `buildPaneSegmentLineMap`): a row carrying vertical pane-border
      glyphs (│ family; ASCII `|` deliberately excluded — it's shell
      syntax) scopes matching to the border-delimited segment under the
      press, and a path that wrapped at the PANE border (mid-row, never
      `isWrapped`) rejoins via segment-edge heuristics — border continuous
      across the joined rows, upper segment reaching the segment's right
      edge, seam forming a link. Border-free rows keep the whole-row path
      untouched. Locked by `TerminalSplitPaneLinkTests`.
    - Both row-join heuristics (whole-row and pane-segment; never the
      `isWrapped` chain) decline a seam that butts a FINISHED file name
      against a plain word (`Terminal.seamGluesFinishedFileToWord`):
      upper side ends in `.` + 2–8 word chars, lower side opens with ≥ 3
      word chars before any `/` or `.`. Listing rows (`git status`, build
      logs) reach the right edge routinely, and the join used to read
      `Sources/foo/test.ts`⏎`modified:` as one path `test.tsmodified`.
      Accepted trade: a wrap landing inside a long extension (`.swi`⏎`ft`)
      splits into two presses. Locked in
      `GhosttyImplicitLinkDetectionTests`.
    - visionOS coalesces pending redraws to one 90 Hz frame (~11.1 ms) in
      `queuePendingDisplay`; the upstream 16.67 ms delay assumed a 60 Hz
      display and beat against Vision Pro's 90 Hz compositor during
      streaming output (typing already bypassed it via
      `displayImmediately`). iOS keeps 60 Hz.
    - Metal renderer visionOS bring-up (still OFF by default; the app
      exposes it as Settings → Terminal renderer, with `MULTIPLEX_METAL=1`
      as the harness/scheme override and `MULTIPLEX_METAL_FPS=1` printing a
      per-second FPS/row-cache heartbeat in every configuration —
      `SWIFTTERM_PROFILE=1` adds signposts for Instruments): the
      drawable/atlas scale no longer trusts `backingScaleFactor()` (1.0 on
      visionOS — 1x blur) but takes the layer contentsScale / trait
      displayScale max; the MTKView is non-opaque over the view's layer
      ground so the GLASS clear composites; and the clear/margin background
      resolves `nativeBackgroundColor` against the terminal view's traits —
      `getRed()` resolves dynamic colors via `UITraitCollection.current`,
      which inside an MTKView delegate callback misses the app's glass
      trait and silently painted the opaque fallback. Sim-verified matching
      CG pixel-for-pixel in DARK/LIGHT/GLASS; selection, marked text, and
      kitty images under Metal are still unverified. Do NOT judge Metal
      performance in the simulator: `com.apple.metal.simulator` presents at
      ~2–4 fps under streaming load with the row cache warm (rows rebuilt
      0/58) — the stall is the sim's present path, not the renderer; only a
      real-device A/B against the CG damage-strip path counts.
    - The visible screen's links are enumerable (`Terminal
      .visibleLinkMatches` + `TerminalView.visibleLinkRegions`, the inverse
      of `calculateTapHit`) — what visionOS gaze hover stands on.
    - Echo-latency sampling (`echoLatencySampleHandler`): the first feed
      chunk after each user-input stamp yields one keystroke→paint sample
      (ms) — the delta the immediate-display gate already computes and
      discards. Handler runs on the feed thread; the sampled stamp shares
      `userInputLock` with the stamp itself. Window is 2 s (its own
      constant, NOT `interactiveInputDisplayWindowNs` — a slow link's echo
      is still an echo at 300+ ms); a first chunk outside it consumes the
      stamp without sampling, so stream output never counts. Feeds the
      Connection Stats center.

    Sample apps trimmed. When bumping either package, re-apply the patches
    and diff before trusting it.
- **Citadel pinned to exactly 0.12.0**: 0.12.1 moved its swift-nio-ssh dep
  to an unaudited personal fork. Don't bump without review — this is the
  transport.
