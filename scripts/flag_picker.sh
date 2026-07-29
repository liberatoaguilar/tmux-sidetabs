#!/usr/bin/env bash
# Interactive flag color picker: a display-menu of live color swatches, one per
# entry in @sidetabs-flag-colors, plus a "clear" entry. Bound to
# @sidetabs-flag-picker-key (default M-c) when the sidebar is focused; C-c still
# cycles, so both the fast path (one step forward) and the direct path exist.
# Usage: flag_picker.sh [--print] [window_id] [client_name]
#   --print  emit the menu as "key<TAB>value<TAB>label" lines instead of opening
#            it — the only way to assert on menu construction from a test, since
#            an overlay menu never lands in capture-pane output.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

MODE="menu"
if [ "${1:-}" = "--print" ]; then MODE="print"; shift; fi

WID="${1:-$(tmux display-message -p '#{window_id}' 2>/dev/null)}"
CLIENT="${2:-}"
[ -z "$WID" ] && exit 0

TAB="$(printf '\t')"
# Menu shortcut keys, positionally. "0" is reserved for clear, so the color
# slots start at "1"; past 36 colors an entry simply has no shortcut (tmux
# accepts an empty key) and stays reachable with the arrow keys.
KEYCHARS="123456789abcdefghijklmnopqrstuvwxyz"
SWATCH="      "   # 6 columns painted in the color itself — the "picker" part

colors="$(get_tmux_option '@sidetabs-flag-colors' "$DEFAULT_FLAG_COLORS")"
names="$(get_tmux_option '@sidetabs-flag-names' "$DEFAULT_FLAG_NAMES")"
cur="$(get_window_option "$WID" "$FLAG_OPTION" "0")"
case "$cur" in ''|*[!0-9]*) cur=0 ;; esac

# Word-split the name list into an array (NOT `set --` + a lookup function:
# a function's $1..$N are its own args, so it can't see the script's).
NAMES=()
for _n in $names; do NAMES+=("$_n"); done

ITEMS=()   # flat triples: label, key, command
PRINTED=""
i=0
for c in $colors; do
    i=$((i + 1))
    if [ "$i" -le 36 ]; then key="${KEYCHARS:$((i - 1)):1}"; else key=""; fi
    label="#[bg=${c}]${SWATCH}#[default] ${NAMES[$((i - 1))]:-$c}"
    [ "$i" = "$cur" ] && label="${label} (current)"
    ITEMS+=("$label" "$key" "run-shell -b '$CURRENT_DIR/flag_set.sh $WID $i'")
    PRINTED="${PRINTED}${key}${TAB}${i}${TAB}${label}
"
done

clear_label="${SWATCH}#[default] none (clear flag)"
ITEMS+=("$clear_label" "0" "run-shell -b '$CURRENT_DIR/flag_set.sh $WID none'")
PRINTED="${PRINTED}0${TAB}none${TAB}${clear_label}
"

if [ "$MODE" = "print" ]; then
    printf '%s' "$PRINTED"
    exit 0
fi

if [ -n "$CLIENT" ]; then
    tmux display-menu -c "$CLIENT" -T ' flag color ' "${ITEMS[@]}"
else
    tmux display-menu -T ' flag color ' "${ITEMS[@]}"
fi
