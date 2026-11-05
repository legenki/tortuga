#!/usr/bin/env bash
# Build the .deb in a rust:1-bookworm container for this machine's
# architecture (helper/dist/), then install it in a clean debian:bookworm-slim
# container and check, as an ordinary user, that the files are readable and
# the helper starts and answers hello. Run from a folder Docker can mount
# (Docker Desktop doesn't share /private/tmp).
# Usage: helper/packaging/linux/docker-build.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
MAINTAINER="${DEB_MAINTAINER:-$(git config user.name) <$(git config user.email)>}"
# A separate target dir: the host's helper/target holds macOS builds.
docker run --rm -v "$REPO:/src" -v tortuga-cargo:/usr/local/cargo/registry \
  -e CARGO_TARGET_DIR=/src/helper/target/linux -e DEB_MAINTAINER="$MAINTAINER" \
  -w /src rust:1-bookworm bash -c '
    apt-get update -qq && apt-get install -qq -y python3 >/dev/null && helper/packaging/linux/build-deb.sh'
DEB="$(ls -t "$REPO"/helper/dist/tortuga-helper_*.deb | head -1)"
echo "built $DEB"
# Install as root, run as an ordinary user: root can read anything, so only a
# user shows whether the installed files are readable by everyone.
docker run --rm -v "$DEB:/tmp/helper.deb:ro" -v "$REPO/helper:/helper:ro" debian:bookworm-slim bash -c '
  apt-get update -qq && apt-get install -qq -y /tmp/helper.deb python3 >/dev/null 2>&1 &&
  ls -l /usr/lib/tortuga /usr/lib/tortuga/pt /usr/lib/mozilla/native-messaging-hosts &&
  useradd -m tester &&
  su tester -c "cat /usr/lib/tortuga/pt/pt_config.json > /dev/null && echo pt_config.json is readable by users" &&
  su tester -c "python3 /helper/packaging/smoke.py /usr/lib/tortuga/tortuga-helper"'
