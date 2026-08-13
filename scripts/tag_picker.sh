#!/usr/bin/env bash
# "Assign client…" submenu: a display-menu listing every tag from the tags
# file (@sidetabs-timer-tags-file), one entry per row, plus an "untagged
# (clear)" entry. tmux 3.6b has no native nested display-menu, so this script
# IS the submenu — timer.sh's own menu opens it via a run-shell item (C7).
# Cloned structurally from flag_picker.sh.
# Usage: tag_picker.sh [--print] [window_id] [client_name]
#   --print  emit the menu as "key<TAB>tag<TAB>label" lines instead of opening
#            it — the only testable seam, since an overlay menu never lands in
#            capture-pane output (flag_picker.sh:7-9).
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/tags.sh"

MODE="menu"
if [ "${1:-}" = "--print" ]; then MODE="print"; shift; fi

WID="${1:-$(tmux display-message -p '#{window_id}' 2>/dev/null)}"
CLIENT="${2:-}"
[ -z "$WID" ] && exit 0

TAB="$(printf '\t')"
# Menu shortcut keys, positionally, same convention as flag_picker.sh: "0" is
# reserved for the clear entry, so tag slots start at "1"; past 36 tags an
# entry simply has no shortcut and stays reachable with the arrow keys.
KEYCHARS="123456789abcdefghijklmnopqrstuvwxyz"

cur="$(get_window_option "$WID" "$TIMER_TAG_OPTION" "")"

# Strip TAB/control chars and single quotes from a tags-file field before it
# is shown as a label or embedded in a run-shell command string. A stray
# single quote in a hand-edited row would otherwise break out of tag_set.sh's
# quoted invocation below (menu items are literal argv, so this is the only
# injection seam) — same "sanitize on write" idiom as timer.sh:72-74.
sanitize() {
    printf '%s' "$1" | tr '\011' ' ' | tr -d '\000-\037' | tr -d "'" | tr -s ' '
}

ITEMS=()   # flat triples: label, key, command
PRINTED=""
i=0
while IFS="$TAB" read -r rawtag rawlabel; do
    [ -n "$rawtag" ] || continue
    i=$((i + 1))
    if [ "$i" -le 36 ]; then key="${KEYCHARS:$((i - 1)):1}"; else key=""; fi
    tag="$(sanitize "$rawtag")"
    [ -n "$tag" ] || continue
    label="$(sanitize "$rawlabel")"
    [ -n "$label" ] || label="$tag"
    [ "$tag" = "$cur" ] && label="${label} (current)"
    ITEMS+=("$label" "$key" "run-shell -b '$CURRENT_DIR/tag_set.sh $WID $tag'")
    PRINTED="${PRINTED}${key}${TAB}${tag}${TAB}${label}
"
done < <(tags_list)

clear_label="untagged (clear)"
{ [ -z "$cur" ] || [ "$cur" = "-" ]; } && clear_label="${clear_label} (current)"
ITEMS+=("$clear_label" "0" "run-shell -b '$CURRENT_DIR/tag_set.sh $WID none'")
PRINTED="${PRINTED}0${TAB}none${TAB}${clear_label}
"

if [ "$MODE" = "print" ]; then
    printf '%s' "$PRINTED"
    exit 0
fi

if [ -n "$CLIENT" ]; then
    tmux display-menu -c "$CLIENT" -T ' assign client ' "${ITEMS[@]}"
else
    tmux display-menu -T ' assign client ' "${ITEMS[@]}"
fi
