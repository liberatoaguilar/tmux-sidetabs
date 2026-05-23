#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

source "$SCRIPTS_DIR/variables.sh"
source "$SCRIPTS_DIR/helpers.sh"

register_hooks() {
    tmux set-hook -g after-new-window \
        "run-shell -b '$SCRIPTS_DIR/create_sidebar.sh #{session_id} #{window_id}'"
    tmux set-hook -g after-new-session \
        "run-shell -b '$SCRIPTS_DIR/create_sidebar.sh #{session_id} #{window_id}'"
    tmux set-hook -g window-renamed \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh #{session_id}'"
    tmux set-hook -g session-window-changed \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh #{session_id}'"
    tmux set-hook -g window-linked \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh #{session_id}'"
    tmux set-hook -g window-unlinked \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh #{session_id}'"
    tmux set-hook -g pane-focus-in \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh #{session_id}'"
    tmux set-hook -g alert-activity \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh #{session_id}'"
}

bind_keys() {
    local toggle_key
    toggle_key="$(get_tmux_option "@sidetabs-toggle-key" "$DEFAULT_TOGGLE_KEY")"
    tmux bind-key "$toggle_key" run-shell "$SCRIPTS_DIR/toggle_collapse.sh"

    local uninstall_key
    uninstall_key="$(get_tmux_option "@sidetabs-uninstall-key" "")"
    if [ -n "$uninstall_key" ]; then
        tmux bind-key "$uninstall_key" run-shell "$SCRIPTS_DIR/uninstall.sh"
    fi
}

initial_setup() {
    tmux list-windows -a -F '#{session_id} #{window_id}' 2>/dev/null \
        | while read -r sid wid; do
            "$SCRIPTS_DIR/create_sidebar.sh" "$sid" "$wid"
          done
}

main() {
    register_hooks
    bind_keys
    initial_setup
}
main
