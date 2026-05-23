#!/usr/bin/env bash
# window-layout-changed dispatcher: recreate a killed sidetab, then sync width.
# Usage: layout_changed.sh <window_id>
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

WINDOW_ID="$1"

# If only the sidetab is left (all content panes closed), close the window and
# stop — no point resurrecting/syncing a window we just killed.
if "$CURRENT_DIR/close_empty.sh" "$WINDOW_ID"; then
    exit 0
fi

"$CURRENT_DIR/resurrect.sh" "$WINDOW_ID" || true
"$CURRENT_DIR/sync_width.sh" "$WINDOW_ID" || true
