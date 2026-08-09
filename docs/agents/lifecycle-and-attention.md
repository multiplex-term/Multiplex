# Host lifecycle, background time & attention alerts

Load-bearing decisions split from AGENTS.md — read before touching host
enable/disable, session resume, background keep-alive/refresh, or alerts.

- **A disabled host is one the app never dials on its own**
  (`Host.isEnabled`; deck rail menu / DISABLED tile / Host Settings →
  Monitoring): the wall skips it in `runFeed`, never asks `ConnectionHub`
  for its model (asking would revive it), drops it from
  `tileCount`/`fleetSummary` and the `localNetworkAccess.check` list;
  `ExternalActionPerformer` refuses with its own message. It rides the
  synced record and stays in `connectionModelConfiguration` — load-bearing
  twice: the feed restarts on the change, and that restart is where a
  disable from ANOTHER device tears the probe down (`hub.suspendModel`,
  which unlike `dropModel` keeps the deck snapshot); the local action
  calls it too so the socket goes with the press. Deliberately NOT
  covered: already-open terminal windows keep running (explicit intent,
  `keepHostProbeWarm` included) and Host Settings' Signal check still
  connects. Disabling never buys back a free-tier host slot.
- **A suspended app's dead transport repairs itself; a session the user
  ended stays ended** (`SessionResumePolicy`, pure + tested). The channel
  closes identically for suspension damage and a deliberate exit, so the
  discriminator is: did the app leave the foreground while the session was
  live, and has it not been live since. Both orderings count — the socket
  death surfaces before OR after `.active`, and a close within a short
  grace window after returning is still that wake; never attempted from
  the background. Attempts capped (3, spaced 0/2/5 s), reset the moment a
  session reaches live. `TerminalWorkspace` owns the ONE app-level
  background/foreground observation and fans it out (unmounted tabs need
  repair too — not a scene-phase concern). A pending key-passphrase
  challenge always defers to the person. Logs under category `resume`
  (debug level). Deliberately NOT covered: a foreground transport death
  stays manual, exactly so a deliberate exit is never undone.
- **Background keep-alive is one opt-in host record buying one
  background-task assertion — never a `UIBackgroundModes` declaration**
  (`Host.backgroundKeepAlive`, Host Settings → Monitoring;
  `BackgroundActivityPolicy` pure + tested; `BackgroundActivity` the
  UIKit shell). Off is the plain iOS contract that `SessionResumePolicy`
  repairs. On, `didEnterBackground` takes ONE app-wide
  `beginBackgroundTask` and this host's transports and probes keep
  running until the grant ends — **measured ~26 s on iPad 26; tens of
  seconds, never indefinite**, so every surface's copy is sized to that
  and none of them promises minutes. The modes that would buy more
  (`audio`, `voip`, `location`) require the app to genuinely do that
  thing and faking one is a rejection; `BGTaskScheduler` reconnects
  minutes-to-hours later at the system's discretion, which is not
  keep-alive and is far too late for "your agent is waiting on you".
  Both were considered and refused (2026-08-05) — don't re-propose
  either without new platform facts. Load-bearing details:
  - **The assertion is only taken when there is work for it**
    (`wantsBackgroundTime`: an opted-in host that is `isEnabled` or has
    a live tab — a *disabled* host's already-open windows count). A user
    who opted no host in never takes one, so the default install's
    background behaviour is byte-for-byte unchanged.
  - **`isHoldingBackgroundTime` is cleared BEFORE the assertion is
    handed back**, or a tick starting in between opens an exec channel
    the suspension is about to cut. The expiration handler MUST end the
    task or the app is killed.
  - ⚠ **`backgroundTimeRemaining` answers `.greatestFiniteMagnitude`
    while the system is not counting down — which is exactly when
    `didEnterBackground` runs.** It is *finite*, so an `isFinite` guard
    passes and `Int(_:)` traps past `Int.max`: a crash on every
    background, caught E2E 2026-08-05. Range-check the value, never its
    finiteness.
  - **The probe feed's lifetime is the wall's visibility, not the
    scene's focus** (`FleetWall.restartFeedIfNeeded` keys on
    `isOnScreen`; `viewDidDisappear` is what ends a feed). It used to
    die on resign-active, which both defeated this gate and stopped an
    iPad Stage Manager sibling's visible deck from probing at all.
    Activity changes still force a restart — that is where a returning
    scene resets each model's connect-retry backoff. Pinned by
    `testTheProbeFeedOutlivesTheSceneResigningActive`.
  - `.inactive` counts as permitted for every host (unsuspended
    foreground); `.background` needs the opt-in AND a held assertion.
    Three loops ask: the wall feed, `keepHostProbeWarm` (reads the LIVE
    record, so an edit reaches it without a tab change), and the direct
    shell's agent monitor.
  - Deliberately NOT covered: reconnecting from the background.
    `SessionResumePolicy` still parks repair until foreground — redialling
    inside a window that is about to end is churn, not recovery. The file
    viewer's watch tick likewise stays `.active`-only.
  - Free, not Pro: this is connection plumbing, and the agent alerts it
    feeds are already gated where they are scheduled. Rides the synced
    record and participates in `connectionModelConfiguration`.
  - Headless: seed key `backgroundKeepAlive`, notify hook
    `debug.hostkeepalive` (flips the FIRST host). Proof is the
    `background` log category (debug level) plus the harness sshd log
    continuing to take exec probes across the trip; background the
    simulator app by launching another one (`xcrun simctl launch <udid>
    com.apple.mobilesafari`) — Xcode 27 ships no Simulator.app to send
    Cmd+Shift+H to.
  - Deliberately still `.active`-only: `watchActivePane`'s 1 s
    focused-pane check. It refreshes helper *chips* — UI nobody can see
    while backgrounded — at one exec per second, and it is not an alert
    source. Letting it run would spend the grant on invisible chrome
    instead of the 5 s probe that feeds notifications.
