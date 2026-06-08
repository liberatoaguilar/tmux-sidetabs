#!/usr/bin/env bash
# tmux-resurrect @resurrect-hook-pre-restore-all
#
# Stand down sidebar auto-creation while resurrect rebuilds panes. Its burst of
# window/layout events would otherwise spawn duplicate sidetabs around the
# (unmarked) panes it restores. resurrect_post.sh clears this flag and rebuilds.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

set_tmux_option "$RESTORING_OPTION" "1"
