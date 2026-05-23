#!/usr/bin/env bash
# Usage: create_sidebar.sh <window_id>
# Idempotent: if a sidetab already exists in the window, exits 0 silently.
#
# Takes ONLY the window id and derives the session from it. This is robust to
# hooks that pass an empty session_id (e.g. after-new-session, where an empty
# expansion would otherwise shift argument positions), and avoids passing the
# session id through tmux's command parser (which strips quotes and lets sh
# expand tokens like `$0`).
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

WINDOW_ID="$1"
[ -z "$WINDOW_ID" ] && exit 0

SESSION_ID="$(tmux display-message -p -t "$WINDOW_ID" '#{session_id}' 2>/dev/null)"

if window_has_sidetab "$WINDOW_ID"; then
    exit 0
fi

# Atomic per-window lock: mkdir succeeds for exactly one process. This
# serializes concurrent creations triggered by overlapping hooks
# (after-new-window + window-layout-changed both fire when a window is born),
# preventing duplicate sidetabs. Namespaced by the tmux server PID so window
# ids reused across servers (@0, @1, …) don't share — and leak — a lock.
SERVER_PID="$(tmux display-message -p '#{pid}' 2>/dev/null)"
LOCK_DIR="${TMPDIR:-/tmp}/sidetabs_${SERVER_PID}_${WINDOW_ID//[^a-zA-Z0-9]/_}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# Re-check after acquiring the lock — a prior holder may have just created one.
if window_has_sidetab "$WINDOW_ID"; then
    exit 0
fi

expanded_width="$(get_tmux_option "@sidetabs-expanded-width" "$DEFAULT_EXPANDED_WIDTH")"
collapsed_width="$(get_tmux_option "@sidetabs-collapsed-width" "$DEFAULT_COLLAPSED_WIDTH")"
collapsed="$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")"
[ "$collapsed" = "1" ] && width="$collapsed_width" || width="$expanded_width"

# render.sh determines its session from its own pane, so no argument is needed.
RENDER_CMD="$CURRENT_DIR/render.sh"

# split-window flags:
#   -h  horizontal split (side-by-side)
#   -b  before (left of target)
#   -f  full edge (spans whole window height, ignores existing splits)
#   -d  detached (don't move focus into the new pane)
#   -l  exact size
#   -P  print new pane id
#   -F  format for that print
sidetab_pane_id="$(tmux split-window -hbfd \
    -l "$width" \
    -t "$WINDOW_ID" \
    -P -F '#{pane_id}' \
    "$RENDER_CMD" 2>/dev/null || true)"

if [ -z "$sidetab_pane_id" ]; then
    # Likely the window is too narrow. Bail silently — window-resized hook
    # will retry later.
    exit 0
fi

set_pane_option "$sidetab_pane_id" "$SIDETAB_MARKER" "1"
