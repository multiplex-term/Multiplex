#!/bin/bash
# Multiplex build / test / verify helper.
#
#   ./Tools/build.sh gen                 regenerate the Xcode project (XcodeGen)
#   ./Tools/build.sh build [vos|ipad]    build for a platform (default: vos)
#   ./Tools/build.sh test  [vos|ipad]    run unit tests (default: vos)
#   ./Tools/build.sh verify [vos|ipad]   build + install + drive end-to-end
#                                        against the local sshd/tmux harness
#   ./Tools/build.sh all                 gen + build both + test
#
# Single source of truth for destinations, the shared DerivedData path, and the
# headless verification recipe. Keep flags here, not scattered across callers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="Multiplex.xcodeproj"
SCHEME="Multiplex"
TEST_SCHEME="MultiplexTests"
DERIVED="DerivedData"
BUNDLE_ID="tools.bricks.multiplex"
HARNESS="$ROOT/Tools/dev-sshd/harness.sh"
SEED="$ROOT/Tools/dev-sshd/state/seed.json"

# Resolve a booted (or bootable) simulator UDID for a platform key.
destination() {
    case "$1" in
        vos|visionos|xr) echo 'platform=visionOS Simulator,name=Apple Vision Pro' ;;
        ipad|ios)        echo 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' ;;
        *) echo "unknown platform '$1' (use vos|ipad)" >&2; exit 2 ;;
    esac
}

sim_udid() {
    # First available device matching the platform's device name.
    local name
    case "$1" in
        vos|visionos|xr) name="Apple Vision Pro" ;;
        ipad|ios)        name="iPad Pro 13-inch (M5)" ;;
    esac
    xcrun simctl list devices available | grep -F "$name (" | head -1 \
        | grep -oE '[0-9A-F-]{36}'
}

gen() {
    command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen" >&2; exit 1; }
    xcodegen generate
}

build() {
    local plat="${1:-vos}"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "$(destination "$plat")" \
        -derivedDataPath "$DERIVED" build
}

run_tests() {
    local plat="${1:-vos}"
    xcodebuild -project "$PROJECT" -scheme "$TEST_SCHEME" \
        -destination "$(destination "$plat")" \
        -derivedDataPath "$DERIVED" test
}

verify() {
    local plat="${1:-vos}"

    # Resolve one concrete device and build + install against THAT exact UDID,
    # so a machine with multiple Vision Pro runtimes can't build for one and
    # install to another (SDK mismatch).
    local udid product
    udid="$(sim_udid "$plat")"
    [ -n "$udid" ] || { echo "no simulator found for '$plat'" >&2; exit 1; }
    case "$plat" in
        vos|visionos|xr) product="$DERIVED/Build/Products/Debug-xrsimulator/Multiplex.app" ;;
        ipad|ios)        product="$DERIVED/Build/Products/Debug-iphonesimulator/Multiplex.app" ;;
    esac

    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "id=$udid" -derivedDataPath "$DERIVED" build

    echo "== starting harness =="
    "$HARNESS" start
    "$HARNESS" demo

    echo "== booting $udid =="
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true

    echo "== installing =="
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$udid" "$product"

    echo "== launching with seeded host + auto-attach =="
    SIMCTL_CHILD_MULTIPLEX_SEED_HOST="$SEED" \
    SIMCTL_CHILD_MULTIPLEX_AUTO_ATTACH="main" \
        xcrun simctl launch "$udid" "$BUNDLE_ID"

    echo "== driving the live session =="
    sleep 12
    tmux send-keys -t main:2 'echo "verified: Mac -> sshd -> tmux -> Multiplex"' Enter 2>/dev/null || true
    sleep 2
    local shot="$ROOT/DerivedData/verify-$plat.png"
    xcrun simctl io "$udid" screenshot "$shot"
    echo "screenshot: $shot"
    echo "verify OK — inspect the screenshot to confirm output rendered."
}

case "${1:-}" in
    gen) gen ;;
    build) build "${2:-vos}" ;;
    test) run_tests "${2:-vos}" ;;
    verify) verify "${2:-vos}" ;;
    all) gen; build vos; build ipad; run_tests vos ;;
    *) sed -n '2,17p' "$0"; exit 1 ;;
esac
