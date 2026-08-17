# Cross-device sync, widgets & Shortcuts

Load-bearing decisions split from AGENTS.md.

- **Cross-device sync rides iCloud Keychain, nothing else**
  (E2E-encrypted, no entitlement/CloudKit): secrets AND a JSON host
  record per host are synchronizable items (services
  `app.multiplexterm.multiplex` / `….multiplex.hosts`). Every keychain
  query must pass `kSecAttrSynchronizable(Any)` — omitting it silently
  matches only device-local items. `HostSync.merge` (pure, tested): last
  writer wins by `Host.updatedAt`; a locally-persisted mirrored-IDs set
  distinguishes "new local → publish" from "peer deleted → drop". No
  change notification exists — deck and terminal roots re-merge on
  scenePhase `.active`.
- **Widgets/Shortcuts add no background execution and must stay that
  way**: they declare no background mode of their own and must not grow
  one (the app's single `fetch` mode belongs to the agent-alert refresh —
  see the keep-alive entries in `lifecycle-and-attention.md`; widgets never
  connect at all); intents are
  `openAppWhenRun`; widget
  timelines are `.never` with app-pushed, hash-gated reloads; probe
  loops gate network work through `BackgroundActivity` (see the
  keep-alive entry in `lifecycle-and-attention.md` — still no background
  mode, and a host that
  never opted in keeps the old `.active`-only behaviour). The
  Shortcuts host picker and widget config read `SharedStateStore`; Open
  Agent's dependent pickers re-resolve against the live `HostStore`.
  Configured working-dir paths ride widget state for the widget's own
  directory picker; setup-script names and bodies never do.
  Directory stays a String for variables (unset = host default, `"~"` =
  Home); Open File likewise keeps its remote path as a String, carries an
  optional positive line number, and recognizes a `path:10-15` range in that
  path, registering the in-memory viewer before its
  route opens; the setup-script String is validated DEFAULT/NONE/UUID; the
  Model String is gated by `normalizedLaunchModel`. `SharedStateTests`
  locks intent/widget/`ExternalActionURL` formats in lockstep (the
  widget target compiles only `Multiplex/Shared` — never import
  Host/Tmux/Agent types there). XcodeGen quirk: the widget target's
  deployment floors need explicit
  `IPHONEOS_DEPLOYMENT_TARGET`/`XROS_DEPLOYMENT_TARGET` (target-level
  `deploymentTarget` is ignored for multi-destination targets). E2E
  without widgets: `xcrun simctl openurl <UDID>
  "multiplex://open?host=devbox&action=shell"`; the App Group file lands
  under `simctl get_app_container … groups`. iOS 26 confirms the FIRST
  simctl-originated open per install. The failure alert presents from
  the mode root (`ExternalActionHost`) — never the deck pane, which the
  expanded shell clips to zero width.
- **A widget's featured session is the last one OPENED, not the newest
  created** (`WidgetHostState.featuredSession`, pure + tested): the Host
  widget's own Session setting first (an explicit Backend is strict; Host
  Default tries the host's default namespace, then wherever the name lives,
  because the picker lists both backends' names), then the host's
  `lastAttached`, then `mostRecentSession` (creation date, kept as the final
  fallback; the bare shell deep link's router fallback follows the same
  last-opened → newest order). Creation order was the old rule and is
  meaningless on herdr — `HerdrProbe` synthesizes near-epoch dates from
  list order, so a mixed host featured a tmux session forever.
  `HostStore.recentSessions` (device-local UserDefaults beside tile order;
  never synced) is written from ONE place, `TerminalWindowUIKit`'s
  active-tab chokepoint (first appearance, tab switch, deck/notification
  reveal) — never from `TerminalWorkspace`'s controller getter, which runs
  for every restored tab in array order. The deck observes it like `hosts`
  and republishes; the ref rides the snapshot name-only on single-backend
  hosts and backend-qualified on mixed ones (the row convention); a stale
  name falls through, never blanks.
