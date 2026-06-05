#!/usr/bin/env bash
# Usage: sync_width.sh <window_id>
# If the sidetab in this window was resized (its width differs from the session's
# stored expanded width), persist the new width and resize every other window's
# sidetab to match — so the sidebar width is consistent across the session.
#
# Propagating a resize to the other windows itself fires window-layout-changed
# (-> this script) for each of them. Under tmux's concurrent `run-shell -b`
# hooks, naive propagation race-loops forever: windows ping-pong the shared
# width option and re-trigger one another (8 drags once produced 177 invocations
# across 6 windows, oscillating for seconds after input stopped). Two guards
# prevent that:
#   1. A per-session lock serializes sync, so the read-modify-write on the width
#      option below can't race.
#   2. A short per-window suppression stamp (@sidetabs_sync_until / _win): while
#      armed, events from OTHER windows exit immediately, so the resizes we cause
#      (echoes) are ignored. The source window stays live, so a drag's final
#      width still propagates and every sidetab converges to the same value.
# No-op while collapsed. Converges: clamped/odd widths no longer re-propagate.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

WINDOW_ID="$1"
[ -z "$WINDOW_ID" ] && exit 0

SESSION_ID="$(tmux display-message -p -t "$WINDOW_ID" '#{session_id}' 2>/dev/null)"
[ -z "$SESSION_ID" ] && exit 0

# Only sync the expanded width.
[ "$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")" = "1" ] && exit 0

# Suppression guard: while armed, ignore layout-changed events from windows OTHER
# than the one that owns the guard. Those are the echoes of our own propagation;
# letting them run is what loops forever. The owning (source) window stays live,
# so a drag's final width still propagates. now is reused when arming below.
now="$(now_ms)"
guard_until="$(get_session_option "$SESSION_ID" "$SYNC_GUARD_OPTION" "0")"
guard_win="$(get_session_option "$SESSION_ID" "$SYNC_GUARD_WIN_OPTION" "")"
if [ "$now" -lt "$guard_until" ] && [ "$WINDOW_ID" != "$guard_win" ]; then
    exit 0
fi

sidetab="$(find_sidetab_pane "$WINDOW_ID")"
[ -z "$sidetab" ] && exit 0

default_w="$(get_tmux_option '@sidetabs-expanded-width' "$DEFAULT_EXPANDED_WIDTH")"
cur="$(tmux display-message -p -t "$sidetab" '#{pane_width}' 2>/dev/null)"
[ -z "$cur" ] && exit 0
[ "$cur" = "$(get_session_option "$SESSION_ID" "$WIDTH_OPTION" "$default_w")" ] && exit 0

# Serialize: one sync at a time per session so the width read-modify-write can't
# race. Namespaced by server pid (window/session ids are reused across servers).
# If another sync holds the lock, drop this one — a fresh layout-changed follows.
SERVER_PID="$(tmux display-message -p '#{pid}' 2>/dev/null)"
LOCK_DIR="${TMPDIR:-/tmp}/sidetabs_sync_${SERVER_PID}_${SESSION_ID//[^a-zA-Z0-9]/_}"
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# Re-read under the lock; a prior holder may have just synced to this width.
cur="$(tmux display-message -p -t "$sidetab" '#{pane_width}' 2>/dev/null)"
[ -z "$cur" ] && exit 0
[ "$cur" = "$(get_session_option "$SESSION_ID" "$WIDTH_OPTION" "$default_w")" ] && exit 0

# Arm the guard for THIS window before resizing, so the layout-changed events our
# resizes generate in the OTHER windows are ignored, while further ticks of this
# same drag keep flowing.
set_session_option "$SESSION_ID" "$SYNC_GUARD_WIN_OPTION" "$WINDOW_ID"
set_session_option "$SESSION_ID" "$SYNC_GUARD_OPTION" "$(( now + SYNC_GUARD_MS ))"
set_session_option "$SESSION_ID" "$WIDTH_OPTION" "$cur"

tmux list-windows -t "$SESSION_ID" -F '#{window_id}' 2>/dev/null \
    | while read -r w; do
        st="$(find_sidetab_pane "$w")"
        [ -z "$st" ] && continue
        [ "$st" = "$sidetab" ] && continue
        tmux resize-pane -t "$st" -x "$cur" 2>/dev/null || true
      done

exit 0
