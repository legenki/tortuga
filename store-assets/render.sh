#!/usr/bin/env bash
# Render store-assets/src/slides.html into the store images, each at its exact
# size, with headless Chrome. CHROME: a Chrome or Chrome for Testing binary
# (default: Google Chrome in /Applications).
#   store-assets/render.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT
render() { # slide width height output
  "$CHROME" --headless=new --user-data-dir="$PROFILE" --hide-scrollbars --force-device-scale-factor=1 \
    --allow-file-access-from-files --window-size="$2,$3" --screenshot="$HERE/$4" \
    "file://$HERE/src/slides.html#$1" >/dev/null 2>&1
  echo "$4"
}
render route     1280 800 screenshot-1-route.png
render bridges   1280 800 screenshot-2-bridges.png
render downloads 1280 800 screenshot-3-downloads.png
render settings  1280 800 screenshot-4-settings.png
render dark      1280 800 screenshot-5-dark.png
render tile      440  280 promo-small-440x280.png
render marquee   1400 560 promo-marquee-1400x560.png
