#!/usr/bin/env bash
# Usage: sync_width.sh <window_id>
# If the sidetab in this window was resized (its width differs from the session's
# stored expanded width), persist the new width and resize every other window's
# sidetab to match — so the sidebar width is consistent across the session.
# No-op while collapsed. Converges (other windows then already match → no loop).
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

WINDOW_ID="$1"
[ -z "$WINDOW_ID" ] && exit 0

SESSION_ID="$(tmux display-message -p -t "$WINDOW_ID" '#{session_id}' 2>/dev/null)"
[ -z "$SESSION_ID" ] && exit 0

# Only sync the expanded width.
[ "$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")" = "1" ] && exit 0

sidetab="$(find_sidetab_pane "$WINDOW_ID")"
[ -z "$sidetab" ] && exit 0

cur="$(tmux display-message -p -t "$sidetab" '#{pane_width}' 2>/dev/null)"
[ -z "$cur" ] && exit 0

default_w="$(get_tmux_option '@sidetabs-expanded-width' "$DEFAULT_EXPANDED_WIDTH")"
stored="$(get_session_option "$SESSION_ID" "$WIDTH_OPTION" "$default_w")"
[ "$cur" = "$stored" ] && exit 0

# A genuine resize: remember it and propagate to the other windows' sidetabs.
set_session_option "$SESSION_ID" "$WIDTH_OPTION" "$cur"
tmux list-windows -t "$SESSION_ID" -F '#{window_id}' 2>/dev/null \
    | while read -r w; do
        st="$(find_sidetab_pane "$w")"
        [ -z "$st" ] && continue
        [ "$st" = "$sidetab" ] && continue
        tmux resize-pane -t "$st" -x "$cur" 2>/dev/null || true
      done

exit 0
