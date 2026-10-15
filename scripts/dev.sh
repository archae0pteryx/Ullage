#!/usr/bin/env bash
# Build, replace the installed app, and run it with terminal logs.
# Usage: scripts/dev.sh [installation-directory]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST_DIR="${1:-/Applications}"
ULLAGE_BUILD_CONFIGURATION=debug scripts/install-app.sh "$DEST_DIR"
echo 'Running Ullage (Debug). Quit Ullage to stop; rerun this script after editing.'
exec "$DEST_DIR/Ullage.app/Contents/MacOS/UllageApp"
