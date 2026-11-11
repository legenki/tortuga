#!/bin/sh
# Remove the Tortuga helper installed by Tortuga-Helper-*-macos.pkg for this user.
# Run with: "$HOME/Library/Application Support/Tortuga/uninstall.sh"
# Your data (~/Library/Application Support/org.Tortuga.tortuga-helper) and
# downloads (~/Downloads/Tortuga) are left alone.
set -e
AS="$HOME/Library/Application Support"
rm -f "$AS/Mozilla/NativeMessagingHosts/org.tortuga.helper.json"
rm -f "$AS/Google/Chrome/NativeMessagingHosts/org.tortuga.helper.json"
rm -f "$AS/Chromium/NativeMessagingHosts/org.tortuga.helper.json"
rm -rf "$AS/Tortuga"
pkgutil --volume "$HOME" --forget org.tortuga.helper >/dev/null 2>&1 || true
echo "Tortuga helper removed."
# Versions up to 0.2.0 installed for every user, under /Library.
if [ -e "/Library/Application Support/Tortuga" ]; then
  echo "An older Tortuga helper is still installed for every user. Remove it with:"
  echo "  sudo \"/Library/Application Support/Tortuga/uninstall.sh\""
fi
