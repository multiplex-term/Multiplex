# Backends & the probe (tmux facts, mixed hosts, herdr, session creation, drops)

Load-bearing decisions split from AGENTS.md — read before touching TmuxProbe,
HerdrProbe, session creation/targeting, or file attach/drop.

- **tmux `-F` sanitizes control chars** (0x1F → `_`): the probe format is
  space-separated with the variable-length name last, correlated by
  `session_id`, tail-rejoined on parse. Don't switch to a control-char
  delimiter.
- **Every tmux invocation is `tmux -u`** (`TmuxProbe.tmuxCommand`; the
  `multiplex_tmux` runner too). SSH exec channels inherit no locale, so tmux
  falls back to C and `-F` sanitizes every *multibyte* char to `_` — which
  silently gutted the deck spine title, the Braille RUNNING spinner, Pi's
  `π - ` prefix, and `#{pane_current_path}` (file drops aimed at a
  nonexistent dir). `-u` needs no locale to exist on the remote (Alpine
  ships none; macOS has no `C.UTF-8`), which is why it beats exporting one.
  Capture-pane output is raw bytes and was never affected.
- **A pane title is shown only where it can speak for its window**
  (`PaneTitleDisplay`, pure + tested; deck spine + widget). tmux seeds every
  pane title with the server's own hostname, so suppression compares
  against the probe-reported `#{host}` (`TmuxSession.serverHost`) — never
  `Host.hostname`, which is routinely an IP or tunnel alias; short/FQDN
  forms count as the same host. Also dropped: a title that repeats the
  window name, and ANY title on a split window (it speaks for one pane, not
  the window). Pre-pane-inventory snapshots report `paneCount == 1` and
  fail open. Spine line `0 EDITOR · ✳ Claude Code`: name uppercased as a
  chassis label, title **verbatim** — it is screen content.
