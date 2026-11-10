#!/bin/sh
# Build Tortuga, put it in /Applications (macOS activates system extensions
# only from there) and open it. Arguments go to the app, e.g. -spike YES.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Tortuga.xcodeproj -scheme Tortuga -configuration Debug -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build | tail -1
pkill -x Tortuga 2>/dev/null || true
rm -rf /Applications/Tortuga.app
cp -R build/Build/Products/Debug/Tortuga.app /Applications/
open /Applications/Tortuga.app --args "$@"
