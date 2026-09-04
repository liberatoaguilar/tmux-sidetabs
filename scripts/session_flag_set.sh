#!/usr/bin/env bash
# Set a SESSION's colour to an explicit palette index, or clear it.
# The session-scoped twin of flag_set.sh: the picker (session_flag_picker.sh)
# binds every menu entry to this, so a pick is one jump.
# Usage: session_flag_set.sh <target> <index|0|none>
#   target = anything tmux can resolve a session from — normally a PANE id
#            (%N), which is what the key binding and the picker pass. A session
#            id ($N) or name works too when the caller is a shell rather than
#            tmux.
#   index  = 1-based position in @sidetabs-flag-colors; 0/none clears the colour.
#
# WHY A PANE ID AND NOT A SESSION ID. tmux runs a `run-shell` command string
# through `sh -c`, and a session id is spelled "$0", "$1", … — sh expands it as
# a positional parameter, so `run-shell 'x.sh #{session_id}'` arrives as the
# literal string "sh" (measured on tmux 3.6b). Window and pane ids ("@N", "%N")
# have no such meaning to sh, which is why every other binding here passes
# #{window_id}. This script therefore takes a target and asks tmux which session
# it belongs to, the same "query, never pass" rule render.sh follows.
#
# Sessions share the WINDOW palette (@sidetabs-flag-colors / -names / -fg) on
# purpose — one list to configure, and reordering it recolours window flags and
# session colours together, since both store an index rather than a hex value.
#
# Out-of-range and non-numeric values are ignored (no state change, no store
# write, no redraw) so a stale menu built from a longer palette can't write an
# unrenderable index. That inertness is also the house rule in miniature: a
# call that cannot be honoured is a NO-OP, never a clear.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

TARGET="${1:-}"
VAL="${2:-}"
[ -z "$TARGET" ] && exit 0

# Resolve the session ONCE, up front. A target whose pane died between the menu
# opening and the pick resolves to nothing, and this exits without touching a
# thing — a vanished target is a no-op, never a clear of some other session.
SID="$(tmux display-message -p -t "$TARGET" '#{session_id}' 2>/dev/null || true)"
[ -z "$SID" ] && exit 0

# Capture args BEFORE `set --` clobbers the positional parameters.
colors="$(get_tmux_option '@sidetabs-flag-colors' "$DEFAULT_FLAG_COLORS")"
set -- $colors
n=$#

case "$VAL" in
    none|0)
        unset_session_option "$SID" "$SFLAG_OPTION"
        ;;
    ''|*[!0-9]*)
        exit 0
        ;;
    *)
        { [ "$VAL" -ge 1 ] && [ "$VAL" -le "$n" ]; } || exit 0
        set_session_option "$SID" "$SFLAG_OPTION" "$VAL"
        ;;
esac

# Write through to the durable store. Placed AFTER the case, not inside its
# arms, for the same reason flag_set.sh does it: the two arms that reach here
# (set and clear) both changed live state, while the two that bail exit before
# this line and so leave the store alone, exactly as they leave the option
# alone. The CLEAR arm needs the write every bit as much as the set arm — the
# store is a snapshot of live state, so the only way a cleared colour stays
# cleared across a restart is for the clear itself to be snapshotted.
# `|| true` because an unwritable store must never make a keypress look like it
# failed: the live change above already happened.
"$CURRENT_DIR/flag_store.sh" sync || true

# Redraw the bottom session strip, whose pill for this session is coloured by
# exactly the option just written. NOTHING else will do it: tmux fires no hook
# on a user-option write, so every strip hook (session-created/-closed/-renamed,
# alert-bell, client-resized, …) is about some other event entirely — without
# this line the pill keeps its old colour until one of those happens to fire,
# which can be minutes later or not at all. `force`, because a deliberate
# keypress must never be swallowed by the 100ms debounce; `|| true` because the
# strip is off by default and a strip failure must not make a keypress that
# already changed live state look like it failed.
"$CURRENT_DIR/strip.sh" force || true

# `force` because the tint lands in the sidebar HEADER of every window of this
# session, and most of those sidebars are hidden — a hidden sidebar rebuilds
# only on this signal, so a debounced refresh could leave the old header colour
# on screen until its slow self-heal tick.
"$CURRENT_DIR/refresh.sh" force
