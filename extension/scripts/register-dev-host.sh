#!/usr/bin/env bash
# Register helper/scripts/dev-host.sh as the org.tortuga.helper native host
# for development. Firefox always; Chrome when given the unpacked extension's
# id (chrome://extensions, with Developer mode on).
# Usage: extension/scripts/register-dev-host.sh [CHROME_EXTENSION_ID]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="$ROOT/helper/scripts/dev-host.sh"
[ -x "$HOST" ] || { echo "missing $HOST" >&2; exit 1; }
case "$(uname -s)" in
  Darwin) FF="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
          CR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts" ;;
  Linux)  FF="$HOME/.mozilla/native-messaging-hosts"
          CR="$HOME/.config/google-chrome/NativeMessagingHosts" ;;
  *) echo "unsupported OS" >&2; exit 1 ;;
esac
mkdir -p "$FF"
cat > "$FF/org.tortuga.helper.json" <<JSON
{
  "name": "org.tortuga.helper",
  "description": "Tortuga helper (development)",
  "path": "$HOST",
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
  "path": "$HOST",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$1/"]
}
JSON
  echo "Chrome:  $CR/org.tortuga.helper.json"
fi
