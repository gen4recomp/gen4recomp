#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/dev.sh
# The daily development boot enables F3-toggleable diagnostics; the overlay
# starts hidden. A bare `love app/` run is product mode.
exec love app/ --dev "$@"
