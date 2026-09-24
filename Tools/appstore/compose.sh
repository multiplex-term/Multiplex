#!/bin/bash
# Compose App Store screenshots: renders each frame of storyboard.html at
# exact store pixel size via headless Chrome, then copies the results into
# fastlane/screenshots/<ios|visionos>/en-US/ with sortable names (store
# order = file order). Two dirs because ASC screenshot sets are
# per-platform-version: deliver must push iPhone/iPad to the ios version
# and Vision Pro to the xros version — a Vision Pro display type on the
# ios version is refused ("Display Type Not Allowed").
#
#   1. Put raw captures in Tools/appstore/raw/   (see docs/appstore/screenshots-plan.md)
#   2. ./compose.sh            # everything with a raw capture present
#   3. bundle exec fastlane store_screenshots
#
# deliver infers the device class from pixel size: 3840×2160 → Vision Pro,
# 2752×2064 → iPad 13″, 1320×2868 → iPhone 6.9″.
#
# Frames whose raw capture is missing are still rendered (as AWAITING CAPTURE
# boards) but are NOT copied into fastlane/screenshots.

set -euo pipefail
cd "$(dirname "$0")"

# Keep ids + order in sync with SHOTS/ORDER in storyboard.html.
# v1.3 order (2026-08-07): herdr + fileviewer in on iPad/visionOS, mosh +
# drop out there (both stay iPhone shots); iPhone tells herdr as the mixed
# deck and still drops windows (one-window shell); every platform carries
# its own keys shot (rail / ornament cluster).
shots_for() { # macOS bash 3.2 has no associative arrays
  case "$1" in
    visionos|ipad) echo "wall windows herdr agents strip launch fileviewer widgets keys themes" ;;
    iphone)        echo "wall keys agents herdr strip launch drop widgets mosh themes" ;;
  esac
}
size_for() {
  case "$1" in
    visionos) echo "3840,2160" ;;
    ipad)     echo "2752,2064" ;;
    iphone)   echo "1320,2868" ;;
  esac
}

CHROME=""
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
  [[ -x "$c" ]] && CHROME="$c" && break
done
[[ -n "$CHROME" ]] || { echo "No Chrome/Chromium/Edge found (needed for headless render)"; exit 1; }

mkdir -p out raw
dest_for() { # ASC platform version the set belongs to (see header)
  case "$1" in
    visionos) echo "../../fastlane/screenshots/visionos/en-US" ;;
    *)        echo "../../fastlane/screenshots/ios/en-US" ;;
  esac
}

for platform in visionos ipad iphone; do
  size="$(size_for "$platform")"
  dest="$(dest_for "$platform")"
  mkdir -p "$dest"
  # Renumbering means stale names linger and push the set past ASC's cap of
  # 10 — clear this platform's files before recomposing (iphone and ipad
  # share the ios dir, so the glob must stay platform-prefixed).
  rm -f "${dest}/${platform}"-*.png
  i=0
  for shot in $(shots_for "$platform"); do
    i=$((i + 1))
    frame="${platform}-${shot}"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
      --force-device-scale-factor=1 --window-size="$size" \
      --virtual-time-budget=5000 \
      --screenshot="out/${frame}.png" \
      "file://$PWD/storyboard.html?frame=${frame}" 2>/dev/null
    if [[ -f "raw/${frame}.png" ]]; then
      printf -v n '%02d' "$i"
      cp "out/${frame}.png" "${dest}/${platform}-${n}-${shot}.png"
      echo "composed  ${frame} → ${dest#../../}/${platform}-${n}-${shot}.png"
    else
      echo "awaiting  ${frame} (no raw/${frame}.png — rendered to out/ only)"
    fi
  done
done

echo "Done. Review out/*.png, then: bundle exec fastlane store_screenshots"
