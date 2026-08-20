#!/bin/bash
# Multiplex build / test / verify helper.
#
#   ./Tools/build.sh gen                 regenerate the Xcode project (XcodeGen)
#   ./Tools/build.sh lint [--fix]        SwiftLint over the app + tests + tools
#   ./Tools/build.sh build [vos|ipad] [xcodebuild args...]
#                                        build for a platform (default: vos)
#   ./Tools/build.sh test  [vos|ipad] [xcodebuild args...]
#                                        run unit tests (default: vos)
#   ./Tools/build.sh verify [vos|ipad]   build + install + drive end-to-end
#                                        against the local sshd/tmux harness
#   ./Tools/build.sh interop             round-trip against real mosh-server
#   ./Tools/build.sh strings             sync the String Catalogs from the
#                                        last visionOS build's .stringsdata
#   ./Tools/build.sh all                 gen + lint + build both + test
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
BUNDLE_ID="app.multiplexterm.multiplex"
HARNESS="$ROOT/Tools/dev-sshd/harness.sh"
SEED="$ROOT/Tools/dev-sshd/state/seed.json"

# Resolve one concrete simulator UDID for a platform key. Name-based
# xcodebuild destinations are ambiguous the moment several runtimes carry an
# "Apple Vision Pro" — prefer a booted device (what the user is looking at),
# else the newest runtime (simctl lists runtimes ascending).
#
# Each platform names its preferred device first and then falls back: a CI
# runner's Xcode ships whatever iPad generation it ships, and the device set
# a laptop accumulated is not the one a fresh image creates. `iPad` last
# matches any of them, so the build never dies on a model name.
sim_udid() {
    local candidates name list
    case "$1" in
        vos|visionos|xr) candidates="Apple Vision Pro" ;;
        ipad|ios)        candidates="iPad Pro 13-inch (M5)|iPad Pro 13-inch|iPad Pro|iPad Air|iPad" ;;
        *) echo "unknown platform '$1' (use vos|ipad)" >&2; exit 2 ;;
    esac
    while IFS= read -r name; do
        list="$(xcrun simctl list devices available | grep -F "$name")"
        [ -n "$list" ] || continue
        { echo "$list" | grep -F '(Booted)' | head -1; echo "$list" | tail -1; } \
            | grep -oE '[0-9A-F-]{36}' | head -1
        return
    done < <(echo "$candidates" | tr '|' '\n')
}

require_udid() {
    local udid
    udid="$(sim_udid "$1")"
    [ -n "$udid" ] || { echo "no simulator found for '$1'" >&2; exit 1; }
    echo "$udid"
}

gen() {
    command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen" >&2; exit 1; }
    xcodegen generate
}

# Deliberately NOT an Xcode build phase: ENABLE_USER_SCRIPT_SANDBOXING is on,
# and a phase that reads the whole source tree would need an input file list
# regenerated on every added file. Keeping it here also means a contributor
# without SwiftLint installed can still build and ship.
lint() {
    command -v swiftlint >/dev/null || {
        echo "install swiftlint: brew install swiftlint" >&2
        exit 1
    }
    # `--strict` promotes warnings to errors: the tree is clean, so anything
    # new should fail the command rather than scroll past.
    swiftlint lint --strict "$@"
}

# String Catalog sync. `xcodebuild` emits per-file .stringsdata (every
# `String(localized:)` / SwiftUI `Text` literal) but only the Xcode IDE folds
# them back into the .xcstrings; this is the same `xcstringstool sync` the IDE
# runs. Run after `build vos`; commit the catalog diff. Keys that vanish from
# source are marked stale (Xcode's behaviour), never silently deleted.
strings() {
    local inter="$DERIVED/Build/Intermediates.noindex/Multiplex.build/Debug-xrsimulator"
    [ -d "$inter" ] || { echo "run ./Tools/build.sh build vos first" >&2; exit 1; }
    local target catalog
    for pair in "Multiplex:Multiplex/Localizable.xcstrings" \
                "MultiplexWidgets:MultiplexWidgets/Localizable.xcstrings"; do
        target="${pair%%:*}"; catalog="${pair#*:}"
        # shellcheck disable=SC2046
        xcrun xcstringstool sync "$catalog" --stringsdata \
            $(find "$inter/$target.build/Objects-normal" -name '*.stringsdata')
        echo "synced $catalog"
    done
}

# Trailing arguments go straight to xcodebuild, so a caller (CI) can add
# settings or flags without a second, drifting invocation of its own.
build() {
    local plat="${1:-vos}"
    shift || true
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "id=$(require_udid "$plat")" \
        -derivedDataPath "$DERIVED" build "$@"
}

run_tests() {
    local plat="${1:-vos}"
    shift || true
    xcodebuild -project "$PROJECT" -scheme "$TEST_SCHEME" \
        -destination "id=$(require_udid "$plat")" \
        -derivedDataPath "$DERIVED" test "$@"
}

verify() {
    local plat="${1:-vos}"

    # Resolve one concrete device and build + install against THAT exact UDID,
    # so a machine with multiple Vision Pro runtimes can't build for one and
    # install to another (SDK mismatch).
    local udid product
    udid="$(require_udid "$plat")"
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

interop() {
    command -v swiftc >/dev/null || { echo "swiftc not found" >&2; exit 1; }
    command -v mosh-server >/dev/null || {
        echo "mosh-server not found (install with: brew install mosh)" >&2
        exit 1
    }

    local src="$ROOT/Multiplex/Services/Mosh"
    local harness="$ROOT/Tools/mosh-interop"
    mkdir -p "$DERIVED"
    swiftc -O -o "$DERIVED/mosh-interop" \
        "$src/MoshCrypto.swift" \
        "$src/MoshZlib.swift" \
        "$src/MoshProtobuf.swift" \
        "$src/MoshFragment.swift" \
        "$src/MoshPacket.swift" \
        "$src/MoshTransport.swift" \
        "$harness/Shims.swift" \
        "$src/MoshSession.swift" \
        "$harness/Main.swift"
    MOSH_SERVER="$(command -v mosh-server)" "$DERIVED/mosh-interop"
}

case "${1:-}" in
    gen) gen ;;
    lint) shift; lint "$@" ;;
    build) shift; build "$@" ;;
    test) shift; run_tests "$@" ;;
    verify) verify "${2:-vos}" ;;
    interop) interop ;;
    strings) strings ;;
    all) gen; lint; build vos; build ipad; run_tests vos ;;
    *) sed -n '2,18p' "$0"; exit 1 ;;
esac
