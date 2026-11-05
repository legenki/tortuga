#!/usr/bin/env bash
# Install the helper's release build as the org.tortuga.helper native host for
# development: Firefox always, Chrome when given the unpacked extension's id
# (chrome://extensions, with Developer mode on). Run it again after every
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
          CR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" ;;
  Linux)  DEV="$HOME/.local/share/tortuga/dev"
          FF="$HOME/.mozilla/native-messaging-hosts"
          CR="$HOME/.config/google-chrome/NativeMessagingHosts" ;;
  *) echo "unsupported OS" >&2; exit 1 ;;
esac

# The helper looks for pt/ next to itself.
mkdir -p "$DEV/pt"
cp "$BIN" "$DEV/tortuga-helper"
cp "$PT/lyrebird" "$PT/pt_config.json" "$DEV/pt/"
echo "Helper:  $DEV/tortuga-helper"

mkdir -p "$FF"
cat > "$FF/org.tortuga.helper.json" <<JSON
{
  "name": "org.tortuga.helper",
  "description": "Tortuga helper (development)",
  "path": "$DEV/tortuga-helper",
  "type": "stdio",
  "allowed_extensions": ["tortuga@legenki.com"]
}
JSON
echo "Firefox: $FF/org.tortuga.helper.json"

if [ $# -ge 1 ]; then
  mkdir -p "$CR"
  cat > "$CR/org.tortuga.helper.json" <<JSON
{
  "name": "org.tortuga.helper",
  "description": "Tortuga helper (development)",
  "path": "$DEV/tortuga-helper",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$1/"]
}
JSON
  echo "Chrome:  $CR/org.tortuga.helper.json"
fi
