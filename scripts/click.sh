#!/usr/bin/env bash
# Usage: click.sh <mouse_y> <mouse_pane_id>
#
# Bound to MouseDown1Pane, but only invoked when the moused pane IS a sidetab
# (the if-shell condition in sidetabs.tmux guarantees this). Maps the clicked
# row (mouse_y) to a window via the @sidetabs_rowmap option that render.sh
# writes each draw, then selects that window and focuses its content pane.
# A click on a non-row line (header / rule / summary / blank) just focuses the
# sidebar pane, so clicking the sidebar always "enters" it.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

Y="$1"
PANE="$2"

# Derive the session from the moused pane (robust — see render.sh's note on why
# passing ids through tmux's command parser is unreliable).
SESSION_ID="$(tmux display-message -p -t "$PANE" '#{session_id}' 2>/dev/null)"
[ -z "$SESSION_ID" ] && exit 0

rowmap="$(get_session_option "$SESSION_ID" "$ROWMAP_OPTION" "")"

win=""
for entry in $rowmap; do
    if [ "${entry%%:*}" = "$Y" ]; then
        win="${entry#*:}"
        break
    fi
done

if [ -n "$win" ]; then
    tmux select-window -t "$win"
    content="$(find_content_pane "$win" || true)"
    [ -n "$content" ] && tmux select-pane -t "$content"
else
    # Header/rule/summary/blank: just enter the sidebar.
    tmux select-pane -t "$PANE"
fi
