# libtailscale (vendored C ABI)

Embedded userspace Tailscale (tsnet) as a Go `c-archive`, exposed to Swift as
the `CLibTailscale` module. Powers the per-host "Connect via Tailscale"
option (SSH over an in-process tailnet node — no system VPN, no
NetworkExtension). **iPhone/iPad only**: Go has no visionOS target, so the
visionOS build never links this and the feature is compiled out there
(`#if canImport(CLibTailscale)`). Full investigation record:
`local-plan/libtailscale-investigation.md`.

## Provenance

- Source: https://github.com/tailscale/libtailscale
- Pinned commit: `5e89501def80a6579ca5d0f9a02f336be62b8f2e` (main, 2026-02-27)
- Embeds `tailscale.com v1.94.1` (tsnet), built with Go 1.25.5 (via
  GOTOOLCHAIN), `-ldflags -w -tags ios`, upstream Makefile targets.
- Licenses: BSD-3-Clause (this library and tailscale.com), MIT-lineage
  (tailscale/wireguard-go), Apache-2.0 (gvisor netstack). `LICENSE` here is
  libtailscale's.

## Layout

- `include/tailscale.h` — the hand-written public C API from the pinned
  commit (verbatim). `include/module.modulemap` wraps it as `CLibTailscale`.
- `lib/ios-arm64/libtailscale.a` (device), `lib/ios-simulator/libtailscale.a`
  (universal arm64 + x86_64 — Release simulator builds link both slices)
  — **git-ignored** (~27-54 MB each). Rebuild them with:

```sh
./Tools/build-libtailscale.sh
```

(Requires Go and network access; the script pins the commit above and
verifies the `_tailscale_dial` symbol.) `project.yml` links the archives via
`[sdk=iphoneos*]`/`[sdk=iphonesimulator*]`-conditional settings only — the
xros SDK never sees them.

When bumping the pinned commit: re-read `tailscale.h` for ABI changes,
re-run the script, and update the investigation record's gates (§10) —
especially the UDP/datagram and SwiftPM ones.
