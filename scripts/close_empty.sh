#!/usr/bin/env bash
# Usage: close_empty.sh <window_id>
# If every remaining pane in the window is a sidetab (all real/content panes were
# closed), close the window — otherwise a lone sidebar would keep an empty window
# alive. Returns 0 (killed) so the caller can skip further work on a dead window.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

WINDOW_ID="$1"
[ -z "$WINDOW_ID" ] && exit 1

info="$(tmux list-panes -t "$WINDOW_ID" -F '#{pane_id} #{@is_sidetab}' 2>/dev/null)"
[ -z "$info" ] && exit 1   # window already gone

nonsidetab="$(printf '%s\n' "$info" | awk '$2 != "1" { c++ } END { print c + 0 }')"
if [ "$nonsidetab" -eq 0 ]; then
    tmux kill-window -t "$WINDOW_ID" 2>/dev/null || true
    exit 0
fi
exit 1
