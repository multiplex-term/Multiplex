# Multiplex — Privacy Policy

*Draft — publish at `https://bricks.tools/multiplex/privacy` before
submission (ship-blocker #4 in the release playbook).*

**Effective:** <date of publication>

Multiplex is an SSH/tmux terminal for Apple Vision Pro and iPad, made by
Jhen-Jie Hong (Bricks). It is built so that we cannot see your data.

## What we collect

Nothing. Multiplex has no accounts, no analytics, no crash-reporting SDKs,
no advertising, and no servers of ours. We never see your hostnames,
credentials, keys, terminal content, or usage.

## Where your data lives

- **Host records and secrets** (addresses, usernames, passwords, private
  keys) are stored in the device Keychain. If iCloud Keychain is enabled,
  Apple syncs them between your devices **end-to-end encrypted**; we cannot
  read them, and neither can Apple.
- **Terminal traffic** flows directly between your device and your servers
  over SSH (or mosh), encrypted in transit. It never passes through any
  third party of ours.
- **Themes and preferences** are stored locally on device.

## Permissions the app may request

- **Notifications** — only to alert you when a CLI agent in one of your
  sessions finishes or needs input. Processed entirely on device; optional.
- **Local Network** — only to connect to SSH hosts on your own network.

## Purchases

Payments are processed by Apple. We receive no payment details.

## Data shared with third parties

None. There is no third party.

## Children

Multiplex is a developer tool, rated 4+, and collects no data from anyone.

## Changes

Changes to this policy will be posted at this URL with a new effective date.

## Contact

jhen@bricks.tools
