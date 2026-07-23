#!/bin/sh
# Builds the vendored libtailscale static archives (device + simulator) at
# the pinned commit and installs them under Vendor/libtailscale/lib/.
# Requires: go (any recent version; GOTOOLCHAIN fetches the one go.mod
# wants), git, network access. See Vendor/libtailscale/README.md.
set -eu

PINNED_COMMIT=5e89501def80a6579ca5d0f9a02f336be62b8f2e
REPO_URL=https://github.com/tailscale/libtailscale
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor/libtailscale"
WORK="${LIBTAILSCALE_BUILD_DIR:-$(mktemp -d /tmp/libtailscale-build.XXXXXX)}"

if [ ! -d "$WORK/.git" ]; then
    git clone "$REPO_URL" "$WORK"
fi
git -C "$WORK" fetch --quiet origin "$PINNED_COMMIT"
git -C "$WORK" checkout --quiet "$PINNED_COMMIT"

# Sanity: the vendored header must match the pinned commit's.
if ! cmp -s "$WORK/tailscale.h" "$VENDOR/include/tailscale.h"; then
    echo "error: Vendor/libtailscale/include/tailscale.h differs from the pinned commit's tailscale.h — reconcile before building" >&2
    exit 1
fi

make -C "$WORK" libtailscale_ios.a libtailscale_ios_sim_arm64.a

mkdir -p "$VENDOR/lib/ios-arm64" "$VENDOR/lib/ios-arm64-simulator"
cp "$WORK/libtailscale_ios.a" "$VENDOR/lib/ios-arm64/libtailscale.a"
cp "$WORK/libtailscale_ios_sim_arm64.a" "$VENDOR/lib/ios-arm64-simulator/libtailscale.a"

for slice in ios-arm64 ios-arm64-simulator; do
    if ! nm -gU "$VENDOR/lib/$slice/libtailscale.a" 2>/dev/null | grep -q _tailscale_dial; then
        echo "error: $slice archive is missing _tailscale_dial" >&2
        exit 1
    fi
done

echo "Installed:"
ls -l "$VENDOR/lib/ios-arm64/libtailscale.a" "$VENDOR/lib/ios-arm64-simulator/libtailscale.a"
