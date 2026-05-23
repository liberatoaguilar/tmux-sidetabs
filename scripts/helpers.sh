#!/usr/bin/env bash

get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local value
    value="$(tmux show-option -gqv "$option" 2>/dev/null)"
    [ -z "$value" ] && echo "$default_value" || echo "$value"
}

set_tmux_option() {
    tmux set-option -gq "$1" "$2"
}

get_session_option() {
    local session_id="$1" option="$2" default_value="$3" value
    value="$(tmux show-option -t "$session_id" -qv "$option" 2>/dev/null)"
    [ -z "$value" ] && echo "$default_value" || echo "$value"
}

set_session_option() {
    tmux set-option -t "$1" -q "$2" "$3"
}

get_pane_option() {
    local pane_id="$1" option="$2" default_value="$3" value
    value="$(tmux show-option -p -t "$pane_id" -qv "$option" 2>/dev/null)"
    [ -z "$value" ] && echo "$default_value" || echo "$value"
}

set_pane_option() {
    tmux set-option -p -t "$1" -q "$2" "$3"
}

# Returns the pane_id of the sidetab pane in a window, or empty.
find_sidetab_pane() {
    local window_id="$1"
    tmux list-panes -t "$window_id" -F '#{pane_id} #{@is_sidetab}' 2>/dev/null \
        | awk '$2 == "1" { print $1; exit }'
}

window_has_sidetab() {
    local window_id="$1"
    [ -n "$(find_sidetab_pane "$window_id")" ]
}

pane_is_sidetab() {
    local pane_id="$1"
    [ "$(get_pane_option "$pane_id" "@is_sidetab" "0")" = "1" ]
}

# Current epoch ms (portable: uses python3 if available, otherwise date+nanoseconds).
now_ms() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time()*1000))'
    else
        # macOS date doesn't support %N; fall back to seconds*1000.
        echo $(( $(date +%s) * 1000 ))
    fi
}
