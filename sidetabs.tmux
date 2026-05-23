#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

source "$SCRIPTS_DIR/variables.sh"
source "$SCRIPTS_DIR/helpers.sh"

register_hooks() {
    tmux set-hook -g after-new-window \
        "run-shell -b '$SCRIPTS_DIR/create_sidebar.sh #{window_id}'"
    tmux set-hook -g after-new-session \
        "run-shell -b '$SCRIPTS_DIR/create_sidebar.sh #{window_id}'"
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
    # Recreate a sidetab if it disappears (manual kill) or if a too-narrow
    # window later widens. window-layout-changed covers both; create_sidebar
    # is idempotent and lock-guarded so this can't spawn duplicates.
    tmux set-hook -g window-layout-changed \
        "run-shell -b '$SCRIPTS_DIR/layout_changed.sh #{window_id}'"
    tmux set-hook -g window-resized \
        "run-shell -b '$SCRIPTS_DIR/resurrect.sh #{window_id}'"
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

    local skip_nav
    skip_nav="$(get_tmux_option "@sidetabs-skip-nav" "$DEFAULT_SKIP_NAV")"
    if [ "$skip_nav" = "on" ]; then
        # Preserve user's is_vim detection regex verbatim — mirrors their .tmux.conf.
        # C-h is intentionally left alone: the user's own binding (select-pane -L)
        # moves into the sidetab, which is how you enter it. We only override
        # C-j / C-k so that, when focused IN the sidetab, they step through windows.
        local is_vim
        is_vim="ps -o state= -o comm= -t '#{pane_tty}' | grep -iqE '^[^TXZ ]+ +(\\\\S+\\\\/)?g?(view|n?vim?x?)(diff)?\$'"

        # C-j: vim → forward; sidetab focused → next-window; else → select-pane -D.
        tmux bind-key -n 'C-j' \
            "if-shell \"$is_vim\" \
                'send-keys C-j' \
                'run-shell \"$SCRIPTS_DIR/sidetab_nav.sh down #{pane_id}\"'"

        # C-k: vim → forward; sidetab focused → previous-window; else → select-pane -U.
        tmux bind-key -n 'C-k' \
            "if-shell \"$is_vim\" \
                'send-keys C-k' \
                'run-shell \"$SCRIPTS_DIR/sidetab_nav.sh up #{pane_id}\"'"
    fi
}

initial_setup() {
    tmux list-windows -a -F '#{window_id}' 2>/dev/null \
        | while read -r wid; do
            "$SCRIPTS_DIR/create_sidebar.sh" "$wid"
          done
}

main() {
    register_hooks
    bind_keys
    initial_setup
}
main
