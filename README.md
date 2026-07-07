# Multiplex

A spatial SSH terminal for people who live inside remote tmux sessions.
**visionOS first, iPadOS alongside.** Every tmux session gets its own window
you can place around the room; the deck shows each host's sessions live —
window count, active window, activity — before you attach.

*Design rationale and tokens: [DESIGN.md](DESIGN.md).*

![Deck with live session cards](docs/visionos-deck.png)

![Two sessions attached, each in its own spatial window](docs/visionos-multiwindow.png)

## What it does

- **Hosts deck** — add SSH hosts (password or OpenSSH ed25519/RSA key, secrets
  in the Keychain). Selecting a host connects and probes tmux over an exec
  channel: one round-trip lists every session and its windows.
- **tmux session cards** — each card shows the *window spine* (one cell per
  tmux window, the active one lit, activity flagged), attach state, and window
  count. **Attach** opens the session in its own window
  (`tmux attach-session`). **New Session** runs `tmux new-session -A`.
  **Shell** opens a plain login shell, no tmux.
- **Terminal windows** — each terminal is its own SwiftUI scene
  (`WindowGroup(for: TerminalRoute.self)` + `openWindow`): independent
  placement on visionOS, real multiple scenes on iPadOS (Stage Manager /
  split screen). SwiftTerm renders xterm-256color; resizing the window sends
  PTY window-change to the remote. **Detach** closes the channel — tmux keeps
  the session; the deck still shows it.

## Architecture

```
SwiftUI (Deck window + N Terminal windows)
   │
   ├── HostStore            hosts.json in App Support; secrets in Keychain
   ├── ConnectionHub        one HostConnectionModel per host (probe connection)
   │      └── TmuxProbe     list-sessions/-windows format strings + parser
   └── TerminalSessionController   one per terminal window
          └── SSHConnection (actor) ── Citadel ── SwiftNIO SSH
                 ├── exec channel      tmux probing
                 └── PTY shell channel bytes ⇄ SwiftTerm.TerminalView
```

tmux attach must run inside a PTY. The PTY opens the user's login shell and
Multiplex injects `exec tmux attach-session -t '<name>'` as the first stdin
line with terminal echo disabled in the PTY modes — silent handoff, works
with any POSIX-ish login shell, and channel close = clean detach.

## Libraries

| Library | Version | Why |
| --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.13.0 (exact) | The only mature native-Swift terminal emulator view; declares visionOS support; MIT. |
| [Citadel](https://github.com/orlandos-nl/Citadel) | 0.12.0 (exact) | Async/await SSH on SwiftNIO: PTY shell + resize, exec, and OpenSSH key parsing (ed25519/RSA, encrypted keys included). |

**Supply-chain note.** Citadel is deliberately pinned to **0.12.0**: 0.12.1
switched its `swift-nio-ssh` dependency from the maintainer's own fork
(`Joannis/swift-nio-ssh`) to an unaudited personal fork. Diff/review before
upgrading — this is the app's transport security layer.

**Vendored `swift-nio-ssh`.** `Vendor/swift-nio-ssh` is Citadel 0.12.0's
resolved dependency (`Joannis/swift-nio-ssh` @ `0.3.5`, revision
`791437a67f5394b13060314c778c0f63124803b1`, Apache-2.0) vendored as a local
package override — same package identity, so SwiftPM prefers it over the
remote. Two reasons: the fork's `NIOSSH` target uses `import NIO` without
declaring that product (rejected by Xcode 27's module resolution — the only
change here is that one-line manifest fix in `Package.swift`), and vendoring
freezes the SSH transport code against upstream fork churn.

**Host keys.** Connections currently use `.acceptAnything()` host-key
validation — fine for development, not for shipping. The TODO before any
release is trust-on-first-use pinning via Citadel's `.custom` validator.

## Building

Requires Xcode with the visionOS SDK, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
xcodebuild -project Multiplex.xcodeproj -scheme Multiplex \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

The `Multiplex` scheme also builds for iPad (`platform=iOS Simulator,name=iPad
Pro 13-inch (M5)`). Unit tests cover the tmux probe parser and route commands:

```sh
xcodebuild -project Multiplex.xcodeproj -scheme MultiplexTests \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' test
```

## End-to-end verification without a remote server

`Tools/dev-sshd/harness.sh` runs a **user-mode sshd on 127.0.0.1:2222**
(pubkey-only, its own host key and authorized_keys under `Tools/dev-sshd/state/`,
never touching `~/.ssh`) and seeds demo tmux sessions:

```sh
./Tools/dev-sshd/harness.sh start   # keys + sshd + writes state/seed.json
./Tools/dev-sshd/harness.sh demo    # tmux sessions: main, scratch, deploy
./Tools/dev-sshd/harness.sh stop
```

Because the simulator shares the Mac's network, launching the app with the
`MULTIPLEX_SEED_HOST` environment variable pointing at `state/seed.json`
(DEBUG builds only) imports a ready-to-use `devbox` host — connect, watch the
session cards fill in, attach, and drive the session from the Mac side with
`tmux send-keys` to see bytes stream into the window.

## Verified

End-to-end in the **visionOS 26.4 simulator** against the harness above
(real sshd, real tmux 3.6a):

- Citadel connects over ed25519 pubkey auth; the deck probes and renders all
  sessions with correct window spines (active window, counts).
- Attach opens a per-session spatial window; **two sessions attached
  concurrently** over independent SSH connections
  (`docs/visionos-multiwindow.png`).
- `tmux select-window` / `send-keys` on the host render **live** in the app —
  the full sshd → PTY → tmux → SwiftTerm pipeline
  (`docs/visionos-terminal-sendkeys.png`).
- Detach closes the channel; tmux keeps the session and the deck reflects it.
- The tmux-attach handoff is silent (PTY opens with ECHO off for command
  routes), and the injected command exercises the same stdin `write()` path
  keyboard input uses.
- Unit tests (probe parser, quoting, route commands) pass on the visionOS
  simulator; the app also builds and runs on the iPad Pro 13-inch simulator
  (`docs/ipad-deck.png`).

## Known limits (v1)

- Host-key verification is accept-all (see above) — dev builds only.
- Connections drop when iPadOS suspends the app in the background; reattach
  is one tap (tmux keeps the session — that's the point of tmux).
- The remote-command PATH fixups assume a POSIX-ish login shell (bash/zsh);
  csh/fish users may need tmux on the default PATH.
- iPhone is out of scope (iPad + Vision Pro device families).
