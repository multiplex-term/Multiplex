# CLI-agent detection, helpers & history

Load-bearing decisions split from AGENTS.md — read before touching
AgentSignature, helper chips, launch model overrides, the keychain tip, or
HISTORY/jump.

- **An agent launch's model override is one verified flag, picked from
  host-configured lists, fail-soft**
  (`AgentKind.launchCommand(model:initialPrompt:)` +
  `normalizedLaunchModel`, pure + tested): every supported CLI spells it
  `--model <value>` (verified 2026-07-27: Claude Code 2.1.220, Codex rust
  0.145.0, Pi 0.81.1). Values are NOT app-curated (names churn faster
  than releases); full ids are typed once into `Host.agentLaunchModels`
  (keyed by agent rawValue, host-scoped — Pi's models genuinely differ
  per machine) and every surface offers them as a picker with free text
  as escape hatch. The normalizer enforces argv-token shape only (no
  whitespace/controls, no leading `-`, ≤64 chars); rejection means "agent
  default", never an error; UNKNOWN agent keys are preserved verbatim
  across edit-saves. The composed value is always shell-quoted (Claude's
  `sonnet[1m]` would glob in zsh). Surfaces: New Session sheet (REMEMBER
  per agent, device-local; + TAB agent variants inherit it), the Open
  Agent Shortcut (String, for variables), the Host widget's Model setting
  (lists ride the App Group projection as names; `&model=` validated
  app-side), and the ASK prompt sheet. Both option providers lead with an
  "Agent Default" row and are NEVER empty (a zero-item options query
  makes the widget-config picker open and immediately dismiss). Synced
  record, zeroed from `connectionModelConfiguration`; external actions
  never inherit the remembered model.
