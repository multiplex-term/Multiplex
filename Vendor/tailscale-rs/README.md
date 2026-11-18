# tailscale-rs (vendored C ABI)

Tailscale's Rust implementation as a `staticlib`, exposed to Swift as the
`CTailscaleRS` module. Backs the per-host "Connect via Tailscale" option on
**all three platforms — visionOS included** (Rust has an
`aarch64-apple-visionos` target; Go never will). Parallel to the Go-backed
spike on branch `tailscale-host-option` (PR #12); investigation record:
`local-plan/tailscale-rs-investigation.md`.

**Upstream status (v0.7.1)**: the `ts_tunnel` cryptography has had a
third-party audit (v0.6.0) and upstream recommends it from a security
perspective; init logs a work-in-progress warning. Still pre-1.0 with no API stability,
**iOS is on upstream's unsupported-platform list** (we build it anyway, and
visionOS rides the same code), no MagicDNS / peer lookup by name, and
direct connections work "in many cases" — otherwise peers relay through
public DERP servers. Upstream's network monitor covers only
macOS/Linux/Windows, so iOS and visionOS run without one. SSH/mosh payloads
stay independently encrypted regardless.

## Provenance

- Source: https://github.com/tailscale/tailscale-rs
- Pinned: tag `v0.7.1` = `a2a56c41b1db72d50d59d71d35c6669ff9639d14`
  (2026-11-06), unpatched. The `ts_netmon` cfg patch carried through
  v0.6.1 landed upstream in v0.7.0 (the `PlatformMon` re-export is now
  gated to the platforms that have one).
- Toolchains: Rust 1.98.1 (repo pin) for the iOS slices;
  **nightly-2026-09-17 + `-Zbuild-std=std,panic_abort`** for the two xros
  slices (`aarch64-apple-visionos{,-sim}` are still tier 3).
- License BSD-3-Clause (+ Tailscale PATENTS grant upstream); dep licenses
  constrained by upstream's deny.toml to permissive families.

## Layout

- `include/tailscale.h` — cbindgen-generated C ABI from the pinned commit
  (`crates/bindings/ts_ffi`'s build.rs writes it; upstream git-ignores it);
  `include/module.modulemap` wraps it as `CTailscaleRS`.
- `lib/{ios-arm64,ios-simulator,xros-arm64,xros-simulator}/libtailscalers.a`
  — **git-ignored** (~17-44 MB). The ios-simulator slice is universal
  (arm64 + x86_64: Release simulator builds link both). Rebuild all four:

```sh
./Tools/build-tailscale-rs.sh
```

Link needs beyond libSystem: `-framework CoreFoundation -liconv`
(project.yml carries them with the SDK-conditional settings).

## ABI traps

- `ts_sockaddr_set_port` is a no-op (it writes a by-value copy of the
  union); `TailscaleTunnel` sets `sin_port`/`sin6_port` directly.
- `ts_config.ephemeral` (since v0.5.0) defaults to false in Rust but a
  zeroed C struct also means false; the tunnel sets it explicitly.
- The ABI reports no auth verdict. With a rejected auth key `ts_init`
  returns a device in about 2 s and `ts_ipv4_addr` then blocks for good,
  waiting for a netmap that never comes (measured at v0.7.1 with an invalid
  key; through v0.6.1 it was `ts_init` that hung). The Rust API gained an
  `AuthKeyRejected` error in v0.7.0, but `ts_ffi` exposes no
  `is_authorized`. The tunnel races `ts_init` and the address read
  together against a 30 s deadline.

When bumping the pin: re-run the script, diff `tailscale.h` for ABI drift
(pre-1.0 churn is expected; v0.6.1 to v0.7.1 had none, only the move to
`crates/bindings/ts_ffi`), re-run a rejected-key startup, and re-check the
investigation record's re-evaluate list (§7).
