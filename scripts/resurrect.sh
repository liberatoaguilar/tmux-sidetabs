#!/usr/bin/env bash
# Called from window-layout-changed / window-resized hooks. Recreates the
# window's sidetab if it's missing (manual kill, or a too-narrow window that
# has since widened). No-op when the sidetab is already present.
# Usage: resurrect.sh <window_id>
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

WINDOW_ID="$1"
[ -z "$WINDOW_ID" ] && exit 0

if window_has_sidetab "$WINDOW_ID"; then
    exit 0
fi

"$CURRENT_DIR/create_sidebar.sh" "$WINDOW_ID"
