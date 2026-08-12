# fastlane — one-time setup

```sh
bundle install                      # installs fastlane from Gemfile
cp fastlane/.env.sample fastlane/.env   # fill in (git-ignored)
```

## 1. App Store Connect API key

Users and Access → Integrations → App Store Connect API → **Team Keys** →
generate (role: **App Manager**). Download the `.p8` into `fastlane/keys/`
(git-ignored), and put key id / issuer id / path into `.env`.

## 2. App record — ✅ created 2026-07-12

- Name: `Multiplex — SSH tmux Terminal` · SKU `multiplex`
- Bundle ID: `app.multiplexterm.multiplex` · **Apple ID `6790074057`**
- Platforms: iOS + visionOS (one record, two platforms)

Still to do by hand in the record (deliver doesn't manage these): the
App Privacy declaration (**Data Not Collected**), age rating (all None → 4+),
and confirmation that the app itself is Free and available in the intended
storefronts. IAP **6790252556**
(`app.multiplexterm.multiplex.pro`, non-consumable) is `READY_TO_SUBMIT`: its
en-US localization, $19.99 USA-base/equalized price, review note,
availability, and processed 2064×2752 review screenshot were configured
2026-07-13 through the App Store Connect API. Built-in
`deliver` still does not manage IAP metadata; a custom Spaceship lane can call
Apple's public endpoints. Details are in
`docs/appstore/release-playbook.md`. Export compliance is declared as exempt
standard encryption in the app plist; distributing in France still requires
the France-specific step in the playbook.

## 3. Signing

Lanes archive with `CODE_SIGN_STYLE=Automatic` + `-allowProvisioningUpdates`
using the API key — no match/profiles repo needed for a one-person team.
Xcode must be signed into the account once (Settings → Accounts).

## 4. Sanity checks

```sh
bundle exec fastlane tests                     # unit tests on the visionOS sim
bundle exec fastlane archive platform:visionos # first archive, watch signing
bundle exec fastlane beta                      # both platforms → TestFlight internal
```

visionOS in fastlane rides the `xros` platform value (pilot/gym support it;
current fastlane required — `bundle update fastlane` if pilot rejects the
platform). `store_metadata` uploads to both platform versions by default;
pass `platform:ios` or `platform:visionos` to update only one. Shared listing
fields live in `fastlane/metadata`, while each locale's
`description_ios.txt` / `description_visionos.txt` and
`release_notes_ios.txt` / `release_notes_visionos.txt` are selected for the
matching version. The lane maps the public `visionos` option to deliver's
`xros` value. `store_screenshots` also runs one deliver per platform — pushing
the 3840×2160 set at the iOS version fails with "Display Type Not Allowed"
(ASC screenshot sets hang off a platform version). If the `xros` deliver
still refuses the set, upload it in
the ASC UI (it changes rarely). Metadata/screenshot writes need the API key
role **App Manager** — a Developer-role key uploads TestFlight builds fine but
deliver fails with "forbidden for security reasons".

## 5. Before review

- `fastlane/metadata/review_information/` — the whole directory is left out
  of git on purpose (reviewer contact PII + the demo host coordinates). On a
  fresh machine, recreate its `*.txt` files or rely on the `.env` fallbacks;
  `phone_number.txt` is one line (`+886…`).
- Demo host up + credentials in `.env` (`DEMO_SSH_USER/PASSWORD`) and in the
  ASC demo-account fields — runbook in the release playbook.
- `fastlane/testflight-whats-new.txt` written for the build.

`review_information/` is the single source for App Store review *and*
TestFlight's Beta App Review: the Fastfile reads it once and maps it into
deliver's and pilot's respective spellings. The directory is git-ignored; the
`.env` keys stand in for the short fields when a file is absent, and anything
still empty is a hard error before a lane archives anything.

## 6. TestFlight external group

```sh
bundle exec fastlane testflight_group
```

Creates `Public Beta` (name overridable with `TESTFLIGHT_EXTERNAL_GROUP`) as
an **invitation-only** external group — no public link, so testers join by
emailed invite. The lane is idempotent, and it disables a public link if one
appears later. `beta external:true` runs it first, because pilot silently
ignores a `groups:` name that does not exist yet; add `submit_review:false` to
put the build in the group without starting Beta App Review.

## 7. TestFlight Test Information

```sh
bundle exec fastlane testflight_info
```

The app-level record testers read in TestFlight: description
(`fastlane/metadata/<locale>/beta_app_description.txt`), feedback email (the
review contact), and the listing's marketing/privacy URLs. App Store Connect
**requires the description before it will accept an external submission** —
without it a build uploads and joins the group, then the submission fails with
`Beta App Description is missing`. `beta external:true` pushes the same record
before it archives anything, so this lane is only needed to update the text on
its own, or to repair a submission that was blocked on it.

pilot's own `beta_app_description` option is deliberately unused: it only
patches locales that already exist, so on an app that never had Test
Information it writes nothing at all.
