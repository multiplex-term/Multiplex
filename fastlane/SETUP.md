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
and the IAP (`app.multiplexterm.multiplex.pro`, non-consumable, $19.99) —
details in `docs/appstore/release-playbook.md`. Export compliance is declared
as exempt standard encryption in the app plist; distributing in France still
requires the France-specific step in the playbook.

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
platform). Known gap: **deliver** can be behind on visionOS *screenshot*
uploads — if `store_screenshots` refuses the 3840×2160 set, upload those in
the ASC UI (they change rarely; metadata still uploads fine).

## 5. Before review

- `fastlane/metadata/review_information/phone_number.txt` — create it (one
  line, `+886…`); left out of git on purpose.
- Demo host up + credentials in `.env` (`DEMO_SSH_USER/PASSWORD`) and in the
  ASC demo-account fields — runbook in the release playbook.
- `fastlane/testflight-whats-new.txt` written for the build.
