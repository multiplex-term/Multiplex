# Release playbook — TestFlight & App Store

How a commit on `main` becomes a TestFlight build and, eventually, an App
Store release. Store copy lives in `fastlane/metadata/` (uploaded verbatim by
`fastlane store_metadata`); screenshot design in
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
- Build number = `git rev-list --count HEAD`, injected at archive time by the
  `archive` lane. Both platform binaries of a release share it; never reuse a
  (version, build) pair. A hotfix commit bumps it automatically.

## TestFlight cadence

**Internal group ("Core")** — you + up to 100 App Store Connect users. No
review, available minutes after processing. `bundle exec fastlane beta` at
whatever cadence is useful; write `fastlane/testflight-whats-new.txt` first
(it becomes the build's What to Test).

**External group ("Multiplex Beta")** — real testers via public link.
The **first** external build (and later ones with significant changes) goes
through Beta App Review (~1 day). It needs the demo host below and the review
notes already in `fastlane/metadata/review_information/notes.txt` — the
`beta` lane sends both with `external:true`:

```sh
bundle exec fastlane beta external:true
```

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
Feedback: screenshot in TestFlight, or jhen@bricks.tools
```

Builds expire after 90 days — ship something monthly or testers go dark.

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

Set up the IAP by hand (deliver doesn't manage IAPs): non-consumable
`app.multiplexterm.multiplex.pro`, display name **Multiplex Pro**, price tier
$19.99, Family Sharing on if desired, plus its own review screenshot (the
paywall screen) — IAPs are reviewed with images too. Submit the IAP together
with the app version.

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
| 2 | **Real StoreKit 2 purchase** (or hide Pro UI) | A visible "coming soon" purchase button is rejectable (2.1 completeness / 2.3 accuracy). `EntitlementStore` is a stub; RELEASE builds lock Pro with no way to buy. | `Services/EntitlementStore.swift`, `ProPaywallView` |
| 3 | **Ship all free-tier gates and the IAP together** | Never un-free a feature post-launch (`local-plan/pricing-strategy.md` §7). Gate line decided 2026-07-12: host cap, mosh gate, agent-strip taste meter (§5 there). | pricing-strategy.md |
| 4 | **Privacy policy live** at `multiplexterm.dev/privacy` | URL is required metadata; draft ready in `docs/appstore/privacy-policy.md`. | — |
| 5 | **Support URL live** at `multiplexterm.dev` | Required; a page with the app name + contact email is enough. | — |
| 6 | **France excluded or French encryption declaration filed** | Apple requires the French declaration for standard app-provided crypto only when distributing in France. | ASC availability / App Encryption Documentation |
| ~~7~~ | ~~App name check~~ **Done 2026-07-12**: record created as "Multiplex — SSH tmux Terminal", bundle id `app.multiplexterm.multiplex`, Apple ID `6790074057`. | — | ASC |
