#!/usr/bin/env bash
# Long-lived render loop. Runs inside the sidetab pane.
#
# Redraws every second (and immediately on SIGUSR1 from refresh.sh). The draw
# is flicker-free: it homes the cursor and overwrites each line with a
# clear-to-EOL, then clears below — no full-screen wipe. Reprinting identical
# content is therefore invisible, which also lets us recover transparently when
# tmux repaints the pane (e.g. right after the pane is created or resized).
#
# The active window is drawn as a full-width highlighted bar (nord palette by
# default); idle windows are plain colored text; activity is flagged in yellow.

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

# --- Theme -----------------------------------------------------------------
ESC="$(printf '\033')"
hex_rgb() { local h="${1#\#}"; printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }

active_bg="$(get_tmux_option '@sidetabs-active-bg' '#88c0d0')"
active_fg="$(get_tmux_option '@sidetabs-active-fg' '#2e3440')"
idle_fg="$(get_tmux_option '@sidetabs-fg' '#d8dee9')"
activity_fg="$(get_tmux_option '@sidetabs-activity-fg' '#ebcb8b')"

SGR_ACTIVE="${ESC}[1;48;2;$(hex_rgb "$active_bg");38;2;$(hex_rgb "$active_fg")m"
SGR_IDLE="${ESC}[38;2;$(hex_rgb "$idle_fg")m"
SGR_ACT="${ESC}[1;38;2;$(hex_rgb "$activity_fg")m"
RESET="${ESC}[0m"

emit_row() {
    local active="$1" activity="$2" label="$3" width="$4"
    local marker body maxbody pad spaces
    if [ "$active" = "1" ]; then marker="▸"
    elif [ "$activity" = "1" ]; then marker="•"
    else marker=" "; fi
    maxbody=$((width - 1)); [ "$maxbody" -lt 0 ] && maxbody=0
    body="${label:0:maxbody}"
    if [ "$active" = "1" ]; then
        pad=$((width - 1 - ${#body})); [ "$pad" -lt 0 ] && pad=0
        spaces="$(printf '%*s' "$pad" '')"
        printf '%s%s%s%s%s\n' "$SGR_ACTIVE" "$marker" "$body" "$spaces" "$RESET"
    elif [ "$activity" = "1" ]; then
        printf '%s%s%s%s\n' "$SGR_ACT" "$marker" "$body" "$RESET"
    else
        printf '%s%s%s%s\n' "$SGR_IDLE" "$marker" "$body" "$RESET"
    fi
}

emit_lines() {
    local collapsed width
    collapsed="$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")"
    width="$(tmux display-message -p -t "$MY_PANE_ID" '#{pane_width}' 2>/dev/null)"
    [ -z "$width" ] && width=4
    if [ "$collapsed" = "1" ]; then
        tmux list-windows -t "$SESSION_ID" \
            -F '#{window_active} #{window_activity_flag} #{window_index}' \
            2>/dev/null \
            | while read -r active activity idx; do
                emit_row "$active" "$activity" "$idx" "$width"
              done
    else
        tmux list-windows -t "$SESSION_ID" \
            -F '#{window_active} #{window_activity_flag} #{window_index} #{window_name}' \
            2>/dev/null \
            | while read -r active activity idx name; do
                emit_row "$active" "$activity" "$idx $name" "$width"
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
