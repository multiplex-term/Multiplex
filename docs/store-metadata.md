# Store metadata

This is the source-of-truth inventory for Multiplex's App Store listing,
Multiplex Pro in-app purchase, review material, and release automation
boundaries. Update it in the same change whenever a user-visible feature,
Free/Pro allocation, price, platform, system requirement, permission, privacy
behavior, or App Review flow changes.

## App record

| Field | Current value |
| --- | --- |
| App name | Multiplex — SSH tmux Terminal |
| Apple ID | `6790074057` |
| SKU | `multiplex` |
| Bundle ID | `app.multiplexterm.multiplex` |
| Platforms | iOS (iPhone + iPad) and visionOS in one app record — the iPhone joined the universal iOS binary 2026-07-18 (single-window shell) and ships with the next binary |
| Current version | 1.3.0 in `project.yml` (1.0 was the first submitted version; 1.1.0 remained unpublished during App Review, so its release-note content was carried forward into 1.2.0) |
| Minimum OS | iOS 17.0; visionOS 1.0 |
| Target release model | Free download with one non-consumable Pro unlock; confirm the base-app price manually |
| Primary category | Developer Tools |
| Secondary category | Utilities |
| Privacy declaration | Target: Data Not Collected; selected files/photos and camera captures go directly to the user's SSH host; dictation audio is transcribed by Apple's Speech framework (on device wherever the locale supports it) and the resulting text is typed into the user's own session — Multiplex stores and transmits neither; set/confirm manually in App Store Connect |
| Runtime permissions | Camera only after FILE → Camera on iPad/iPhone, or Add Host ▸ BIND → SCAN QR (iPhone/iPad; visionOS App Store apps have no camera access at all); Microphone + Speech Recognition only after a terminal dictation button (in the key rail while a physical keyboard is attached, or in the top-center KEYBOARD LOCKED tip while the software keyboard is locked closed); Local Network for LAN hosts and for finding machines offering to bind (Bonjour browsing, only while the Add Host sheet's BIND pane is open); Notifications only for enabled agent alerts; Face ID/Optic ID only when the optional App Lock setting is enabled (device passcode fallback). Photos/Files use system pickers. |
| Age rating | Target: all questionnaire answers None → 4+; complete/confirm manually |
| Base-app price | Free; confirm in App Store Connect before submission |
| Storefronts | Confirm intended coverage in App Store Connect; France needs the encryption step in the release playbook |

The canonical localized listing copy is stored in
[`fastlane/metadata/en-US/`](../fastlane/metadata/en-US/):

- shared name, subtitle, promotional text, and keywords;
- platform-specific `description_ios.txt` / `description_visionos.txt` and
  `release_notes_ios.txt` / `release_notes_visionos.txt` in each locale;
- support, marketing, and privacy URLs;
- `beta_app_description.txt` — TestFlight's Test Information, the tester-facing
  description, pushed by `testflight_info` and by `beta external:true` (not an
  App Store field; `deliver` ignores it);
- categories and copyright in [`fastlane/metadata/`](../fastlane/metadata/);
- App Review contact/demo flow in
  [`fastlane/metadata/review_information/`](../fastlane/metadata/review_information/).
  `notes.txt` is capped by App Store Connect at **4000 characters** (characters,
  not bytes — em dashes and arrows make the byte count run several hundred
  higher). Keep it a page shorter than that: the Fastfile enforces the cap in
  `review_value` and fails the lane before archiving, since the API's own
  rejection arrives mid-upload as `An attribute value is too long. -
  /data/attributes/notes`.

Do not duplicate either complete description in this document. The
`store_metadata` lane uploads shared fields to both platform versions and
injects each locale's matching description and release notes into its
`deliver` call. Never restore a shared `description.txt`: iOS copy must not
advertise visionOS-only surfaces such as GLASS, while the visionOS listing
should describe spatial windows rather than iPhone/iPad windowing. Pass
`platform:ios` or `platform:visionos` to target only one.

| Platform version | Description emphasis | Appearance claim |
| --- | --- | --- |
| iOS | iPhone adaptive shell, iPad scenes/Stage Manager, Home Screen widgets | SYSTEM / LIGHT / DARK only |
| visionOS | Spatial windows and, on visionOS 26+, widgets pinned in the room | SYSTEM / LIGHT / DARK / GLASS |

## Open-source licenses

Free surface added 2026-08-03 (unreleased; ships with the next binary):

| Item | Facts |
| --- | --- |
| Availability | Settings → About → Open Source Licenses on iPhone, iPad, and Vision Pro |
| Inventory | The 13 runtime components shipped in the binary: nine Apache-2.0, three MIT, and one BSD. The build-only `swift-docc-plugin` and `swift-docc-symbolkit` packages are deliberately excluded |
| Presentation | Compact widths group the registry by license family and push full text per component; regular iPad widths and Vision Pro use a filterable two-pane component wall. Every full-text screen has a COPY action and identifies vendored forks separately |
| Mosh note | The page states that Multiplex's mosh transport is a clean-room implementation from protocol facts and carries no third-party license |
| Tier / privacy / store impact | Free, offline, and no permission or data-collection impact. This legal-notice surface does not change the Pro allocation, IAP, public App Store descriptions, review flow, or screenshot set; its tester flow is staged in `fastlane/testflight-whats-new.txt` |

## Bind Host (companion CLI)

Free surface added 2026-07-27 (unreleased; ships with the next binary):

| Item | Facts |
| --- | --- |
| What it is | A **BIND** road inside the Add Host sheet (a `BIND | MANUAL` choice bar; BIND is the default for a new host, and editing an existing host has no such bar) plus an open-source companion CLI (`mpx`, `github.com/multiplex-term/multiplex-cli`, MIT) that the user runs **on the machine being added**. The machine offers itself over a terminal QR, a Bonjour announcement, and — only with `mpx bind --copy` — the clipboard; the app enrolls **its own** newly generated ed25519 public key into that machine's `authorized_keys` |
| Distribution of the CLI | Not shipped inside the app and not required to use it — a Homebrew tap (`multiplex-term/tap`) and `curl -fsSL https://multiplexterm.dev/install-mpx-cli | sh`, both covering macOS and Linux and both offered as copyable text in the BIND pane. Prebuilt archives are hosted in `multiplex-term/multiplex-cli-releases`; the installer verifies each download's SHA-256 against that release's `SHA256SUMS`; the MANUAL road is the unchanged Add Host form |
| Discovery | Bonjour `_multiplex-bind._tcp` (`NSBonjourServices`), browsed only while the Add Host sheet's BIND pane is open (or an enrollment it started is still in flight) and the app is active. Discovery never browses or holds a socket in the background and rides no background mode (the app declares only `fetch`, used solely by the agent-alert refresh described under Multiplex Pro). **No special networking entitlement**: Bonjour browsing needs only `NSBonjourServices` + `NSLocalNetworkUsageDescription`, both declared |
| Credentials | The normal path moves no private key: the device keeps its key, the machine gets the public half (comment-marked `multiplex:bind:<id>:<device>`, removable with `mpx unbind`). `mpx bind --offline`, for hosts reachable only over SSH, ships a CLI-generated key inside the payload; the app then replaces it with a device-generated key on the first connection |
| Confirmation | Every enrollment is confirmed twice — a 6-digit PIN or single-use token app-side, and `[Y/n]` on the machine's own terminal. A `multiplex://b/` URL opened from another app never executes: it only adds a candidate row on the BIND pane, which the user must ENROLL. Scan and paste live inside that pane, where the act itself is the app-side confirmation |
| Tier | Free, and the two-host free limit is enforced **before** anything is written to the machine (the paywall appears instead) |
| Privacy impact | None new: bind traffic is a direct connection between the user's device and the user's own machine; no telemetry, nothing leaves the local pair. The host's SSH key fingerprints it reports are stored in the app's existing synced host record |
| Review note | Reviewers do not need the CLI: Add Host ▸ MANUAL still adds hosts, and the demo host in review notes is reached that way |

## herdr session backend

Free surface added 2026-08-02 (unreleased; ships with the next binary):

| Item | Facts |
| --- | --- |
| Selection | Per host in manual Add / Host Settings: `TMUX | HERDR`; the synced host record carries the choice. Add Host ▸ BIND carries the same choice for the machines bound from that pane (default TMUX, reset when the pane closes — binding proves identity, not what a machine runs). A NO TMUX tile may offer an explicit USE HERDR action only after the host proves herdr is installed; nothing switches automatically |
| Wall model | One tile per herdr **session**, with that session's workspaces adapted onto the existing window spine. Live miniatures come from `pane read`; herdr's pane lifecycle states drive agent RUNNING / NEEDS YOU and Pro alerts, including Pi |
| Attach/create/close | A tile attaches the full herdr client. Attach creates missing sessions and restarts stopped ones. The deck's New Session can type the selected setup script and agent launch into the fresh pane before attach, and its Working Directory choice roots the new session's world (a missing directory falls back to home); close stops then deletes (herdr keeps its protected default session on disk, stopped) |
| New tab in a terminal | The terminal's `+ TAB` leads with **New Session** on every backend — another session attached as its own Multiplex tab, agent entries included, starting in the focused pane's directory, the same shape as tmux. A herdr tab adds a second entry, **New Tab in Workspace**: a tab in the session's focused workspace, in the focused pane's directory, focused by herdr — the attached client is the surface, so that entry opens no second Multiplex tab |
| Requirements | herdr 0.7.5+ / protocol 17 on the SSH host. Homebrew and herdr's installer are offered in-app. Plain SSH shells remain available without either multiplexer |
| Honest limits | No herdr API reports attached-client count or creation time, so those claims are omitted. The Claude HISTORY panel stays hidden on herdr tabs (herdr exposes no transcript identity), and tmux Copy Mode stays tmux's own — herdr tabs instead carry the shared Select Text mode, their own HRDR shortcut panel, and the same FILE attach/drop. Widget/Shortcut shell attach and Open Agent both work — an agent launch mints a herdr session, or lands inside an existing one as a new tab in the focused workspace / a new workspace |
| Tier / privacy | Free, like tmux. No new permission or collection: probes and attaches still travel directly over the user's SSH connection. This does not change the Pro allocation, StoreKit catalog, paywall, IAP screenshot, or public screenshot set |

## Widgets, Shortcuts, and the URL scheme

Free surfaces added 2026-07-18 (unreleased; ships with the next binary):

| Surface | Facts |
| --- | --- |
| Widget extension | `MultiplexWidgets` (`app.multiplexterm.multiplex.widgets`), embedded in the app; iPadOS 17.0+, visionOS 26.0+ (WidgetKit does not exist on earlier visionOS — the app itself stays 1.0) |
| Widgets | "Host Monitor" (small/medium, configurable: host, small-tap action, agent, optional model picked from the host's configured launch models, optional target session with an Open In placement, optional working directory from the host's configured list, ask-for-prompt) and "Fleet Wall" (medium/large, host order follows the deck) |
| Widget data | Last-known sessions/miniatures plus configured agent model names and working directories from an App Group snapshot (`group.app.multiplexterm.multiplex`, `widget-state.json`, secret-free). Widgets never open connections and show no liveness claims — a relative SEEN stamp only |
| App Shortcuts | "Open Shell" (attach the selected backend's most recent session or create), "Open File" (remote file path plus optional positive line number, or a tool-call-style `path:10-15` line range; opens read-only in a File Viewer tab, with relative paths based at the host's first configured working directory or home), and "Open Agent" (Claude Code/Codex/Pi, host-configured working-directory, setup-script, and launch-model pickers — models passed as `--model` — optional first prompt; works on tmux and herdr hosts, with Session + Open In pickers to launch inside an existing session: a new tmux window, or a herdr tab in the focused workspace / a new workspace) — run in-app; failures surface as an in-app alert |
| URL scheme | `multiplex://open?host=<uuid|name>&action=shell\|agent[&session=…][&agent=…][&prompt=…][&ask=1][&dir=…][&script=<uuid\|none>][&model=…][&in=tab\|workspace\|window]` or `multiplex://open?host=<uuid|name>&action=file&path=…[&line=…]` — widget taps and user automation; omitting `script` uses the remembered New Session choice, omitting `model` uses the agent's default; on `action=agent`, `session` targets an existing session and `in` places the launch inside it (tmux: a new window; herdr: tab in the focused workspace / new workspace) |
| Privacy impact | None: the App Group snapshot stays on-device, contains no credentials, and adds no new data collection; setup-script bodies remain in the app's host record and never become Shortcut parameter values |

The App Group entitlement must exist on the App ID for device/TestFlight
builds (automatic signing creates it on first device build; confirm in the
developer portal before archiving).

## visionOS Glass appearance

Free surface shipping with the next binary:

| Item | Facts |
| --- | --- |
| Availability | Vision Pro only, in every distribution configuration (App Store/TestFlight Release as well as development builds); iPhone and iPad retain SYSTEM/LIGHT/DARK |
| Choice | Settings → Appearance adds GLASS beside SYSTEM/LIGHT/DARK; it updates every open deck, terminal, sheet, and popover live and persists like the other choices |
| Material | Smoked native spatial glass with TALLY strata, lines, and open-pane hierarchy; DARK remains the separate opaque graphite choice |
| Terminal themes | GLASS derives from dark traits and shares DARK's terminal-theme selection rather than adding a hidden third theme slot |
| Privacy/accessibility | No data or permission impact. The app-lock veil remains opaque; state colors and captions are unchanged |
| Tier | Free |

## Multiplex Pro

Last remote readback: **2026-08-03 — `IN_REVIEW`** (App Store Connect API:
en-US localization present, review screenshot asset `COMPLETE`, one open-ended
$19.99 manual price, `availableInNewTerritories=true`). The readback was taken
while triaging the 2026-08-03 App Review report "an error displayed upon
purchasing Pro plan" — the IAP record itself is complete and attached to the
submission, so that report points at the Paid Applications Agreement, a
sandbox-environment fault, or a device-side condition, not missing product
configuration. The local review screenshot was refreshed on 2026-07-15 for the
two-host free-tier wording; confirm which revision the `COMPLETE` remote asset
is before relying on it.

Same-day triage facts (2026-08-03 readbacks; keep until the IAP first reaches
`APPROVED`):

- The empty-product failure **reproduced on the TestFlight 1.2.0 build** with
  `Product.products` succeeding but returning zero products (the paywall's
  "not available from the App Store right now" branch). TestFlight IAP rides
  the sandbox with the user's real Apple ID — the Settings sandbox tester is
  consulted only by development-signed builds.
- Ruled out by API readback: IAP availability spans 175 territories (USA and
  TWN included) and the `app.multiplexterm.multiplex` bundle ID has the
  `IN_APP_PURCHASE` capability enabled. Per Apple DTS/TN3186, in-review state
  does not gate sandbox availability.
- **The IAP has never been `APPROVED`**: every visionOS review submission
  (1.0, 1.0.1, 1.2.0 — `READY_FOR_SALE` since 2026-07-30) carried only the
  app-version item; the IAP item rides only the iOS submissions (all removed
  or rejected so far). Until an iOS submission carrying the IAP is approved,
  the production catalog serves nothing — the live visionOS paywall shows the
  same "not available" state, so no customer can buy Pro yet.
- ASC UI state decoder: the product page's "In Review" is the IAP lifecycle
  state (tied up in an open review cycle); the iOS submission item's "Ready
  for Review" is that item's queue state after the app-version item was
  rejected — resubmitting reviews both.
- Business section (Paid Applications Agreement, banking, tax forms) was
  confirmed all-active in the ASC UI on 2026-08-03 after this triage;
  incomplete/outdated tax detail (e.g. W-8BEN / Certificate of Foreign
  Status) is TN3186's remaining cause for an empty sandbox catalog and is
  invisible to the API — re-verify it first if the symptom returns.

| Field | Current value |
| --- | --- |
| App Store Connect IAP ID | `6790252556` |
| Product ID | `app.multiplexterm.multiplex.pro` |
| Reference/display name | Multiplex Pro |
| Type | Non-consumable |
| Price | US $19.99 base price with automatic storefront equalization |
| Trial/subscription | None; one purchase, no subscription |
| Family Sharing | Disabled |
| en-US description | Unlimited hosts, mosh, agent tools & themes. |
| Availability | All configured territories; automatically include new territories |
| Review material | Review note plus a refreshed local screenshot pending re-upload |

The IAP-specific review note is configured in App Store Connect but its
verbatim text is not currently committed. Before changing it, read back the
remote text and add the canonical wording here (or in a linked tracked file)
so future edits can be reviewed as source changes.

The product ID, type, localized test data, and $19.99 development storefront
also live in [`Multiplex.storekit`](../Multiplex.storekit). Production always
uses StoreKit's localized price; the catalog's price is for development and
tests.

The exact territory list could not be independently read with the current API
key; the availability resource and `availableInNewTerritories=true` were
confirmed. Review the actual storefront list in App Store Connect before
submission.

Current product split:

- Free: two hosts, adding one by running the companion CLI on it (QR,
  clipboard (opt-in, `--copy`), or local-network discovery with a PIN — the two-host limit
  still applies), full SSH spatial windows/tabs/merge with multilingual
  system-keyboard/IME input, a dedicated RET key immediately after the
  direction keys (always on iPad, and while iPhone's software keyboard is
  locked closed), app-owned terminal dictation from the physical-keyboard rail
  or software-keyboard-lock tip (on device wherever the locale supports it,
  typed into the session as it settles and never submitted),
  and primary-button touch/pointer input for mouse-aware TUIs, all-pane agent
  detection and wall
  telemetry with foreground-aware helpers in tmux panes, herdr sessions,
  and plain SSH shells (including direct-shell NEEDS YOU chrome; the strip
  folds to a corner dot on a title tap), a per-host
  TMUX / HERDR backend choice (herdr 0.7.5+; one tile per session, workspaces
  on its spine, lifecycle-backed RUNNING / NEEDS YOU, attach/create/restart/
  close; a herdr-specific HRDR shortcut panel and the same FILE attach ride
  along, while the Claude HISTORY panel stays tmux-only), a
  System/Light/Dark appearance setting plus smoked GLASS on Vision Pro
  (SYSTEM follows the device; the whole chassis, launch screen, and keyboard
  flip together; GLASS shares the dark terminal-theme slot), New Session
  launches for Claude Code,
  Codex, or Pi with optional per-host setup scripts and one-shot first
  prompts, per-host new-session tmux options (one option per line; defaults
  `mouse on` and `focus-events on`) applied when sessions are created from
  the app — session-scoped values leave host-made sessions untouched while
  tmux's server-scoped values remain server-wide, a per-host switch (deck
  menu, its tile, or Host Settings) that parks a host on the wall without
  connecting to it — no probing, no local-network check, and widget or
  Shortcut actions report it as disabled — carried with the host record to
  the user's other devices, a second per-host switch (Host Settings →
  Monitoring, off by default) that keeps that host's sessions and probing
  alive for the short stretch of running time iOS grants an app on its way
  to the background, and — through the one background mode the app declares
  (`fetch`, for `BGAppRefreshTask`) — lets iOS wake it later to check that
  host again so an agent finishing while the user is away can still notify
  them. No socket is held in the background, the wake is entirely at the
  system's discretion (and does nothing if the user disables Background App
  Refresh), and a host that was never opted in is never probed or scheduled
  for — built-in terminal themes with independent light/dark
  selections (GLASS shares dark; light adds Tally Frost/Paper/Ivory),
  free file attachment on SSH-backed tmux and herdr tabs from Files/Photos
  (plus camera
  on iPad) and drag-and-drop through the same SSH upload path, a read-only
  File Viewer (code, rendered Markdown, images, and git diffs) summoned from
  + TAB or a confirmed path in terminal output (a percent-decoded,
  local-authority `file:` URI naming that SSH host takes the same road); a
  tree-file long press opens that file in another viewer tab, per-file
  DIFF mode carries across changed-file selections, and web links in rendered
  Markdown use the same confirmation with a choice of an inline viewport or
  the system browser,
  opening web and mail links found in terminal output (long press, or tap
  where the remote is not tracking the mouse; the confirmation shows the
  resolved target and its host, and unsupported schemes are shown for copying
  rather than followed), an
  inline viewport browser for confirmed web links (⌗): the page docks as a
  tab beside the session that printed it, splits into its own window and
  merges back like any tab with the live page riding along, the sheet's
  REACH row says which network the address lives on and rewrites a remote
  `localhost` to the host's own dialled address in the open, the rail's
  address is tap-to-edit (typed addresses ride the same web-only gate and
  loopback rewrite), and viewport
  tabs never persist across launches, a
  most-used shortcut dropdown for each backend — TMUX, or HRDR on herdr
  tabs — on both platforms (including touch-native copy-mode selection and
  explicit exit), an app-owned Select Text mode from a terminal long press or
  touch double-tap (a SELECT / SELECT ALL / PASTE block on any live pane; the
  selection clamps to that pane with a floating COPY / SELECT ALL / DONE
  block beside it, a pointer's secondary click raises the same block, and herdr
  tabs add a MENU chip that opens herdr's own pane menu in place), Home Screen
  widgets (per-host monitor +
  fleet wall; iPadOS 17+, visionOS 26+) and App Shortcuts ("Open Shell" /
  "Open File" with remote path and optional line or `path:10-15` range /
  "Open Agent" with
  host-configured working-directory, setup-script, and
  launch-model pickers plus an optional first prompt; per-host agent model
  lists are configured once in Host Settings and offered on the New Session
  sheet and widget setting too) with the
  `multiplex://` deep-link
  scheme behind them, iCloud Keychain host/secret/command-setup sync,
  per-host/per-agent
  built-in command placement between Bar and More, custom commands (ordered,
  multiline, optional Auto Submit and explicit bar placement, with
  nine-character bar label previews, plus optional sharing across that host's
  Claude Code, Codex, and Pi strips), and
  ten built-in or custom agent-command chip taps per local calendar day.
  ⚠ The built-in set lost **STOP** on 2026-08-05 — no chip types a bare
  Escape any more (it interrupts a running turn, and every platform already
  carries a real ESC key beside the terminal). The shipped `strip`
  screenshots still show it; see `docs/appstore/screenshots-plan.md`.
- Pro: unlimited hosts, mosh, unmetered built-in and custom agent command
  chips, Claude Code/Codex agent alerts from tmux sessions and plain shells
  plus lifecycle-backed Claude Code/Codex/Pi alerts from herdr sessions,
  the HISTORY panel (a Claude Code session's prompt history read from
  Claude's own session file, with full text where the TUI truncates, plus
  jump-back-to-message on tmux and herdr tabs — Claude Code only; Codex/Pi
  history was deliberately withdrawn 2026-07-16 to keep the jump exact), and
  custom-theme editing.
- Existing/synced hosts, existing mosh configuration, and existing custom
  themes are never deleted or disabled when Pro is absent.

When this split changes, update this document, the local StoreKit catalog,
the app description and release notes, review notes, paywall copy, affected
screenshots, and the pricing plan together. Never advertise a gate before the
corresponding binary ships.

When the price changes, also update the DEBUG review-preview default in
`EntitlementStore.prepareDebugPaywallPreview`, its StoreKit tests, the
`MULTIPLEX_AUTO_PAYWALL` price wording in `docs/agents/e2e-headless.md`, and
the review screenshot.
Production purchase UI must continue to use StoreKit's localized price.

## IAP review screenshot

The IAP review screenshot is private review material for Apple. It is not one
of the public App Store gallery screenshots.

| Asset | Purpose |
| --- | --- |
| [`docs/appstore/iap-review-screenshot.jpg`](appstore/iap-review-screenshot.jpg) | Canonical 2064×2752 JPEG ready for App Store Connect (714,227 bytes) |
| [`docs/appstore/iap-review-screenshot.png`](appstore/iap-review-screenshot.png) | Lossless 2064×2752 source/export retained for regeneration (3,907,546 bytes) |

The 2026-07-13 image revision is fully processed in App Store Connect; the
2026-07-15 local replacement above is not uploaded yet. The replacement shows
the real locked `ProPaywallView`, including the one-time US $19.99 purchase CTA
and Restore Purchases action. It is not a hand-built mock. In DEBUG builds,
`MULTIPLEX_AUTO_PAYWALL=1` opens that real paywall with a deterministic $19.99
storefront preview so the simulator can reproduce the review state without a
working local StoreKit transaction.

Regenerate and re-upload the review screenshot when any of these change:

- paywall layout, benefits, price presentation, purchase/restore controls, or
  material wording;
- the Free/Pro feature split or product type;
- the visual appearance enough that the submitted image no longer matches the
  reviewed binary.

After regeneration:

1. Inspect the full-resolution image and keep both PNG and JPEG at 2064×2752.
2. Confirm the screenshot shows the current real paywall and no simulator or
   developer-only artifacts.
3. Upload it manually or through a custom Spaceship/App Store Connect API
   flow; the project's built-in `deliver` lane does not upload IAP review
   images.
4. Wait until App Store Connect reports the image fully processed, then record
   the readback date/status here.

Public product screenshots follow
[`docs/appstore/screenshots-plan.md`](appstore/screenshots-plan.md) and live in
`fastlane/screenshots/ios/en-US/` + `fastlane/screenshots/visionos/en-US/`
(one dir per ASC platform version); do not mix the two screenshot sets.
The plan was re-worked 2026-07-18 for three device classes — Vision Pro
3840×2160, iPad 13″ 2752×2064, and the new iPhone 6.9″ 1320×2868 portrait
set — and for the features added since 2026-07-11 (widgets/App Shortcuts,
agent HISTORY, file attach, the light appearance). On 2026-07-21 the
`history` frame was pulled from the gallery plan (the jump machinery is not
yet stable enough to headline; the listing description still describes the
shipped feature) and replaced with `launch` — the New Session sheet's
one-step Claude Code/Codex/Pi start with setup script and first prompt, the
description's lead agent claim. As of 2026-07-21 the public gallery set has
not been generated or uploaded—the directory contains only its placeholder.

## Fastlane and manual boundaries

“Not supported by Fastlane” here means **not handled by this project's normal
built-in `deliver` lanes**. A custom Fastlane lane may use Spaceship or Apple's
App Store Connect API for supported endpoints, including IAP localization,
price, availability, and review-image upload. Some account/app-level endpoints
can still be permission-gated or require App Store Connect UI work.

| Work | Current route |
| --- | --- |
| App listing metadata and review notes | `bundle exec fastlane store_metadata` (shared fields plus each platform's description/release notes; both versions by default, optional `platform:ios\|visionos`) |
| Public App Store screenshots | `bundle exec fastlane store_screenshots` |
| iOS (iPhone + iPad) + visionOS TestFlight binaries | `bundle exec fastlane beta` |
| TestFlight Test Information (beta app description, feedback email, URLs) | `bundle exec fastlane testflight_info` (also pushed by `beta external:true`) |
| IAP metadata and IAP review screenshot | Already configured; manual ASC or custom Spaceship/API for future changes |
| App Privacy questionnaire | App Store Connect UI |
| Age Rating questionnaire | App Store Connect UI |
| Confirm base app is Free and review storefronts | App Store Connect UI |
| Verify support, marketing, and privacy URLs are live | Browser/hosting check before submission |
| Attach the first IAP to the first app-version submission | App Store Connect UI |
| App Preview videos | App Store Connect UI |
| Final submission and signed Sandbox/TestFlight transaction checks | App Store Connect/TestFlight |

The visionOS public screenshot lane is best-effort: if `deliver` rejects the
3840×2160 set, upload those public screenshots in App Store Connect. This does
not affect the separate IAP review screenshot described above.

Before review, also supply the intentionally uncommitted contact phone in
`fastlane/metadata/review_information/phone_number.txt`, plus
`REVIEW_CONTACT_PHONE`, `DEMO_SSH_USER`, and `DEMO_SSH_PASSWORD` in
`fastlane/.env`. Keep the demo host and the reviewer instructions current.
That directory is the single source for **both** reviews: the Fastfile reads
it once and hands the same record to deliver (App Store review) and to pilot
(TestFlight Beta App Review), with `.env` as the fallback for the two files
kept out of git. Editing the notes updates both.

## Agent maintenance checklist

For every feature change, decide whether it changes any customer-facing claim.
If yes:

1. Update the canonical files under `fastlane/metadata/`.
2. Reconcile this inventory and the Free/Pro table.
3. Update review notes when setup, permissions, demo credentials, navigation,
   or the reviewer-visible flow changes.
4. Update public screenshots when a visible surface or headline feature
   changes; update the IAP review screenshot under the rules above.
5. Update `Multiplex.storekit` and App Store Connect when product metadata or
   commerce behavior changes.
   For price changes, also update the DEBUG review price, its tests, AGENTS
   wording, and the IAP review screenshot.
6. Re-check privacy, age rating, export compliance, platform requirements, and
   storefront implications.
7. Record remote App Store Connect status as a dated readback. Do not claim a
   remote change merely because local metadata was edited.

Submission sequencing, signed transaction checks, demo-host operations, and
export details remain in
[`docs/appstore/release-playbook.md`](appstore/release-playbook.md).
