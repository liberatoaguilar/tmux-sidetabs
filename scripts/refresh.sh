#!/usr/bin/env bash
# Send SIGUSR1 to every sidetab render PID in the given session.
# Debounced to REFRESH_DEBOUNCE_MS per session.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

SESSION_ID="$1"

# Debounce: skip if last refresh was <REFRESH_DEBOUNCE_MS ago.
now="$(now_ms)"
last="$(get_session_option "$SESSION_ID" "$LAST_REFRESH_OPTION" "0")"
if [ "$((now - last))" -lt "$REFRESH_DEBOUNCE_MS" ]; then
    exit 0
fi
set_session_option "$SESSION_ID" "$LAST_REFRESH_OPTION" "$now"

tmux list-windows -t "$SESSION_ID" -F '#{window_id}' 2>/dev/null \
    | while read -r wid; do
        sidetab="$(find_sidetab_pane "$wid")"
        [ -z "$sidetab" ] && continue
        pid="$(get_pane_option "$sidetab" "$RENDER_PID_OPTION" "")"
        [ -z "$pid" ] && continue
        kill -USR1 "$pid" 2>/dev/null || true
      done
