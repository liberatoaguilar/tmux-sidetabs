#!/usr/bin/env bash
# Wrapper for `select-pane -L` that snaps back if it lands on a sidetab.
# Usage: skip_sidetab_left.sh <originating_pane_id>
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

ORIGIN_PANE="$1"

tmux select-pane -L
new_active="$(tmux display-message -p '#{pane_id}')"
if pane_is_sidetab "$new_active"; then
    tmux select-pane -t "$ORIGIN_PANE"
fi
