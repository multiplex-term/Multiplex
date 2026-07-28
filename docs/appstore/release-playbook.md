# Release playbook — TestFlight & App Store

How a commit on `main` becomes a TestFlight build and, eventually, an App
Store release. Store copy lives in `fastlane/metadata/`; `fastlane
store_metadata` sends shared copy to both platform versions and selects each
locale's matching iOS or visionOS release notes. Screenshot design lives in
`docs/appstore/screenshots-plan.md`; one-time account setup in
`fastlane/SETUP.md`.

```
xcodegen ──► gym (iOS) ─────► pilot (ios)  ─┐   internal testers (instant)
         └─► gym (visionOS) ► pilot (xros) ─┤─► TestFlight ─► external group (Beta App Review)
                                            │
                       deliver (metadata + screenshots)
                                            └─► App Store review ─► release
```

One app record, **two platform binaries**: the same target archives once per
platform (`generic/platform=iOS`, `generic/platform=visionOS`) and both are
uploaded per release. TestFlight and the store page show them under one app.
Universal purchase is automatic — one bundle id, buy once, both devices.

## Versioning

- `MARKETING_VERSION` lives in `project.yml` — bump by hand per release.
- Build number follows `YYYYMMDDN` (`N` is the day's counter, `0`–`9`). The
  `archive` and `beta` lanes persist the next value to `project.yml` before
  generating the project. Both platform binaries of a release share it; never
  reuse a (version, build) pair. More than ten builds in one day requires the
  next calendar day. The app plist expands `CURRENT_PROJECT_VERSION`, and the
  archive lane verifies the exported bundle kept that exact value.

## TestFlight cadence

**Internal group ("Internal")** — you + up to 100 App Store Connect users. No
review, available minutes after processing. `bundle exec fastlane beta` at
whatever cadence is useful; write `fastlane/testflight-whats-new.txt` first
(it becomes the build's What to Test).

**External group ("Public Beta")** — real testers, **invitation only**: the
group is created with no public link, so a seat is an emailed invite and
cannot be forwarded on. `bundle exec fastlane testflight_group` creates it
(and takes a public link away again if one ever appears); `beta external:true`
calls the same helper first, because pilot *silently skips* a group name App
Store Connect does not know.

The **first** external build (and later ones with significant changes) goes
through Beta App Review (~1 day). Beta App Review gets the **same record as
App Store review** — one hash in the Fastfile feeds deliver and pilot both,
sourced from `fastlane/metadata/review_information/` with `.env` covering the
two files kept out of git. So the demo host below and
`review_information/notes.txt` are all it needs:

External testing additionally needs **Test Information** — the app-level
description testers read, in
`fastlane/metadata/<locale>/beta_app_description.txt`. `beta external:true`
pushes it (with the review contact as the feedback address and the listing's
marketing/privacy URLs) before it archives anything; `bundle exec fastlane
testflight_info` pushes it alone. It is not optional: an unset record uploads
and joins the group fine, then fails the submission call with
`Beta App Description is missing`.

```sh
bundle exec fastlane beta external:true                     # add + submit for review
bundle exec fastlane beta external:true submit_review:false # add, submit later
```

Adding a build to the group and submitting it for Beta App Review are two
separate calls, so `submit_review:false` takes only the first: the build lands
in Public Beta and the review submission waits for the App Store Connect UI
(or a later run). Use it to stage a build before committing it to a ~1-day
review queue. Apple still gates external testers on that review — until it
passes, the staged build sits in the group untestable. The Beta App Review
record (contact, demo host, notes) is written either way, so a later
submission already has everything.

What-to-Test template (keep it a test script, not marketing):

```
NEW IN THIS BUILD
• <feature> — <where to find it>

PLEASE TRY
1. Add your own host (key or password) — did the wall probe everything?
2. Attach two sessions, place the windows apart, type in both.
3. Merge one window into the other; move the tab back out.
4. If you run Claude Code/Codex in tmux: do the wall badge + alerts fire?

KNOWN
• <current sharp edges>
Feedback: screenshot in TestFlight, or iainst0409@gmail.com
```

Builds expire after 90 days — ship something monthly or testers go dark.

### Pro transaction sign-off

Xcode 27 beta can load the real local non-consumable catalog, but its 27.0
simulators mark locally created transactions `invalidDeviceVerification` and
its pre-27 runtimes cannot load the current StoreKit test session. The required
unit suite therefore verifies the complete app-owned lifecycle through the
injected `ProStoreClient` (verified/unverified purchase, pending completion,
duplicate suppression, Ask-to-Buy decline recovery, restore, authority-ordering
races, errors, revocation and expiry), while this
signed TestFlight/Sandbox pass remains mandatory before external beta:

1. Start locked on iPad; buy Pro and verify immediate unlock plus relaunch.
2. Install the visionOS build with the same sandbox Apple ID; verify the
   current entitlement unlocks automatically, then exercise Restore.
3. Exercise a second host, a fresh mosh toggle, unmetered slash chips, alerts,
   and custom-theme creation on both platforms.
4. Run Ask to Buy: verify approval unlocks automatically; in a separate run,
   decline, tap Restore Purchases, and confirm Purchase becomes retryable.
5. Clear/refund the sandbox purchase; verify new intents relock while existing
   hosts, synced hosts, existing mosh records and existing themes remain usable.

## Export compliance

Multiplex does **not** qualify for the "only HTTPS / OS crypto" answer: it
ships its own SSH implementation (vendored `swift-nio-ssh`) and a hand-rolled
AES-128-OCB3 for mosh. It *does* use only **standard, published algorithms**
(SSH, AES-OCB per RFC 7253) — no proprietary cryptography.

Apple's `ITSAppUsesNonExemptEncryption` key asks whether the app uses
**non-exempt** encryption; `NO` also covers apps that contain only exempt
encryption. Apple requires no App Store Connect documentation for published
industry-standard crypto outside its OS unless the app is distributed in
France. Therefore `project.yml` declares:

```yaml
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
```

`fastlane beta` also passes `uses_non_exempt_encryption: false` explicitly as
Pilot's fallback, so iOS and visionOS resolve to the same status even if a
platform build is still processing when Pilot first sees it. No Apple export
compliance code is expected in this configuration.

France is the exception: before enabling the French storefront, file the
French encryption declaration through App Store Connect; otherwise exclude
France at launch and add it after the declaration is accepted.

Separate from Apple's upload metadata, the U.S. BIS mass-market classification
may require a self-classification report for **5D992.c** software. That is a
developer export obligation, not an Apple plist code (not legal advice).

## App Store submission

`fastlane store_metadata` + `store_screenshots`, then submit in the ASC UI
(first submission is nicer by hand: age rating questionnaire — everything
"None" → 4+; App Privacy → **Data Not Collected**, which is true: no
accounts, no analytics, hosts/secrets live in the user's Keychain/iCloud
Keychain).

The non-consumable IAP `app.multiplexterm.multiplex.pro` is configured with
display name **Multiplex Pro**, a $19.99 USA-base/equalized price, all-territory
availability, and review notes. App Store Connect reports it
`READY_TO_SUBMIT`; its 2026-07-13 paywall screenshot is processed, while the
refreshed 2026-07-16 asset (`docs/appstore/iap-review-screenshot.jpg`, updated
for the Pro prompt-history copy; full-screen capture, not the earlier Stage
Manager staging) still needs upload + processing before submission. Submit the
IAP together with the first app version.
Built-in `deliver` does not manage IAP metadata; custom Spaceship
code can call Apple's public IAP endpoints, including the review-image
reserve/upload/commit flow.

### Reviewer demo host — yes, it's required

Guideline 2.1 (App Completeness): reviewers must be able to exercise the app
fully, including "app-specific resources" like a server. An SSH client with
no reachable host is an empty screen → near-certain "we were unable to
assess" rejection. Providing a host also removes their incentive to type
random credentials at your error paths.

The runbook is code: **`Tools/review-host/`** — a Dockerfile + compose file
run the whole box as a container on any US-West VPS (Hetzner Hillsboro
recommended, ~$5/mo, left running permanently; **rebuild the image** to pick
up security updates — host keys persist in a volume, so the SSH identity is
stable). A cloud-init variant covers Docker-less VMs, and `verify.sh` is the
pre-submission check either way. What it provisions: password auth
for `review` only with every SSH forwarding surface disabled, no sudo,
tmux + mosh-server, boot/nightly-reseeded demo sessions (including the
disclosed agent stub that makes the Pro strip demonstrable), and a
zero-egress firewall stance (host `DOCKER-USER` rules / in-VM ufw — the box
can't relay spam or proxy traffic).

Two rules the automation can't enforce: the password goes into **both**
`fastlane/.env` and ASC's demo-account fields, and `verify.sh` runs the day
before every submission — updates are reviewed against this box too.

The same host and credentials serve Beta App Review (TestFlight external) —
`fastlane beta external:true` sends them from `.env`.

### Expected review friction

- **Camera permission** — requested in context only after FILE → Camera on
  iPad; Photos and Files use system pickers without broad library access.
- **Notifications permission** — requested in context (first agent event),
  purpose string ready; fine.
- **Local Network prompt** — only fires for LAN addresses; the demo host is
  public, so reviewers likely never see it. The usage string ships anyway.
- **Sign-in-required apps** must offer… nothing extra here: SSH credentials
  are the user's own infrastructure, not an account with the developer —
  4.8 (Login Services) and account-deletion rules don't apply.
- **visionOS screenshots** must show the app in an environment capture, not
  flat UI on black — the compositor handles this.
- **Pro features during review** — mosh and the unmetered strip sit behind
  the IAP; reviewers unlock it with a free sandbox purchase (the review
  notes say so), and the free tier's daily strip taps keep the agent strip
  demonstrable even without it.

## Ship-blockers — do these BEFORE external beta / submission

| # | Blocker | Why | Where |
| --- | --- | --- | --- |
| 1 | **Host-key TOFU pinning** | `.acceptAnything()` is fine for the sim, indefensible for real users' credentials; also the one security claim reviewers/users will test. | Citadel `.custom` validator; README "Known limits" |
| 2 | **Re-upload the refreshed Pro IAP review screenshot** | The 2026-07-13 image is processed and IAP `6790252556` is `READY_TO_SUBMIT`, but the 2026-07-15 local asset reflects the current two-host free-tier wording and still needs upload + processing. | ASC IAP `app.multiplexterm.multiplex.pro` |
| ~~3~~ | ~~**Ship all free-tier gates and the IAP together**~~ **Code complete 2026-07-13; host allowance raised 2026-07-15**: two-host add-intent cap, grandfathering mosh toggle, 10/day agent-command meter (built-in or custom), custom-theme mutation gate, and alert scheduling gate all ship with the StoreKit surface. Commerce policy has deterministic lifecycle tests; a live visionOS run proved 11 tap intents produce only 10 command sends and then the passive reset pill. | Never un-free a feature post-launch (`local-plan/pricing-strategy.md` §7). | pricing-strategy.md |
| 4 | **Privacy policy live** at `multiplexterm.dev/privacy` | URL is required metadata; draft ready in `docs/appstore/privacy-policy.md`. | — |
| 5 | **Support URL live** at `multiplexterm.dev` | Required; a page with the app name + contact email is enough. | — |
| 6 | **France excluded or French encryption declaration filed** | Apple requires the French declaration for standard app-provided crypto only when distributing in France. | ASC availability / App Encryption Documentation |
| ~~7~~ | ~~App name check~~ **Done 2026-07-12**: record created as "Multiplex — SSH tmux Terminal", bundle id `app.multiplexterm.multiplex`, Apple ID `6790074057`. | — | ASC |
| 8 | **Run the signed Pro transaction sign-off above** | Simulator StoreKit proves the catalog but Xcode 27 beta cannot verify its local JWS; TestFlight/Sandbox is the authoritative buy-once/cross-device proof. | iPad + Vision Pro, same sandbox Apple ID |
| 9 | **Confirm the app itself is Free and review storefront coverage** | The current API key receives 403 for app-level price/availability reads even though the IAP itself is `READY_TO_SUBMIT`. | ASC Pricing and Availability |
