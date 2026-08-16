# Terminal input, windows & scenes

Load-bearing decisions split from AGENTS.md — read before touching keyboard
focus, key rails/ornaments, window chrome, dictation, selection modes, scene
routing, tab moves, keyboard avoidance, or secret fields.

- **Keyboard focus goes through `TerminalFocusArbiter`, never per-view**:
  every visionOS window is its own always-key scene, so per-view responders
  leave input stuck on the first session; claiming resigns the previous
  owner and activates the claimed scene. Its visibility tracking must ride
  the frame-change notifications (`KeyboardAvoidance.isPresented`, pure):
  floating keyboards never post didShow/didHide, and stuck-false visibility
  makes a terminal tap tear down the input session. Stage Manager's
  zero-height frame while a floating keyboard stays active is ambiguous,
  not a hide — preserve the previous state. Stage Manager also transiently
  clears a moving window's `isKeyWindow`: an already-owned claim must stay
  a no-op, never `makeKey()`. The compact shell's deck is a focus-exclusion
  surface: restoration passes stage visibility through
  `TerminalFocusArbiter.restore` and refuses/resigns a hidden responder.
- **The shell spends the safe areas; its panes hand back the clearance**
  (`SingleWindowShell`). The GeometryReader stays *inside* the safe area
  (ignoring an edge zeroes that edge's inset), the pane stack spans the
  bands, and each pane restores its own: FleetWall as wall padding
  (`shellSafeArea`), the terminal as content insets (`contentSafeArea`,
  down to `KeyBarRow`'s own padding inside the ViewThatFits proposal).
  Traps: a landscape Dynamic Island sits mid-edge and iOS reports BOTH
  landscape edges unsafe without saying which holds it — no band is safe to
  read in; heights are `height + safeArea.bottom` (this reader is inset by
  whichever bottom region applies, so adding it back lands on the window
  edge, keyboard or not). The key rail takes the bottom strip at compact
  vertical size class and on every iPad stage (shell or classic window) —
  the rail IS the window's bottom edge there, so a reserved strip would only
  park a dead band under the row. Where it does,
  `SwiftTermView.railOwnsBottomSafeArea` moves `restingBottom` with it — a
  static fact per pane, never read from the live frame (the strip's padding
  would feed back) — and the rail buys its own daylight back below the key
  faces (`TerminalKeyBar.keyBottomInset(isIOSAppOnMac:spendsBottomStrip:)`:
  3 → 8, which is also the iPhone-landscape padding fix, so the bar's height
  moves with the fact). The auxiliary panes' rails instead paint through the
  strip and lift their controls by the classic window's `contentSafeArea
  .bottom`, which is why a classic window now hands that inset down.
  Panes are placed
  with `.offset` (claims no width): align the frame `.topLeading` or
  SwiftUI centers the lot.
- **iPhone's left-edge right-swipe arbitrates above SwiftTerm**
  (`ShellBackSwipeRecognizer`, one `UIScreenEdgePanGestureRecognizer` on
  the shell window): at the edge, horizontal movement gets first refusal;
  vertical intent fails immediately back to SwiftTerm (remote scrolling
  preserved); an active local selection rejects the touch before tracking
  and re-checks at begin. A SwiftUI gesture does not reliably receive drags
  begun inside `TerminalView`.
- **The iPad/iPhone key rail is app-owned chrome, never an
  `inputAccessoryView`** (`TerminalKeyBar`): ESC / latching CTRL / TAB, the
  shell symbols `~ | / -`, DECCKM-aware autorepeat arrows, RET (iPad, and
  iPhone while locked), autorepeating PgUp/PgDn (`CSI 5~`/`6~`), and one
  slot that is the keyboard toggle or — with a physical keyboard — the
  dictation key. Keep `TerminalView.inputAccessoryView = nil`: a
  physical-iPad A/B proved TextInputUI rehosts even a custom accessory
  during Stage Manager moves, stalling the UI. The keyboard key holds
  (~0.5 s) into the **keyboard lock** (`TerminalFocusArbiter.lock` — a
  zero-size custom `inputView`, so the input session, rail, and hardware
  keys stay live while taps stop summoning); a KEYBOARD LOCKED tip
  top-center carries the dictation action, latching while permissions
  resolve then yielding to the LISTENING bar (it shares the dictation
  bar's slot — the top-trailing slot belongs to window chrome the tip
  used to cover). Without a physical keyboard, the lock is also a named
  action in the `⋯` menu at every width (`toggleKeyboardLock`; wide chrome
  passes `displacesDirectActions: false` so it never duplicates chips).
  `HardwareKeyboardMonitor` hides the redundant LOCK action while a keyboard
  is connected (an already-held lock keeps UNLOCK reachable). State is
  app-wide (`KeyboardLock.shared`, arbiter-written, never persisted); `claim`
  re-applies it to whichever terminal takes focus.
  Narrow tiers drop page keys, then symbols; `SingleWindowShellLayout`'s
  390/420 pt cutoffs must stay in lockstep with the measured `KeyBarRow`
  tiers (375 pt locked floor keeps RET; narrow locked phones move TMUX to
  a top-right button, and the overflow deliberately has no duplicate tmux
  entry). "TMUX" names the shortcut-key SLOT: a herdr tab fills it with
  HRDR — four mono characters, so every tier and cutoff holds unchanged —
  and both open the shared `ShortcutPanelViewController`, whose content
  (`ShortcutPanelContent.tmux`/`.herdr`) is the ONE place a backend's
  shortcut set lives. Pane cycling (both backends) and herdr tab cycling are
  deliberately absent because those targets are already directly tappable;
  tmux Last Window is absent because the live switch list targets a window
  directly. The panel root scrolls when a phone popover clamps
  its height — never clip rows. The top popover opens downward; while presented, the arbiter
  resigns the terminal (a docked keyboard would clip the grid) and
  restores only if that tab still owns focus. Every key sends through
  `TerminalView.send` → delegate → ordered pump — never a side channel;
  CTRL rides `controlModifier`, latch released on
  `.terminalViewControlModifierReset`. **Hold CTRL (0.3 s,
  `KeyCommandPanelViewController.controlHoldDuration`; a tap still
  latches and never fires the hold) opens KEY COMMANDS** — a popover
  anchored to the CTRL key on both platforms (`KeyCommandPanelViewController`
  in `KeyCommandPanel.swift`; ONE `KeyCommandPanelPresenter` owns present /
  dismiss / focus-resume / popover delegate for both hosts — `TerminalKeyBar`
  and the visionOS `TerminalKeyClusterGroupView` supply only the anchor and
  their appearance step, the ornament carrying the C / B popover's appearance
  and glass mirroring). The panel stands on the shortcut panel's now-shared
  grammar (`ShortcutPanelRootView`, `ShortcutPressControl`,
  `TallyHairlineGrid`, `TallyPanelHeader`, `UIKitChassisMonoLabel`) and the
  agent editor's shared controls in `Design/TallyEditorControls.swift`
  (`TallyEditorSwitch`, `TallyEditorRowActionButton`, `TallyEditorRowActions`,
  `TallyEditorLegend`, `TallyEditorFooter`). Two tabs: COMMANDS is a two-column hairline grid of
  saved rows (tap sends; a row with CLOSE ON PRESS off keeps the panel up;
  a 0.5 s hold jumps to that row's setup); CUSTOM SETUP is the agent editor's
  numbered list with an inline composer (TYPE KEYS | TEXT, ⌃ ⇧ ⌥ + one key
  from ↩ ⇥ ⎋ ⌫ ␣ ↑ ↓ ← → or a one-character field, or one line of text with
  SUBMIT = CR ~160 ms later, REPEAT count + gap under the guard ×5 · 50–500 ms ·
  burst ≤ 2 s, PANEL, SENDS readout of the live bytes) — a draft
  transaction, DONE normalizes once, CANCEL/outside dismissal discards.
  The model (`KeyCommand`, `KeyChord`, `KeyTextSnippet`, `KeyCommandSet`
  with the three shipped defaults ⇧↩ · ⌃C×2 · ⌥⌫-stays, `KeyCommandRepeatGuard`)
  is pure; **chords are never bytes** — `KeyCommandDispatcher` asks the fork
  (`TerminalView.bytes(for:)`, fourteenth patch group) at press time, so a
  chord sends exactly what a hardware press would in the terminal's current
  mode (kitty flags, DECCKM, backspace mode), and text rows ride
  `send(txt:)` + a delayed CR like slash chips. Every send is
  `TerminalView.send`, i.e. the ordered pump. Storage is app-wide
  (`KeyCommandStore.shared`: `keycommands.json` beside `hosts.json` plus one
  synchronizable Keychain item; `KeyCommandSync.merge` is the pure
  last-writer-wins rule; refreshed at launch and when the panel opens, at
  most once a minute — no CloudKit/KVS entitlement exists). Tier: free
  keeps `EntitlementStore.freeKeyCommandLimit` (5) commands, Pro the model's
  cap (12) — the same rule as hosts: a set that already holds more (synced
  from a Pro device) is never trimmed and every row keeps sending; only
  ADD COMMAND is gated, turning into the prominent "ADD COMMAND · PRO"
  chip that opens the paywall (a legend line says why the cap is 5). The
  rail and cluster never learn about Pro: the terminal window builds a
  `KeyCommandPlan` (limit + paywall route) from its `EntitlementStore` and
  hands it down — iPad through `TerminalPaneConfiguration` →
  `TerminalSurfaceView.Configuration` → `TerminalKeyBar.keyCommandPlan`,
  visionOS onto both `TerminalKeyClusterContext`s (shell + ornament) — and
  the presenter wraps the route so the popover is down before the paywall
  sheet presents (`presentPaywall` refuses while anything is presented).
  `entitlements.isPro` is in the window's observation set, so a purchase
  re-renders with the lifted plan. The terminal
  GUIDE carries a HOLD CTRL card (figure 12). Focus: the
  panel never suspends the terminal; only if one of its own fields took the
  keyboard does dismissal `resumeAfterPresentation`. Design record + grill:
  `local-plan/key-commands-bakeoff/`. visionOS: `TerminalKeyCluster`
  (same keys + latch + DEBUG hook) flanks the UMD on ONE console line in
  the bottom ornament. ViewThatFits compacts key faces first; when even
  compact can't fit, a `fixedSize` floor lets the row overflow the window
  edges symmetrically. Never re-add a keys-under-UMD restack (the system
  CLIPS ornament content hanging below the anchor) and never let the UMD
  compress (its title truncates). `UIHostingOrnament` centers the root's
  geometric bounds; a descendant alignment guide does not cross that host.
  `TerminalVisionConsoleLayout` therefore makes the console row's top the
  root's actual midpoint, with the helper in the upper half. Do not regress
  it to a plain VStack/alignment guide: helper-less keys will straddle the
  window until an agent grows the stack. Re-verify visually when touching
  it. DECK and the text-size chips live in the UMD title row. ⚠ SwiftTerm
  still *builds* its stock accessory on
  visionOS and `commitTextInput` prefers its `controlModifier` —
  `SwiftTermView` nils `inputAccessoryView` there; don't remove that.
- **Auxiliary tabs wear their whole bottom chrome in the ornament
  (2026-08-10)** — on classic visionOS windows the in-window ▤/⌗ rails are
  not mounted (`showsInWindowRail: false`); their end chips collided with
  the system resize corners. The ▤ file viewer stacks its file row above
  the verbatim UMD row in ONE slab (`ViewportUMDRootView
  .installStackedDeck`; the rail's duplicate CLOSE is deleted — the window
  row's CLOSE is the only one). The ⌗ viewport replaces rail + UMD with
  three content-sized slabs (`ViewportSwitchboardViewController`:
  navigate DECK ◂ ⟳ / locate address+reach / act SYSTEM ⋯ CLOSE; the caps
  `⌗ port · host` title is retired — the address readout is the identity,
  and MERGE folds into ⋯). Both mount `.fixedSize()` — NEVER window-width:
  a slab that tracks the window permanently covers the system resize bar
  (shipped and caught same day). `TerminalVisionStackedDeckGeometry`
  biases the deck so its top edge sits half a window row above the anchor
  and the extra file row hangs BELOW it, off the pane's last lines;
  auxiliary slab content below the anchor does render — the CLIPS trap
  above is about restacking keys under the UMD console line. Shell/iPad
  keep the in-window rails unchanged; re-verify placement visually when
  touching any of this.
- **A terminal window's title bar is app-owned, and its scene asks for
  `.minimal` window controls** (`TerminalClassicRailInsets`;
  `MultiplexSceneDelegate.preferredWindowingControlStyle(for:)`). Two
  system pieces had to go. **The navigation bar**: iPadOS 26+ sizes it for
  system controls and it CANNOT be shortened — measured 54 pt above a
  10 pt scene inset (64 pt of chrome for 21 pt faces), where
  `sizeThatFits` is consulted and ignored, a `frame` clamp never lands
  (constraint-driven layout), and a `bounds` clamp shrinks the bar but
  leaves UIKit centring it in the band it still reserves, pushing the
  content inset to 74.5 pt. Don't retry those; the classic window mounts
  the same `UMDBarViewController` `.shell` rail a full-screen iPad wears,
  and the navigation controller stays only as the hosting plan with its
  bar hidden. **The window-control pill**: iPadOS 26's default
  `.unifiedStyle` parks it INSIDE the scene's content, 21–43 pt below the
  window's top edge, and nothing app-side moves it (hidden status bar, no
  navigation controller, rail heights 54/41/31 all left it exactly there).
  `.minimalStyle` — "occupy as little of the scene's space as possible" —
  lifts it to 6–27.5 pt, in line with the rail's own chips. It is scoped
  to terminal scenes: the deck and shell still host system navigation
  bars, and `.unified` is what insets THOSE bars around the pill. Total
  chrome: 44 pt in a window — the rail matches `TerminalKeyBar.barHeight`
  at the pane's other end (`minimumContentHeight`; the faces keep their
  size and centre in it, and the padding becomes a floor) — pill
  contained, versus the old 64 pt. The rail spends a top strip ONLY where the scene reaches the
  display's top chrome, and never on the Mac (its scene already sits below
  a real title bar). Both halves are caught regressions: spending it
  always paints the row below a floating window's pill and under a second,
  empty Mac title bar; spending it never paints the rail UNDER the status
  bar when the window is maximised. ⚠ Under iPadOS 26 windowing NONE of
  the obvious signals answer this (all measured 2026-08-04):
  `safeAreaInsets.top` reports the display's 32 pt status bar even for a
  711x941 window floating in the middle of a 1032x1376 display,
  `statusBarManager` likewise answers for the display, and
  `UIWindowScene.isFullScreen` is Mac Catalyst's property — it stays false
  even when the window is maximised. ⚠ Nothing reports a window MOVE
  either: `UIWindowSceneGeometry` on iOS carries no origin (coordinate
  space, orientation, `isInteractivelyResizing`; `systemFrame` is Mac
  Catalyst only), so `windowScene(_:didUpdateEffectiveGeometry:)` —
  iOS 26's replacement for the deprecated `didUpdateCoordinateSpace`,
  adopted here — covers resizes and screen moves but NOT a drag, and
  the rail kept stale insets (user-reported as "doesn't always expand
  or collapse when the window is moved"). A 0.5 s position watch
  closes it: one rect conversion per tick while the scene is active,
  layout invalidated only on a real change — watching is polling, the
  deck's way. Geometry is what's left, and a
  window's own frame is scene-relative (origin always zero) — the position
  comes from `window.convert(window.bounds, to: screen.coordinateSpace)`,
  which DOES report where a scene sits on the display (measured: a
  floating window at y 217.5 on a 1376 pt display). `meetsSystemTopChrome`
  (spans the display) compares the dimensions UNORDERED — `UIScreen
  .bounds` does not follow the scene's orientation, so a maximised
  landscape window is 1376x1032 against a 1032x1376 screen. Same trap for anything else asking "am I full
  screen" — the shell-mode decision's own `isFullScreen` read is worth
  re-checking. TMUX/HRDR names one road and exactly one rail may draw it: the
  pane's key rail owns the chip wherever it fits, and the rail above takes
  it over only at the widths where the key rail drops it. The rail
  therefore measures the KEY RAIL's content width (`keyRailContentWidth`),
  never its own — a classic window's rail clears the window-control pill
  and is ~90 pt narrower than the pane below it, while the shell's wide
  row stays above the cutoff on any landscape phone (drawing a second chip
  there was a shipped bug, 2026-08-06). No key rail at all (visionOS)
  means the rail owns the chip outright.
  MERGE rides the wide row beside DETACH (the overflow carries it only
  when it displaces the direct actions).
  ⚠ The clearances are the RAIL's (`umdSafeArea`), never a pane's
  (`contentSafeArea`): the leading inset reaching
  `TerminalPaneConfiguration` shoves the terminal and key rail off their
  own window (shipped-and-caught, 2026-08-04; `paneAndRailInsetsForTesting`
  pins them apart). `umdAvailableWidth` must likewise stay non-nil or the
  rail never chooses its compact row. There is still NO way to touch the
  Mac's own title bar from a Designed-for-iPad binary (`UITitlebar` is
  Mac Catalyst-only and absent from the iOS SDK).

- **A physical keyboard or software-keyboard lock exposes app-owned
  dictation** (`HardwareKeyboardMonitor`, `DictationSession`,
  `DictationStream`/`DictationText` pure + tested; the pane's
  `DictationBar`). Hardware detection is `GCKeyboard.coalesced` + its
  notifications — UIKit cannot answer it (keyboard-frame notifications
  describe only the software keyboard). iOS exposes no way to trigger
  system dictation, so the app runs recognition itself (Speech +
  AVAudioEngine), requesting on-device recognition wherever the locale
  supports it — terminal input must not leave the device outside the
  user's own SSH connection. Invariants:
  - **Nothing typed is ever retracted** — a byte handed to
    `TerminalView.send` has left the app, and backspaces would aim at a
    remote composer this app cannot see. Words type as they settle:
    `DictationStream` never commits the newest `tailHold` (2) words, a
    word must hold its index across `holdUpdates` (2) hypotheses, and ~1 s
    without a hypothesis means settled → `flush()` types the held tail.
  - ⚠ The "already typed" baseline is the typed **text**, never a position
    in the hypothesis (`DictationStream.rebase`): recognizers endpoint
    mid-task and restart their hypothesis shorter, and a positional
    baseline silently swallowed every later word forever (LISTENING, mic
    open, nothing typed — the bug that survived two rounds of fixing the
    Speech API instead). Comparison ignores case/punctuation; a real
    divergence drops the baseline to the agreement point. Worst case is a
    visible duplicate word. `testANewUtteranceInTheSameSegmentKeepsTyping`
    is that bug's shape.
  - Two engines, choice logged as `engine=analyzer|sfspeech`. iOS 26's
    `SpeechAnalyzer` + `DictationTranscriber` is the point: one analyzer
    per take, no rolling, results marked volatile/final by the recognizer
    (the stream's hold rules go unused — `absorb`/`endSegment` only).
    Quiet flush asks the analyzer to `finalize`; STOP is
    `finalizeAndFinishThroughEndOfInput`; `AnalyzerFeed` re-derives its
    format converter on route changes. The analyzer is on **probation**:
    no result within 10 s → fall back to `SFSpeechRecognizer` mid-flight
    (nothing typed yet, so it costs nothing); a missing dictation model
    falls back too and requests the model in the background.
  - **The language is pickable from the LISTENING bar**: a globe chip
    ("EN·US") opens a native `UIMenu` (checkmark rows — deliberately NOT a
    TALLY panel; a hand-built popover fought iOS 26's corner curves and
    was replaced) listing `Locale.preferredLanguages` kept where the
    recognizer supports them (`DictationLanguages` pure + tested —
    identifiers match on *maximal* language forms, bridging Settings'
    "zh-Hant-TW" to Speech's "zh-TW", with a region-stripping fallback
    because a real device tags EVERY preferred language with the device
    region: "en-TW" must land on en-US, not vanish). The pick is app-wide
    (`DictationLanguageSetting`, UserDefaults; `choices()` memoized on the
    preferred-language list — the bar re-renders per hypothesis), rides
    `DictationSession.start(locale:)` into both engines, and a mid-take
    pick RESTARTS the take in the new language (typed words stay; only the
    unsettled queue drops — deliberate: an in-place engine swap walks into
    the born-dead-task trap the restart ladder exists for). Nothing stored
    means the system default; a stale pick falls back rather than lingers.
    One preferred language → no chip and no menu
    (`DictationLanguages.effective`), matching the system keyboard. ⚠ A
    mic long-press was the first entry point and was replaced — nobody
    discovers a hold with no visible affordance; don't rebuild it. The
    chip is provable headlessly (`debug.dictation` + screenshot); the open
    menu is system UI and is not.
  - The `SFSpeechRecognizer` path rolls tasks (one utterance per task, and
    the server-backed path dies after ~a minute). Every roll waits
    `restartDelays` (200 ms → 500 ms/1 s/2 s) — a task created while the
    daemon tears the last one down comes back dead. Only a task that died
    without hearing anything inside 2 s counts toward the cap of six;
    exhausting the cap surfaces the failure bar, never a silent close.
    Each task gets its OWN capture graph (tap removed + engine stopped
    before build) — a reused tap comes back deaf. A route change re-taps
    via an ordinary roll; a task silent for 12 s is replaced
    (`deafSegmentTimeout`). Audio-session deactivation checks that no
    other take has claimed the mic meanwhile.
  - Chunks ride `TerminalView.send` → ordered pump, sanitized to one line
    with no control bytes (`DictationText.words` is the one splitter — no
    CR can ride a chunk) and **never submitted**. LISTENING means the mic
    is open, never merely that the key was pressed. The bar shows the
    queue (heard, not yet typed, drawn dimmer); STOP types it, CANCEL
    abandons it; a starting history jump cancels dictation outright.
    Recognition stops after 30 s of quiet (5 min hard cap — an agent
    prompt's mid-sentence think must not end the take); auto-punctuation
    on. One session holds the mic app-wide (a second tab takes it). Free
    rail plumbing, not an agent-helper surface. ⚠ The simulator always
    reports a hardware keyboard, so screenshot runs capture the mic slot;
    the no-hardware branch needs a real device.
- **Copy Mode is an app-owned interaction state over tmux's remote mode**:
  the shortcut sends stock `Ctrl-B [` through the ordered pump, then the
  controller disables SwiftTerm mouse reporting and enables
  `forceRemoteCursorScroll` (tmux can render in the primary buffer, so
  alternate-screen detection alone is insufficient). Pans continue as
  cursor keys; hold/double-tap selection stays local and copies to the
  device pasteboard. The contextual bar's Done (and keyboard Escape) sends
  Escape through the same path. Always restore mouse reporting when the
  mode ends or the transport closes, or tmux touch interaction silently
  stops. **Select Text is the backend-agnostic sibling**
  (`selectTextModeUIActive`; entered ONLY from the selection block's SELECT /
  SELECT ALL on tmux AND herdr — a shortcut-panel Screen row
  shipped and was removed 2026-08-03, don't re-add one without asking):
  the same tap-ownership flip with NO
  remote mode entered — mouse reporting off so native selection owns
  taps, pans suppressed outright (`suppressRemotePanScroll`, a fork
  patch: with no copy-mode view answering cursor keys, the
  alternate-screen fallback would type arrows into the remote app). DONE
  or Escape exits; the Escape byte is consumed app-side (it must not
  interrupt a running agent) unless tmux copy mode is active too and
  needs it to leave. **Selection is clamped to the TARGET pane**
  (`PaneScreenRect`/`PaneScreenRectEntry`; `SelectionService.clampRect`
  in the fork): entry and every resize run one read-only control exec
  listing EVERY visible pane — tmux `list-panes -F` geometry (content
  cells, no inset), herdr the snapshot's layout rects border-inset by
  the `viewport_rows` oracle — and the target is the pane under the gesture
  that raised the block (the focused pane when no position rides along), so
  drags can't bleed across a split, Select All means the pane
  (not herdr's sidebar/tab bar), and extraction joins per-pane-row
  slices with newlines instead of splicing neighbor-pane bytes. **The
  backend's focus follows a pressed non-focused pane** — the switch a
  click would have made: tmux `select-pane` by `%id`; herdr's only
  focus verb is directional (0.7.5 has no focus-by-id), so ONE step
  fires and only in a two-pane layout, where a single step is exact.
  Clamp rows are SCREEN-relative (converted through `yDisp` per
  operation); a failed fetch falls back to whole-screen, and a clamp
  arriving after a Select All *re-clamps* the live selection
  (`reclampActiveSelection`), never drops it. **In this mode the app
  owns ALL selection chrome in ONE floating block**
  (`TerminalView.selectionUIHandler`, a fork patch;
  `TerminalSelectionActionsOverlay`, a TerminalView subview — the link
  hover overlay's pattern): the deprecated UIMenuController never
  shows, a plain tap or long press seeds a word selection directly (no
  PASTE/SELECT detour; links wait until the mode ends), and every
  selection change reports its screen box so the block — SELECT TEXT
  lamp, COPY (hidden without a selection), SELECT ALL, DONE — floats
  beside the selection, parking top-center without one so the mode and
  its exit stay visible; there is deliberately NO separate top-center
  HUD. COPY rides the fork's `copy(_:)` (pasteboard + clear) and then
  ENDS the mode — the grab is what the mode was entered for; SELECT
  ALL rides the clamped `selectAll`. Detach restores the stock flow and
  clears the selection. **Outside the mode, a long press or touch double-tap
  raises the app's own SELECT / SELECT ALL / PASTE block**
  (`selectionMenuHandler` + `TerminalSelectionMenuOverlay`, every live pane)
  in UIMenuController's place. Long press resolves links/paths first; double
  tap goes straight to selection. SELECT / SELECT ALL enter the mode (seeded
  at the gesture's word / the whole pane — a Select All taken before the
  async pane rect lands is *re-clamped*, never dropped); PASTE types the
  pasteboard as ever; a tap dismisses-and-consumes, the native menu's
  contract (`appMenuDismiss`). A pointer's secondary click runs the SAME
  local chain (`presentLocalPressActions`, shared by the long press and a tap
  recognizer pinned to
  `allowedTouchTypes = [.indirectPointer]` +
  `buttonMaskRequired = .secondary` — the mask alone does NOT filter
  direct finger taps, verified on device). Designed-for-iPad adds a physical
  `GCMouse.rightButton` HID fallback aimed by the terminal's last
  `UIPointerInteraction` location; a 200 ms gate deduplicates mice that reach
  both roads. Thus either road resolves a link/path into its confirmation
  sheet first, else the block — deliberately never a remote button-2 report,
  or links would be pointer-unreachable under mouse tracking (the MENU chip
  below is the explicit road to a TUI's right-click surface). Mac synthetic
  clicks exercise the UIKit road; no headless route can drive the GCMouse
  hardware callback or an iPad pointer. On herdr tabs the block adds
  MENU — one right-button press+release reported at the pressed cell
  (`sendRemoteRightClick`; `Terminal.sendButtonReleaseEvent` names the
  true button in SGR release, which the stock path masks to a *left* up)
  so herdr's own pane menu, unreachable by touch, opens where the finger
  was. herdr-only on purpose: tmux's right-click menu would fight the
  shortcut panel and the block itself. Selection covers the
  visible screen only (herdr's scrollback lives host-side) and nothing
  freezes — a busy pane keeps drawing under the selection.
- **"Back to deck" reuses the one deck scene**: `UIKitSceneRouting`
  resolves DECK to `.activateExisting` whenever a deck session exists
  (legacy and native restoration activities both decode); `DeckScene`
  destroys a second session. Raising can never resize (an activation
  request cannot carry geometry); only scene *creation*
  (`sceneRequestsInitialGeometry`) runs `configureGeometry` — DEBUG env →
  `SceneWindowSizeStore` remembered size → authored default. That ordering
  preserves `.defaultSize`'s advisory semantics (an imperative
  `requestGeometryUpdate` per create snapped user-resized windows back).
  Symmetrically, a deck tile press focuses the already-attached window
  (`TerminalWorkspace.focusTab` → `WindowEntry.reveal` → `revealWindow()`,
  which raises the scene explicitly); long-press "Attach in New Window"
  stays the duplicate-client path.
- **Tabs move between windows without dropping the shell**: a terminal
  window's scene value (`TerminalWindowRoute`) *is* its tab list —
  merge/split mutate the window-value binding, never close-and-reopen.
  Controllers strongly own their `TerminalView`; `SwiftTermView`
  re-parents it when a tab lands in a new window (buffer + scrollback
  survive). An emptied window dismisses via plain `dismiss()` — not
  `dismissWindow(id:value:)`, whose lagging committed-value matching
  leaves ghost windows. `onDisappear` closes remaining tabs, so a merge
  empties the source first and never detaches moved tabs.
- **Input is one ordered AsyncStream pump per shell**, not a Task per
  keystroke (which could reorder bytes). Citadel already sets
  `TCP_NODELAY`.
- **iPad keyboard clearance has exactly one owner** — `SwiftTermView`'s
  keyboard-frame handler, gated by the pure `KeyboardAvoidance.isDocked`.
  The terminal window opts out of SwiftUI's avoidance
  (`.ignoresSafeArea(.keyboard)` in `TerminalWindow`) — SwiftUI reserves
  space for *floating* keyboards and goes stale across dock/float; don't
  remove the opt-out or re-add a second responder. The handler
  re-measures on didChangeFrame, container layout, and a settle delay;
  only bottom-pinned, window-spanning frames inset. Zero-height end
  frames are deliberately no-ops (the app-owned rail already occupies
  real layout space) — never infer rail geometry from keyboard
  notifications. The container backfills the strip a docked keyboard
  covers with `Theme.bezel` (iOS 26's translucent keyboard samples
  what's behind it; a light theme read as a washed-white keyboard) —
  don't let the terminal theme extend under a docked keyboard. The
  helper strip pads itself by the published
  `TerminalSessionController.keyboardObstruction` (measured against the
  *window*, so it never feeds back); while nonzero the pane ignores the
  bottom container safe area (else the corner inset double-counts and
  clips tmux's status row) — keep that opt-out conditional. The
  interactive rail stays inside the rounded-corner boundary; the passive
  bezel paint runs through it. SwiftTerm's fractional row remainder
  moves into the top gutter for tmux routes (remainder-derived, one
  pixel of safety — an unconditional inset can drop a row). Stage
  Manager spams didChangeFrame during moves: classify presentation
  before touching layout, coalesce docked settle remeasures, and require
  a real docked keyboard to span the screen (short shortcut frames
  classify only, never produce clearance).
- **Host secrets never use `isSecureTextEntry`** (`MaskedSecretField` in
  `AddHostSheet.swift`): iOS hard-wires the Passwords QuickType chip and
  save prompt to secure entry — every `textContentType` opt-out is
  ignored, and one secure field drags the sheet's OTHER fields into
  login-form treatment (an SSH secret must never be offered to
  Passwords). Bullets are drawn app-side; the real string lives only in
  the binding; copy/cut/select refused while masked. The sheet clears
  all secret state before dismissal, and the key-unlock alert (which can
  only host a system `SecureField`) empties its field in every button
  action. Don't regress any of these.

## Known limit: held-backspace input filler

- **Held-backspace auto-repeat rides an input filler and is NOT verified**
  (`inputFillerLength`/`inputFillerCharacter`, `seedInputFillerIfNeeded`/
  `clearInputFiller`). iOS reads the `UITextInput` document's real
  characters to accelerate a held delete into word-wise deletion, and
  `textInputStorage` is empty for text the remote echoed — the repeat
  starved (`hasText` = true and `inputDelegate` reporting were tried
  first; neither moved it). The buffer is stocked with filler when it
  holds nothing real; each consumed filler char becomes one backspace
  byte. Invariant: **filler exists only while there is no real text** —
  `commitTextInput`, `setMarkedText`, and `replace` clear it before
  reading the buffer (keeps it away from word-wise over-counting,
  auto-period, and Korean resyllabification; filler deletions can't open
  a resyllabification transaction). Restocking happens *after*
  `endTextInputEdit` so the keyboard sees the shortened document.
  Geometry is unaffected (caret answers from the terminal caret). ⚠ No
  headless route can drive a held software key, so this shipped on
  device testing alone; if IME regresses, suspect a mutation path that
  reads the buffer without clearing filler first. Both constants are
  tuning knobs.
