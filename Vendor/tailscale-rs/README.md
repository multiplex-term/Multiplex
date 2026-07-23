# tailscale-rs (vendored C ABI)

Tailscale's Rust implementation as a `staticlib`, exposed to Swift as the
`CTailscaleRS` module. Backs the per-host "Connect via Tailscale" option on
**all three platforms — visionOS included** (Rust has an
`aarch64-apple-visionos` target; Go never will). Parallel to the Go-backed
spike on branch `tailscale-host-option` (PR #12); investigation record:
`local-plan/tailscale-rs-investigation.md`.

**Upstream labels this experimental**: unaudited crypto ("assume … in the
clear"), a mandatory `TS_RS_EXPERIMENT=this_is_unstable_software` env var
(the tunnel sets it before init), no pre-1.0 API stability, and today ALL
peer traffic relays through public DERP servers (no NAT traversal yet —
"seamless upgrade" later). SSH/mosh payloads stay independently encrypted
regardless.

## Provenance

- Source: https://github.com/tailscale/tailscale-rs
- Pinned commit: `31b007904be298b69c4af1ffbefa937ad9848dbe` (main,
  2026-07-22; tags run v0.2.0–v0.4.0) + one local patch:
  `patches/ts_netmon-apple-mobile-cfg.patch` (cfg-gates a `PlatformMon`
  re-export that doesn't exist on iOS/visionOS — upstream-PR-able).
- Toolchains: Rust 1.95.0 (repo pin) for iOS/darwin slices;
  **nightly-2026-07-22 + `-Zbuild-std=std,panic_abort`** for the two xros
  slices (`aarch64-apple-visionos{,-sim}` are still tier 3).
- License BSD-3-Clause (+ Tailscale PATENTS grant upstream); dep licenses
  constrained by upstream's deny.toml to permissive families.

## Layout

- `include/tailscale.h` — cbindgen-generated C ABI (23 `ts_*` functions)
  from the pinned commit; `include/module.modulemap` wraps it as
  `CTailscaleRS`.
- `lib/{ios-arm64,ios-simulator,xros-arm64,xros-simulator}/libtailscalers.a`
  — **git-ignored** (~17-44 MB). The ios-simulator slice is universal
  (arm64 + x86_64: Release simulator builds link both). Rebuild all four:

```sh
./Tools/build-tailscale-rs.sh
```

Link needs beyond libSystem: `-framework CoreFoundation -liconv`
(project.yml carries them with the SDK-conditional settings).

When bumping the pin: re-run the script (it re-applies the patch — drop it
once upstream merges), re-read `tailscale.h` for ABI drift (pre-1.0 churn
is expected), and re-check the investigation record's re-evaluate list
(§7): security audit / env-gate removal, direct connections, visionOS
tier-2 promotion.
