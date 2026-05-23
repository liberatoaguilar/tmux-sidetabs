#!/usr/bin/env bash
# Usage: sidetab_nav.sh <down|up> <originating_pane_id>
# If origin pane is the sidetab → next/previous window.
# Else → fall through to the user's normal select-pane -D/-U behavior.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

DIRECTION="$1"
ORIGIN_PANE="$2"

if pane_is_sidetab "$ORIGIN_PANE"; then
    case "$DIRECTION" in
        down) tmux next-window ;;
        up)   tmux previous-window ;;
    esac
else
    case "$DIRECTION" in
        down) tmux select-pane -D ;;
        up)   tmux select-pane -U ;;
    esac
fi
