#!/usr/bin/env bash
# Build the Firefox extension, install the dev helper, start headless Firefox
# with the extension and run check.mjs against it. Needs network access to Tor.
# Usage: extension/scripts/live-check/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXT="$(cd "$HERE/../.." && pwd)"
"$EXT/scripts/register-dev-host.sh" >/dev/null
(cd "$EXT" && npm run build:firefox --silent >/dev/null)
LOG="$(mktemp)"
# System access lets check.mjs open the extension's own page in a tab.
(cd "$EXT" && MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1 npx --yes web-ext@10.8.0 run --source-dir dist-firefox \
  --no-input --no-reload --arg=--headless --arg=--remote-debugging-port=9222 --arg=--remote-allow-system-access) >"$LOG" 2>&1 &
WEBEXT=$!
cleanup() {
  kill "$WEBEXT" 2>/dev/null || true
  pkill -f 'Firefox.app/Contents/MacOS/firefox.*headless|firefox.*--headless' 2>/dev/null || true
  pkill -f 'Tortuga/dev/tortuga-helper|tortuga/dev/tortuga-helper' 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT
for _ in $(seq 1 60); do nc -z 127.0.0.1 9222 2>/dev/null && break; sleep 0.5; done
sleep 2
node "$HERE/check.mjs"
