# tailscale-rs (vendored C ABI)

Tailscale's Rust implementation as a `staticlib`, exposed to Swift as the
`CTailscaleRS` module. Backs the per-host "Connect via Tailscale" option on
**all three platforms — visionOS included** (Rust has an
`aarch64-apple-visionos` target; Go never will). Parallel to the Go-backed
spike on branch `tailscale-host-option` (PR #12); investigation record:
`local-plan/tailscale-rs-investigation.md`.

**Upstream status (v0.6.1)**: the `ts_tunnel` cryptography has had a
third-party audit and upstream now recommends it from a security
perspective; the `TS_RS_EXPERIMENT` env gate is gone (init logs a
work-in-progress warning instead). Still pre-1.0 with no API stability,
**iOS is on upstream's unsupported-platform list** (we build it anyway, and
visionOS rides the same code), no MagicDNS / peer lookup by name, and
direct connections work "in many cases" — otherwise peers relay through
public DERP servers. Upstream's network monitor covers only
macOS/Linux/Windows, so iOS and visionOS run without one. SSH/mosh payloads
stay independently encrypted regardless.

## Provenance

- Source: https://github.com/tailscale/tailscale-rs
- Pinned: tag `v0.6.1` = `d34658bbb2eb4593ae6df959aa93e9ee1e0457c6`
  (2026-09-17) + one local patch: `patches/ts_netmon-apple-mobile-cfg.patch`
  (cfg-gates a `PlatformMon` re-export that doesn't exist on
  iOS/visionOS — upstream-PR-able).
- Toolchains: Rust 1.98.1 (repo pin) for the iOS slices;
  **nightly-2026-09-17 + `-Zbuild-std=std,panic_abort`** for the two xros
  slices (`aarch64-apple-visionos{,-sim}` are still tier 3).
- License BSD-3-Clause (+ Tailscale PATENTS grant upstream); dep licenses
  constrained by upstream's deny.toml to permissive families.

## Layout

- `include/tailscale.h` — cbindgen-generated C ABI from the pinned commit
  (`ts_ffi`'s build.rs writes it; upstream git-ignores it);
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
- `ts_init` can block indefinitely on a rejected auth key; the tunnel races
  it against a 30 s deadline.

When bumping the pin: re-run the script (it re-applies the patch — drop it
once upstream merges), diff `tailscale.h` for ABI drift (pre-1.0 churn is
expected), and re-check the investigation record's re-evaluate list (§7).
