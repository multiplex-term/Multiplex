#!/bin/bash
# Render the App Store creative assets from creative.html at exact store size
# and copy them into fastlane/screenshots/creative/en-US/ for a hand upload
# (App Store Connect → Asset Library; fastlane 2.240.1 has no support for
# them). Headless Chrome emits opaque RGB PNGs, which ASC requires.
#
#   ./compose-creative.sh          # header.png + search-results.png
#   GUIDES=1 ./compose-creative.sh # review copies with the safe area drawn,
#                                  # rendered to out/ only

set -euo pipefail
cd "$(dirname "$0")"

CHROME=""
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
  [[ -x "$c" ]] && CHROME="$c" && break
done
[[ -n "$CHROME" ]] || { echo "No Chrome/Chromium/Edge found (needed for headless render)"; exit 1; }

dest="../../fastlane/screenshots/creative/en-US"
mkdir -p out "$dest"

render() { # frame size file
  local query="frame=$1" name="$3"
  if [[ -n "${GUIDES:-}" ]]; then query+="&guides=1"; name="${name%.png}-guides.png"; fi
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --window-size="$2" \
    --virtual-time-budget=5000 \
    --screenshot="out/creative-${name}" \
    "file://$PWD/creative.html?${query}" 2>/dev/null
  if [[ -z "${GUIDES:-}" ]]; then
    cp "out/creative-${name}" "${dest}/${name}"
    echo "composed  ${name} → ${dest#../../}/${name}"
  else
    echo "rendered  out/creative-${name}"
  fi
}

render header 3840,1646 header.png
render search 3840,2560 search-results.png
