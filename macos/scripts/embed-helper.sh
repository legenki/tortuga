#!/bin/sh
# Xcode build phase of TortugaProxy: put tortuga-helper into the extension's
# Contents/MacOS and pt/{lyrebird, pt_config.json} into Contents/Resources
# (only code may sit in MacOS; the helper finds pt/ through TORTUGA_PT_DIR),
# and sign the two programs so they may run inside its sandbox.
# Set TORTUGA_SKIP_HELPER=1 to skip (CI's app job).
set -eu
[ "${TORTUGA_SKIP_HELPER:-}" = 1 ] && exit 0
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
HELPER="$SRCROOT/../helper"
(cd "$HELPER" && cargo build --release -p tortuga-helper)
PT="$HELPER/target/pt-macos"
[ -x "$PT/lyrebird" ] || "$HELPER/scripts/fetch-pt.sh" 16.0 "" "$PT"
DEST="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
RES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/pt"
rm -rf "$DEST/pt"
mkdir -p "$RES"
cp "$HELPER/target/release/tortuga-helper" "$DEST/tortuga-helper"
cp "$PT/lyrebird" "$PT/pt_config.json" "$RES/"
SIGN="${EXPANDED_CODE_SIGN_IDENTITY:--}"
for bin in "$DEST/tortuga-helper" "$RES/lyrebird"; do
  codesign --force --options runtime --sign "$SIGN" --entitlements "$SRCROOT/TortugaProxy/Helper.entitlements" "$bin"
done
