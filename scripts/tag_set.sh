#!/usr/bin/env bash
# Set a window's client-attribution tag (@sidetabs_timer_tag), or clear it.
# The counterpart to tag_picker.sh: every submenu entry runs this so a pick is
# one jump instead of hand-editing the window option. Mirrors flag_set.sh.
# Usage: tag_set.sh <window_id> <tag|none>
#   tag  = opaque attribution tag (C2: customer_uuid[:project_uuid]); anything
#          that sanitizes to empty is ignored (no state change, no redraw) —
#          same "garbage can't corrupt state" contract as flag_set.sh.
#   none = clear the tag.
#
# A tag CHANGE clears @sidetabs_timer_last_reset (C5's marker): reassigning a
# window from customer A (reset day 26) to B (reset day 1) must not carry A's
# last_reset forward — cycle_check would compare it against B's boundary and
# could either zero a total the user just meant to relabel, or silently skip a
# reset B genuinely owes. Unsetting sends the next cycle_check down C5's
# first-sighting path (adopt the new tag's current cycle start, don't reset) —
# exactly the rollout-seeding behavior C5 already relies on. Re-picking the
# SAME tag (the menu marks it "(current)") is deliberately a no-op here: an
# unconditional unset would re-seed to "now" and swallow a reset that was
# actually due.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

WID="${1:-}"
VAL="${2:-}"
[ -z "$WID" ] && exit 0

old_tag="$(get_window_option "$WID" "$TIMER_TAG_OPTION" "")"

case "$VAL" in
    none)
        unset_window_option "$WID" "$TIMER_TAG_OPTION"
        [ -n "$old_tag" ] && unset_window_option "$WID" "$TIMER_LAST_RESET_OPTION"
        ;;
    '')
        exit 0
        ;;
    *)
        # Strip TAB and other control chars before the write — the value lands
        # in a TSV log column (timer.sh log_event) and, via tag_picker.sh, in a
        # run-shell command string. Same idiom as timer.sh:72-74 / note.sh.
        tag="$(printf '%s' "$VAL" | tr '\011' ' ' | tr -d '\000-\037' | tr -s ' ')"
        [ -z "$tag" ] && exit 0
        set_window_option "$WID" "$TIMER_TAG_OPTION" "$tag"
        [ "$tag" != "$old_tag" ] && unset_window_option "$WID" "$TIMER_LAST_RESET_OPTION"
        ;;
esac

"$CURRENT_DIR/refresh.sh" force
