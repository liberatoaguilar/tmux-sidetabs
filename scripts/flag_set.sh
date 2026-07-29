#!/usr/bin/env bash
# Set a window's flag color to an explicit palette index, or clear it.
# The counterpart to flag_cycle.sh: the picker (flag_picker.sh) binds every menu
# entry to this, so a pick is one jump instead of N presses of the cycle key.
# Usage: flag_set.sh <window_id> <index|0|none>
#   index = 1-based position in @sidetabs-flag-colors; 0/none clears the flag.
# Out-of-range and non-numeric values are ignored (no state change, no redraw)
# so a stale menu built from a longer palette can't write an unrenderable index.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

WID="${1:-}"
VAL="${2:-}"
[ -z "$WID" ] && exit 0

# Capture args BEFORE `set --` clobbers the positional parameters.
colors="$(get_tmux_option '@sidetabs-flag-colors' "$DEFAULT_FLAG_COLORS")"
set -- $colors
n=$#

case "$VAL" in
    none|0)
        unset_window_option "$WID" "$FLAG_OPTION"
        ;;
    ''|*[!0-9]*)
        exit 0
        ;;
    *)
        { [ "$VAL" -ge 1 ] && [ "$VAL" -le "$n" ]; } || exit 0
        set_window_option "$WID" "$FLAG_OPTION" "$VAL"
        ;;
esac

"$CURRENT_DIR/refresh.sh" force
