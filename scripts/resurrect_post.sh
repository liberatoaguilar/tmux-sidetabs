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

# Durable state FIRST, cosmetics after. Everything below this point is sidebar
# housekeeping that touches panes the restore may have moved or killed under
# us; if one of those sweeps ever aborts (this script runs under `set -euo
# pipefail`), the timers must already be back. Neither restore needs a sidebar
# to exist — they only read window names and write window options.
#
# Bring per-window timers back from the durable event log (window ids changed
# across the restart, so this matches by session + window name). Failure used
# to be swallowed whole: a restore that never ran looked exactly like a restore
# that ran and found nothing, which is how a chain that had never fired went
# unnoticed for a week. Say so instead.
# `-d 0` holds the message until a keypress: this fires once in a blue moon,
# right when a client is attaching, and a 750ms flash is exactly how it would
# go unnoticed again.
if ! "$CURRENT_DIR/timer_restore.sh"; then
    tmux display-message -d 0 "sidetabs: timer restore failed (timers not re-seeded)" \
        2>/dev/null || true
fi

# Same story for per-window notes: the live option died with the server, the
# TSV note store is the durable record (also matched by session + window name).
"$CURRENT_DIR/note.sh" restore || true

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
        # Guarded like the respawn above: a pane that vanished mid-sweep would
        # otherwise fail the whole pipeline subshell under `set -e`.
        set_pane_option "$pane" "$SIDETAB_MARKER" "1" 2>/dev/null || true
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

# Land focus in a content pane. Sidebar navigation keeps the sidebar pane active,
# so most windows are SAVED with the strip as their active pane and resurrect
# faithfully restores that — leaving the user focused in the strip on attach
# (and anything cwd-inheriting, like `split-window -c '#{pane_current_path}'`,
# opening in the strip's cwd). resurrect_scrub.sh fixes new saves at the source;
# this covers save files written before it existed.
tmux list-windows -a -F '#{window_id}' 2>/dev/null | while read -r wid; do
    active_is_strip="$(tmux list-panes -t "$wid" -F '#{pane_active} #{@is_sidetab}' 2>/dev/null \
        | awk '$1 == 1 { print $2 }')"
    [ "$active_is_strip" = "1" ] || continue
    # `|| true` on the pipeline: awk's early `exit` can SIGPIPE list-panes, and
    # pipefail would make the assignment inherit 141 and `set -e` kill us here.
    target="$(tmux list-panes -t "$wid" -F '#{pane_id} #{@is_sidetab}' 2>/dev/null \
        | awk '$2 != "1" { print $1; exit }' || true)"
    [ -n "$target" ] && tmux select-pane -t "$target" 2>/dev/null || true
done
