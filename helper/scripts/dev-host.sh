#!/bin/sh
# The native host during development: the release build of the helper, with
# the transports that scripts/fetch-pt.sh put in resources/pt.
HELPER="$(cd "$(dirname "$0")/.." && pwd)"
export TORTUGA_PT_DIR="$HELPER/resources/pt"
exec "$HELPER/target/release/tortuga-helper" "$@"
