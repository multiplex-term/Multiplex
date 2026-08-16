# End-to-end verification (headless, no real remote needed)

`Tools/dev-sshd/harness.sh` runs a user-mode sshd on `127.0.0.1:2222` (own
keys under `Tools/dev-sshd/state/`, never touches `~/.ssh`):

```sh
./Tools/dev-sshd/harness.sh start   # keys + sshd + writes state/seed.json
./Tools/dev-sshd/harness.sh demo    # tmux sessions: main, scratch, deploy, agent
./Tools/dev-sshd/harness.sh stop
```

The `agent` session fakes CLI agents: window `cc` sets the `✳ Claude Code`
OSC title, `cx` runs `exec -a codex cat`, `pi` sets `π - harness` + `exec -a
pi cat`; all run `cat`, so `tmux capture-pane -t agent:0 -p` shows what a
chip typed.

**DEBUG-only env vars** (the simulator shares the Mac's network; pass with
the `SIMCTL_CHILD_` prefix through `xcrun simctl launch <UDID>
app.multiplexterm.multiplex`):

- `MULTIPLEX_SEED_HOST=<path to seed.json>` — imports a ready `devbox` host
  (idempotent, stable UUID). ⚠ Idempotence is per install: `simctl uninstall`
  wipes hosts.json but NOT the Keychain mirror, so the next launch seeds a
  new devbox AND re-adopts the old record (two identically named hosts).
  Prefer terminate + relaunch over reinstall. Optional seed keys:
  `workingDirs` / `sessionScripts` / `newSessionTmuxConf` /
  `agentLaunchModels` feed the picker/script/conf/model paths;
  `secondaryBackends: ["herdr"]` imports a MIXED host (two probes on one
  connection, both backends' tiles); `passphrase`
  stores the key passphrase in the Keychain so an encrypted `privateKey`
  proves the sealed-key connect path (probe logs `Accepted publickey`, no
  prompt); `"enabled": false` proves the never-dials promise against a
  silent `state/sshd.log`; `"backgroundKeepAlive": true` starts the host
  opted into background keep-alive (nothing can tap that switch headlessly).
- `MULTIPLEX_AUTO_ATTACH=main,scratch` — opens a terminal per entry via the
  real Attach route; `+` inside an entry groups sessions as tabs of one
  window. Fires once per process. `MULTIPLEX_AUTO_ATTACH_HOST=devbox` names
  the host — without it the first host wins (on a device with synced real
  hosts that is NOT the seed).
- `MULTIPLEX_AUTO_TMUX_COPY=1` — sends Copy Mode after attach; proof:
  `#{pane_in_mode}` becomes 1.
- `MULTIPLEX_AUTO_TMUX_CLOSE=pane|window` — runs the confirmed close action
  through the direct SSH control path. Disposable sessions only; verify
  host-side.
- `MULTIPLEX_AUTO_MERGE=1` — merges every terminal window into the first
  through the real surrender/adopt path (moved tabs keep connections).
- `MULTIPLEX_AUTO_DROP=<local path>` — drops that file into the first tab
  (SFTP upload + typed path, the real drag path).
- `MULTIPLEX_AUTO_ACTION_URL=multiplex://open?…` — submits the URL through
  the exact `onOpenURL` → router seam once per process; the headless widget
  stand-in (simctl openurl's first-run confirmation can't be clicked
  headlessly, and idb HID taps died with Xcode 27).
- `MULTIPLEX_AUTO_BIND=<multiplex://b/…>` / `MULTIPLEX_BIND_AUTOPIN=<6
  digits>` — drive Bind Host headlessly: submit a payload through the real
  parse → confirm → handshake seam / answer the first machine heard with
  that PIN. Stage the other side with `harness.sh bind` (prints the PIN) or
  `bind --print-only` (prints the payload URL; transcript in
  `state/bind.log`). Proof is host-side: a `multiplex:bind:<id>:<device>`
  line in `state/authorized_keys`, then `Accepted publickey` in `sshd.log`.
  `MULTIPLEX_BIND_PASSPHRASE=<text>` presets KEY PASSPHRASE so a headless
  bind stores its key sealed; `MULTIPLEX_BIND_BACKEND=<comma list>` presets
  the pane's Backend selection, so the minted host record carries it (proof:
  the deck tile probes herdr, not tmux). The FIRST entry is the default that
  mints, and every entry is shown — `herdr` is the old single-backend
  meaning unchanged, `tmux,herdr` binds a MIXED host straight from the pane.
  ⚠ These are `DeckWindow` tasks — a restored
  terminal-only scene never runs them; `simctl uninstall` + `simctl
  keychain <udid> reset` first (or the mirror re-adopts the old host and
  the free host limit blocks the bind).
