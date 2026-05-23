#!/usr/bin/env bash
# Toggle the collapsed state for the CURRENT session and resize accordingly.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

SESSION_ID="$(tmux display-message -p '#{session_id}')"

expanded_width="$(get_tmux_option "@sidetabs-expanded-width" "$DEFAULT_EXPANDED_WIDTH")"
collapsed_width="$(get_tmux_option "@sidetabs-collapsed-width" "$DEFAULT_COLLAPSED_WIDTH")"

current="$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")"
if [ "$current" = "1" ]; then
    new_state="0"; new_width="$expanded_width"
else
    new_state="1"; new_width="$collapsed_width"
fi

set_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "$new_state"

tmux list-windows -t "$SESSION_ID" -F '#{window_id}' 2>/dev/null \
    | while read -r wid; do
        sidetab="$(find_sidetab_pane "$wid")"
        [ -z "$sidetab" ] && continue
        tmux resize-pane -t "$sidetab" -x "$new_width"
      done

# Force redraw — bypass the global debounce by resetting the stamp.
set_tmux_option "$LAST_REFRESH_OPTION" "0"
"$CURRENT_DIR/refresh.sh"
