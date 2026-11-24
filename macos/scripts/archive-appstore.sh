#!/bin/sh
# Build Tortuga for the Mac App Store: archive it, then export it signed for
# App Store Connect (Xcode creates the Apple Distribution certificate and the
# App Store profiles for the app and its extension on first use). With
# --upload, the export is uploaded to App Store Connect instead of saved.
#
# Needs Local.xcconfig with your team (see Config/Base.xcconfig) and an
# Xcode account signed in to that team. The build number is the time, so
# every upload is newer than the last.
#
# Usage: macos/scripts/archive-appstore.sh [--upload]
set -eu
cd "$(dirname "$0")/.."
MODE=export
[ "${1:-}" = "--upload" ] && MODE=upload
TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Local.xcconfig)"
[ -n "$TEAM" ] || { echo "Set DEVELOPMENT_TEAM in macos/Local.xcconfig" >&2; exit 1; }
BUILD="$(date +%Y%m%d%H%M)"
OUT="build/appstore"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT/Tortuga.xcarchive" \
  -allowProvisioningUpdates TORTUGA_BUILD="$BUILD" archive | tail -3
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$MODE</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Tortuga.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates | tail -3
echo "Build $BUILD: $OUT/export"
