#!/usr/bin/env bash
# Put lyrebird and pt_config.json from the official Tor Expert Bundle into a
# folder, after checking the bundle's SHA-256 against Tor's signed sums list.
#
# Usage: helper/scripts/fetch-pt.sh [VERSION [PLATFORM [OUT_DIR]]]
#   VERSION   Tor Browser version of the bundle (default 16.0)
#   PLATFORM  macos-aarch64, macos-x86_64, linux-x86_64, linux-aarch64,
#             windows-x86_64 (default: this machine)
#   OUT_DIR   default helper/resources/pt
set -euo pipefail
V="${1:-16.0}"
P="${2:-}"
if [ -z "$P" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) P=macos-aarch64 ;;
    Darwin-x86_64) P=macos-x86_64 ;;
    Linux-x86_64) P=linux-x86_64 ;;
    Linux-aarch64 | Linux-arm64) P=linux-aarch64 ;;
    MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64) P=windows-x86_64 ;;
    *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
fi
HELPER="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${3:-$HELPER/resources/pt}"
F="tor-expert-bundle-$P-$V.tar.gz"
EXE=lyrebird
case "$P" in windows-*) EXE=lyrebird.exe ;; esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sSf -o "$TMP/$F" "https://dist.torproject.org/torbrowser/$V/$F"
curl -sSf -o "$TMP/sums.txt" "https://dist.torproject.org/torbrowser/$V/sha256sums-signed-build.txt"
if command -v sha256sum >/dev/null; then SUM="sha256sum -c -"; else SUM="shasum -a 256 -c -"; fi
(cd "$TMP" && grep " $F\$" sums.txt | $SUM)
tar -xzf "$TMP/$F" -C "$TMP"
mkdir -p "$OUT"
cp "$TMP/tor/pluggable_transports/$EXE" "$TMP/tor/pluggable_transports/pt_config.json" "$OUT/"
# The bundle's files are owner-only (0600); installed as root, every user's
# helper must still read pt_config.json and run lyrebird.
chmod 644 "$OUT/pt_config.json"
chmod 755 "$OUT/$EXE"
if [ "$(uname -s)" = Darwin ]; then xattr -d com.apple.quarantine "$OUT/$EXE" 2>/dev/null || true; fi
echo "$EXE and pt_config.json ($P) are in $OUT"
