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
    'session-window-changed[0]'
    'session-window-changed[1]'
    'session-window-changed[2]'
    'client-session-changed[0]'
    'client-session-changed[1]'
    'client-attached[0]'
    'client-attached[1]'
    'client-attached[2]'
    'client-detached[0]'
    'client-detached[1]'
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

tmux display-message "tmux-sidetabs uninstalled. Reload ~/.tmux.conf to restore C-j/C-k."
