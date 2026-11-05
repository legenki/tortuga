#!/usr/bin/env bash
# Put lyrebird and pt_config.json from the official Tor Expert Bundle into
# helper/resources/pt/, after checking the bundle's SHA-256.
# Usage: helper/scripts/fetch-pt.sh [TOR_BROWSER_VERSION]   (default: 16.0)
set -euo pipefail
V="${1:-16.0}"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) P=macos-aarch64 ;;
  Darwin-x86_64) P=macos-x86_64 ;;
  Linux-x86_64) P=linux-x86_64 ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
F="tor-expert-bundle-$P-$V.tar.gz"
HELPER="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HELPER/resources/pt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sSf -o "$TMP/$F" "https://dist.torproject.org/torbrowser/$V/$F"
curl -sSf -o "$TMP/sums.txt" "https://dist.torproject.org/torbrowser/$V/sha256sums-signed-build.txt"
(cd "$TMP" && grep " $F\$" sums.txt | shasum -a 256 -c -)
tar -xzf "$TMP/$F" -C "$TMP"
mkdir -p "$OUT"
cp "$TMP/tor/pluggable_transports/lyrebird" "$TMP/tor/pluggable_transports/pt_config.json" "$OUT/"
if [ "$(uname -s)" = Darwin ]; then xattr -d com.apple.quarantine "$OUT/lyrebird" 2>/dev/null || true; fi
echo "lyrebird and pt_config.json are in $OUT"
