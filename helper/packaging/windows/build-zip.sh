#!/usr/bin/env bash
# Build Tortuga-Helper-<version>-windows-x86_64.zip in helper/dist/, in Git
# Bash on Windows with cargo, python and curl. The zip holds the helper,
# lyrebird.exe, ids.json and install.ps1 / uninstall.ps1; install.ps1 copies
# them to %LOCALAPPDATA%\Tortuga and registers the host (no admin needed).
set -euo pipefail
HELPER="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HELPER/tortuga-helper/Cargo.toml" | head -1)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
NAME="Tortuga-Helper-$VERSION-windows-x86_64"
OUT_DIR="$STAGE/$NAME"
mkdir -p "$OUT_DIR/pt"
cd "$HELPER"
cargo build --release -p tortuga-helper
cp "${CARGO_TARGET_DIR:-target}/release/tortuga-helper.exe" "$OUT_DIR/"
scripts/fetch-pt.sh 16.0 windows-x86_64 "$OUT_DIR/pt"
python packaging/hosts.py ids > "$OUT_DIR/ids.json"
cp packaging/windows/install.ps1 packaging/windows/uninstall.ps1 "$OUT_DIR/"
mkdir -p "$HELPER/dist"
OUT="$HELPER/dist/$NAME.zip"
rm -f "$OUT"
(cd "$STAGE" && powershell -NoProfile -Command "Compress-Archive -Path '$NAME' -DestinationPath '$NAME.zip'")
mv "$STAGE/$NAME.zip" "$OUT"
echo "$OUT"
