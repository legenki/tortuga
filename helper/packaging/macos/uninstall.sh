#!/bin/sh
# Remove the Tortuga helper installed by Tortuga-Helper-*-macos.pkg.
# Run with: sudo "/Library/Application Support/Tortuga/uninstall.sh"
# Each user's data (~/Library/Application Support/org.Tortuga.tortuga-helper)
# and downloads (~/Downloads/Tortuga) are left alone.
set -e
if [ "$(id -u)" != 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi
rm -f "/Library/Application Support/Mozilla/NativeMessagingHosts/org.tortuga.helper.json"
rm -f "/Library/Google/Chrome/NativeMessagingHosts/org.tortuga.helper.json"
rm -f "/Library/Application Support/Chromium/NativeMessagingHosts/org.tortuga.helper.json"
rm -rf "/Library/Application Support/Tortuga"
pkgutil --forget org.tortuga.helper >/dev/null 2>&1 || true
echo "Tortuga helper removed."
