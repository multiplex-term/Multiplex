# Release surfaces: app icon, release notes, store metadata

Split from AGENTS.md — read before committing any user-visible change.

- **App icon is a hand-authored Icon Composer package** (`AppIcon.icon`;
  spec + bake-off in `DESIGN.md`); icon.json lists groups
  frontmost-first. Validate headlessly with `xcrun actool AppIcon.icon
  --compile <dir> --platform iphonesimulator
  --minimum-deployment-target 17.0 --app-icon AppIcon
  --output-partial-info-plist <dir>/p.plist` — zero warnings today; the
  emitted PNGs are the flattened pre-26 fallbacks. Icon Composer has no
  visionOS target, so `Assets.xcassets/AppIcon.solidimagestack` is
  **baked, not hand-drawn**: `swift Tools/bake-vision-icon.swift`
  renders with Icon Composer's own `ictool` and unblends the layers,
  verifying the restack recomposites the reference (≤0.5/255). Never
  edit the three layer PNGs by hand — edit `AppIcon.icon` and re-bake.
- **The release notes are one content model with two renderings, and the
  launch card is priced like the interruption it is** (`ReleaseNotes` pure +
  tested; `WhatsNewViewController` / `ReleaseLogViewController`;
  `ReleaseNotesStore`). The card shows FOUR changes, no navigation bar, and
  ends inside one phone screen; FULL NOTES and Settings ▸ About ▸ What's New
  both open the full banked record. Bake-off record: the log alone was
  dismissed at the fold, the card alone left eight changes unread, so each
  absorbs the other's failure. Load-bearing details:
  - **A missing stamp is not a first run.** Every device updating from a
    version that never wrote one has `lastSeenVersion == nil`, so
    `ReleaseNotesGate` takes `installHasPriorUse` (the deck answers it with
    its locally cached host list) to tell "updated" from "installed today".
    Reading nil as new silences the notes for exactly the people they are
    for; reading it as updated shows a changelog to someone meeting the app.
    Pinned by `ReleaseNotesTests` + `DeckWindowUIKitTests`.
  - **Once per MINOR version** (1.3.0 → 1.3.1 must not re-open it), stamped
    on presentation rather than dismissal (a force-quit mid-animation must
    not make it recurring), and **device-local `UserDefaults`** — updating
    on iPad must not consume the notice on Vision Pro, so it never rides the
    synced Host record.
  - **`ReleaseNotes.version` is the notes' own release, not the bundle's**
    short version: a patch build must not present itself as a release with
    its own notes.
  - Entries and highlights are platform-filtered the way
    `TerminalGuide.entries(for:)` is — GLASS never reaches an iPad, keep-alive
    never a Vision Pro — and each platform's FOURTH card row is whichever
    change is about it. The card's "also in 1.3" line is DERIVED from the
    entries no shown highlight `covers`, so it can never re-offer something
    the card just said or miscount the rest.
  - It rides the deck's presentation queue as its own `PresentationKind`, so
    it waits behind the app-lock veil; it defers while
    `ExternalActionRouter.hasPendingActions` (a widget deep link asked for
    something specific), and it needs real deck width — the compact shell
    clips its deck pane to zero, and a later layout pass retries. FULL NOTES
    *supersedes* the card rather than stacking a second sheet, the same
    reason the licenses page is its own modal.

`docs/store-metadata.md` is the source of truth for the App Store listing,
Multiplex Pro IAP, automation boundaries, and review assets. Whenever a
user-visible feature, Free/Pro allocation, price, platform, requirement,
permission, privacy behavior, or reviewer flow changes, update that
document AND reconcile `fastlane/metadata/`, review notes, release notes,
`Multiplex.storekit`, and screenshots in the same change. App Store
descriptions are platform-specific:
`fastlane/metadata/*/description_{ios,visionos}.txt`; never add a shared
`description.txt`, which can put Vision Pro-only claims on the iOS listing.
Paywall / Pro
value changes regenerate the real-paywall IAP review assets at
`docs/appstore/iap-review-screenshot.{png,jpg}` (private review material,
separate from public `fastlane/screenshots/`). Price changes also update
`EntitlementStore`'s DEBUG review-preview default, its tests, and the
`MULTIPLEX_AUTO_PAYWALL` wording in `e2e-headless.md`. Record App Store
Connect state
only after a dated remote readback; standard `deliver` lanes do not manage
IAP metadata/review images (Spaceship/API automation or the UI).

**Before committing a user-visible change, add it to the TestFlight
changelog** — `fastlane/testflight-whats-new.txt`, uploaded verbatim by the
`beta` lane as What to Test. It stages the NEXT build: append to existing
entries, never replace (create the file if absent). Write it as a test
script for testers — what changed, where, what to try (template in
`docs/appstore/release-playbook.md`); refactors, build plumbing, docs, and
test-only changes get no entry. This is NOT the App Store release notes —
those are the per-locale `fastlane/metadata/*/release_notes_{ios,visionos}
.txt`, written per *release* in customer voice under the metadata rules;
never write a commit's changes into them as a side effect.

The **landing site** (marketing URL + privacy policy) lives in
**multiplex-home** (`github.com/jhen0409/multiplex-home` — Astro on
Cloudflare Workers; manual `npm run deploy`, decoupled from git), serving
`multiplexterm.dev`. Landing changes go through PRs, and ride the same
change as the metadata when features, pricing, platforms, or privacy
behavior change. Bake-off records stay here under `docs/landing/`.
