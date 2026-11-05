#!/usr/bin/env bash
# Install the helper's release build as the org.tortuga.helper native host for
# development: Firefox always; Chrome and Chromium when the Chrome ID is pinned
# (helper/packaging/hosts.py set-chrome-key) or given as an argument (the
# unpacked extension's id from chrome://extensions). Run it again after every
# helper build.
#
# The binary and its transports are copied out of the repository because macOS
# doesn't let browsers run programs from ~/Documents, ~/Desktop or ~/Downloads.
#
# Usage: extension/scripts/register-dev-host.sh [CHROME_EXTENSION_ID]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/helper/target/release/tortuga-helper"
PT="$ROOT/helper/resources/pt"
[ -x "$BIN" ] || { echo "build the helper first: (cd helper && cargo build --release -p tortuga-helper)" >&2; exit 1; }
[ -f "$PT/lyrebird" ] || { echo "fetch transports first: helper/scripts/fetch-pt.sh" >&2; exit 1; }
case "$(uname -s)" in
  Darwin) DEV="$HOME/Library/Application Support/Tortuga/dev"
          FF="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
          CR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
          CM="$HOME/Library/Application Support/Chromium/NativeMessagingHosts" ;;
  Linux)  DEV="$HOME/.local/share/tortuga/dev"
          FF="$HOME/.mozilla/native-messaging-hosts"
          CR="$HOME/.config/google-chrome/NativeMessagingHosts"
          CM="$HOME/.config/chromium/NativeMessagingHosts" ;;
  *) echo "unsupported OS" >&2; exit 1 ;;
esac

# The helper looks for pt/ next to itself.
mkdir -p "$DEV/pt"
cp "$BIN" "$DEV/tortuga-helper"
cp "$PT/lyrebird" "$PT/pt_config.json" "$DEV/pt/"
echo "Helper:   $DEV/tortuga-helper"

MANIFESTS="$(mktemp -d)"
trap 'rm -rf "$MANIFESTS"' EXIT
python3 "$ROOT/helper/packaging/hosts.py" manifests "$DEV/tortuga-helper" "$MANIFESTS" >/dev/null 2>&1
mkdir -p "$FF"
cp "$MANIFESTS/firefox.json" "$FF/org.tortuga.helper.json"
echo "Firefox:  $FF/org.tortuga.helper.json"

if [ ! -f "$MANIFESTS/chrome.json" ] && [ $# -ge 1 ]; then
  # Not pinned: register for the unpacked extension's id instead.
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m.pop("allowed_extensions"); m["allowed_origins"]=["chrome-extension://%s/" % sys.argv[2]]; open(sys.argv[3],"w").write(json.dumps(m, indent=2)+"\n")' \
    "$MANIFESTS/firefox.json" "$1" "$MANIFESTS/chrome.json"
fi
if [ -f "$MANIFESTS/chrome.json" ]; then
  for dir in "$CR" "$CM"; do
    mkdir -p "$dir"
    cp "$MANIFESTS/chrome.json" "$dir/org.tortuga.helper.json"
  done
  echo "Chrome:   $CR/org.tortuga.helper.json (and Chromium)"
fi
