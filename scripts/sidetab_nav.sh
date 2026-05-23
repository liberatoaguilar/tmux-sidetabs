#!/usr/bin/env bash
# Usage: sidetab_nav.sh <down|up> <originating_pane_id>
# If origin pane is the sidetab → next/previous window, keeping focus in the
# new window's sidetab so you can keep browsing.
# Else → fall through to the user's normal select-pane -D/-U behavior.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

DIRECTION="$1"
ORIGIN_PANE="$2"

if pane_is_sidetab "$ORIGIN_PANE"; then
    case "$DIRECTION" in
        down) tmux next-window ;;
        up)   tmux previous-window ;;
    esac
    # Re-focus the sidetab in the now-active window for continuous browsing.
    new_window="$(tmux display-message -p '#{window_id}')"
    new_sidetab="$(find_sidetab_pane "$new_window")"
    [ -n "$new_sidetab" ] && tmux select-pane -t "$new_sidetab"
else
    case "$DIRECTION" in
        down) tmux select-pane -D ;;
        up)   tmux select-pane -U ;;
    esac
fi
