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
    # Visibility transitions (window switch, attach, session switch, link/
    # unlink) use `refresh.sh force` — hidden sidebars only rebuild on the USR1
    # this sends, so these wakes must never be lost to the debounce. Cosmetic
    # events (rename, activity, focus churn) stay debounced; the viewed
    # sidebar's own 0.5s tick covers a swallowed one.
    tmux set-hook -g window-renamed \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh'"
    # A rename changes the KEY the flag store is filed under (session + window
    # name — window ids do not survive a restart, so names are all there is).
    # Re-snapshotting here re-files the flag under the new name; the row under
    # the old name is left behind untouched, which is what brings the colour
    # back if the window is ever renamed back.
    tmux set-hook -g 'window-renamed[1]' \
        "run-shell -b '$SCRIPTS_DIR/flag_store.sh sync'"
    # --- bottom session strip (@sidetabs-session-strip, default off) ---------
    # Registered HERE, in the plugin, rather than typed into a conf — that is
    # the fix for the reported bug. The strip this replaces kept its
    # neighbour-colour bookkeeping in per-session options refreshed by hooks
    # that existed only in a RUNNING server, so after a machine restart the
    # options were stale and the separators came back wrong. Hooks registered by
    # the plugin are re-registered every time the conf is loaded, so they
    # survive a restart. Every one of these is a no-op while the switch is off:
    # strip.sh checks it before touching anything.
    #
    # The strip is a per-SESSION status-left, so the events that matter are the
    # ones that change the set of sessions, what is happening inside one, or
    # which session a client is looking at.
    tmux set-hook -g session-created \
        "run-shell -b '$SCRIPTS_DIR/strip.sh'"
    tmux set-hook -g session-closed \
        "run-shell -b '$SCRIPTS_DIR/strip.sh'"
    tmux set-hook -g session-renamed \
        "run-shell -b '$SCRIPTS_DIR/strip.sh'"
    # A session rename changes the KEY its colour is filed under in the durable
    # store (session NAME — session ids do not survive a restart), exactly as a
    # window rename does for a window flag. Without this the colour would come
    # back on the OLD name after a restart and the renamed session would look
    # uncoloured. The row under the old name is left behind untouched, which is
    # what brings the colour back if the session is ever renamed back.
    tmux set-hook -g 'session-renamed[1]' \
        "run-shell -b '$SCRIPTS_DIR/flag_store.sh sync'"
    # A bell is one of the two things that can recolour a pill. Note this is a
    # real hook on the ALERT, not a poll of #{session_bell_flag} — that format
    # is broken on tmux 3.6b and always reports 0 (see strip.sh).
    tmux set-hook -g alert-bell \
        "run-shell -b '$SCRIPTS_DIR/strip.sh'"
    # Resizing changes how much of the strip fits. Nothing shrinks yet (the
    # strip simply clips), but status-left-length is regenerated from the real
    # session list here so a later width cascade has its trigger already wired.
    tmux set-hook -g client-resized \
        "run-shell -b '$SCRIPTS_DIR/strip.sh'"
    tmux set-hook -g 'session-window-changed[0]' \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh force'"
    tmux set-hook -g 'session-window-changed[1]' \
        "run-shell -b '$SCRIPTS_DIR/timer_focus.sh'"
    # Visiting a tab consumes its agent "done"/"attention" signal (bell
    # semantics). #{window_id} is safe to interpolate through run-shell's sh:
    # window ids are "@N", unlike session ids ("$N", which sh would expand).
    tmux set-hook -g 'session-window-changed[2]' \
        "run-shell -b '$SCRIPTS_DIR/agent_status.sh visited #{window_id}'"
    # Focus engine also needs client transitions (attach/detach/session switch).
    tmux set-hook -g 'client-session-changed[0]' "run-shell -b '$SCRIPTS_DIR/timer_focus.sh'"
    tmux set-hook -g 'client-attached[0]'        "run-shell -b '$SCRIPTS_DIR/timer_focus.sh'"
    tmux set-hook -g 'client-detached[0]'        "run-shell -b '$SCRIPTS_DIR/timer_focus.sh'"
    # Wake sleeping sidebars the moment a client can see them again. Detach is
    # a visibility transition too: the last client leaving flips hidden
    # active-window sidebars to visible under the zero-clients rule.
    tmux set-hook -g 'client-session-changed[1]' "run-shell -b '$SCRIPTS_DIR/refresh.sh force'"
    tmux set-hook -g 'client-attached[1]'        "run-shell -b '$SCRIPTS_DIR/refresh.sh force'"
    tmux set-hook -g 'client-detached[1]'        "run-shell -b '$SCRIPTS_DIR/refresh.sh force'"
    # Fallback timer restore. tmux-continuum skips auto-restore ENTIRELY — and
    # with it tmux-resurrect's post-restore hook, our only other delivery path —
    # whenever another tmux server was running at startup or the server is past
    # @continuum-restore-max-delay, leaving every timer silently zeroed. This is
    # NOT a bare restore-on-attach hook: `boot` mode self-gates on server age
    # and on the once-per-generation @sidetabs_timer_restored flag (see the
    # header of timer_restore.sh), because seeding a window created LATER from
    # same-name log rows would be a silent billing overcount.
    tmux set-hook -g 'client-attached[2]'        "run-shell -b '$SCRIPTS_DIR/timer_restore.sh boot'"
    # The same fallback for flag colours, with its own generation flag
    # (@sidetabs_flag_restored) so disabling one restore cannot make the other
    # believe this generation is already seeded. Same age gate, same reason:
    # seeding on a LATER attach would paint a freshly created window with a
    # long-gone same-named window's colour.
    tmux set-hook -g 'client-attached[3]'        "run-shell -b '$SCRIPTS_DIR/flag_restore.sh boot'"
    # Strip regeneration on the client transitions. A client attaching to, or
    # switching to, a session needs that session's own status-left to exist —
    # each string highlights ITS session as the current one, which is what lets
    # two clients on two different sessions each see themselves highlighted.
    # Detach matters for the same reason attach does: it is a session the strip
    # may never have been generated for while it had no client.
    # flag_restore.sh[3] above ends with its own `strip.sh force` when it
    # actually re-seeded something, so the strip cannot be left showing
    # pre-restore colours if these two race (both are `run-shell -b`).
    tmux set-hook -g 'client-attached[4]'        "run-shell -b '$SCRIPTS_DIR/strip.sh'"
    tmux set-hook -g 'client-session-changed[2]' "run-shell -b '$SCRIPTS_DIR/strip.sh'"
    tmux set-hook -g 'client-detached[2]'        "run-shell -b '$SCRIPTS_DIR/strip.sh'"
    tmux set-hook -g window-linked \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh force'"
    tmux set-hook -g window-unlinked \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh force'"
    tmux set-hook -g 'pane-focus-in[0]' \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh'"
    # Moving between panes of the window you are ALREADY on is also "you
    # looked", so it consumes the agent signal too — session-window-changed only
    # fires on a window CHANGE. (This hook only fires at all when focus-events
    # is on; the raise-time check in agent_status.sh is what covers the rest.)
    tmux set-hook -g 'pane-focus-in[1]' \
        "run-shell -b '$SCRIPTS_DIR/agent_status.sh visited #{window_id}'"
    tmux set-hook -g alert-activity \
        "run-shell -b '$SCRIPTS_DIR/refresh.sh'"
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
    local flag_key flag_picker_key timer_key timer_menu_key
    flag_key="$(get_tmux_option "@sidetabs-flag-key" "$DEFAULT_FLAG_KEY")"
    case "$flag_key" in none) flag_key="" ;; esac
    if [ -n "$flag_key" ]; then
        tmux bind-key -n "$flag_key" \
            "if-shell -F '#{==:#{@is_sidetab},1}' \
                'run-shell -b \"$SCRIPTS_DIR/flag_cycle.sh #{window_id}\"' \
                'send-keys $flag_key'"
    fi

    # Picker: same relationship to the cycle key as M-t has to C-t — the key
    # steps, the meta-key opens the full menu.
    flag_picker_key="$(get_tmux_option "@sidetabs-flag-picker-key" "$DEFAULT_FLAG_PICKER_KEY")"
    case "$flag_picker_key" in none) flag_picker_key="" ;; esac
    if [ -n "$flag_picker_key" ]; then
        tmux bind-key -n "$flag_picker_key" \
            "if-shell -F '#{==:#{@is_sidetab},1}' \
                'run-shell -b \"$SCRIPTS_DIR/flag_picker.sh #{window_id} #{client_name}\"' \
                'send-keys $flag_picker_key'"
    fi

    # Session colour: a picker with no cycle counterpart (a session colour is
    # set once; a window flag is flipped daily). The target passed through is
    # the PANE id, NOT #{session_id}: run-shell hands its command string to
    # `sh -c`, and a session id is spelled "$0"/"$1"/… so sh expands it away to
    # the literal "sh" (measured on tmux 3.6b). session_flag_picker.sh resolves
    # the session from the pane instead, and threads the same pane id into the
    # menu entries, which go through `sh -c` a second time.
    local session_flag_key
    session_flag_key="$(get_tmux_option "@sidetabs-session-flag-key" "$DEFAULT_SESSION_FLAG_KEY")"
    case "$session_flag_key" in none) session_flag_key="" ;; esac
    if [ -n "$session_flag_key" ]; then
        tmux bind-key -n "$session_flag_key" \
            "if-shell -F '#{==:#{@is_sidetab},1}' \
                'run-shell -b \"$SCRIPTS_DIR/session_flag_picker.sh #{pane_id} #{client_name}\"' \
                'send-keys $session_flag_key'"
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

    # Note editor: same sidebar gate as the flag/timer keys, but the action is a
    # popup running $EDITOR. display-popup needs a client, which a key binding
    # always has (unlike a `run-shell -b` hook), so it is invoked directly here
    # rather than from inside note.sh.
    local note_key
    note_key="$(get_tmux_option "@sidetabs-note-key" "$DEFAULT_NOTE_KEY")"
    case "$note_key" in none) note_key="" ;; esac
    if [ -n "$note_key" ]; then
        tmux bind-key -n "$note_key" \
            "if-shell -F '#{==:#{@is_sidetab},1}' \
                'display-popup -E -w 70% -h 60% -T \" note \" \"$SCRIPTS_DIR/note.sh edit-popup #{window_id}\"' \
                'send-keys $note_key'"
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
    # Draw the strip once at load, so enabling @sidetabs-session-strip and
    # reloading the conf shows it immediately instead of waiting for the next
    # session event. `force` because a conf reload is exactly the moment a
    # debounce must not swallow the only regenerate that will happen. Still a
    # no-op while the switch is off, and `|| true` so a strip failure can never
    # abort plugin load.
    "$SCRIPTS_DIR/strip.sh" force || true
}

main() {
    register_hooks
    bind_keys
    initial_setup
}
main
