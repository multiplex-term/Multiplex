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
| Platforms | iPadOS and visionOS in one app record |
| Current version | 1.0 |
| Minimum OS | iPadOS 17.0; visionOS 1.0 |
| Target release model | Free download with one non-consumable Pro unlock; confirm the base-app price manually |
| Primary category | Developer Tools |
| Secondary category | Utilities |
| Privacy declaration | Target: Data Not Collected; set/confirm manually in App Store Connect |
| Age rating | Target: all questionnaire answers None → 4+; complete/confirm manually |
| Base-app price | Free; confirm in App Store Connect before submission |
| Storefronts | Confirm intended coverage in App Store Connect; France needs the encryption step in the release playbook |

The canonical localized listing copy is stored in
[`fastlane/metadata/en-US/`](../fastlane/metadata/en-US/):

- name, subtitle, promotional text, description, keywords, release notes;
- support, marketing, and privacy URLs;
- categories and copyright in [`fastlane/metadata/`](../fastlane/metadata/);
- App Review contact/demo flow in
  [`fastlane/metadata/review_information/`](../fastlane/metadata/review_information/).

Do not duplicate the complete description in this document. The files above
are what `fastlane store_metadata` uploads.

## Multiplex Pro

Last remote readback: **2026-07-13 — `READY_TO_SUBMIT`**.

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
| Review material | Review note plus the processed review screenshot below |

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

- Free: one host, full SSH spatial windows/tabs/merge, all-pane agent detection
  and wall telemetry with active-pane-aware helpers, built-in terminal themes,
  a most-used tmux shortcut dropdown on
  both platforms (including touch-native copy-mode selection and explicit
  exit), iCloud Keychain sync, and ten slash-command chip taps per local
  calendar day.
- Pro: unlimited hosts, mosh, unmetered agent command chips, agent alerts, and
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
| [`docs/appstore/iap-review-screenshot.jpg`](appstore/iap-review-screenshot.jpg) | Canonical 2064×2752 JPEG uploaded to App Store Connect (800,625 bytes) |
| [`docs/appstore/iap-review-screenshot.png`](appstore/iap-review-screenshot.png) | Lossless 2064×2752 source/export retained for regeneration (4,584,585 bytes) |

The current image is fully processed in App Store Connect. It shows the real
locked `ProPaywallView`, including the one-time US $19.99 purchase CTA and
Restore Purchases action. It is not a hand-built mock. In DEBUG builds,
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
`fastlane/screenshots/en-US/`; do not mix the two screenshot sets.
As of 2026-07-13 the public gallery set has not been generated or uploaded—the
directory contains only its placeholder.

## Fastlane and manual boundaries

“Not supported by Fastlane” here means **not handled by this project's normal
built-in `deliver` lanes**. A custom Fastlane lane may use Spaceship or Apple's
App Store Connect API for supported endpoints, including IAP localization,
price, availability, and review-image upload. Some account/app-level endpoints
can still be permission-gated or require App Store Connect UI work.

| Work | Current route |
| --- | --- |
| App listing metadata and review notes | `bundle exec fastlane store_metadata` |
| Public App Store screenshots | `bundle exec fastlane store_screenshots` |
| iPadOS + visionOS TestFlight binaries | `bundle exec fastlane beta` |
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
