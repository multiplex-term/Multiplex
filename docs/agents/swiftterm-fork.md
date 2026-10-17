# Vendored packages (SwiftTerm fork, SSH pins)

Load-bearing decisions split from AGENTS.md — read before touching `Vendor/`,
input encoding, or terminal rendering.

- **Vendored packages** (`Vendor/`) — `rnnoise` is the C noise suppressor
  behind dictation (library only, built `USE_WEIGHTS_FILE`, one local patch;
  the model is downloaded and SHA-256-pinned at runtime — its
  `README.md` is the bump recipe); the other two are same-identity local
  overrides:
  - `swift-nio-ssh` — Citadel 0.12.0's resolved fork (`Joannis` 0.3.5),
    patched to declare the `NIO` product it imports (Xcode 27 rejects the
    undeclared import); also freezes the SSH transport supply chain.
  - `SwiftTerm` — 1.99.0 (rev `2dad6a1`, the SwiftTerm 2.0 API preview;
    bumped from 1.18.0 on 2026-10-11 by reconstructing the patch set as a
    commit on the old rev and 3-way merging it onto the new tag — do the same
    next time, but expect the view files to need a hand port: 1.99 rewrote
    the view layer, so AppleTerminalView / iOSTerminalView were rebuilt from
    upstream's files with each group re-applied). Patched in the behavior
    groups below plus a remote-input hardening set (all marked
    `Multiplex patch`). Upstream 1.18.0 added `implicitLinkCouldBeVisible`,
    an early-out that skips implicit link detection when the highlight mode
    would discard the match — it must honour `linkActivationIgnoresHighlight`
    or every touch-activated path link disappears.
    - **SwiftTerm 2 seams.** `TerminalView.getTerminal()` is gone: the
      terminal lives behind `terminalLock`, the parse runs synchronously on
      whatever thread calls `feed`, and frames come from a `CADisplayLink`
      `FrameDriver` drawing a snapshot. View code reaches the terminal only
      inside `withTerminal { }` (never re-entrantly — the lock is not
      recursive; app callbacks such as `longPressMouseDragFilter` run
      outside it). The app uses copied reads — `terminalDimensions`,
      `visibleRowsText`, `terminalStateSnapshot()` (`viewportRow` is
      `yDisp`), `keyboardEnhancementFlags` — plus three patched accessors
      2.0 lacks: `applicationCursorKeys` (DECCKM for app-sent arrows),
      `isAlternateBufferActive` (agent detection), and a view-level
      `linkWithRowTexts` (DEBUG first-link hook). Owners must call
      `updateUiClosed()` when a view is released for good —
      `TerminalSessionController.detach()` does (a tab move never runs it),
      retrying while a Metal surface reports GPU work in flight. Backstop
      patch: a display-link tick whose driver is gone invalidates its link,
      so a view released mid-burst cannot keep a link firing at display rate.
      The re-locked gesture seams — claimed long-press drags, the
      traveling long press's hand-off to the remote's own selection
      (`longPressDragSelectsRemotely`), the remote right click,
      wheel/cursor-key pans — are pinned on the wire by
      `TerminalRemoteMouseTests`; the input stamp and echo sampler by
      `TerminalTypingQuietTests`.
    - **Retired at 1.99.0** (upstream now carries the fix): the OSC/APC
      payload caps (upstream bounds both at 65 MiB and drops oversized
      retained capacity), the whole Sixel set (input cap, overflow-checked
      fields, pixel/write budgets, the `maxX` sizing fix — so
      `appendingDecimalDigit` is gone), the negative OSC 104 index, Kitty's
      pending-chunk cap / control-value clamping / placement-scroll bound /
      inflate limit / cache budget (upstream: UInt32-parsed fields, a
      10 MB-per-screen store, inflate bounded by it), the
      `sendButtonReleaseEvent` SGR release (upstream's release encoding now
      names the button), the Metal GLASS-clear resolve (upstream's
      `FrameColor` resolves against the view's traits), and the 90 Hz
      redraw coalescing (the display link ticks at the display's native
      rate). Kept: Kitty's per-image ceiling (64 MiB vs upstream 400 MiB —
      it bounds the PNG decode's RGBA allocation; the vendored
      `KittyPNGHeaderBoundsTests` is resized to match), the title-stack
      depth cap, and the bounded OSC 1337 inline-image decode.
    - **Manifest**: upstream's `swift-png` dependency (and its transitive
      `rarestype/h`) is dropped — it is linked only for non-Apple platforms,
      but SwiftPM resolves every declared dependency, so the app fetched two
      unaudited repositories for code it never compiles. The build-info
      plugin (`SwiftTermBuildInfoPlugin`, generates the XTGETTCAP table)
      runs under plain `xcodebuild` without a trust prompt for this local
      package.
    - **Deliberate divergences from 1.99 behavior**, kept from the shipped
      fork: an unfocused terminal's tap only focuses (upstream forwards it
      as a click to a mouse-tracking app — the focus arbiter owns which pane
      takes keys); a double tap under mouse reporting never selects locally
      (the single recognizer already sent both clicks); and pans keep the
      remote-scroll routing below rather than upstream's one-finger
      wheel / two-finger scrollback split (`forwardWheelDrag` is left in
      place, unwired). `hasText` stays patched to true although upstream
      made it `open`.
    Behavior groups:
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
    - Fully obscured tabs keep parsing bytes but get no frames until
      visible (one full-screen frame then): `renderUpdatesEnabled` drives a
      host-visibility input on the `FrameDriver`, separate from its
      background/window-attach inputs so a foreground transition cannot
      un-hide an obscured tab. It also reports DEC 2033 not-visible to the
      remote.
    - iOS/visionOS output damage invalidates a padded row STRIP, not the
      whole viewport (`damagedRowStrip`, computed in the iOS branch of
      `TerminalRenderOwner.prepareFrame`, widened to the rows a bidi
      paragraph depends on; a viewport scrolled into history keeps the full
      redraw. The CG renderer is the live path — Metal is opt-in, see
      below). `drawTerminalContents` narrows its
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
      2026-07-24; unmodified Return keeps the UIKit path for IME). Return
      is a kitty functional key for the flags-on branch only — 1.99 routes
      flags-off functional keys through the legacy encoder, and Return must
      stay out of that route or IME commits break. On Mac,
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
    - Metal renderer visionOS bring-up (still OFF by default; the app
      exposes it as Settings → Terminal renderer, with `MULTIPLEX_METAL=1`
      as the harness/scheme override and `MULTIPLEX_METAL_FPS=1` printing a
      per-second FPS/row-cache heartbeat in every configuration —
      `SWIFTTERM_PROFILE=1` adds signposts for Instruments): the
      rasterization scale (`FrameViewState.renderingScale`, read only by
      Metal) no longer trusts `backingScaleFactor()` (1.0 on visionOS — 1x
      blur) but takes `metalRenderingScaleFactor()`, the layer contentsScale
      / trait displayScale max; and the MTKView and its layer are always
      non-opaque over the view's layer ground so the GLASS clear composites
      (upstream's one-time `backgroundOpacity` read would freeze the
      appearance). The background colour itself needs no patch since 1.99:
      `FrameColor` resolves it against the view's traits. Sim-verified
      matching CG pixel-for-pixel in DARK/LIGHT/GLASS at 1.18; not re-run
      at 1.99, and selection, marked text, and kitty images under Metal are
      still unverified. Do NOT judge Metal
      performance in the simulator: `com.apple.metal.simulator` presents at
      ~2–4 fps under streaming load with the row cache warm (rows rebuilt
      0/58) — the stall is the sim's present path, not the renderer; only a
      real-device A/B against the CG damage-strip path counts.
    - The visible screen's links are enumerable (`Terminal
      .visibleLinkMatches` + `TerminalView.visibleLinkRegions`, the inverse
      of `calculateTapHit`) — what visionOS gaze hover stands on.
    - Echo-latency sampling (`echoLatencySampleHandler`, `@Sendable`): the
      first feed chunk after each user-input stamp yields one
      keystroke→paint sample (ms). Upstream 1.99 retired its own input stamp
      with the 150 ms immediate-display window, so the stamp is patched back
      in: `TerminalViewCrossThreadState` holds it, the input sender's
      `registerInput` writes it (every input road funnels through there),
      and the feed sender samples after each batch, calling the handler on
      the feed thread outside the lock. `lastUserInputUptimeNanoseconds`
      reads the same stamp. Window is 2 s (a slow link's echo is still an
      echo at 300+ ms); a first chunk outside it consumes the stamp without
      sampling, so stream output never counts. Feeds the Connection Stats
      center.

    Trimmed from the vendored tree: the sample apps (`TerminalApp/`),
    `Tools/`, the browser demo (`Web/`) and its JS tests
    (`Tests/WebWasmTests`), and `.github/`. When bumping either package,
    re-apply the patches and diff before trusting it.
- **Citadel pinned to exactly 0.12.0**: 0.12.1 moved its swift-nio-ssh dep
  to an unaudited personal fork. Don't bump without review — this is the
  transport.
