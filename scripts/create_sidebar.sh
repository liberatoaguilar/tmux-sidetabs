#!/usr/bin/env bash
# Usage: create_sidebar.sh <session_id> <window_id>
# Idempotent: if a sidetab already exists in the window, exits 0 silently.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

SESSION_ID="$1"
WINDOW_ID="$2"

if window_has_sidetab "$WINDOW_ID"; then
    exit 0
fi

expanded_width="$(get_tmux_option "@sidetabs-expanded-width" "$DEFAULT_EXPANDED_WIDTH")"
collapsed_width="$(get_tmux_option "@sidetabs-collapsed-width" "$DEFAULT_COLLAPSED_WIDTH")"
collapsed="$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")"
[ "$collapsed" = "1" ] && width="$collapsed_width" || width="$expanded_width"

RENDER_CMD="$CURRENT_DIR/render.sh '$SESSION_ID'"

# split-window flags:
#   -h  horizontal split (side-by-side)
#   -b  before (left of target)
#   -f  full edge (spans whole window height, ignores existing splits)
#   -d  detached (don't move focus into the new pane)
#   -l  exact size
#   -P  print new pane id
#   -F  format for that print
sidetab_pane_id="$(tmux split-window -hbfd \
    -l "$width" \
    -t "$WINDOW_ID" \
    -P -F '#{pane_id}' \
    "$RENDER_CMD" 2>/dev/null || true)"

if [ -z "$sidetab_pane_id" ]; then
    # Likely the window is too narrow. Bail silently — window-resized hook
    # will retry later.
    exit 0
fi

set_pane_option "$sidetab_pane_id" "$SIDETAB_MARKER" "1"