- **The late half of keep-alive is one `BGAppRefreshTask`, on iOS's
  schedule** (`BackgroundRefresh`; `UIBackgroundModes: fetch` +
  `BGTaskSchedulerPermittedIdentifiers`, the app's ONLY background mode).
  The assertion covers tens of seconds; a real agent turn takes minutes,
  so leaving and having the turn end 60 s later reached nobody until the
  app was reopened (measured, user-reported 2026-08-05). This wakes the
  app later, probes the opted-in hosts, and lets the edges post.
  `earliestBeginDate` (15 min) is a FLOOR — the system decides from usage,
  and Background App Refresh off means never. **No surface may promise
  timing.** Scheduled only when there is something to deliver (an opted-in
  enabled host AND `attention.isActive`), re-armed at the top of every run
  so an expiration still chains. The grant window rides
  `BackgroundActivity.isRunningBackgroundRefresh`, OR'd with the assertion
  into `hasBackgroundGrant`, and is closed BEFORE the task completes.
  - ⚠ **Its whole ability to emit rests on the edge baseline surviving a
    reconnect.** `AttentionTracker.update` returns nothing without a prior
    observation, and the socket always dies across a suspension.
    `evaluateAttention` therefore clears the *displayed* attention map when
    the probe stops showing sessions but KEEPS the tracker — a lost
    connection is not evidence an agent's state changed. Resetting it (as
    the code did until 2026-08-05) makes both this and "alert me on return"
    silently impossible. Verified E2E: busy at suspension → turn ends while
    suspended → the reconnect's first pass posts `turnEnded`.
  - ⚠ Cold relaunch gap: if iOS *terminated* rather than suspended the app,
    the tracker starts empty and a refresh only establishes a baseline.
    Persisting baselines was deliberately declined — it would announce a
    turn that ended hours ago as if it just happened.
  - Headless: the simulator NEVER schedules (`submit` throws
    `BGTaskSchedulerErrorDomain error 1`, logged and ignored), and a
    *suspended* app cannot receive a notify poke — so `debug.bgrefresh`
    runs the same probe under the same window and must be fired while the
    app is running. Scheduling itself is only provable on device.
- **Keyboard focus only silences an alert while the app is frontmost**
  (`AttentionFocusPolicy`, pure + tested; `AttentionCenter.isFocused`).
  The arbiter answers "which terminal would receive a keystroke", NOT
  "is anyone here" — it keeps its owner when the app leaves the screen.
  So the old focus check silently inverted on backgrounding and
  suppressed alerts about the session the user had just walked away
  from, which is the likeliest one running an agent: "leave while the
  agent works, get pinged" was the one case that stayed quiet
  (user-reported, fixed 2026-08-05). `.inactive` deliberately does not
  count as engagement — a Stage Manager sibling beside the app being
  typed in is not being watched, and `ForegroundBanner` exists to draw
  over a visible-but-unattended window. All three event sources share
  the rule (probe alerts, direct-shell events, in-band bells).
- **Notification permission is asked with the app on screen, never from
  the background** (`AttentionCenter.primeAuthorization`, called from
  `sceneDidBecomeActive` and when the Alerts switch goes on). The ask
  used to ride the FIRST alert; raised for a backgrounded app that
  puts a system prompt over whatever the user switched to and spends
  the alert buying permission instead of delivering it — verified on
  the iPhone 17 sim 2026-08-05 (prompt over Safari, no banner ever).
  A background alert with permission still undetermined is dropped;
  the wall's NEEDS YOU badge stays the in-app surface and the next
  foreground moment asks properly.
- **Every alert that does not become a banner says why** (category
  `attention`, debug level: `alert dropped for <session>: focused|locked`
  / `alert posted for <session>`). An undelivered alert is otherwise
  indistinguishable from one never detected, which is what made the
  focus bug above invisible for so long. ⚠ Notification authorization
  cannot be granted headlessly (`simctl privacy` has no such service),
  so the log line is the delivery proof a simulator run can give.
