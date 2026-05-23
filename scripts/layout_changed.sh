#!/usr/bin/env bash
# window-layout-changed dispatcher: recreate a killed sidetab, then sync width.
# Usage: layout_changed.sh <window_id>
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

WINDOW_ID="$1"

"$CURRENT_DIR/resurrect.sh" "$WINDOW_ID" || true
"$CURRENT_DIR/sync_width.sh" "$WINDOW_ID" || true
