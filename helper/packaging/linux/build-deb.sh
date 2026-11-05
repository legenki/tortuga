#!/usr/bin/env bash
# Build tortuga-helper_<version>_<arch>.deb in helper/dist/, on Debian or
# Ubuntu with cargo, python3, curl and dpkg-deb (or in Docker: docker-build.sh).
#
# DEB_MAINTAINER ("Name <email>") is the package's Maintainer field; it
# defaults to this machine's git user.
#
# The package installs:
#   /usr/lib/tortuga/{tortuga-helper, pt/}
#   /usr/lib/mozilla/native-messaging-hosts/org.tortuga.helper.json
#   and, once the Chrome ID is pinned, the Chrome and Chromium manifests in
#   /etc/opt/chrome/native-messaging-hosts and /etc/chromium/native-messaging-hosts.
set -euo pipefail
HELPER="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HELPER/tortuga-helper/Cargo.toml" | head -1)"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64) PT=linux-x86_64 ;; arm64) PT=linux-aarch64 ;; *) echo "unsupported: $ARCH" >&2; exit 1 ;; esac
MAINTAINER="${DEB_MAINTAINER:-$(git config user.name 2>/dev/null) <$(git config user.email 2>/dev/null)>}"
case "$MAINTAINER" in " <>" | *"<>"*) echo "set DEB_MAINTAINER=\"Name <email>\"" >&2; exit 1 ;; esac
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/root"
LIB=usr/lib/tortuga
mkdir -p "$ROOT/$LIB/pt" "$ROOT/DEBIAN"

cd "$HELPER"
cargo build --release -p tortuga-helper
install -m 755 "${CARGO_TARGET_DIR:-target}/release/tortuga-helper" "$ROOT/$LIB/tortuga-helper"
scripts/fetch-pt.sh 16.0 "$PT" "$ROOT/$LIB/pt"
chmod 755 "$ROOT/$LIB/pt/lyrebird"

python3 packaging/hosts.py manifests "/$LIB/tortuga-helper" "$STAGE/manifests" >/dev/null
install -D -m 644 "$STAGE/manifests/firefox.json" "$ROOT/usr/lib/mozilla/native-messaging-hosts/org.tortuga.helper.json"
if [ -f "$STAGE/manifests/chrome.json" ]; then
  install -D -m 644 "$STAGE/manifests/chrome.json" "$ROOT/etc/opt/chrome/native-messaging-hosts/org.tortuga.helper.json"
  install -D -m 644 "$STAGE/manifests/chrome.json" "$ROOT/etc/chromium/native-messaging-hosts/org.tortuga.helper.json"
else
  echo "note: Chrome ID not pinned — the package registers the helper for Firefox only" >&2
fi

cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: tortuga-helper
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Depends: libc6 (>= 2.34), libgcc-s1, libssl3 | libssl3t64
Section: net
Priority: optional
Homepage: https://github.com/legenki/tortuga
Description: Tor and torrents for the Tortuga browser extension
 The native messaging host the Tortuga extension starts: Tor (Arti) with
 per-site circuits and bridges (Snowflake, obfs4, WebTunnel through the
 bundled lyrebird), and torrent downloads, which go directly, not through Tor.
CONTROL
mkdir -p "$HELPER/dist"
OUT="$HELPER/dist/tortuga-helper_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT" >/dev/null
echo "$OUT"
