#!/usr/bin/env bash
# Kill every sidetab pane, unset hooks, unbind keys.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

# Unhook everything FIRST — otherwise killing a sidetab pane fires
# window-layout-changed and the resurrection hook recreates it.
#
# Naming an array hook without an index clears EVERY index (verified on tmux
# 3.6) — so a bare `set-hook -gu after-new-window` doesn't just remove ours,
# it wipes any handler another plugin appended with `set-hook -ga` on the
# same name. tmux-ticker (a separate plugin the user also runs) does exactly
# that on after-new-window, after-new-session, window-renamed,
# window-layout-changed and session-window-changed, so a bare unset here used
# to silently break it with no error. This list is therefore the exact
# indices sidetabs.tmux's register_hooks() claims, one entry per set-hook
# call there — a call with no bracketed index occupies index [0] under tmux's
# array-hook rules, so it is unset as "name[0]" here rather than by bare
# name. tests/uninstall_hooks_smoke.sh's drift check greps both files and
# fails if this list and register_hooks() ever disagree.
hook_indices=(
    'after-new-window[0]'
    'after-new-session[0]'
    'window-renamed[0]'
    'window-renamed[1]'
    'session-window-changed[0]'
    'session-window-changed[1]'
    'session-window-changed[2]'
    'client-session-changed[0]'
    'client-session-changed[1]'
    'client-attached[0]'
    'client-attached[1]'
    'client-attached[2]'
    'client-attached[3]'
    'client-attached[4]'
    'client-session-changed[2]'
    'client-detached[0]'
    'client-detached[1]'
    'client-detached[2]'
    'client-resized[0]'
    'session-created[0]'
    'session-closed[0]'
    'session-renamed[0]'
    'session-renamed[1]'
    'alert-bell[0]'
    'window-linked[0]'
    'window-unlinked[0]'
    'pane-focus-in[0]'
    'pane-focus-in[1]'
    'alert-activity[0]'
    'window-layout-changed[0]'
)
for hook in "${hook_indices[@]}"; do
    tmux set-hook -gu "$hook" 2>/dev/null || true
done

# Now kill all sidetab panes.
tmux list-panes -a -F '#{pane_id} #{@is_sidetab}' 2>/dev/null \
    | awk '$2 == "1" { print $1 }' \
    | while read -r pid; do
        tmux kill-pane -t "$pid" 2>/dev/null || true
      done

# Unbind the toggle (and optional uninstall) key.
toggle_key="$(get_tmux_option "@sidetabs-toggle-key" "$DEFAULT_TOGGLE_KEY")"
tmux unbind-key "$toggle_key" 2>/dev/null || true

uninstall_key="$(get_tmux_option "@sidetabs-uninstall-key" "")"
[ -n "$uninstall_key" ] && tmux unbind-key "$uninstall_key" 2>/dev/null || true

# Unbind the window-search key.
search_key="$(get_tmux_option "@sidetabs-search-key" "$DEFAULT_SEARCH_KEY")"
[ -n "$search_key" ] && tmux unbind-key "$search_key" 2>/dev/null || true

# Unbind the flag/timer keys (root table). "none" = binding was skipped.
flag_key="$(get_tmux_option "@sidetabs-flag-key" "$DEFAULT_FLAG_KEY")"
case "$flag_key" in none) flag_key="" ;; esac
[ -n "$flag_key" ] && tmux unbind-key -n "$flag_key" 2>/dev/null || true
flag_picker_key="$(get_tmux_option "@sidetabs-flag-picker-key" "$DEFAULT_FLAG_PICKER_KEY")"
case "$flag_picker_key" in none) flag_picker_key="" ;; esac
[ -n "$flag_picker_key" ] && tmux unbind-key -n "$flag_picker_key" 2>/dev/null || true
session_flag_key="$(get_tmux_option "@sidetabs-session-flag-key" "$DEFAULT_SESSION_FLAG_KEY")"
case "$session_flag_key" in none) session_flag_key="" ;; esac
[ -n "$session_flag_key" ] && tmux unbind-key -n "$session_flag_key" 2>/dev/null || true
timer_key="$(get_tmux_option "@sidetabs-timer-key" "$DEFAULT_TIMER_KEY")"
case "$timer_key" in none) timer_key="" ;; esac
[ -n "$timer_key" ] && tmux unbind-key -n "$timer_key" 2>/dev/null || true
timer_menu_key="$(get_tmux_option "@sidetabs-timer-menu-key" "$DEFAULT_TIMER_MENU_KEY")"
case "$timer_menu_key" in none) timer_menu_key="" ;; esac
[ -n "$timer_menu_key" ] && tmux unbind-key -n "$timer_menu_key" 2>/dev/null || true
note_key="$(get_tmux_option "@sidetabs-note-key" "$DEFAULT_NOTE_KEY")"
case "$note_key" in none) note_key="" ;; esac
[ -n "$note_key" ] && tmux unbind-key -n "$note_key" 2>/dev/null || true

