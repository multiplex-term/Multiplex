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
| Current version | 1.0.1 in `project.yml` (1.0 was the first submitted version) |
| Minimum OS | iOS 17.0; visionOS 1.0 |
| Target release model | Free download with one non-consumable Pro unlock; confirm the base-app price manually |
| Primary category | Developer Tools |
| Secondary category | Utilities |
| Privacy declaration | Target: Data Not Collected; selected files/photos and camera captures go directly to the user's SSH host; dictation audio is transcribed by Apple's Speech framework (on device wherever the locale supports it) and the resulting text is typed into the user's own session — Multiplex stores and transmits neither; set/confirm manually in App Store Connect |
| Runtime permissions | Camera only after FILE → Camera on iPad/iPhone, or BIND → Scan QR (iPhone/iPad; visionOS App Store apps have no camera access at all); Microphone + Speech Recognition only after the key rail's dictation key, which appears only while a physical keyboard is attached; Local Network for LAN hosts and for finding machines offering to bind (Bonjour browsing, deck-frontmost only, and only once at least one host exists or the user opens BIND); Notifications only for enabled agent alerts; Face ID/Optic ID only when the optional App Lock setting is enabled (device passcode fallback). Photos/Files use system pickers. |
| Age rating | Target: all questionnaire answers None → 4+; complete/confirm manually |
| Base-app price | Free; confirm in App Store Connect before submission |
| Storefronts | Confirm intended coverage in App Store Connect; France needs the encryption step in the release playbook |

The canonical localized listing copy is stored in
[`fastlane/metadata/en-US/`](../fastlane/metadata/en-US/):

- name, subtitle, promotional text, description, and keywords;
- platform-specific `release_notes_ios.txt` and
  `release_notes_visionos.txt` in each locale;
- support, marketing, and privacy URLs;
- categories and copyright in [`fastlane/metadata/`](../fastlane/metadata/);
- App Review contact/demo flow in
  [`fastlane/metadata/review_information/`](../fastlane/metadata/review_information/).

Do not duplicate the complete description in this document. The
`store_metadata` lane uploads the shared files to both platform versions and
injects the matching platform release notes into each `deliver` call. Pass
`platform:ios` or `platform:visionos` to target only one.

## Bind Host (companion CLI)

Free surface added 2026-07-27 (unreleased; ships with the next binary):

| Item | Facts |
| --- | --- |
| What it is | A deck `BIND` chip plus an open-source companion CLI (`mpx`, `github.com/multiplex-term/multiplex-cli`, MIT) that the user runs **on the machine being added**. The machine offers itself over a terminal QR, the clipboard, and a Bonjour announcement; the app enrolls **its own** newly generated ed25519 public key into that machine's `authorized_keys` |
| Distribution of the CLI | Not shipped inside the app and not required to use it — Homebrew tap and a `curl | sh` script from `multiplexterm.dev`; the manual Add Host sheet remains unchanged |
| Discovery | Bonjour `_multiplex-bind._tcp` (`NSBonjourServices`), browsed only while the deck is frontmost and only once a host exists or the user opens BIND. No `UIBackgroundModes`, no background sockets. A custom UDP beacon variant is **not** in this release — it needs `com.apple.developer.networking.multicast`, applied for separately |
| Credentials | The normal path moves no private key: the device keeps its key, the machine gets the public half (comment-marked `multiplex:bind:<id>:<device>`, removable with `mpx unbind`). `mpx bind --offline`, for hosts reachable only over SSH, ships a CLI-generated key inside the payload; the app then replaces it with a device-generated key on the first connection |
| Confirmation | Every enrollment is confirmed twice — a 6-digit PIN or single-use token app-side, and `[Y/n]` on the machine's own terminal. Scanned, pasted, or `multiplex://bind` URLs never bind automatically |
| Tier | Free, and the two-host free limit is enforced **before** anything is written to the machine (the paywall appears instead) |
| Privacy impact | None new: bind traffic is a direct connection between the user's device and the user's own machine; no telemetry, nothing leaves the local pair. The host's SSH key fingerprints it reports are stored in the app's existing synced host record |
| Review note | Reviewers do not need the CLI: the manual Add Host path still adds hosts, and the demo host in review notes is reached that way |

## Widgets, Shortcuts, and the URL scheme

Free surfaces added 2026-07-18 (unreleased; ships with the next binary):

