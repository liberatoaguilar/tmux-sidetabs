#!/usr/bin/env bash
# Interactive SESSION colour picker: a display-menu of live colour swatches, one
# per entry in @sidetabs-flag-colors, plus a "clear" entry. Bound to
# @sidetabs-session-flag-key (default M-s) when the sidebar is focused.
#
# The session-scoped twin of flag_picker.sh, and deliberately the ONLY way to
# set a session colour — there is no cycle key. A window flag gets flipped
# daily, so one-press stepping earns its keybinding there; a session colour is
# set once and then left alone, and stepping to slot 6 to reach it would be the
# wrong affordance.
#
# Sessions share the WINDOW palette (@sidetabs-flag-colors / -names): one list to
# configure, and since both scopes store an INDEX, reordering the list recolours
# window flags and session colours together.
#
# Usage: session_flag_picker.sh [--print] [target] [client_name]
#   target   anything tmux can resolve a session from — normally a PANE id
#            (%N). NOT a session id: see the "why a pane id" note in
#            session_flag_set.sh (sh eats "$0"). Defaults to the current pane.
#   --print  emit the menu as "key<TAB>value<TAB>label" lines instead of opening
#            it — the only way to assert on menu construction from a test, since
#            an overlay menu never lands in capture-pane output.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

MODE="menu"
if [ "${1:-}" = "--print" ]; then MODE="print"; shift; fi

TARGET="${1:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
CLIENT="${2:-}"
[ -z "$TARGET" ] && exit 0

# The menu entries must carry a target that survives `run-shell -> sh -c`, so
# they reuse the one we were given verbatim rather than the resolved session id.
SID="$(tmux display-message -p -t "$TARGET" '#{session_id}' 2>/dev/null || true)"
[ -z "$SID" ] && exit 0

TAB="$(printf '\t')"
# Menu shortcut keys, positionally — identical scheme to flag_picker.sh so the
# two menus have the same muscle memory. "0" is reserved for clear, so the
# colour slots start at "1"; past 36 colours an entry simply has no shortcut
# (tmux accepts an empty key) and stays reachable with the arrow keys.
KEYCHARS="123456789abcdefghijklmnopqrstuvwxyz"
SWATCH="      "   # 6 columns painted in the colour itself — the "picker" part

colors="$(get_tmux_option '@sidetabs-flag-colors' "$DEFAULT_FLAG_COLORS")"
names="$(get_tmux_option '@sidetabs-flag-names' "$DEFAULT_FLAG_NAMES")"
cur="$(get_session_option "$SID" "$SFLAG_OPTION" "0")"
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
    ITEMS+=("$label" "$key" "run-shell -b '$CURRENT_DIR/session_flag_set.sh $TARGET $i'")
    PRINTED="${PRINTED}${key}${TAB}${i}${TAB}${label}
"
done

clear_label="${SWATCH}#[default] none (clear colour)"
ITEMS+=("$clear_label" "0" "run-shell -b '$CURRENT_DIR/session_flag_set.sh $TARGET none'")
PRINTED="${PRINTED}0${TAB}none${TAB}${clear_label}
"

if [ "$MODE" = "print" ]; then
    printf '%s' "$PRINTED"
    exit 0
fi

# The title names the session, because unlike a window flag this key colours
# something you cannot see the whole of from one sidebar.
SNAME="$(tmux display-message -p -t "$TARGET" '#{session_name}' 2>/dev/null || true)"
if [ -n "$CLIENT" ]; then
    tmux display-menu -c "$CLIENT" -T " session colour: ${SNAME} " "${ITEMS[@]}"
else
    tmux display-menu -T " session colour: ${SNAME} " "${ITEMS[@]}"
fi
