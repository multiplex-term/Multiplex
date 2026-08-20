# Contributing

Thanks for helping with Multiplex.

## Bug fixes and small improvements

Welcome anytime — open a pull request directly. Typo fixes, crash fixes,
small UI polish, doc corrections, and the like need no prior discussion.

## New features

Open an issue first and wait for a go-ahead before sending a PR. Multiplex is
opinionated (see `DESIGN.md` and `docs/agents/`), and agreeing on the shape up
front avoids work that can't be merged. Feature PRs without a linked issue may
be closed.

## Language support

Translation PRs are welcome without prior discussion — a new language, or
corrections to an existing one (currently Traditional Chinese and Japanese).
It's recommended that you be a native speaker or a learner of the language,
though this isn't a hard requirement.

Read [`docs/agents/i18n.md`](docs/agents/i18n.md) first. In short: strings
live in the String Catalogs (`Multiplex/Localizable.xcstrings`,
`MultiplexWidgets/Localizable.xcstrings`); the glossary and string tiers
there apply (the TALLY micro chrome deliberately stays English); a new
locale should also mirror `fastlane/metadata/en-US` for the App Store
listing. `./Tools/build.sh strings` syncs the catalogs after code changes.

## Before you send a PR

- Edit `project.yml`, never the `.xcodeproj`; run `xcodegen generate`.
- `./Tools/build.sh lint` passes with zero violations.
- Unit tests pass (`MultiplexTests` scheme).
- User-visible changes get a line in `fastlane/testflight-whats-new.txt`.

Full workflow and architecture: [`AGENTS.md`](AGENTS.md).
