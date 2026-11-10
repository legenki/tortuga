#!/bin/sh
# Build Tortuga, put it in /Applications (macOS activates system extensions
# only from there) and open it. Arguments go to the app.
#
# The app and extension products are removed first: the extension's build
# phase copies in the helper and lyrebird, which Xcode doesn't track, so an
# incremental build can leave the extension's seal stale ("a sealed resource
# is missing or invalid") and sysextd refuses it.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
rm -rf build/Build/Products/Debug/Tortuga.app build/Build/Products/Debug/org.tortuga.app.proxy.systemextension
xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -configuration Debug -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration TORTUGA_BUILD="$(date +%s)" build | tail -1
codesign --verify --deep --strict build/Build/Products/Debug/Tortuga.app
pkill -x Tortuga 2>/dev/null || true
rm -rf /Applications/Tortuga.app
cp -R build/Build/Products/Debug/Tortuga.app /Applications/
codesign --verify --deep --strict /Applications/Tortuga.app
open /Applications/Tortuga.app --args "$@"