| Surface | Facts |
| --- | --- |
| Widget extension | `MultiplexWidgets` (`app.multiplexterm.multiplex.widgets`), embedded in the app; iPadOS 17.0+, visionOS 26.0+ (WidgetKit does not exist on earlier visionOS — the app itself stays 1.0) |
| Widgets | "Host Monitor" (small/medium, configurable: host, small-tap action, agent, optional model picked from the host's configured launch models, ask-for-prompt) and "Fleet Wall" (medium/large, host order follows the deck) |
| Widget data | Last-known sessions/miniatures plus configured agent model names from an App Group snapshot (`group.app.multiplexterm.multiplex`, `widget-state.json`, secret-free). Widgets never open connections and show no liveness claims — a relative SEEN stamp only |
| App Shortcuts | "Open Shell" (attach most recent tmux session or create) and "Open Agent" (Claude Code/Codex/Pi, host-configured working-directory, setup-script, and launch-model pickers — models passed as `--model` — optional first prompt) — run in-app with a connection status guard; failures surface as an in-app alert |
| URL scheme | `multiplex://open?host=<uuid|name>&action=shell\|agent[&session=…][&agent=…][&prompt=…][&ask=1][&dir=…][&script=<uuid\|none>][&model=…]` — widget taps and user automation; omitting `script` uses the remembered New Session choice, omitting `model` uses the agent's default |
| Privacy impact | None: the App Group snapshot stays on-device, contains no credentials, and adds no new data collection; setup-script bodies remain in the app's host record and never become Shortcut parameter values |

The App Group entitlement must exist on the App ID for device/TestFlight
builds (automatic signing creates it on first device build; confirm in the
developer portal before archiving).

## Multiplex Pro

Last remote readback: **2026-07-13 — `READY_TO_SUBMIT`**. The local review
screenshot was refreshed on 2026-07-15 for the two-host free-tier wording and
still needs to be re-uploaded and read back before submission.

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
  clipboard, or local-network discovery with a PIN — the two-host limit
  still applies), full SSH spatial windows/tabs/merge with multilingual
  system-keyboard/IME input, a dedicated iPad RET key immediately after the
  direction keys, and primary-button touch/pointer input for mouse-aware TUIs,
  all-pane agent detection and wall
  telemetry with foreground-aware helpers in tmux panes and plain SSH
  shells (including direct-shell NEEDS YOU chrome), a System/Light/Dark
  appearance setting (SYSTEM follows the device; the whole chassis, launch
  screen, and keyboard flip together), New Session launches for Claude Code,
  Codex, or Pi with optional per-host setup scripts and one-shot first
  prompts, per-host new-session tmux options (one option per line; defaults
  `mouse on` and `focus-events on`) applied when sessions are created from
  the app — session-scoped values leave host-made sessions untouched while
  tmux's server-scoped values remain server-wide, a per-host switch (deck
  menu, its tile, or Host Settings) that parks a host on the wall without
  connecting to it — no probing, no local-network check, and widget or
  Shortcut actions report it as disabled — carried with the host record to
  the user's other devices, built-in terminal themes
  and a separate theme selection per appearance (light adds Tally Frost/Paper/Ivory),
  free file attachment on SSH-backed tmux tabs from Files/Photos (plus camera
  on iPad) and drag-and-drop through the same SSH upload path, opening web and
  mail links found in terminal output (long press, or tap where the remote is
  not tracking the mouse; the confirmation shows the resolved target and its
  host, and other schemes are shown for copying rather than followed), a
  most-used tmux
  shortcut dropdown on both platforms (including touch-native copy-mode
  selection and explicit exit), Home Screen widgets (per-host monitor +
  fleet wall; iPadOS 17+, visionOS 26+) and App Shortcuts ("Open Shell" /
  "Open Agent" with host-configured working-directory, setup-script, and
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
- Pro: unlimited hosts, mosh, unmetered built-in and custom agent command
  chips, Claude Code/Codex agent alerts from tmux sessions and plain shells,
  the HISTORY panel (a Claude Code session's prompt history read from
  Claude's own session file, with full text where the TUI truncates, plus
  jump-back-to-message on tmux tabs — Claude Code only; Codex/Pi history
  was deliberately withdrawn 2026-07-16 to keep the jump exact), and
  custom-theme editing.
- Existing/synced hosts, existing mosh configuration, and existing custom
  themes are never deleted or disabled when Pro is absent.

When this split changes, update this document, the local StoreKit catalog,
the app description and release notes, review notes, paywall copy, affected
screenshots, and the pricing plan together. Never advertise a gate before the
corresponding binary ships.

When the price changes, also update the DEBUG review-preview default in
`EntitlementStore.prepareDebugPaywallPreview`, its StoreKit tests, the
`MULTIPLEX_AUTO_PAYWALL` price wording in `AGENTS.md`, and the review screenshot.
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
| App listing metadata and review notes | `bundle exec fastlane store_metadata` (both platform versions by default; optional `platform:ios\|visionos`) |
| Public App Store screenshots | `bundle exec fastlane store_screenshots` |
| iOS (iPhone + iPad) + visionOS TestFlight binaries | `bundle exec fastlane beta` |
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