- **A host may show a SECOND backend's sessions, offered and never assumed**
  (`Host.secondaryBackends` / `monitoredBackends`; `BackendDiscovery`;
  plan + measurements in `local-plan/mixed-backend-deck-plan.md` and
  `mixed-backend-deck.md`). `sessionBackend` stays the PRIMARY: it mints
  sessions, answers the Signal check, owns the rail phase and the NO TMUX /
  NO SERVER / UNREACHABLE tiles, and defaults every external action.
  - **Identity is `SessionKey(backend, name)`, never a bare name.** A tmux
    `main` beside a herdr `main` used to make `SessionOrdering.ordered`'s
    `Dictionary(uniqueKeysWithValues:)` **trap at runtime** — a fatal error
    on the deck's render path for any mixed host with a saved tile order.
    In-memory maps are `[SessionKey: …]`; persisted ones
    (`deck-snapshots.json`, `widget-state.json`, `MultiplexSessionOrders`)
    stay `[String: …]` through `storageKey`, so a legacy file's bare `"main"`
    reads back as `.tmux/"main"` — no migration, no version bump.
    `DeckSnapshot.keysCarryBackend` is the one exception: a pre-mixed HERDR
    snapshot's whole content belongs to its file-level `sessionBackend`, and
    the decoder stamps it forward rather than reading it as tmux.
  - **Discovery is free; the second full probe is not.** Every tick rides
    `BackendDiscovery.riderCommand` for each UNmonitored backend on the
    primary's own channel — measured +1 ms absent, +4–9 ms and <1 KB present,
    which is what the old standalone `command -v herdr` already cost (the
    rider replaced it, and `herdrPresent` is now derived from it). A full
    second probe is 25 KB/tick for herdr against tmux's 3.5 KB, so it is
    **offered**, never taken: the rail draws `+ HERDR · 3`, a confirmation
    names the cost, and only that press writes `secondaryBackends`. Long-press
    dismisses per host per backend, device-local (`BackendOfferPreferences`)
    — a dismissal is a this-device annoyance judgement, not a fleet fact.
  - ⚠ **`BackendDiscovery.read` consumes only the LEADING region block.** A
    probe response carries panes' visible screens in its capture tails, so
    scanning the whole response would let terminal content forge an offer —
    or, worse, get the tails swallowed as region body and blank every
    miniature. Noise *before* the block is tolerated (remote `.bashrc`
    echoes are real); once a non-region line follows it, nothing later is
    read or removed. That placement is `BackendDiscovery.riderPrefix`'s job,
    not each probe builder's — the rule (subtract self, sort by raw value so
    the command is byte-stable, lead) is written once, and the rider spells
    its list verbs through `TmuxProbe.tmuxCommand` / `HerdrProbe
    .sessionListVerb` so the mandatory `-u` and the shape
    `parseSessionNames` reads each have one owner. `read` itself walks the
    response line by line and returns the remainder as prefix + suffix
    SLICES: both probe parsers cut their capture-tail region off before
    walking it precisely so 25 KB of pane screens is tokenized once, and
    splitting the whole response into lines here would undo that for both.
  - **A secondary's failure is structurally contained.** Two concurrent exec
    channels on the SAME connection (105 ms vs 176 ms concatenated); the
    primary alone owns `phase`, `markFailed`, and the `reusedLink && mayRetry`
    rebuild. A secondary that throws is logged under `wall` and keeps its
    LAST state — one bad round-trip is not evidence its sessions went away.
  - ⚠ **`evaluateAttention(answered:)` takes the backends that actually
    ANSWERED, never the union of everything expected.** A backend that failed
    has not proved its sessions are gone, so its displayed attention AND its
    `AttentionTracker` baseline must survive. Getting this wrong reproduces
    the 2026-08-05 bug exactly: NEEDS YOU silently cleared by an unrelated
    probe's failure, invisible outside the `attention` log, and "the agent
    finished while you were away" made unannounceable. `prune` has a
    predicate overload for precisely this.
  - **A tile's backend comes from its own record** (`TmuxSession.backend`,
    stamped by the parser that built it), never `host.sessionBackend`. That
    is what `TerminalRoute.Mode.attach(host:session:)`, the attention
    classifier, `killSession`, and the external-action router all read; the
    name-only overload falls back to the primary as a documented tie-break.
    Anything that TARGETS a session states the backend rather than defaulting
    it, because pairing a name with the host's primary is a silent miss on a
    mixed host — a duplicate window from `focusOrAttach`, a banner press that
    finds nothing, an `in=tab` launch running tmux verbs at a herdr session.
    So `kill` reads `session.backend` (the parameter that let the two
    disagree is gone), `launchInSession` and `detectActiveAgent` take it
    required, `AttentionAlert` carries it into `tapTarget` and out through
    `AttentionCenter`'s attach, `AgentPromptRequest` holds it across the ASK
    sheet's rebuild, and `ExternalActionPlan.mostRecentSession` returns the
    RECORD — the name-then-re-lookup it replaced resolved in exactly the
    namespace `SessionKey` exists to disambiguate.
  - **The primary is never also a secondary, enforced by the record**
    (`didSet` on both `Host.sessionBackend` and `Host.secondaryBackends`), so
    no writer has to remember it and a stray copy can't make
    `connectionModelConfiguration` unequal and rebuild the probe for nothing.
    `init(from:)` repeats the rule because observers don't run during
    initialization; that is the one place it lives twice. ⚠ The rule does NOT
    reach `AddHostFormState`, which carries its own fields.
  - **Host Settings ▸ Backend is a CHECK selection, not a switch**
    (`AddHostCheckBar`): tmux and herdr as peers, at least one always
    checked, plus a "New sessions run on" single-choice bar that appears
    only once more than one is. A boolean "Also show herdr sessions" row
    shipped first and read badly — it framed two peers as a primary and an
    afterthought and said nothing about where a new session lands.
    Unchecking the current default promotes what remains, so the record can
    never point at a backend it no longer shows. The New Session sheet
    mirrors it with a "Runs on" bar under the same gate, and **Add Host ▸
    BIND wears the same two controls** — a machine may genuinely run both,
    and one choice made at mint time meant correcting it on the deck
    afterwards.
  - ⚠ **The two controls edit `Host.BackendSelection`, never the two fields.**
    The record stores a default plus extras, so writing either half alone
    silently changes the other: promoting a checked backend to default used
    to un-check the one that had been default, because the extras still held
    the backend just promoted — checking both and then choosing a default
    collapsed the checks back to one (reported 2026-08-06).
    `setPreferred` moves the default and keeps the set; `setEnabled` changes
    the set and promotes a survivor. `AddHostFormState` and `BindController`
    both hold the value, and the bind mint carries it as ONE parameter down
    the handshake/offline chain rather than two that must agree.
  - **Tiles say which backend only on a mixed host** (`showsBackendIdentity`),
    and say it in the CHASSIS: a herdr tile takes a very light purple
    (`TallyPalette.herdrBezel` — Catppuccin Mauve, herdr's own default theme;
    luminance-matched to `bezel` so it changes hue, not hierarchy). A
    single-backend host's tiles are byte-for-byte as shipped. A `TMUX`/`HRDR`
    chip led the UMD row first and was removed 2026-08-06 (user direction):
    the tint reads faster and from further away than a 9.5 pt label, and the
    prefix spent a crowded row's width repeating it. ⚠ That leaves the tint
    as the only *visual* channel, so the backend MUST stay in the tile's
    `accessibilityLabel` ("main, on herdr, live, …") — VoiceOver cannot see a
    chassis color, and color-only encoding is what that label prevents.
  - Any monitored backend having sessions outranks the primary's `.noServer`
    tile, so an opted-in secondary's live tiles are never hidden behind a
    placeholder. A secondary answering "missing" or "no sessions" renders
    nothing — the user asked to see its sessions if they exist.
  - **Every surface that creates or targets a session can name a backend**,
    and each omits the choice where there is only one answer.
    `ExternalActionURL`/`WidgetLink` carry `backend=` — omitted for the
    host's default, so every URL, widget, and Shortcut built before mixed
    hosts keeps its exact bytes and meaning; an unknown token fails soft to
    the default (`model`/`in`'s rule) but a named backend the host does NOT
    monitor resolves to NO session rather than the other one's namesake.
    `WidgetSessionState.backendRaw` is set only on a mixed host, so widget
    rows deep-link unambiguously. The Open Shell / Open Agent Shortcuts and
    the Host widget grow a Backend parameter whose rows come from
    `SessionTargetChoices.backendChoices` — **empty for a single-backend
    host**, which is what keeps the setting invisible there. Pinned by
    `SharedStateTests`.
  - Headless: seed key `secondaryBackends: ["herdr"]`, notify hook
    `debug.backendoffer` (accepts/withdraws the offer for the FIRST host).
    Proof is host-side — two exec channels per tick in `state/sshd.log` —
    and the `wall` timing line's per-backend byte breakdown.
- **herdr is an explicit per-host backend** (`Host.sessionBackend`,
  `HerdrProbe`; 0.7.5 / protocol 17), adapted as session→tile,
  workspace→window, pane→pane. Identity is `(backend, session, pane)` because
  pane ids collide; routes and snapshots retain the backend. Gate tmux-only
  behavior on `route.usesTmux`; never auto-switch. Attach may create/restart,
  close is stop+delete, and creation validates the live list/name before
  typing setup. A fresh mint roots the session's world by cd'ing the
  headless spawn (herdr has no start-directory flag, but the session
  server inherits the spawning process's cwd — verified 0.7.5): the tmux
  mint's two directory riders both land this way, a source session's
  focused-pane cwd asked from one snapshot exec, an explicit Working
  Directory (deck sheet, external launches) consulted only without a
  source, every miss $HOME, never a failed mint (the rare PTY-creates
  fallback stays $HOME). External agent launches (widget/Shortcut/URL `session=` +
  `in=tab|workspace|window`) can land INSIDE an existing session: tmux is
  one `new-window -t '=name'` exec typing at the printed pane id; herdr
  spawns (attach revives a stopped session), then `tab create` (0.7.5
  defaults to the FOCUSED workspace) or `workspace create` — `--focus`
  explicit (creates are unfocused by default), a missing `--cwd` fails soft
  to $HOME host-side, and typing aims at the envelope's `root_pane`, so
  there is no stale-name window. In-session launches carry the Working
  Directory semantics (explicit choice, else the host's first configured
  dir — one field, one meaning; an unconfigured host falls to the
  session's world: tmux active-pane cwd / herdr server default). A dead
  target name falls back to the fresh-session mint; a failed in-session
  create is a visible failure, never a fallback mint. herdr reports no client
  count or creation time — nothing in `session list`, `api snapshot`,
  `status`, or the bundled `api schema` names an attached client — so a herdr
  tile's LIVE lamp answers for the one client the app can verify: its own open
  terminal tab (`Host.SessionBackend.isSessionLive`, pure). A shell attached
  on the host stays invisible there; the tile understates rather than guesses,
  the same choice its blank client-count and age telemetry already make.
  The shortcut panel has a herdr variant (`HerdrShortcut`, pure + tested;
  the rail key face reads HRDR; deliberately curated small — zoom,
  scrollback, rename-tab, picker, and sidebar rows were trimmed
  2026-08-02; pane/tab cycling followed 2026-08-14 because the TUI already
  makes those targets directly tappable): non-destructive rows send herdr's stock
  ⌃B defaults through SwiftTerm (read from `herdr --default-config`,
  splits exercised against a real 0.7.5 TUI attach 2026-08-02 —
  `split_vertical` ⌃B V is left/right, `split_horizontal` ⌃B − is
  top/bottom; a same-burst prefix+key registers), while the confirmed
  closes resolve the focused pane/tab/workspace from ONE snapshot exec
  and close by id (`HerdrProbe.parseFocusedCloseTarget` — strictly what
  the server names focused, never a guess) so a rebound key can't
  misfire them. The panel's Switch Workspace section rides
  `workspace list` → `workspace focus <id>` on the control connection;
  response-derived ids pass the bake vet before splicing.
  Keep the Agent Gallery withdrawn until transcript support exists.
  A terminal window's `+ TAB` leads with NEW SESSION on every backend —
  another session minted in the host's current backend and attached as a
  sibling Multiplex tab, agent entries included, starting in the source
  pane's directory (tmux asks server-side in the create; herdr asks the
  source session's snapshot and cds the spawn). A Multiplex tab IS a
  session attach, and app chrome is the only surface that can mint one;
  remote-level structure (tmux windows, herdr tabs) belongs to the
  backend's own prefix keys and the shortcut panel. A herdr tab appends
  the one remote-level row that earns chrome, NEW TAB IN WORKSPACE
  (`TerminalRoute.extraNewTabTarget` — the one place the row, the
  control's label, and the failure alert read it from, so no rail can
  drift from another; it carries the setup-script
  rider the HRDR panel's stock ⌃B New Tab cannot): a tab in the
  session's focused workspace through the same `createTabCommand` +
  `typeCommand` pair, label and `--cwd` both omitted (herdr numbers the
  tab and inherits the focused pane's directory), typing the remembered
  script but never an agent (agent entries mint sessions; external
  `in=tab` launches stay the agent road into an existing session), and
  adds no Multiplex tab at all: herdr's focus is session-wide, so a
  second client on the same session would only mirror the first, and
  the client already on screen is what renders it — a stopped session
  fails visibly rather than spawn-first. The deck's own `+ New Session`
  defaults to minting a session — a tile IS a session — but a herdr
  host's sheet adds a Creates row (herdr only; tmux windows stay with
  the prefix keys): pick an existing session and the mint becomes a tab
  in its focused workspace through `launchInSession(placement: .tab)`,
  the external `in=tab` road — name field leaves (herdr numbers the
  tab), launch/script/directory riders apply, nil directory inherits
  the focused pane's (the sheet's Focused Pane row). A herdr session
  tile's long-press menu carries NEW TAB IN WORKSPACE too (remembered
  script, never an agent). Both deck roads — unlike the `+ TAB` row —
  ride the reviving spawn and then front/attach the session's window,
  so the new tab lands on screen, never where nobody is attached; an
  in-session create that fails alerts ("Couldn't Create Tab"), never a
  fallback mint.
- **tmux attach needs a PTY**: the shell opens with ECHO off and `exec
  tmux attach-session …` is injected as the first stdin line; detach =
  close the channel. oh-my-zsh's update check steals queued stdin, so
  `ShellHandoff` (pure, tested) prefixes a sacrificial `:` line (feeds
  both single-key and line readers) and `UpdatePromptWatch` re-types the
  payload once when the blocked prompt appears in early output (retires at
  alternate-screen takeover or 32 KB). Keep the prompt needles
  phrase-exact so MOTD mentions of oh-my-zsh can't trigger a re-type.
- **A first tmux server must outlive the SSH login scope on systemd
  Linux** (`KillUserProcesses=yes` reaps a daemonized server): new
  sessions are created detached through `TmuxSessionLaunch`'s best-effort
  `systemd-run --user --scope` runner, then attached (the server lands
  under `user@<uid>.service/app.slice`). Plain and agent New Session both
  mint through the control connection first. Falls back to ordinary tmux
  on macOS/BSD or without a systemd user manager (then a headless host
  with logind cleanup needs lingering or `KillUserProcesses=no`).
- **Session setup scripts are chosen, then typed — never implicit**
  (`SessionScript`, `Host.sessionScripts`; editor in Host Settings): a
  newly *created* session types the selected script into the fresh shell
  before the launch line — same shell, so exports are live for the
  launch. Sequential, never `&&`-gated (a failing script leaves its error
  visible above a launch that still runs; a stdin-reading script eats the
  launch line — documented footgun). Attach never types anything; the
  legacy PTY-side `.create` route stays untouched. REMEMBER stores a
  device-local host → script-id map (`NewSessionPreferences`; deleted ids
  fail soft to NONE); + TAB and the widget router inherit it. The Open
  Agent Shortcut adds NEW SESSION DEFAULT / NONE / a stable UUID resolved
  against the live host just before creation. List order is presentation
  only — a script never runs merely because it exists. Ids are
  load-bearing (the editor preserves them across edits); bodies get the
  custom-command sanitize. Rides the synced Host record, zeroed out of
  `connectionModelConfiguration`, never in the widget projection.
- **The per-host new-session tmux conf is Host-record text applied as
  targeted `set-option -t` calls — never a host file, never `-f`, never
  on the raced create** (`Host.newSessionTmuxConf`). Defaults: `mouse on`
  (the app's premise) + `focus-events on` (server-scoped — the one
  documented leak, said in the editor copy); absent-key decodes inherit
  the defaults; a cleared field persists as "apply nothing". One option
  per line, parsed by `TmuxProbe.tmuxConfOptions` — forgiving of
  `.tmux.conf` muscle memory (leading `set`/`setw` + scope flags drop,
  comments/blanks skip, one layer of value quotes unwraps) and
  injection-safe by construction (name must be option-shaped or the line
  skips; the value rides as one shell-quoted argv). Every
  control-connection creation path threads the LIVE host's conf into
  `createSession`; attach never applies it. Scope facts (3.6a): session
  options land on the minted session only; window options land on its
  first window and later windows do NOT inherit; server-scoped options
  silently reach the whole server. Each line is its own
  `2>/dev/null`-silenced client call inside the mint's success guard.
  Never fold conf into the create as a `\;` sequence (a failure exits the
  shared client nonzero — the retry mints a DUPLICATE session — and its
  error text lands inside `$i`); never start the server with `-f`.
  Synced record, zeroed from `connectionModelConfiguration` — which is
  why callers pass it from the live record, never the model's stale copy.
- **File attach/drop = SFTP upload + typed path, never Enter**:
  SSH-backed tmux and herdr tabs carry one free FILE menu in the UMD
  rail (Camera on iPad/iPhone; Photos + Files everywhere). On
  compact widths FILE is a submenu of the terminal overflow: picker
  state and presentation modifiers must stay on the persistent OUTER
  menu, and presentation waits one main-queue turn — SwiftUI tears down
  nested-submenu state as it closes, leaving options inert. Everything
  becomes `[DroppedFile]` → `TerminalSessionController.deliverDrop`:
  upload over the tab's own connection (SFTP multiplexed beside the PTY;
  `.forceCreate` = O_EXCL makes collision renames race-free) into the
  pane cwd ($HOME + absolute typed path only if unresolvable). tmux
  answers the cwd in one exec (`#{pane_current_path}` + the git check on
  a shell variable); herdr answers from a snapshot exec — strictly the
  server-named focused pane, `foreground_cwd` (the `pane_current_path`
  analog) before `cwd`, absolute + control-free only — then the corral
  check runs as its own exec (`TmuxProbe.gitWorktreeCheckCommand`) since
  the cwd came home as JSON; both print the marker
  `parseDropDestination` reads, one wire format one parser. Inside a
  git worktree drops corral into
  `.multiplex-drops/` (created with a `*` .gitignore; a user's existing
  .gitignore is never overwritten — O_EXCL again). ⚠ Query pane formats
  with **`list-panes -F`, never `display-message -p -t`** — 3.6a renders
  every `pane_*` variable empty for outside clients. Also 3.6a:
  pane-target commands (`send-keys`, `capture-pane`) reject `=name`
  targets — use session *ids* (`$N`); `=name` works only for
  session/window targets. Typed text is sanitized/quoted (`DropText`,
  pure + tested) so it stays inert at a shell prompt. Session-backed SSH
  tabs only: `.shell` tabs (no pane cwd) and mosh tabs (no SFTP) hide
  FILE; direct drops refuse via the status pill. The same per-backend
  cwd query anchors the file viewer's + TAB summon
  (`paneWorkingDirectory`). Picker URLs hold their
  security-scoped grant during reads; camera captures are 0.9 JPEGs
  named by `DropText.photoName`. Plans: `local-plan/file-drop.md`,
  `local-plan/file-attach-button.md`.
