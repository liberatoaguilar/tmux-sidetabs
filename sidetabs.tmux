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
    # window later widens. window-layout-changed fires for both (a resize
    # changes pane geometry too), and create_sidebar is idempotent +
    # lock-guarded, so this can't spawn duplicates. tmux-resurrect restores are
    # handled separately by scripts/resurrect_post.sh.
    tmux set-hook -g window-layout-changed \
        "run-shell -b '$SCRIPTS_DIR/layout_changed.sh #{window_id}'"
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

    local search_key
    search_key="$(get_tmux_option "@sidetabs-search-key" "$DEFAULT_SEARCH_KEY")"
    if [ -n "$search_key" ]; then
        # fzf if available -> fuzzy popup; otherwise tmux's native window picker.
        if command -v fzf >/dev/null 2>&1; then
            tmux bind-key "$search_key" display-popup -E -w 60% -h 50% -T ' windows ' \
                "$SCRIPTS_DIR/search.sh #{session_id}"
        else
            tmux bind-key "$search_key" choose-tree -Zw
        fi
    fi

    # Sidebar-focused flag + timer keys (root table, act only when the focused
    # pane is a sidetab; otherwise pass the key through). Bound here, not in
    # keys.conf, so they work regardless of @sidetabs-skip-nav and stay
    # configurable. Set an option to "none" to skip its binding (an empty
    # string can't disable: show-option can't distinguish it from unset, so
    # the default would substitute).
    local flag_key timer_key timer_menu_key
    flag_key="$(get_tmux_option "@sidetabs-flag-key" "$DEFAULT_FLAG_KEY")"
    case "$flag_key" in none) flag_key="" ;; esac
    if [ -n "$flag_key" ]; then
        tmux bind-key -n "$flag_key" \
            "if-shell -F '#{==:#{@is_sidetab},1}' \
                'run-shell -b \"$SCRIPTS_DIR/flag_cycle.sh #{window_id}\"' \
                'send-keys $flag_key'"
    fi

    timer_key="$(get_tmux_option "@sidetabs-timer-key" "$DEFAULT_TIMER_KEY")"
    case "$timer_key" in none) timer_key="" ;; esac
    if [ -n "$timer_key" ]; then
        tmux bind-key -n "$timer_key" \
            "if-shell -F '#{==:#{@is_sidetab},1}' \
                'run-shell -b \"$SCRIPTS_DIR/timer.sh toggle #{window_id}\"' \
                'send-keys $timer_key'"
    fi

    timer_menu_key="$(get_tmux_option "@sidetabs-timer-menu-key" "$DEFAULT_TIMER_MENU_KEY")"
    case "$timer_menu_key" in none) timer_menu_key="" ;; esac
    if [ -n "$timer_menu_key" ]; then
        tmux bind-key -n "$timer_menu_key" \
            "if-shell -F '#{==:#{@is_sidetab},1}' \
                'run-shell -b \"$SCRIPTS_DIR/timer.sh menu #{window_id} #{client_name}\"' \
                'send-keys $timer_menu_key'"
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

        # Sidebar-focused window management (C-n new, C-r rename, C-x kill,
        # M-k/M-j reorder). Pure tmux bindings; pass through when not focused
        # in the sidebar. Sourced from a static conf to keep the quoting sane.
        tmux source-file "$SCRIPTS_DIR/keys.conf"
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
