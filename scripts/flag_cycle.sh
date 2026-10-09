#!/usr/bin/env bash
# Cycle the window's flag color: unset -> 1 -> 2 -> ... -> N -> unset.
# The value is a 1-based index into @sidetabs-flag-colors; render.sh maps it to
# a pill background (precedence: bell > flag > active > activity > idle).
# Bound to @sidetabs-flag-key (default C-c) when the sidebar is focused.
# Usage: flag_cycle.sh [window_id]   (defaults to the current window)
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

WID="${1:-$(tmux display-message -p '#{window_id}')}"
[ -z "$WID" ] && exit 0

colors="$(get_tmux_option '@sidetabs-flag-colors' "$DEFAULT_FLAG_COLORS")"
set -- $colors
n=$#
[ "$n" -eq 0 ] && exit 0

cur="$(get_window_option "$WID" "$FLAG_OPTION" "0")"
case "$cur" in ''|*[!0-9]*) cur=0 ;; esac   # garbage value -> restart cycle
[ "$cur" -gt "$n" ] && cur=0                # color list shrank -> restart cycle

next=$((cur + 1))
if [ "$next" -gt "$n" ]; then
    unset_window_option "$WID" "$FLAG_OPTION"
else
    set_window_option "$WID" "$FLAG_OPTION" "$next"
fi

# Write through to the durable store, so the colour survives the server. The
# CLEAR arm needs this every bit as much as the set arm: the store is a snapshot
# of live state, so the only way a cleared flag stays cleared across a restart
# is for the clear itself to be snapshotted. `|| true` because an unwritable
# store must never make a keypress look like it failed — the live change above
# already happened.
"$CURRENT_DIR/flag_store.sh" sync || true

"$CURRENT_DIR/refresh.sh" force