- `MULTIPLEX_AUTO_ADD_HOST=bind|manual` — opens Add Host on either road for
  layout capture (deliberately bypasses the free-tier add gate).
- `MULTIPLEX_PRO_LOCKED=1` — free-tier mode, never persisted; with
  `MULTIPLEX_AUTO_ATTACH=agent` + the `debug.agentchip` hook it proves
  exactly ten slash-chip sends.
- `MULTIPLEX_DECK_SIZE=<w>x<h>` / `MULTIPLEX_TERM_SIZE=<w>x<h>` (visionOS) —
  scene default window sizes for screenshot runs (the sim can't drag-resize).
- `MULTIPLEX_AUTO_PAYWALL=1` — the real locked paywall with a deterministic
  $19.99 storefront preview (simctl launches don't inherit Xcode's StoreKit
  session).
- `MULTIPLEX_AUTO_SETTINGS=1|theme|licenses` / `MULTIPLEX_AUTO_FAQ=1` — open
  those sheets for headless capture (`theme` pushes the theme editor,
  `licenses` the Open Source Licenses page).
- `MULTIPLEX_AUTO_WHATS_NEW=1|log` — open the release-notes launch card /
  the full record behind its FULL NOTES chip. The launch gate itself is
  unreachable headlessly (it fires only for an install carrying a PREVIOUS
  version's defaults), so this is the layout road; the gate is pinned by
  `DeckWindowUIKitTests` instead. ⚠ Both screens are `DeckWindow`
  presentations — a restored terminal-only scene shows nothing — and the
  notification-permission alert iOS raises on a fresh install sits over the
  middle of the sheet with no headless way to dismiss it.
- `MULTIPLEX_AUTO_HOST_SETTINGS=1|models|backend|directories` — opens the
  first host's edit sheet (regression-checks the Observation environment
  across the sheet boundary — a missing HostStore is a fatal error);
  `models` scrolls to the Agent launch models section, `backend` to the
  tmux/herdr Backend section, `directories` to the New session defaults
  working-directories editor (shown for BOTH backends — the herdr mint
  roots a session's world with these; only the tmux options editor stays
  tmux-scoped).
- `MULTIPLEX_KEYCHAIN_TIP=locked|unlocked|missing` — forces the keychain
  verdict. The sign-in-screen gate still applies: inject a needle first
  (e.g. `tmux send-keys -t agent:cc 'Select login method:' Enter`).
- `MULTIPLEX_APP_LOCK=1|held` — start behind the app-lock veil (never
  persisted). `1` keeps the real authenticator; `held` refuses every
  attempt so the veil can be captured. Shipping toggle: Settings → App lock
  (`AppLockStore`).
- `MULTIPLEX_FORCE_SHELL=1|0` — force the single-window shell on/off.
  Default: iPhone always shell, iPad only when `UIWindowScene.isFullScreen`,
  visionOS never. Logged under category `shell`.

**iOS 27 scene/screenshot notes:** a first-ever install can connect an empty
scene (uninstall from that sim, then install + launch once more); a freshly
booted sim takes 10–15 s to paint (wait ≥12 s before an iPhone screenshot).
Keep the `UIApplicationSceneManifest~iphone` single-scene override (iOS 27
can composite a second scene on the phone panel). Device Hub resize mode can
lie to `simctl io screenshot` — capture on a native-canvas device.

**iOS-app-on-Mac** ("Designed for iPad"): same hooks, two twists. The app is
sandboxed — `MULTIPLEX_SEED_HOST` must point inside the app container
(`~/Library/Containers/<UUID>/Data/tmp/…`, UUID via `MCMMetadataIdentifier`;
a repo path is silently unreadable). No simctl — `launchctl setenv` /
`unsetenv` the vars (GUI launches inherit launchd's environment). Use
`MULTIPLEX_AUTO_ATTACH_HOST=devbox` (real synced hosts exist on a Mac).
Synthetic events (System Events) never reach a *simulator* but DO reach the
Mac app — how the Mac keyboard paths were verified headlessly.

Drive a live session from the Mac side: `tmux send-keys -t main:2 'echo hi'
Enter`.

**mosh path**: seed with `state/seed-mosh.json` (same host/UUID, `useMosh:
true`; `seed-mosh-v6.json` for IPv6). SSH is used only to launch
`mosh-server` (`brew install mosh`; the bootstrap prepends the usual
Homebrew/local dirs); everything downstream is identical to SSH.
`./Tools/build.sh interop` also checks the clean-room stack against the real
binary as a standalone macOS executable (deliberately outside
`MultiplexTests`: the app target has no macOS destination and `Process` is
unavailable in sim tests).

**herdr path**: `./harness.sh herdr` seeds three real lifecycle fixtures
(`brew install herdr`); use `state/seed-herdr.json`. `stop` removes only them.

Simulator caveat: Xcode 27's DeviceHub always bridges the Mac keyboard as
*hardware*, so the software keyboard never auto-shows (Device → Keyboard →
Toggle Software Keyboard).

**DEBUG notification hooks** — `xcrun simctl spawn <UDID> notifyutil -p
app.multiplexterm.multiplex.<name>`:

- `debug.summon` / `debug.dismiss` — press "Show keyboard" / resign the
  focused terminal.
- `debug.hostenable` — toggle the FIRST host's deck switch through
  `HostStore.setEnabled` (watch `sshd.log` go silent and come back).
- `debug.bgrefresh` — run the `BGAppRefreshTask` work path (probe every
  opted-in host under a refresh grant window) without the scheduler, which
  the simulator does not provide. The app must be RUNNING to receive it —
  a suspended process never gets the notify.
- `debug.backendoffer` — accept (or withdraw) the rail's backend offer for
  the FIRST host, through the same store write the chip's confirmation and
  Host Settings both perform. No headless tap route exists for the chip.
- `debug.hostkeepalive` — toggle the FIRST host's background keep-alive
  through the same record write the Host Settings row performs. Then
  background the app (`xcrun simctl launch <udid> com.apple.mobilesafari`)
  and watch the `background` log category: ON logs a hold begun/ended pair
  and `sshd.log` keeps taking exec probes for the whole grant; OFF logs
  nothing and the probes stop at once.
- `debug.appearance` — cycle SYSTEM → LIGHT → DARK → GLASS on visionOS
  (the first three elsewhere) through `ThemeStore.appearance` (persisted,
  flips every window live; pair with `simctl ui <UDID> appearance` to prove
  SYSTEM).
- `debug.connstats` — open the Connection Stats board through the deck's
  own request path, gates included (DEBUG entitlements fail open, so the
  Pro gate passes). The rail chip needs no hook — it renders whenever a
  probed host has a round-trip on record.
- `debug.agentchip` — tap the first slash chip (inject → pump → PTY → tmux).
- `debug.newtab` — run the focused window's "+ TAB" leading New Session
  action (mints a session on either backend, attached as a new tab).
  `debug.herdrtab` — the herdr-only New Tab in Workspace entry; proof is
  host-side: `herdr --session <name> api snapshot` gains a tab in the
  focused workspace, no session is minted, and no Multiplex tab appears.
- `debug.tmuxshortcuts` / `debug.customcommands` / `debug.msghistory` — open
  the focused tab's shortcut popover (TMUX content, or HRDR on a herdr
  tab) / Command Setup editor / agent HISTORY panel for layout capture.
- `debug.keycommands` / `debug.keycommandsetup` / `debug.keycommandcompose` —
  the hold-CTRL KEY COMMANDS popover (iPad rail or visionOS cluster) on its
  COMMANDS grid / CUSTOM SETUP list / with a fresh row's composer expanded.
  A panel already up just switches, so one run can capture all three.
- `debug.guide` — open the focused terminal's GUIDE field manual for layout capture.
- `debug.link` — activate the first visible link through the resolve →
  policy → confirmation path (URL → link sheet, path → file-viewer sheet;
  text both resolvers decline must present nothing). `debug.linkopen` runs
  OPEN; `debug.viewportopen` runs the sheet's ⌗ VIEWPORT chip;
  `debug.linkregions` logs the visionOS gaze-region inventory (category
  `links`, debug level).
- `debug.msgjump` / `debug.msgjumpback` — jump the focused Claude terminal
  to its oldest prompt / BACK TO LIVE; prove both with host-side
  capture-pane.
- `debug.tmuxcopy` / `debug.tmuxcopydone` — Copy Mode and the HUD's Done,
  through the ordered pump.
- `debug.selecttext` / `debug.selecttextdone` / `debug.selecttextall` /
  `debug.longpressmenu` (the idle SELECT/SELECT ALL/PASTE block at screen
  center, through the shared long-press/double-tap entry point) — the
  app-owned Select Text mode, its Done, and Select All (both
  backends; app-local, so proof is the SELECT TEXT HUD, the pane-clamped
  highlight with the floating COPY/SELECT ALL bar after `selecttextall`,
  and a tap that no longer reaches the remote — with tmux `mouse on`,
  `#{pane_in_mode}` stays 0 under a pan).
- `debug.herdrmenu` — one right-click report at screen center (the block's
  MENU chip path); proof is herdr's own pane menu rendering in the pane.
- `debug.tmuxclosepane` / `debug.tmuxclosewindow` — the already-confirmed
  destructive close actions (disposable sessions only).
- `debug.keybar` — iPad key-bar proof: a shell prompt capture shows `~|/-^C`.
- `debug.kbdlock` — toggle the software-keyboard lock headlessly.
- `debug.fvselect` — the file viewer's markdown SELECT mode.
- `debug.fvimage` — press the first image placeholder on the rendered
  markdown screen (destination → resolve → open, the finger's own path).
- `debug.fvplay` — press PLAY/PAUSE on the active viewer's sound screen;
  proof is the PLAYING lamp and a moving clock. Reach the screen via
  `debug.link` + `debug.pathview` on a printed `.wav` path, or launch with
  `MULTIPLEX_AUTO_ACTION_URL='multiplex://open?host=devbox&action=file&path=/abs/x.wav'`
  (works for `.pdf` too; the load can trail launch by ~25 s on a sim with
  hundreds of synced hosts).
- `debug.dictation` — press the dictation action. Grant mic with `simctl
  privacy <UDID> grant microphone …`; speech recognition has no simctl
  service — with the device SHUT DOWN insert `kTCCServiceSpeechRecognition`
  into the sim's `TCC.db`. ⚠ The simulator cannot transcribe at all (broken
  Siri asset; `SFSpeechRecognizer` fails within ~20 ms, verified
  2026-07-31), so the hook proves the whole app-side path — permissions,
  audio session, engine + tap, rolling, restart cap, failure bar, nothing
  typed — while words landing in a pane need a real device. Logged under
  category `dictation` (debug level — `log stream`, not `log show`).
  The LISTENING bar's language chip (globe + "EN·US") appears only with
  ≥2 preferred languages the recognizer supports — seed them BEFORE boot
  (a booted-sim switch rots iCloud state), e.g. `plutil -replace
  AppleLanguages` in the sim's `.GlobalPreferences.plist`. The chip's
  menu is a native `UIMenu`: no headless press exists, so proofs stop at
  the chip's presence in the screenshot.
- `keycluster` — visionOS ornament key-cluster proof: a raw-mode `dd bs=1
  count=3 | od -c` in the pane reads `033 \t 003`.
- `debug.scrollup` / `debug.scrolldown` — one remote scroll tick (wheel
  report under mouse tracking, alternate-screen cursor key otherwise); with
  tmux `mouse on` a scrollup flips `#{pane_in_mode}` to 1.
- `debug.kbd.float` / `….kbd.move` / `….kbd.dock` / `….kbd.hide` (iPad) —
  synthetic keyboard-frame notifications to exercise keyboard avoidance;
  decisions log under category `kbd` (debug level).
