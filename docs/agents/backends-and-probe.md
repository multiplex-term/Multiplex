# Backends & the probe (tmux facts, mixed hosts, herdr, Rex, session creation, drops)

Load-bearing decisions split from AGENTS.md — read before touching TmuxProbe,
HerdrProbe, RexProbe, session creation/targeting, or file attach/drop.

- **Every SSH exec rides `RemoteShellEnvelope`: `printf '<escaped>' | <command shell>`.**
  sshd runs exec requests through the account's login shell, and fish (exit
  127) / csh (exit 1) reject POSIX syntax at token one. The format escapes
  `'` → `\047`, `\` → `\134`, `!` → `\041`, newline → `\012`, `%` → `%%`
  (UTF-8 verbatim), so the outer command is one single-quoted string every
  shell parses alike. The interpreter is always `sh` (POSIX guarantees it; a
  per-host COMMAND SHELL field was built and withdrawn 2026-09-07).
  - The payload is wrapped as `{ … } </dev/null`: sh must parse the whole
    group before a stdin-reading child could eat the rest of the script, and
    children inherit /dev/null. An empty payload becomes `:`.
  - **PTY handoff keeps tty stdin**: `exec sh -c '<payload>'` when the
    payload has no `'`, `\`, `!`, newline; otherwise
    `exec sh -c 'eval "$(printf "<escaped + \042 \044 \140>")"'` —
    only printf owns a pipe, eval/exec keep the tty. `String.universalArgument`
    quotes user text for that line (double-quoted octal printf substitution
    when plain quoting would break; trailing newlines keep POSIX quoting since
    `$( )` strips them). Both the first handoff and the swallowed-prompt
    re-type use it; `.shell` routes stay nil; mosh argv is untouched
    (mosh-server execvp()s it).
  - Rejected: literal `sh -c '<payload>'` (fish reads `\'`/`\\` inside
    single quotes as escapes; csh chokes on `!` and literal newlines) and a
    stdin-fed `sh` (Citadel 0.12.0 keeps its session internal).
  - Citadel drops stderr; `SSHConnection.exec` keeps a 2 KiB head, logs under
    `exec`, throws `.commandFailed`. Every builder exits 0 by construction, so
    a nonzero exit means the command environment failed, never "tmux missing".
    `RemoteShellDiagnosis.command` (`echo "$SHELL"`, via `diagnoseLoginShell`)
    is the ONE raw exec — no envelope, no PATH prelude — so it still answers
    when sh itself cannot start; its non-POSIX wording asks to check sh and
    printf, not to change the login shell.
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
  scrollback, rename-tab, and picker rows were trimmed 2026-08-02; pane/tab
  cycling followed 2026-08-14 because the TUI already makes those targets
  directly tappable; the sidebar toggle is kept because nothing in the TUI
  taps it open or shut): non-destructive rows send herdr's stock
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
- **Rex is shown, attached, and minted — never a host's default**
  (`Host.SessionBackend.rex`;
  `RexProbe` for the deck and the mint, `RexSession` for a tab; Rex 0.1.0-preview.19 /
  API revision 14, measured 2026-11-16 against a throwaway server — the
  app still announces revision 14, and a client making the same calls
  attached, typed, resized and streamed against preview.21 / revision 18 on
  2026-11-23),
  adapted as session→tile, window (a tab)→window, terminal block→pane.
  - **Experimental: off until switched on in Settings ▸ Experimental**
    (`ExperimentalFeatures.isRexBackendEnabled`, default off). ⚠ The switch
    is per DEVICE and the record is per host: `secondaryBackends` keeps
    `rex` whatever the switch says (records sync; another device may have
    it on), and the gate sits where the record is read —
    `SessionBackend.isAvailable`, asked by `Host.monitoredBackends`,
    `monitors(_:)` and `showsBackendIdentity`. Everything downstream (probe
    loop, tiles, New Session's "Runs on", widgets, `backend=rex` actions)
    reads those, so none of it has a check of its own. Two surfaces list
    backends directly and use `availableCases` instead: the discovery riders
    (`ConnectionHub` — no `rex` exec on a host while it is off) and Host
    Settings' check bar, which carries a hidden checked `rex` through an
    edit rather than dropping it. Nothing observes the switch: the hub
    re-reads the host every refresh, so it takes effect within one (~5 s).
    A Rex tab already open keeps running. `MULTIPLEX_REX=1` forces it on —
    the unit-test scheme sets it (`project.yml`), and a harness run that
    seeds `secondaryBackends: ["rex"]` needs it too.
  - **Rex has no terminal client, so Multiplex is one.** No `rex attach`
    exists and `rex block stream` answers `not implemented`: Rex sessions
    are drawn by a native app over the server's WebSocket API
    (`/api/control` `rex.control.v1` JSON; `/api/data`
    `rex.data.terminal.v1` binary). A Rex tab therefore has no remote
    command at all — it is the third `TerminalTransport`, beside the SSH
    PTY and mosh. ⚠ The wire spec is NOT in the website docs — the server
    serves its own (`GET /llms.txt` and `/api/help` on its socket; `rex api
    list --json`).
  - **`canBeDefault` is the one switch, and the record enforces it.**
    ⚠ **Multiplex never starts a Rex server**, so a Rex session can be
    created only while one is running. The default backend answers every
    request that names no backend (New Session, the Signal check, external
    actions) and must answer on an idle host — tmux and herdr bring their
    server up with the first session — so Rex is never the primary:
    `Host.sessionBackend`'s `didSet`, `init(from:)`, and `BackendSelection`
    all demote it to a secondary, and the surfaces that choose a host's
    DEFAULT leave it out (Host Settings' "New sessions run on", Add Host ▸
    BIND, the FAQ install bar — `defaultCases` / `defaultChoices`).
    Everything else treats it as a backend like the others: the New Session
    "Runs on" bar and the widget/Shortcut backend pick list offer it
    (`monitoredBackends`), a Rex tab's `+ TAB` mints a Rex sibling, and
    `multiplex://…&action=agent&backend=rex` mints on it. One gap: an
    external `in=tab` launch aimed at a Rex session resolves to nothing and
    mints fresh instead (`launchInSession` opens no window inside a Rex
    session). What would change the rule is a decision to autostart, which
    needs the unmeasured fact below.
    ⚠ In that `didSet`, restore the primary BEFORE inserting the secondary:
    `secondaryBackends`' own observer strips whatever the primary is at
    that moment, and stripped the newcomer straight back out (caught by
    `testRexIsNeverTheHostsPrimary`).
  - **The mint is one exec** (`RexProbe.mintCommand` → `HostConnectionModel
    .createRexSession`): `rex do -e <lua> --args <json> --json` creates a
    session holding one shell terminal (`session.create` with
    `initial_windows`) and prints its id and stored label; the route is
    `.rexAttach(name, id)`.
    - **No autostart, by choice, not by measurement.** `rex new` would
      start a server; the mint refuses and says so ("No Rex server is
      running on …, and Multiplex doesn't start one" —
      `SessionCreateFailure.serverNotRunning`). A server started from an
      SSH login would be the one the host's Rex app then adopts, and how it
      differs from one the app starts in the desktop session (keychain,
      pasteboard, lifetime under systemd) was NOT measured. Do not flip
      this without measuring it on a Mac and on Linux.
    - ⚠ **What the user typed travels as `--args` JSON, never as script
      text or `KEY=VALUE`.** Pairs are typed by spelling — `label=1e3`
      arrived as the number 1000 — and anything spliced into the Lua would
      be code. The script is a constant.
    - **The script settles the label against the live list** (`api` taken →
      `api-2`, compared without case, tmux's scheme): Rex itself creates a
      second `api` without complaint, and both would then be shown with an
      id tail (`sessionNames`) — the fresh tab's name would not match its
      own tile. The label is cleaned the way a probed one is read
      (`sessionLabel`), never empty (an empty one makes the server invent
      `quiet-meadow`), and the stored label is read back after the create.
    - **Setup script and launch line ride `initial_input`**, each followed
      by a carriage return (Enter): the server types them into the fresh
      shell before any client attaches — tmux's ordering, with nothing to
      poll for. (This is what the earlier "Rex's model does not take a
      setup script in one step" note got wrong.)
    - ⚠ **`cwd` is taken literally.** `~` is not expanded and a directory
      that does not exist silently starts in $HOME. So the exec's SHELL
      resolves the Working Directory (`cd` + `pwd`, absolute or empty) and
      hands it over in `MULTIPLEX_REX_CWD` — the Lua runs in the CLI
      process, so `os.getenv` reads the exec's environment. A `+ TAB`
      sibling starts where the source session's fronted terminal is
      (`foreground.cwd`), which wins over an explicit directory; every miss
      is $HOME. The tmux conf rider does not apply.
  - **A backend set encodes sorted** (`KeyedEncodingContainer` overload in
    `Host.swift`). With three backends `secondaryBackends` can hold two,
    and `Set` iteration order is seeded per process — unsorted, every
    launch rewrote `hosts.json` and the mirrored Keychain record.
  - **The probe is one exec, one connection: `rex do -e <lua> --json`.** A
    script is the only way to make many API calls on a single control
    connection and get one document back — sessions, layouts, titles,
    foreground processes, reported statuses, the fronted screen. Measured
    30 ms and 3 KB for three sessions (10 KB when a fronted block has deep
    scrollback), which is tmux's weight, so `HostGuide.secondBackendCost`
    holds.
    - `session.view` and every block method answer `conflict` until the
      connection is attached. **The probe uses `session.attach_all`, never
      `session.attach`**: it does not join a session, so the probe is not
      listed among its clients and no `client_connected` event fires every
      five seconds. (A tab DOES join — `data.connect` and `own_block`
      require it.)
    - ⚠ **Every invocation carries `REX_AUTOSTART=0`** (`RexProbe
      .rexCommand`; the bridge exports it). The CLI starts a personal
      server when none is running; a probe, rider, or attach that did so
      would leave a server on every host that merely has the binary. With
      it off, no server exits 4 (the CLI's documented "unreachable") →
      `.noServer`; any other nonzero exit is a failure that names the
      status. The env switch, not `--autostart=false`, so a build predating
      the flag still answers.
    - `--json` is pretty-printed even when piped, and an empty Lua table
      encodes as `{}` not `[]` (`LuaArray`). The exit line is the last the
      command prints; JSON above it is indented and quoted, so a screen
      cannot start a line with the marker.
    - **The tail is read from the END, uncapped.** `format` returns screen
      AND scrollback oldest-first, and its `max_bytes` counts JSON-encoded
      bytes: a capped read of "the last 6144 bytes" stopped three lines
      short on multibyte output. So `format(max_bytes: 1)` for the id and
      total, then `blob_read(offset: total - 6144)` with no cap; a read
      that started mid-screen drops its partial first line.
  - **A label is not an identity.** Two sessions may share one and an
    unnamed session gets a generated one (`floral-river`). The id
    (`session:<uuid>`) rides `TmuxSession.tmuxID` and is the only attach
    and kill target — `rex kill work` with two `work`s refuses both
    (exit 3), and `Mode.attach` is nil for a Rex record with no usable id.
    Displayed names are made unique by `RexProbe.sessionNames`: a shared or
    empty label is spelled with the id's tail (`work …8d7863`, the CLI's
    own short form), for EVERY holder of the label — keeping the bare name
    on the oldest would hand that name and its attention baseline to a
    different session the day the oldest closes, and announce a turn that
    never ended. An unnamed window's generated `Window <id tail>` label
    gives way to its focused block's label (`shell`, `agent`) — Rex's
    nearest analog of tmux naming a window after what runs in it — and to
    `window N` only when that is empty too: the spine already leads with
    N, and the first headless run read `1 WINDOW 1`. Only the exact
    generated shape is replaced. A session whose programs all exited stays
    listed with no windows (`0 WIN`, no spine) until someone closes it.
  - **`rex` is not on an SSH exec's PATH on a Mac.** Rex adds it only for
    terminals it opens itself. `RemoteCommandEnvironment.rexPathPrefix`
    names the server copy the app installs (`~/Library/Application
    Support/com.superlogical.rex/RexServer/Versions/Current/…`, which
    leads because it does not depend on the bundle's name or location) and
    the helper inside the app bundle; Linux/FreeBSD packages land in
    `/usr/bin` and the unprivileged install in `~/.local/bin`.
  - **Attention: reported status first, the tmux heuristics otherwise.**
    Programs report idle / working / done / blocked / error through OSC
    7501, kept per block (`program_status`). Where any block reports, the
    fold across EVERY block is the authority (blocked → NEEDS YOU with the
    reported kind, `auth` read as a question; working → busy; `done` and
    `error` → idle, the busy → idle edge that announces a turn once). Where
    nothing reports, the fronted block is classified from its title and
    screen exactly as a tmux tile is — and the tile's own background-pane
    title pass applies too. Alert metadata borrows the fronted block's
    agent and screen only when that block's records produced the verdict.
  - The LIVE lamp is attached APP clients (`client.list` scoped to the
    session, `kinds: ["app"]` — a Rex window showing it) OR this app's own
    open tab. ⚠ **Multiplex says hello as kind `other`, never `app`**
    (`RexWire.hello`): Rex's CLI and agent skill aim client actions (`rex
    do pane.split`) at "the app client when exactly one is connected", and
    a second self-declared app made every one of them ambiguous for as
    long as a tab was attached.
  - Discovery rides every primary probe (`rex ls -q`, one id per line) and
    offers `+ REX · N` on the rail like herdr. The tile takes a cool-blue
    wash at `bezel`'s lightness (`TallyPalette.rexBezel` — Rex publishes no
    palette, so the hue is chosen to differ from herdr's mauve). Its menu
    has no Copy Command for Handoff (no command opens a Rex session in a
    host shell) and, on a session with more than one terminal, an **Open
    Terminal** submenu.
  - **A tab is ONE terminal block.** Rex's window is a split tree the
    client draws; Multiplex does not draw it. A tile press attaches the
    block the session is fronting (active window, focused block —
    `RexWire.attachTarget`, decided at attach time); Open Terminal names
    one (`.rexAttach(…, block:)`, label `session · window`), and a named
    block that has since closed falls back to the fronted one. Tab
    identity stays `(rex, session name)`, so the deck finds either kind.
  - **The REX key's panel switches the tab's terminal** (`ShortcutPanel
    Content.rex`; rows from `RexWire.terminalChoices`, `window — terminal`
    in window order, the shown one marked ACTIVE). Rex has no prefix keys
    to list, so the panel is the one thing a Rex tab needs it for: reaching
    the session's other terminals without leaving the tab.
    `RexSession.switchBlock` takes the new block, opens its stream, redraws
    from `format`, then `disown_block`s the old one — which hands that
    terminal's size back to the Rex app instead of leaving it at this
    tab's. Each data stream carries a generation (`dataGeneration`): the
    old stream's end must not read as the tab ending, and input typed
    during the switch is dropped rather than sent to whichever block wins.
    The choice survives a reconnect (`rexBlockID`). The rail key's
    face comes from `SessionBackend.shortcutKeyCaption` — the three
    `herdr ? "HRDR" : "TMUX"` sites it replaced drew a TMUX key on a Rex
    tab.
  - **A Rex tab has a working directory**: `com.superlogical.terminal
    .process` → `foreground.cwd`, else the shell's (`RexWire
    .workingDirectory`, asked over the tab's own control connection). FILE
    drops land there and the file viewer opens there, as on tmux. (Unit
    tested; not yet driven end to end.)
  - **The link is two byte pipes on the tab's own SSH connection**
    (`SSHConnection.openPipe`), each running `rex __internal dial-stdio` —
    the stdin/stdout ↔ socket bridge Rex's own `ssh://` transport runs
    remotely, which is why it finds the server unaided. ⚠ It is hidden
    and unversioned; a rename surfaces as the CLI's "unknown command" on
    the tab's ended line. (OpenSSH socket forwarding would be the
    documented road; the vendored swift-nio-ssh has only `directTCPIP`.)
    - **A pipe is a SHELL channel with no PTY, not an exec.** Citadel
      0.12.0's exec returns output only and keeps the channel, so nothing
      can write stdin; its `withTTY` opens a login shell on plain pipes
      (no line discipline — binary-safe), handed over with the PTY
      handoff's own cross-shell `exec sh -c '…'` line.
    - ⚠ **Nothing is written until the per-pipe marker comes back.** The
      command echoes one first: it drops whatever a login script printed,
      and it proves the `exec` happened — a shell reading its script from
      a pipe may read ahead, and bytes sent early would be eaten as shell
      input. A channel that ends before or after it throws the head of
      the command's stderr, which is how "no Rex server is running" and
      "rex: command not found" reach the tab. Verified against zsh and
      sh; fish as a login shell is unverified.
  - **`WebSocketCodec` + `RexWire` are the whole protocol, pure.** No
    extension is offered (a data connection is never compressed, and the
    control connection works without), revision 14 is pinned in the hello
    (a newer server translates down to it), pings are answered in
    `RexSocket`, and requests are matched by id with a 10 s timeout.
  - **Attach order is load-bearing** (`RexSession.attach`): hello →
    `session.attach` → **`own_block(take)` + `resize` first** → `data
    .connect` → data HELLO/WELCOME → wait for the first server message →
    `modes` + `format(vt)` (two reads, asked together) → RIS + rendering →
    flush the held stream.
    - ⚠ **The stream opens with a Ghostty binary snapshot
      (`GHOSTSNP…`) SwiftTerm cannot read.** `RexTerminalStream` DROPS
      it: its length is stated nowhere, but a `resize` message "comes
      right after the snapshot", so everything before the first `ESC _
      rex1;<nonce>;` is snapshot (the nonce is 64 random bits per stream,
      which is what makes scanning binary for it sound; the same nonce is
      why a program printing a look-alike is drawn as output). The screen
      comes from `format`'s `vt` rendering instead — colors, cursor,
      modes, scrollback, verified on a shell and on vim.
    - Claim-and-size precedes both so the rendering and the stream
      describe the terminal at THIS tab's size.
    - **The two are not atomic and the gap errs toward repeating.** The
      stream is opened first and held while `format` is fetched; output in
      between is drawn twice rather than lost (lost bytes can leave a mode
      wrong for the session; a repeated line is one line). An idle prompt
      — the common attach — has nothing in the window.
    - `extra_palette` is NOT requested (it repaints the tab in Rex's
      theme); cursor, modes, scrolling region, style, charsets, keyboard,
      kitty keyboard, and tab stops are.
    - A rendering over 3 MB (a terminal keeps up to 64 MiB) is not
      fetched: the attach draws a plain-text tail instead.
  - ⚠ **Attached during a full-screen program, the tab redraws when it
    exits.** While one is up `format` renders ONLY its screen — the shell
    history underneath cannot be asked for — so the emulator's primary
    screen starts empty, and quitting vim showed a bare prompt.
    `AlternateScreenExitWatch` notices `CSI ? 1049/1047/47 l` and the
    screen is fetched again. It waits for the terminal to go quiet first
    (120 ms, capped at 800 ms): a shell prints its prompt within
    milliseconds of the exit, and a rendering fetched during that burst
    drew it twice (`$ $`).
  - **Typing is `com.superlogical.terminal.write`, one call in flight.**
    The server runs block methods concurrently, so two calls could land
    out of order; whatever is typed meanwhile rides the next call as one
    string. Its argument is JSON text, so `RexInputEncoder` holds a
    split multi-byte character and replaces bytes that are not UTF-8.
    ⚠ `RexSession.write` QUEUES AND RETURNS; a drain task makes the calls.
    The tab's input pump awaits each `transport.write`, so a write that
    waited for the server's answer (the first shape) made every keystroke
    its own round trip, queued behind the last, and the "rides the next
    call" batching never happened — an SSH PTY write only enqueues bytes,
    which is why the pump never had to care.
  - **The last client to type owns the size** (tmux's latest-client
    rule): the Rex app can claim the block back (`block_owner_changed`);
    the next keystroke here claims and re-sizes it. Until then the
    terminal has the other client's size, and the tab draws it AT that
    size (next bullet).
  - ⚠ **The emulator's grid follows the terminal's, not the pane's.** A
    terminal has one size, its owner's; the stream says what it is
    (`resize`, with the owner). Ignored — the first shape, "Multiplex does
    not letterbox" — the tab parsed output laid out for 170 columns at 132
    and filled with stray characters the moment the Rex app held the
    terminal at another size (reproduced with a stand-in client; and since
    the tab stopped answering queries, above, nothing claims the size back
    until someone types). Now a size that is another client's
    (`RexSession.noteTerminalSize`: not this client's, not this tab's own
    dimensions) is followed:
    - `RexSession` holds the stream from that `resize` on, waits for the
      repaint a SIGWINCH sets off to go quiet (the alternate-screen wait:
      120 ms, capped at 800), has the emulator take the grid (`onGrid`,
      awaited), then draws the screen again from `format`. Held bytes
      that arrived before the rendering was asked for are in it and are
      NOT drawn again (`Replay.sinceRequest`; `RexWire.resumeOffset`
      keeps the cut off the middle of an escape sequence or a character)
      — replaying them, the attach's rule, drew the program's repaint
      twice. The attach keeps its own rule: it has no quiet wait to lean
      on.
    - Redraws run one at a time (`drawScreen` chains them). Two sharing
      one hold let the first release the stream under the second.
    - The pane gives SwiftTerm the grid by giving it the FRAME
      (`TerminalSurfaceView.Coordinator.applyGridPin`, `TerminalGridFit`,
      pure + tested): text shrinks in half points, never below 5 pt and
      never above the tab's own, until the grid fits; what is left over
      comes off the trailing and bottom edges. The fork is untouched and
      its frame-is-the-grid arithmetic stays true. A fork-side "pinned
      grid" was rejected: the view's scroll geometry, hit testing and
      caret all divide the frame by the cell.
    - The grids SwiftTerm reports on the way (`sizeChanged` for each font
      and frame step) are not this tab's ask and are never sent
      (`TerminalSessionController.gridPin`, `isSettlingGridPin`); the
      tab's own last grid is kept (`ownSize`) for the next attach.
    - It ends when this client owns the block again — typing claims it,
      or the other client leaves and the server hands it back — because
      the stream then reports a size whose owner is this client.
    - Only FOLLOWING: the tab never takes the size back by itself. That
      was the flicker.
    - To re-measure: a second control connection that `own_block(take)`s
      and resizes to something larger than the pane, then type in the
      terminal from that side (`rex send`). The tab must match `rex
      capture` cell for cell. Not exercised: the real Rex app as the
      other client, and a tab whose pane is off screen when the size
      changes hands (its emulator is laid out when it next appears, after
      the rendering was drawn).
  - ⚠ **Every redraw is RIS + a rendering, and RIS has to empty BOTH
    screens.** Upstream SwiftTerm's did not empty the alternate one, so
    the REX key's switch from one full-screen program to another (two
    agents — the common case) drew the second over the first; fixed in
    the fork (`swiftterm-fork.md`, `TerminalFullResetTests`). A shell on
    either side hid it, which is why the first switch tests passed.
  - ⚠ **Nothing the emulator says by itself reaches a Rex terminal**
    (`TerminalSessionController.sendTerminalReport`). The server keeps the
    terminal and answers its queries there — measured with no client
    attached: `CSI c` and `CSI 6n` both came back to the program. SwiftTerm
    reads the same output and answers too, and that answer used to go out
    as a `write`: the program read every reply twice, and because a write
    is what claims, a tab nobody was touching took the terminal's size
    back whenever the program asked something. A program that asks on
    every resize closed the loop — reported as the same terminal in the
    Rex app flickering, and reproduced with a stand-in client that
    reclaims when it loses the block: 82 owner changes in 0.6 s before,
    1 (the stand-in's own) after. So on a Rex tab the emulator's answers
    AND its reports (focus, in-band size, color scheme) are dropped;
    mouse events and prompt clicks are a person's and still go.
    - Focus reports go with the rest on purpose. Only this client knows
      its own focus, but so does every other client of the terminal, and
      a tab that reported "unfocused" as the user looked away would say
      it for a terminal still in use in Rex. Whether the Rex app reports
      focus itself is unmeasured.
    - The split is a fork seam (`Terminal.isSendingUserInput`,
      `TerminalViewDelegate.sendTerminalReport`, see
      `swiftterm-fork.md`): both kinds used to leave SwiftTerm through
      the one `send`.
    - To re-measure: a script in the terminal that prints `CSI 6n` from a
      `WINCH` trap and logs its stdin, then a second control connection
      that `own_block(take)`s and resizes. The server's log lists every
      `terminal.write` — with the tab idle there must be none.
    - Still claimed without a keystroke: the attach itself, so an
      automatic reconnect takes the size once.
  - ⚠ **Say goodbye before cancelling the readers** (`teardown`).
    Cancelling a reader tears its pipe down, and a connection that just
    drops is kept by the server for 60 s — its client listed "connection
    lost", its stream parked for a resume. The data connection closes
    first with status 1000 (ends the stream), then the control connection
    (ends the client at once). A data close of 4000 (`block closed`) or
    1000 is a clean end, like a shell exiting; resume is a fresh attach,
    never the protocol's RESUME.
  - **A link that breaks ends the tab like any transport's**, and
    `SessionResumePolicy` treats it the same: suspension damage re-attaches
    by itself when the app returns (verified on the iPad simulator —
    backgrounded, both SSH connections killed, returned: a new client,
    LIVE, output flowing); a drop in the foreground parks on RECONNECT. The
    ended line says "The connection to the Rex server was lost." — a
    broken pipe's own error under a LIVE tab is the transport's shorthand
    (`Already closed` on the first headless run), which read as a second,
    unrelated failure. During the attach the detail IS the reason and is
    kept. The server lists the dropped client as "connection lost" for its
    60 s resume window; the fresh attach is a new client beside it.
  - What a Rex tab does not have: a prefix-key list (the REX panel only
    switches terminals), Copy Mode, HISTORY, the one-second helper-chip
    probe (`SessionBackend.hasFocusedPaneProbe` is false: the wall probe's
    record is the only authority, and it reaches the strip through the
    window's own observation, so nothing polls), and mosh (no PTY for
    mosh-server to run — a Rex tab rides SSH whatever the host prefers).
    - **TODO, waiting on upstream: mosh for a Rex tab needs a Rex
      terminal client to run in mosh-server's PTY, and Rex ships none.**
      Re-measured 2026-11-23 (0.1.0-preview.21 / API revision 18, mosh
      1.4.0): `rex block stream BLOCK [DATA_REF]` exists and still answers
      `not implemented`; there is no `rex attach`; a `rex do` Lua script
      cannot stand in (the terminal creator lists no events, and the output
      is a second WebSocket the script cannot open). mosh itself syncs a
      screen, not bytes, so `RexSession`'s two WebSockets cannot ride it.
      Revisit when `rex block stream <block>` stops answering `not
      implemented` — and check first whether it is a terminal client at
      all or a one-way dump of the data stream (the `DATA_REF` argument
      suggests the latter, which changes nothing here).
      A throwaway PTY client (a Python port of the attach, run by a real
      mosh-server, read through a real mosh-client) drew, typed and resized
      correctly and met four things any such client has to handle:
      1. **Queries are answered twice.** mosh-server's emulator answers
         DA/DSR in the output too, on the client's stdin, which a naive
         client writes into the terminal (`62;22c;1R62c;1R` at the prompt,
         and a size claim nobody made). Dropping queries from the output
         before the PTY left one answer — the Rex server's.
      2. **No alternate screen.** After `:q` the vim frame stays; the
         client must redraw (RIS + `format`) on every `?1049l`, as
         `AlternateScreenExitWatch` does for one case today.
      3. **Another client's size has no way back to the app.** The client
         sees the stream's `resize`, but a mosh tab's grid is the app's; the
         grid pin above needs a side channel (unmeasured).
      4. **No scrollback, and nothing replaces it**: a mosh tab has none
         (`mosh.md`), and a Rex tab has no Copy Mode or HISTORY.
      Also unbuilt: the REX key's switch, which rides the control
      connection a mosh tab would not have. Not a prerequisite, and cheaper
      for the same complaint (a slow re-attach on a bad link): the
      protocol's RESUME, which continues a dropped stream within 60 s
      without a redraw — today a resume is always a fresh attach.
    ⚠ `TerminalSessionController.ridesMosh` is the one statement of that
    last rule: scrollback, FILE and the bar's MOSH badge read it, where
    reading `host.useMosh` raw gave a Rex tab on a mosh host no
    scrollback, no FILE and a MOSH badge.
  - ⚠ **A Rex tab's agent bar is its OWN terminal's, not the session's
    fronted one** (`TmuxSession.agent(inPane:)`, fed by
    `TerminalSessionController.rexBlockID`; the session is found by id,
    since a label is respelled when another session takes it). tmux and
    herdr tabs show the whole session, so following the record's active
    pane follows what the tab shows; a Rex tab is one terminal, and the
    session's focus is whatever the Rex app last fronted. Read off the
    active pane, the bar vanished from a tab still on Claude Code as soon
    as Rex fronted another window, and never appeared on a tab opened or
    switched to a terminal that was not in front (user-reported
    2026-11-16, reproduced with a real `claude` on a throwaway server).
    `rexBlockID` is learned when the attach settles on a terminal and
    changed by Switch Terminal; the next transport run prefers it too, so
    a reconnect returns to the terminal the tab was on.
    - Measured with Claude Code 2.1.325 (macOS native install) at its
      folder-trust prompt: `process.foreground` is `name: "2.1.325"`,
      `argv0: "claude"`; the title is the shell's (`claude`); `program
      _status` has NO records. So it is the bare-semver rule in
      `AgentSignature.classify` that names it there, not OSC 7501.
  - Deliberately NOT built, with the reason each would need new facts to
    reopen:
    - **Drawing a window's splits.** Every terminal in a split needs its
      own data stream — its own SSH channel and `dial-stdio` process, so
      sshd's `MaxSessions` (10) caps a window near nine — and its own
      emulator, and the terminal window assumes exactly one per tab
      (`TerminalFocusArbiter`, the key rail, Copy Mode, the viewers,
      keyboard avoidance). It would also claim the size of EVERY block in
      the window from the Rex app at once. tmux and herdr tabs are not
      drawn natively either — their multiplexer draws its own panes — so
      this would be a layout engine for one backend. The app's own shape
      already covers it: Switch Terminal inside a tab, Open Terminal for a
      second tab or window.
    - **The stream's RESUME.** A fresh attach restores screen, scrollback
      and modes from `format`; RESUME would save one rendering fetch and
      add a replay-window state machine.
    - **Starting a Rex server**, and with it Rex as a default backend (see
      the mint above).
    - **A new window inside an existing Rex session** (`launchInSession`):
      an external `in=tab` launch mints a fresh session instead.
    - Polling `format` as a fake terminal was rejected outright.
  - Headless: seed key `secondaryBackends: ["rex"]`, then
    `MULTIPLEX_AUTO_ACTION_URL='multiplex://open?host=devbox&action=shell&session=<name>&backend=rex'`
    attaches (the `AUTO_ATTACH` env resolves names on the primary only).
    Proof host-side: two `shell` sessions on one connection in the sshd
    log, `rex client ls --all` listing `Multiplex … other`, `terminal
    .size` naming it the owner; `debug.talkbacktype` + `debug
    .talkbacksend` prove input, `rex send` proves output.
    `MULTIPLEX_AUTO_REX_SWITCH=<n>` presses row n of the REX panel once the
    tab is live; `debug.tmuxshortcuts` opens the panel itself. `debug
    .newtab` from a Rex tab mints a sibling (`rex ls` gains `<name>-2`,
    its `process` cwd is the source's). A link drop: kill the tab's
    `sshd-session` (the newer of the app's two connections in `lsof -iTCP:
    <port>`). "No server": point the wrapper below at a socket path nothing
    listens on and open `…&action=agent&backend=rex` — the mint fails
    before anything is typed. To run without
    touching real sessions: a throwaway server (`rex server run --listen
    unix://<abs path> --state-dir <dir> --restore=false --config <empty
    file>`, the path under macOS's 104-byte socket limit) and a second
    user-mode sshd whose `SetEnv PATH=` leads with a `rex` wrapper that
    adds `-S unix://<that path>`. ⚠ `REX_SERVER` does not isolate: a
    socket path that does not exist is skipped and the CLI falls through
    to the local default server.
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
