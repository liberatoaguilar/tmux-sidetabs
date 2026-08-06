#!/usr/bin/env bash
# window-layout-changed dispatcher: recreate a killed sidetab, re-derive the
# agent aggregate, then sync width.
# Usage: layout_changed.sh <window_id>
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"

WINDOW_ID="$1"

# If only the sidetab is left (all content panes closed), close the window and
# stop — no point resurrecting/syncing a window we just killed.
if "$CURRENT_DIR/close_empty.sh" "$WINDOW_ID"; then
    exit 0
fi

# A layout change is how the plugin learns a pane DIED (kill-pane, a crashed
# agent, a shell that exited). The window's agent aggregate is a cache that only
# the write paths rewrite, so without this it would keep spinning for an agent
# whose pane is gone. Gated on one show-option, inline: this hook fires on every
# split and every resize, and almost no window holds agent state — spawning
# agent_status.sh just to have it decide there is nothing to do would cost a
# process each time.
if [ -n "$(tmux show-option -w -t "$WINDOW_ID" -qv "$AGENT_OPTION" 2>/dev/null)" ]; then
    "$CURRENT_DIR/agent_status.sh" reconcile "$WINDOW_ID" || true
fi

"$CURRENT_DIR/resurrect.sh" "$WINDOW_ID" || true
"$CURRENT_DIR/sync_width.sh" "$WINDOW_ID" || true