# Unbind the navigation + window-management overrides (C-h is left to the user's).
for k in 'C-j' 'C-k' 'C-n' 'C-r' 'C-x' 'M-j' 'M-k'; do
    tmux unbind-key -n "$k" 2>/dev/null || true
done

# --- restore the status line -------------------------------------------------
# This file used to claim the strip's status-left needed no restoring, because
# "status-left comes from the user's own conf, so reloading it puts the original
# back for free". THAT REASONING IS WRONG, and was verified wrong on tmux 3.6b.
#
# status-left is a PER-SESSION option and strip.sh sets it per session (that is
# the whole design — one generated string per session). A session-scoped value
# completely SHADOWS the global one: with `set-option -t alpha status-left
# SESSION_LEFT` in force, a later `set -g status-left GLOBAL_LEFT` renders
# nothing at all, and `show-option -t alpha -qv status-left` still answers
# SESSION_LEFT. So a conf reload restores exactly nothing here — it writes the
# global that the leftover per-session value is hiding. The only thing that puts
# the user's bar back is `set-option -u -t <session> status-left`, which drops
# the session-scoped value so the global shows through again.
#
# The premise was worst where it mattered most: a conf that has stopped setting
# status-left at all (because the strip now provides it) has nothing to reload
# BACK, so the old advice left the user with the plugin's generated bar and no
# obvious way out.
#
# WHICH SIDES ARE OURS TO UNSET. status-left / status-left-length always: the
# plugin writes both for every session whenever the strip is on. status-right /
# status-right-length ONLY when @sidetabs-strip-right-1 is set, which is the
# exact condition under which strip.sh writes that side at all — the same
# ownership rule the README documents. Unsetting a status-right the plugin never
# wrote would destroy the user's own clock, which is precisely the content
# strip.sh goes out of its way to measure and reserve rather than touch.
# (A side that WAS ours and has since been disowned by unsetting
# @sidetabs-strip-right-1 keeps the string the plugin last wrote — same
# documented consequence as disowning it while installed; taking the side back
# is the user's move, not ours to guess at.)
restore_batch=""

# Bookkeeping globals the plugin writes on its own behalf. None of these is user
# state: they are debounce stamps and once-per-server-generation claims, and a
# leftover @sidetabs_restoring="1" would make a REINSTALL in the same server
# stand down from creating sidebars. User state — window flags, timers, notes,
# session colours — is deliberately left alone: it is the user's data, it has
# durable stores of its own, and an uninstall is not a delete.
for gopt in \
    "$STRIP_LAST_OPTION" \
    "$LAST_REFRESH_OPTION" \
    "$RESTORING_OPTION" \
    "$TIMER_RESTORED_OPTION" \
    "$FLAG_RESTORED_OPTION"
do
    restore_batch="${restore_batch}set-option -gqu ${gopt}
"
done

# One `tmux list-sessions`, then ONE batch — the same idiom strip.sh installs the
# strip with, and for the same reason: a tmux process invocation costs ~5ms while
# a command inside one costs ~nothing, so a ten-session server pays one fork
# instead of twenty-plus. `-q` keeps `set-option -u` quiet on a session that
# never had the option set, so one such line cannot abort the rest of the batch.
# The `|| true` is load-bearing under this file's `set -euo pipefail`: without
# it a failed list-sessions would make the substitution non-zero and abort the
# uninstall part-way, leaving hooks unset but keys still bound.
sess_ids="$(tmux list-sessions -F '#{session_id}' 2>/dev/null | sed 's/^\$//' || true)"
# A live server always has at least one session, so an empty answer means the
# call failed rather than that there is nothing to restore. HOUSE RULE: a failed
# operation is a no-op, never a clear — leaving the strip up is recoverable by
# hand, half-unsetting an unknown set of sessions is not.
if [ -n "$sess_ids" ]; then
    own_right=0
    if [ -n "$(get_tmux_option '@sidetabs-strip-right-1' '')" ]; then
        own_right=1
    fi
    while read -r sid; do
        case "$sid" in ''|*[!0-9]*) continue ;; esac
        restore_batch="${restore_batch}set-option -qu -t '\$${sid}' status-left
set-option -qu -t '\$${sid}' status-left-length
"
        if [ "$own_right" = "1" ]; then
            restore_batch="${restore_batch}set-option -qu -t '\$${sid}' status-right
set-option -qu -t '\$${sid}' status-right-length
"
        fi
    done <<< "$sess_ids"
fi
printf '%s' "$restore_batch" | tmux source-file /dev/stdin 2>/dev/null || true

tmux display-message "tmux-sidetabs uninstalled. Reload ~/.tmux.conf to restore C-j/C-k."
