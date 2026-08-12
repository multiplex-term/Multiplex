# Bind Host & the mpx CLI

Load-bearing decisions split from AGENTS.md.

- **A bound host is one the machine itself vouched for; the app's key goes
  out, never a private key** (`Models/Bind/`, `Services/Bind/`; protocol +
  shared vectors in the companion repo `multiplex-term/multiplex-cli`,
  `spec/bind-v1.md`). `mpx bind` runs on the machine being added and
  offers itself three ways: terminal QR, Bonjour announcement, and
  **opt-in** clipboard (`mpx bind --copy` — the payload is
  credential-grade and must not ride Universal Clipboard by default; the
  pane prints the command beside its Paste button). The app generates an
  ed25519 keypair; the CLI appends the **public** half to
  `authorized_keys` with the `multiplex:bind:<8 hex>:<device-slug>`
  comment (`mpx unbind`'s handle). **Distribution is three repos**: closed
  source in `multiplex-term/multiplex-cli` (never promise it will open;
  support@multiplexterm.dev does not exist — problems go to the releases
  repo's issues), archives in `multiplex-term/multiplex-cli-releases`, and
  `multiplex-term/homebrew-tap` (the `homebrew-` prefix is brew's own
  resolution rule for the tap `multiplex-term/tap` — renaming 404s every
  documented install line). A `v*` tag builds four targets (musl + darwin,
  x86_64/aarch64), publishes `SHA256SUMS`, opens a formula bump; needs the
  cross-repo `RELEASE_TOKEN`. `multiplexterm.dev/install-mpx-cli`
  (multiplex-home repo) covers macOS AND Linux and refuses SHA mismatches.
  The OFFER carries the host's SSH key fingerprints into
  `Host.pinnedHostKeys` (storage only — TOFU enforcement is its own
  change). Load-bearing: **the free host limit is checked before the
  handshake** (a key must not land in `authorized_keys` for a host this
  tier can't use); **a payload from outside the modal never auto-binds**
  (`onOpenURL` → `BindController.receive` only adds a candidate row and
  raises the pane for an explicit ENROLL — a `multiplex://b/…` URL is
  attacker-suppliable; the pane's own scan/paste keep auto-confirm, and
  the machine still asks `[Y/n]`); **the machine's own address list
  outranks wherever its listener answered** (`BindNaming.hostname`; `mpx
  bind --addr` covers NAT — the reached address wins only when the machine
  endorses it); the PIN proof is transcript-bound (HKDF over PIN + both
  public keys, 3 attempts then the session locks) while a wrong token
  closes silently (counting 128-bit guesses would gift a LAN spammer a
  DoS). **Two announcements claiming one name raise a caution on both
  rows** (`BindAnnouncement.contestedNames`; discovery dedupes by session
  key, so a shared name means two keys claiming one machine). It is a
  **tell, not a control** — do not let it grow into one: the same
  unauthenticated mDNS lets an attacker forge a goodbye for the real row
  or answer for its instance name and leave a single row standing, and
  two `mpx bind` runs on one machine contest their own name, which is why
  the copy says "if you started only one". The fix that doesn't depend on
  someone noticing is a SAS over `spub` (`spec/bind-v1.md` §3).
  **The whole flow is one modal**: Add Host opens on BIND | MANUAL
  (`AddHostSheet.Mode`); the deck has no bind surface at all (chip, rail,
  and ghost tiles shipped and were withdrawn 2026-07-28). Discovery
  browses only while `bindSurfaceOpen` OR an enrollment is in flight —
  in-flight specifically, or a row parked on FAILED holds the browser
  open behind a closed modal. **A row retires when the machine withdraws
  its announcement** — every way `mpx bind` ends does that (Ctrl-C via
  the CLI's `cancel` module); fix endings in the CLI, never with an
  app-side liveness probe (tried and rejected 2026-07-28: Bonjour
  resolves to dead aliases and deleted live machines). The one
  non-false-positive backstop: `BindOfferLifetime` retires rows older
  than the CLI's `--expires` ceiling (600 s) + margin — keep in step with
  the CLI's clamp or move the expiry into the TXT record. `--offline` (a
  VPS reachable only over SSH) inverts the key direction — the CLI ships
  a private key in the payload — so the app retires it on first
  connection (`BindRotationStore`: append BEFORE remove; a failure
  between the steps must leave a working key). **The bind key passphrase
  lives in the app, nowhere else** (`BindPane` KEY PASSPHRASE; applies to
  handshake and offline-seed alike). Empty = plaintext store. Set → the
  key is sealed as encrypted openssh-key-v1 by
  `BindSSHKey.sealedPrivateOpenSSH` (vendored `mpxbind_`-prefixed OpenBSD
  bcrypt-pbkdf + CommonCrypto; Citadel's independent bcrypt is the
  decrypt side, making the round-trip test a real cross-check); the
  passphrase saves into the host's settings (synced Keychain, the same
  slot Host Settings shows/clears) so the probe connects immediately. A
  sealed key is never rotated, and `save()` skips the probe for a sealed
  key with no passphrase on file. The CLI knows nothing about passphrases
  (a CLI-side variant shipped and was reverted 2026-07-29).
