#!/usr/bin/env bash
# tmux-resurrect @resurrect-hook-post-restore-all
#
# tmux-resurrect restores the sidebar panes as ordinary panes — the @is_sidetab
# marker is a *pane option*, which resurrect does not save — so every restored
# sidebar comes back unmarked and dead (its render.sh is never restarted).
#
# We ADOPT each restored sidebar IN PLACE rather than kill-and-rebuild. The
# sidebar is always created with `split-window -hbf` (before / left / full-edge),
# so it is the ONLY pane that can sit flush against the left edge spanning the
# full window height. Identify that pane, respawn render.sh in it, and re-mark
# it. This changes no geometry, so the user's content panes are never reshuffled
# (kill+rebuild used to redistribute columns and could leave a 1-wide sliver).
#
# resurrect_pre.sh held the restoring flag throughout the restore, so no real
# sidetab was created meanwhile — every flush-left full-height unmarked pane here
# is a restored sidebar, not a freshly-made one.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
RENDER_CMD="$CURRENT_DIR/render.sh"

# Adopt restored sidebars in place. A restored sidebar is: flush-left (pane_left
# 0), spanning the full window height, narrower than half the window (a sidebar
# is never a main pane), and not already marked. Width-relative-to-window keeps
# this correct regardless of the configured sidebar width.
tmux list-panes -a -F \
  '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{window_height} #{window_width} #{@is_sidetab}' \
  2>/dev/null | while read -r pane left top width height wheight wwidth marker; do
    if [ "$marker" != "1" ] && [ "$left" = "0" ] && [ "$top" = "0" ] \
       && [ "$height" = "$wheight" ] && [ $(( width * 2 )) -lt "$wwidth" ]; then
        tmux respawn-pane -k -t "$pane" "$RENDER_CMD" 2>/dev/null || true
        set_pane_option "$pane" "$SIDETAB_MARKER" "1"
    fi
done

# Re-enable normal creation, then make a sidetab for any window that STILL lacks
# one (e.g. a window too narrow for a sidebar at save time, or one resurrect did
# not restore a sidebar pane for). create_sidebar is idempotent + lock-guarded,
# so adopted windows are no-ops and this can't double up.
set_tmux_option "$RESTORING_OPTION" "0"
tmux list-windows -a -F '#{window_id}' 2>/dev/null | while read -r wid; do
    "$CURRENT_DIR/create_sidebar.sh" "$wid" || true
done
