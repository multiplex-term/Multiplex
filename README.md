# Multiplex

A spatial SSH terminal for remote **tmux** — visionOS first, with iPadOS and iPhone alongside. Its deck is a fleet-wide monitor wall: hosts probe concurrently, sessions appear as live `capture-pane` tiles, and each attach opens in its own window. [herdr](https://herdr.dev) is also available per host.

[App Store](https://apps.apple.com/us/app/multiplex-ssh-tmux-terminal/id6790074057)
· [multiplexterm.dev](https://multiplexterm.dev) ·
[Design rationale](DESIGN.md) · [Contributing](CONTRIBUTING.md) · [Contributor guide](AGENTS.md)

![The deck: a live monitor wall of tmux and herdr sessions](docs/visionos-deck.png)

## What it does

- **Fleet-wide deck:** live tmux and herdr sessions across every host, with password, OpenSSH-key, or `mpx bind` setup and iCloud Keychain sync.
- **Real terminal windows:** spatial scenes on visionOS, Stage Manager on iPad, and an adaptive iPhone shell. Tabs can move or merge without reconnecting.
- **Agent awareness:** detects Claude Code, Codex, Pi, and Grok Build; surfaces questions, permissions, and completed turns on the wall and through notifications.
- **Purpose-built input:** keyboard-focus arbitration, key rail with hold-CTRL Key Commands (saved chords and text macros), IME, dictation, remote scrolling, tmux Copy Mode, and text selection.
- **More than a shell:** docked web and file viewers, SFTP uploads, optional clean-room mosh, widgets, Shortcuts, deep links, and custom themes.


<div align="center">
  <video src="https://github.com/user-attachments/assets/90e6e0f2-cdab-4e8f-993a-e6fc5359d7c6" alt="Multiplex AVP demo" width="400" />
</div>

> Vision Pro: Running Claude Code on herdr -> File Viewer -> Inline browser (using [serve-sim](https://github.com/EvanBacon/serve-sim)) -> send create PR message by press Agent bar key.

<div align="center">
  <video src="https://github.com/user-attachments/assets/d25aa980-f3d3-4910-856b-836c3eec20cc" alt="Multiplex iPad demo" width="400" />
</div>

> iPad Pro: Running pi on herdr -> File Viewer -> Inline browser -> send create PR message by press Agent bar key.

Some features require Multiplex Pro; see [`docs/store-metadata.md`](docs/store-metadata.md). This repository contains the complete app.

## Building

Requires Xcode with the visionOS SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The project is generated, so edit `project.yml`, not the `.xcodeproj`.

```sh
xcodegen generate
xcodebuild -project Multiplex.xcodeproj -scheme Multiplex \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -derivedDataPath DerivedData build
```

Use the `MultiplexTests` scheme for unit tests and `./Tools/build.sh lint` for linting. Keep `-derivedDataPath DerivedData`, and do not build visionOS and iOS against it concurrently. Minimum visionOS 1.0 / iOS 17. See [`AGENTS.md`](AGENTS.md) for the contributor workflow and architecture.

## End-to-end without a remote server

The local harness runs a user-mode sshd on `127.0.0.1:2222` without touching `~/.ssh`:

```sh
./Tools/dev-sshd/harness.sh start   # keys + sshd + writes state/seed.json
./Tools/dev-sshd/harness.sh demo    # tmux sessions: main, scratch, deploy, agent
./Tools/dev-sshd/harness.sh herdr   # herdr sessions with deterministic states
./Tools/dev-sshd/harness.sh stop
```

Point `MULTIPLEX_SEED_HOST` at `Tools/dev-sshd/state/seed.json` to seed a DEBUG build. See [`docs/agents/e2e-headless.md`](docs/agents/e2e-headless.md) for the full headless workflow.

## Third-party code

| Library | Version | Role |
| --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.15.0, vendored | Terminal emulator |
| [Citadel](https://github.com/orlandos-nl/Citadel) | 0.12.0, exact | SSH, exec, SFTP, and key parsing |
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) | 0.3.5, vendored | SSH transport dependency |

Citadel 0.12.0 is pinned because 0.12.1 changed its `swift-nio-ssh` source to an unaudited fork. The mosh client is a clean-room implementation. The complete audited inventory and license texts live in `Multiplex/Models/LicenseCatalog.swift`.

## Known limits

- PATH fixups assume a POSIX-like login shell; csh/fish may need tmux on the default PATH.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