- **Agent detection is multi-signal and fail-soft** (`AgentSignature`, fed
  by the probe's P lines + `MULTIPLEX_PS` ps table):
  `pane_current_command` → pane title (`✳ Claude Code`; `π - …` while
  Pi's node wrapper owns the pane — Pi leaves it stale on exit) →
  bare-semver comm (macOS native Claude launcher) → ps-tree walk from
  `pane_pid` matching **argv[0] basename only** (never substring — Claude
  Desktop helpers false-positive; catches npm Codex/Pi wrappers). The 5 s
  probe retains every pane, reuses its one `list-panes` result to root
  ONE subtree-clipped host-wide ps snapshot; FleetWall aggregates split
  panes, helper chips follow only the active pane. Between full probes
  only `TerminalFocusArbiter.current` runs a 1 s focused check: tmux uses
  current-window `list-panes` (with a cached single-TTY ps fallback for
  ambiguous wrappers), while herdr's small `pane current` response names
  the globally focused pane and its canonical agent definitively. A tick
  is skipped while that terminal saw a keystroke within ~1.5 s
  (`TerminalView.hasRecentUserInput`, reading the fork's send-path stamp
  — the pane under the fingers isn't changing, and detection must not
  compete with input handling; chips settle a beat after typing stops,
  and mid-burst the shown chip is left alone rather than dropped to the
  wall verdict). Settled full probes coalesce for 4 s. Plain `.shell` tabs use their own
  PTY authority (`ShellAgentProbe`: exec channel's `$PPID` → sibling PTY
  under sshd → foreground pgid/tpgid only, so a suspended background
  agent leaves no helpers); title/visible-screen signatures are a narrow
  fallback for direct mosh shells or ps-less hosts; Pi's stale title is
  never trusted without the process probe. A direct shell alerts in its
  UMD rail keyed by tab UUID. Any failing stage disables that signal
  only, never the session list. Helper chips only *type* through
  `TerminalSessionController.sendInput` (Enter = CR, Shift+Tab = CSI Z,
  Codex TRANSCRIPT = Ctrl+T, Pi THINK/TOOLS/THINKING = Shift+Tab/Ctrl+O/Ctrl+T;
  Claude PG UP/DN chips are visionOS-only); **never ship a Ctrl+B payload** —
  it's the remote tmux prefix — and **no chip types a bare Escape**: the STOP
  chip did and was withdrawn 2026-08-05 (Escape interrupts a running turn, and
  every platform already carries a real ESC key beside the terminal — the
  iPad/iPhone key rail, visionOS's ornament cluster). Pinned by
  `testNoBuiltInChipTypesABareEscape`. The
  strip and agent alerts (`AttentionCenter`) are Pro-gated; detection and
  wall telemetry stay free. Pi's attention stays fail-soft idle — no
  RUNNING/turn-end claims without a separate reliable signal. **Grok
  Build** (added 2026-08-16 from the xai-org/grok-build *source*, not a
  live process — verify on a real host before tightening anything):
  binary `xai-grok-pager`, shipped as `grok`; the installer symlinks
  `~/.grok/bin/grok → downloads/grok-<semver>-<os>-<arch>`, so the pane's
  comm is the clipped target (`grok-1.0.4-maco` seen live on macOS 27)
  while argv[0] stays `grok` — `classify(command:)` accepts `grok`,
  `xai-grok-pager`, and `grok-<n>.<n>…`; Rust, no interpreter wrapper; `grok --model <id> "prompt"`
  is the documented interactive shape (top-level `-m/--model`, positional
  prompt); Shift+Tab cycles Normal → Plan → Always-approve (so MODE fits),
  Ctrl+T toggles the todos pane (TODOS chip), and its own **Ctrl+B means
  "background this command"** — one more reason no chip may carry the
  tmux prefix. Its OSC title is composed by `TitleManager` (default items:
  `⚠ Action Required`, Braille spinner, activity verb, session name,
  `grok`, joined by ` - `) and **resets to a bare `grok` on exit** — so
  the direct-shell fallback matches only the ` - grok` suffix, and no
  tmux title rule exists (the process signal is enough). Attention has its
  **own classifier** (`AgentAttention.classifyGrok`): `⚠ Action Required`
  anywhere in the title = permission (its `permission_queue` is non-empty;
  the spinner keeps running behind it, so ⚠ outranks it), any Braille
  scalar anywhere = busy (title items are user-orderable — never key on
  position), and a question card is read from the tail as ≥2 option rows
  shaped `<1-9|a-f> (○|●) label` / `<n> [ ]|[x] label` (an
  `ask_user_question` does not touch the title). Trap: the ⚠ item *blinks*
  (~500 ms on/off) once Grok has seen a terminal focus-out — its
  `FocusTracker` starts focused and tmux ships `focus-events off`, so over
  a Multiplex attach it holds still; a host with `focus-events on` could
  re-fire the permission alert on alternate probes. Busy/idle titles and
  the turn-ended alert were **verified live** (grok 1.0.4 in tmux on this
  Mac, sim build, 2026-08-16: `⠋ - Sleep for 20 seconds… - <session> - grok`
  → `<session> - grok` → `alert posted for grok`); the ⚠ permission title
  and the question card are still source-derived — first live capture that
  disagrees wins (sim proof recipe: `e2e-headless.md`, attention). herdr's canonical id for it is assumed to be `grok`. Unknown-agent profiles in a synced Host record are now skipped
  on decode instead of failing the record — from this build on, a device
  that predates a newly added CLI keeps the host (older builds still drop
  the whole record; that ship has sailed). **Slash
  chips submit with a CR sent ~160 ms after the text** (separate write —
  Codex treats a same-burst Enter as a pasted newline; verified
  rust-v0.144; Claude/Pi accept the shape). Bar/More choices persist per
  host + agent as deviations from the curated defaults (stale overrides
  discarded). Custom commands share UUIDs across a host's agent profiles
  (`shared`); part of the Codable Host record (`updatedAt` bump, Keychain
  sync). Custom taps use the daily meter, ordered pump, optional delayed
  CR; labels keep 9 chars + `...`; the editor strips terminal controls
  incl. Ctrl-B, and its rows must bind by command UUID —
  `ForEach($commands)` index capture crashes on delete/reorder under a
  late text write. Research: `local-plan/agent-harness-helpers.md`.
  **Command Setup uses the UIKit-hosted, content-sized iPad popover
  boundary** (like tmux shortcuts): `preferredContentSize` from
  `sizeThatFits`, hosting `sizingOptions = .preferredContentSize` (so
  ADD/DELETE live-resizes), `safeAreaRegions = .container`, adaptive
  sheet disabled — a plain SwiftUI `.popover` grows a blank tail beside a
  floating keyboard, and a one-shot size clips after edits; padding or
  `.fixedSize` fix neither. visionOS keeps its native popover. One
  vertical scroll owner sized from measured rendered height; never
  restore a command-count multiplier (multiline rows have no stable
  height).
- **The deck's KEYCHAIN LOCKED tip mirrors Claude Code's own credential
  read** (`KeychainLockCheck`, pure + tested): an SSH-reached Mac never
  unlocks its login keychain, so Claude Code starts signed out there.
  Only when a probe sees a Claude pane parked on a sign-in screen
  (phrase-exact needles, verified v2.1.218; "API Usage Billing" is
  deliberately NOT a needle — signed-in Console users show it) AND that
  pane's detected agent is Claude does the model run one `security` exec
  on the probe connection. **LOCKED is decided structurally, never by
  error text** — on macOS 27 a locked keychain's
  `find-generic-password -w` fails *silently* over SSH (exit 128, empty
  stderr): data readable → unlocked; item findable but data unreadable →
  LOCKED; only "could not be found" is string-matched. Every stdout is
  discarded host-side (`-w`'s stdout is the secret) — only `MPX_KEYCHAIN`
  sentinels cross the wire; a `uname` gate answers NA once per connection
  on non-Macs. Only LOCKED lights the tip (MISSING is a genuine first
  login). Two surfaces: the deck rail and the affected tabs' terminal
  chrome (UMD cluster / rail lamp). Clears the moment the
  screen moves on; 60 s TTL re-confirm while the symptom persists.
  Verdicts log under category `wall` (debug). `security unlock-keychain`
  advice re-verified on macOS 27 (the registered login keychain persists
  unlock across processes). Copy is shared through `HostGuide` (deck
  sheets, NO TMUX dialog, FAQ) so surfaces can't drift.
- **HISTORY reads Claude Code's own session file; jump walks Claude's
  pager with the header oracle** (`AgentSessionHistory`, pure +
  fixture-tested; Pro via `canBrowseAgentHistory`). **Claude Code only**
  — Codex/Pi history was withdrawn 2026-07-16; don't re-add a lesser
  variant. **Both backends** (E2E-verified on herdr 0.7.5, 2026-08-03):
  the walk's four touchpoints are backend-parameterized (`JumpTarget`:
  capture / key send / literal send / prologue), everything else —
  oracle, needles, twin counting, restore discipline — is shared. herdr
  specifics: context cwd from one `api snapshot` (the drop path's
  parser) and the registry walk rooted at `pane process-info
  --current`'s `shell_pid` (the `pane_pid` analog; both work clientless,
  unlike `pane current`, which the jump prologue may use because a live
  tab IS an attached client); captures via `pane read --source visible
  --format text`; 0.7.5's `send-keys` has no page/end names, so keys go
  as RAW escape bytes (`\e[5~`/`\e[6~`/`\e[1;5F`) each in ONE
  `send-text` write — a split ESC would read as bare Escape and can
  interrupt a turn; the prologue title must be raw `terminal_title`
  (the stripped variant removes exactly the spinner/✳ glyphs the idle
  classifier reads); pane width is measured from the capture's widest
  row (no column oracle exists); header clicks and the client-size
  census stay off (no mouse-flag or client-list surface). File
  selection: pane cwd (`list-panes -F`) → descendants of
  `#{pane_pid}` → Claude's live `<config root>/sessions/<pid>.json`
  registry → that exact `projects/<munged-cwd>/<sessionId>.jsonl`;
  **never regress to newest-mtime-only** (multiple Claude panes per cwd
  are common; the wrong file makes every JUMP miss). `CLAUDE_CONFIG_DIR`
  resolves per candidate pid: `/proc` environ (Linux) → `ps -E`
  (pre-Darwin-27 only; 27 strips same-user procargs env) → the exec
  shell's export → `~/.claude` — each rung accepted only if it holds the
  pid's registry; the winner rides `MULTIPLEX_HIST_CONFIG_DIR` (no
  cross-root rescue). `.shell` tabs honor the exec shell's var alone.
  Reads are sentinel-framed with server-side grep pre-filters, and long
  base64 `"data"` values are blanked BEFORE the tail byte cut (one pasted
  screenshot otherwise crowds out every older prompt). Claude ≥2.x owns
  the alternate screen under tmux — the transcript never enters tmux
  scrollback; jump is ONE server-side exec (RTT-independent). Pager
  facts (2.1.211): PgUp/PgDn move half the region; row 1 of a scrolled
  view is the sticky `❯` header of the owning turn; Ctrl+End/Home =
  bottom/top; no line-granular scroll. The sticky is **click-to-jump**
  (2.1.214; only the sticky reacts): when the prologue sees SGR mouse on
  (`#{mouse_any_flag}`/`#{mouse_sgr_flag}`), a unique-target walk clicks
  every sticky it climbs past (~2 sends/turn); a click that moves
  nothing disarms clicking; twin targets never click (a warp breaks the
  from-the-bottom count). The find ships the WHOLE loaded message list
  as an index (longest-needle-first; an awk classifier reports `pin` =
  which turn owns row 1 and `real` = the target's `❯` row, bottom chrome
  excluded): pin ≥ two turns newer → 6-page leaps; one newer / equal /
  unknown → viewport-safe 2-page steps; pin older → single PgDn from
  above. Landing accepts only a real row in the TOP half (a lower
  sighting takes one PgDn); a UNIQUE target lands on any sighting,
  descent included. Two upward crossings past the target without its row
  = needle mismatch → one retry with the 24-column fallback; scroll-top
  with the fallback unused retries too; both restart from live so twin
  counting stays valid. **A rebuilt transcript (resume, or reflow after
  ANY resize) can omit a long multiline prompt's body entirely** — when
  both needles cross the pinned turn without its row, the walk descends
  to the turn's first view and reports MPXJ_NEAR (the sticky IS the
  flattened text; treat it as the destination, don't lie "not found").
  **A mid-walk capture-height change means another client resized**
  (`window-size latest`): restart once, then MPXJ_RESIZED; multi-size
  sessions surface "ANOTHER CLIENT RESIZES THIS SESSION". The send
  budget is a runaway stop, not a search radius: base 400 scaled by
  `jumpSendBudget(paneWidth:paneHeight:)` up to 1600 (a 44-column pane
  rewraps ~2.3×). Under 12 rows → MPXJ_SHORT ("TERMINAL TOO SHORT TO
  JUMP"). Misses, cancellation, and BACK TO LIVE use Ctrl+End in
  constant time — **never Esc** (Esc can interrupt a running turn);
  every restore-then-capture polls to stability (`stab`). Needles are
  wrap-safe (`wrapSafePrefix`: normalized first-line prefix cut to
  min(width − 6, 60) columns, word-boundary retreat, wide glyphs cost
  two; only the STICKY flattens a prompt to one truncated row — a real
  row word-wraps the full body); pure-paste messages may stay
  peek-only. Identical prompts count from the bottom: each twin's row
  counted once while climbing, upward batches capped under one viewport
  (`twinSafeBatch`), prefix matching ("commit everything" sights as
  "commit"); twins embed in the oracle as the 0 sentinel, and the
  24-column fallback carries its own count. Slash commands (bare and
  `<command-…>`-wrapped, either tag order) are filtered from the list.
  **Only the typed `/compact` line is a transcript-reset boundary**
  (verified 2.1.211) — earlier prompts keep peek with
  `reachable=false`, which withholds JUMP; the pager genuinely cannot
  reach them, don't search harder. `isCompactSummary` entries are NOT
  boundaries (auto-compaction keeps the rendered transcript; treating
  them as resets hid working JUMPs — a wrongly hidden button is
  unexplainable, a wrongly shown one ends in the honest miss pill). Only
  `.finding` blocks a new jump (a lingering JUMPED state is superseded);
  while `.finding`, the input pump is locked and a veil says so.
  `.shell` tabs list history (cwd via `readlink /proc`, `lsof` fallback)
  but never jump. Record: `local-plan/agent-message-history.md`.
