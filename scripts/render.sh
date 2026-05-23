#!/usr/bin/env bash
# Long-lived render loop. Runs inside the sidetab pane.
# Arg: session_id to query.
#
# Redraws every second (and immediately on SIGUSR1 from refresh.sh). The draw
# is flicker-free: it homes the cursor and overwrites each line with a
# clear-to-EOL, then clears below — no full-screen wipe. Reprinting identical
# content is therefore invisible, which also lets us recover transparently when
# tmux repaints the pane (e.g. right after the pane is created or resized).

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

MY_PANE_ID="$TMUX_PANE"

# Determine which session's windows to list from our OWN pane. Passing the id
# as a command argument is unreliable: tmux's command parser strips quoting and
# then sh expands tokens like `$0`, corrupting it. Querying the pane is robust.
SESSION_ID="$(tmux display-message -p -t "$MY_PANE_ID" '#{session_id}' 2>/dev/null)"
[ -z "$SESSION_ID" ] && SESSION_ID="$1"

# No-op handler: its only job is to interrupt `wait` so the loop redraws now.
trap ':' USR1

set_pane_option "$MY_PANE_ID" "$RENDER_PID_OPTION" "$$"

# Hide cursor + restore on exit.
printf '\033[?25l'
trap 'printf "\033[?25h"; exit 0' EXIT INT TERM

emit_lines() {
    local collapsed
    collapsed="$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")"
    if [ "$collapsed" = "1" ]; then
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
    else
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
    fi
}

draw() {
    printf '\033[H'
    emit_lines | while IFS= read -r line; do
        printf '%s\033[K\n' "$line"
    done
    printf '\033[J'
}

while true; do
    draw
    sleep 1 &
    wait $! 2>/dev/null
done
