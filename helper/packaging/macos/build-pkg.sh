#!/usr/bin/env bash
# Build Tortuga-Helper-<version>-macos.pkg in helper/dist/.
#
# Usage: helper/packaging/macos/build-pkg.sh [--universal]
#   --universal  arm64 + x86_64 in one binary (needs rustup targets
#                aarch64-apple-darwin and x86_64-apple-darwin); otherwise
#                this Mac's architecture only.
#
# Signing and notarisation happen only when these are set:
#   DEVELOPER_ID_APP        "Developer ID Application: Name (TEAMID)"
#   DEVELOPER_ID_INSTALLER  "Developer ID Installer: Name (TEAMID)"
#   NOTARY_PROFILE          a `xcrun notarytool store-credentials` profile
#
# The package installs (as root, for every user):
#   /Library/Application Support/Tortuga/{tortuga-helper, pt/, uninstall.sh}
#   the org.tortuga.helper manifests for Firefox, and — once the Chrome ID is
#   pinned (helper/packaging/hosts.py) — for Chrome and Chromium.
set -euo pipefail
HELPER="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HELPER/tortuga-helper/Cargo.toml" | head -1)"
UNIVERSAL=0
[ "${1:-}" = --universal ] && UNIVERSAL=1
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP_DIR="Library/Application Support/Tortuga"
INSTALLED="/$APP_DIR/tortuga-helper"
ROOT="$STAGE/root"
mkdir -p "$ROOT/$APP_DIR/pt"

# 1. The helper.
cd "$HELPER"
TARGET_DIR="${CARGO_TARGET_DIR:-target}"
if [ $UNIVERSAL = 1 ]; then
  cargo build --release -p tortuga-helper --target aarch64-apple-darwin
  cargo build --release -p tortuga-helper --target x86_64-apple-darwin
  lipo -create -output "$ROOT/$INSTALLED" \
    "$TARGET_DIR/aarch64-apple-darwin/release/tortuga-helper" "$TARGET_DIR/x86_64-apple-darwin/release/tortuga-helper"
else
  cargo build --release -p tortuga-helper
  cp "$TARGET_DIR/release/tortuga-helper" "$ROOT/$INSTALLED"
fi

# 2. lyrebird for the same architectures, from the Tor Expert Bundle.
if [ $UNIVERSAL = 1 ]; then
  scripts/fetch-pt.sh 16.0 macos-aarch64 "$STAGE/pt-arm64"
  scripts/fetch-pt.sh 16.0 macos-x86_64 "$STAGE/pt-x86_64"
  lipo -create -output "$ROOT/$APP_DIR/pt/lyrebird" "$STAGE/pt-arm64/lyrebird" "$STAGE/pt-x86_64/lyrebird"
  cp "$STAGE/pt-arm64/pt_config.json" "$ROOT/$APP_DIR/pt/"
else
  scripts/fetch-pt.sh 16.0 "" "$ROOT/$APP_DIR/pt"
fi

# 3. Native messaging host manifests.
python3 packaging/hosts.py manifests "$INSTALLED" "$STAGE/manifests" >/dev/null
mkdir -p "$ROOT/Library/Application Support/Mozilla/NativeMessagingHosts"
cp "$STAGE/manifests/firefox.json" "$ROOT/Library/Application Support/Mozilla/NativeMessagingHosts/org.tortuga.helper.json"
if [ -f "$STAGE/manifests/chrome.json" ]; then
  for dir in "Library/Google/Chrome/NativeMessagingHosts" "Library/Application Support/Chromium/NativeMessagingHosts"; do
    mkdir -p "$ROOT/$dir"
    cp "$STAGE/manifests/chrome.json" "$ROOT/$dir/org.tortuga.helper.json"
  done
else
  echo "note: Chrome ID not pinned — the package registers the helper for Firefox only" >&2
fi
cp packaging/macos/uninstall.sh "$ROOT/$APP_DIR/uninstall.sh"
chmod 755 "$ROOT/$INSTALLED" "$ROOT/$APP_DIR/pt/lyrebird" "$ROOT/$APP_DIR/uninstall.sh"

# 4. Sign the programs (hardened runtime, as notarisation requires).
if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$ROOT/$INSTALLED" "$ROOT/$APP_DIR/pt/lyrebird"
fi

# 5. The package, built by hand rather than with pkgbuild: pkgbuild packs
# extended attributes (com.apple.provenance, which can't be removed) as ._
# files that would be installed too. The payload is a cpio archive (bsdcpio
# leaves xattrs out with COPYFILE_DISABLE) and both it and the bill of
# materials say root:admin, whoever built the package.
export COPYFILE_DISABLE=1
COMP="$STAGE/component"
mkdir -p "$COMP"
(cd "$ROOT" && find . | cpio -o --format odc -R 0:80 --quiet) | gzip -9 -c > "$COMP/Payload"
ME="$(id -u)/$(id -g)"
mkbom "$ROOT" "$STAGE/own.bom"
lsbom "$STAGE/own.bom" | sed -e "s#	$ME	#	0/80	#" -e "s#	$ME\$#	0/80#" > "$STAGE/bom.txt"
mkbom -i "$STAGE/bom.txt" "$COMP/Bom"
FILES="$(find "$ROOT" | wc -l | tr -d ' ')"
KBYTES="$(du -sk "$ROOT" | cut -f1)"
cat > "$COMP/PackageInfo" <<XML
<?xml version="1.0" encoding="utf-8"?>
<pkg-info format-version="2" identifier="org.tortuga.helper" version="$VERSION" install-location="/" auth="root">
  <payload numberOfFiles="$FILES" installKBytes="$KBYTES"/>
</pkg-info>
XML
pkgutil --flatten "$COMP" "$STAGE/component.pkg"
mkdir -p "$HELPER/dist"
OUT="$HELPER/dist/Tortuga-Helper-$VERSION-macos.pkg"
SIGN=()
[ -n "${DEVELOPER_ID_INSTALLER:-}" ] && SIGN=(--sign "$DEVELOPER_ID_INSTALLER")
# ${SIGN[@]+…}: macOS's bash 3.2 calls an empty array unbound under set -u.
productbuild --identifier org.tortuga.helper --version "$VERSION" --package "$STAGE/component.pkg" ${SIGN[@]+"${SIGN[@]}"} "$OUT" >/dev/null

# 6. Notarise and staple.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
fi
echo "$OUT"
