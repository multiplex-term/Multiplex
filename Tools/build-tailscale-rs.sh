#!/bin/sh
# Builds the vendored tailscale-rs static archives for all four app slices
# (iOS device, universal iOS simulator, visionOS device, visionOS
# simulator) at the pinned commit and installs them under
# Vendor/tailscale-rs/lib/. See Vendor/tailscale-rs/README.md.
#
# Requires: rustup + network. Installs the pinned stable and nightly
# toolchains and targets on first run. The two xros slices need nightly +
# -Zbuild-std while aarch64-apple-visionos remains tier 3.
set -eu

# v0.6.1
PINNED_COMMIT=d34658bbb2eb4593ae6df959aa93e9ee1e0457c6
STABLE=1.98.1
NIGHTLY=nightly-2026-09-17
REPO_URL=https://github.com/tailscale/tailscale-rs
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor/tailscale-rs"
WORK="${TAILSCALE_RS_BUILD_DIR:-$(mktemp -d /tmp/tailscale-rs-build.XXXXXX)}"

if [ ! -d "$WORK/.git" ]; then
    git clone "$REPO_URL" "$WORK"
fi
git -C "$WORK" fetch --quiet origin "$PINNED_COMMIT"
git -C "$WORK" checkout --quiet "$PINNED_COMMIT"
git -C "$WORK" checkout -- .
git -C "$WORK" apply "$VENDOR/patches/ts_netmon-apple-mobile-cfg.patch"

rustup toolchain install "$STABLE" --profile minimal 2>/dev/null || true
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
    --toolchain "$STABLE" 2>/dev/null || true
rustup toolchain install "$NIGHTLY" --component rust-src 2>/dev/null || true

cd "$WORK"
IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p ts_ffi --release --target aarch64-apple-ios

# ts_ffi's build.rs writes the cbindgen header (git-ignored upstream), so it
# exists only after the first build. It must match the vendored copy.
if ! cmp -s "$WORK/ts_ffi/tailscale.h" "$VENDOR/include/tailscale.h"; then
    echo "error: Vendor/tailscale-rs/include/tailscale.h differs from the pinned commit's ts_ffi/tailscale.h — reconcile before building" >&2
    exit 1
fi

IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p ts_ffi --release --target aarch64-apple-ios-sim
IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build -p ts_ffi --release --target x86_64-apple-ios
XROS_DEPLOYMENT_TARGET=1.0 cargo "+$NIGHTLY" build -p ts_ffi --release \
    --target aarch64-apple-visionos -Zbuild-std=std,panic_abort
XROS_DEPLOYMENT_TARGET=1.0 cargo "+$NIGHTLY" build -p ts_ffi --release \
    --target aarch64-apple-visionos-sim -Zbuild-std=std,panic_abort

mkdir -p "$VENDOR/lib/ios-arm64" "$VENDOR/lib/ios-simulator" \
    "$VENDOR/lib/xros-arm64" "$VENDOR/lib/xros-simulator"
cp target/aarch64-apple-ios/release/libtailscalers.a "$VENDOR/lib/ios-arm64/libtailscalers.a"
lipo -create -output "$VENDOR/lib/ios-simulator/libtailscalers.a" \
    target/aarch64-apple-ios-sim/release/libtailscalers.a \
    target/x86_64-apple-ios/release/libtailscalers.a
cp target/aarch64-apple-visionos/release/libtailscalers.a "$VENDOR/lib/xros-arm64/libtailscalers.a"
cp target/aarch64-apple-visionos-sim/release/libtailscalers.a "$VENDOR/lib/xros-simulator/libtailscalers.a"

for slice in ios-arm64 ios-simulator xros-arm64 xros-simulator; do
    if ! nm -gU "$VENDOR/lib/$slice/libtailscalers.a" 2>/dev/null | grep -q _ts_init; then
        echo "error: $slice archive is missing _ts_init" >&2
        exit 1
    fi
done
lipo -info "$VENDOR/lib/ios-simulator/libtailscalers.a" | grep -q x86_64 || {
    echo "error: ios-simulator archive is not universal" >&2
    exit 1
}

echo "Installed:"
ls -l "$VENDOR"/lib/*/libtailscalers.a
