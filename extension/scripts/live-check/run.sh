#!/usr/bin/env bash
# Live checks in headless Firefox with the extension and the dev helper.
#   extension/scripts/live-check/run.sh            Tor mode (check.mjs)
#   extension/scripts/live-check/run.sh bridges    Get … lines on the settings page (bridges.mjs)
#   extension/scripts/live-check/run.sh screenshots  README screenshots into docs/screenshots (screenshots.mjs)
#     SHOTS=dir THEME=dark SCALE=2 …run.sh screenshots  elsewhere, dark, at 2x (store assets)
# All need network access; the Tor check needs Tor to be reachable.
set -euo pipefail
WHAT="${1:-tor}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EXT="$(cd "$HERE/../.." && pwd)"
"$EXT/scripts/register-dev-host.sh" >/dev/null
(cd "$EXT" && npm run build:firefox --silent >/dev/null)
TMP="$(mktemp -d)"
case "$(uname -s)" in
  Darwin) MANIFEST="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts/org.tortuga.helper.json"
          HELPER="$HOME/Library/Application Support/Tortuga/dev/tortuga-helper" ;;
  *)      MANIFEST="$HOME/.mozilla/native-messaging-hosts/org.tortuga.helper.json"
          HELPER="$HOME/.local/share/tortuga/dev/tortuga-helper" ;;
esac
DATA=""
if [ "$WHAT" = bridges ] || [ "$WHAT" = screenshots ]; then
  # Keep helper data out of the real data dir: point the host at a wrapper
  # that sets it, and put it back on exit.
  # Not under $TMPDIR: on macOS it can be world-writable, and Arti refuses
  # state there. Next to the dev helper, which is out of ~/Documents.
  DATA="$(mktemp -d "$(dirname "$HELPER")/live-check-data.XXXXXX")"
  cp "$MANIFEST" "$TMP/manifest.json"
  cat > "$TMP/host.sh" <<SH
#!/bin/sh
export TORTUGA_DATA_DIR="$DATA"
exec "$HELPER" "\$@"
SH
  chmod +x "$TMP/host.sh"
  python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); m["path"]=sys.argv[2]; open(sys.argv[1],"w").write(json.dumps(m, indent=2))' "$MANIFEST" "$TMP/host.sh"
fi
(cd "$EXT" && MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1 npx --yes web-ext@10.8.0 run --source-dir dist-firefox \
  --no-input --no-reload --arg=--headless --arg=--remote-debugging-port=9222 --arg=--remote-allow-system-access) >"$TMP/web-ext.log" 2>&1 &
WEBEXT=$!
cleanup() {
  kill "$WEBEXT" 2>/dev/null || true
  pkill -f 'Firefox.app/Contents/MacOS/firefox.*headless|firefox.*--headless' 2>/dev/null || true
  pkill -f 'Tortuga/dev/tortuga-helper|tortuga/dev/tortuga-helper' 2>/dev/null || true
  [ -f "$TMP/manifest.json" ] && cp "$TMP/manifest.json" "$MANIFEST"
  rm -rf "$TMP"
  [ -n "$DATA" ] && rm -rf "$DATA"
}
trap cleanup EXIT
for _ in $(seq 1 60); do nc -z 127.0.0.1 9222 2>/dev/null && break; sleep 0.5; done
sleep 2
if [ "$WHAT" = screenshots ]; then
  node "$HERE/screenshots.mjs" "${SHOTS:-$EXT/../docs/screenshots}"
elif [ "$WHAT" = bridges ]; then
  node "$HERE/bridges.mjs" "${SHOTS:-}"
else
  node "$HERE/check.mjs"
fi
