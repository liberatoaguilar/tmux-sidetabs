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
# This is a thin front end for `timer.sh retag`, which owns the whole operation.
# It cannot be a plain option write here: a tag change is an ATTRIBUTION
# BOUNDARY, so a timer that is RUNNING at that moment must have its open
# interval closed under the old tag and reopened under the new one. Writing the
# option alone left one interval spanning the change, and the CLI replay bills a
# whole interval to the tag it opened under — so every second worked after the
# reassignment went to the previous client, with no warning on either side.
# Closing the interval needs timer.sh's fold/acc/now machinery and its per-window
# lock, and per D8 the cycle check has to run in the same process, so the logic
# lives there and this script just hands over. See the `retag` arm in timer.sh
# for the row shapes and for why @sidetabs_timer_last_reset is cleared.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

WID="${1:-}"
VAL="${2:-}"
[ -z "$WID" ] && exit 0

exec "$CURRENT_DIR/timer.sh" retag "$WID" "$VAL"
