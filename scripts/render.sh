#!/usr/bin/env bash
# Long-lived render loop. Runs inside the sidetab pane.
# Arg: session_id to query.
#
# Polls once per second and redraws only when the frame changes (no flicker
# when idle). A SIGUSR1 (sent by refresh.sh on tmux hooks) interrupts the
# sleep so changes show up immediately instead of waiting for the next tick.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

SESSION_ID="$1"

# No-op handler: its only job is to interrupt `wait` so the loop re-renders now.
trap ':' USR1

MY_PANE_ID="$TMUX_PANE"
set_pane_option "$MY_PANE_ID" "$RENDER_PID_OPTION" "$$"

# Hide cursor + restore on exit.
printf '\033[?25l'
trap 'printf "\033[?25h"; exit 0' EXIT INT TERM

render_expanded() {
    tmux list-windows -t "$SESSION_ID" \
        -F '#{window_active} #{window_activity_flag} #{window_index} #{window_name}' \
        2>/dev/null \
        | while read -r active activity idx name; do
            if [ "$active" = "1" ]; then
                marker="▸"
            elif [ "$activity" = "1" ]; then
                marker="•"
            else
                marker=" "
            fi
            printf '%s%s %s\n' "$marker" "$idx" "${name:0:16}"
          done
}

render_collapsed() {
    tmux list-windows -t "$SESSION_ID" \
        -F '#{window_active} #{window_activity_flag} #{window_index}' \
        2>/dev/null \
        | while read -r active activity idx; do
            if [ "$active" = "1" ]; then
                marker="▸"
            elif [ "$activity" = "1" ]; then
                marker="·"
            else
                marker=" "
            fi
            printf '%s%s\n' "$marker" "$idx"
          done
}

build_frame() {
    local collapsed
    collapsed="$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")"
    if [ "$collapsed" = "1" ]; then
        render_collapsed
    else
        render_expanded
    fi
}

last_frame=""
while true; do
    frame="$(build_frame)"
    if [ "$frame" != "$last_frame" ]; then
        printf '\033[2J\033[H%s' "$frame"
        last_frame="$frame"
    fi
    sleep 1 &
    wait $! 2>/dev/null
done
