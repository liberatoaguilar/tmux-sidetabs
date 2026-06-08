#!/usr/bin/env bash
# Resurrect-integration smoke test. Reproduces the mess tmux-resurrect leaves —
# unmarked, full-height, left-edge "dead" sidebar strips (the @is_sidetab marker
# is a pane option resurrect does not save) — and asserts that:
#   * the restoring flag suppresses sidebar creation during a restore, and
#   * resurrect_post.sh converges every window to exactly one marked sidetab
#     with no leftover dead strip.
set -euo pipefail

SOCKET="sidetab_rez_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

count_marked() {  # $1 = window_id -> number of @is_sidetab panes
  tmux -L "$SOCKET" list-panes -t "$1" -F '#{@is_sidetab}' | grep -c '^1$' || true
}
count_strips() {  # $1 = window_id -> unmarked full-height flush-left narrow panes
  tmux -L "$SOCKET" list-panes -t "$1" -F \
    '#{pane_left} #{pane_top} #{pane_height} #{window_height} #{pane_width} #{@is_sidetab}' \
    | awk '$1==0 && $2==0 && $3==$4 && $5<=24 && $6!="1"' | wc -l | tr -d ' '
}

# 1. Start server + load plugin -> one marked sidetab in the window.
tmux -L "$SOCKET" new-session -d -s main -x 200 -y 50
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.4
w0="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 1p)"
[ "$(count_marked "$w0")" = "1" ] || fail "expected 1 sidetab after load, got $(count_marked "$w0")"
pass "baseline: one marked sidetab on load"

# 2. Restoring flag must suppress creation (no sidetab on a new window).
tmux -L "$SOCKET" set-option -g @sidetabs_restoring 1
tmux -L "$SOCKET" new-window
sleep 0.4
w1="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 2p)"
[ "$(count_marked "$w1")" = "0" ] || fail "restoring flag ignored: sidetab created during restore"
pass "restoring flag suppresses creation"

# 3. Stage resurrect's leftover: an unmarked full-height left strip in w1.
tmux -L "$SOCKET" split-window -hbfd -l 20 -t "$w1" 'sh -c "while :; do sleep 1; done"'
sleep 0.2
[ "$(count_strips "$w1")" -ge 1 ] || fail "could not stage a dead strip"
pass "staged a dead strip in w1"

# 4. Run the post-restore hook the way resurrect does: in-server via run-shell,
#    so the script's bare `tmux` calls target THIS test server (not the default
#    socket). Running it with plain `bash` would hit the real tmux.
tmux -L "$SOCKET" run-shell "$SCRIPTS/resurrect_post.sh"
sleep 0.6

# 5. Flag cleared.
[ "$(tmux -L "$SOCKET" show-option -gqv @sidetabs_restoring)" = "0" ] \
  || fail "restoring flag not cleared by post-restore"
pass "restoring flag cleared by post-restore"

# 6. Every window: exactly one marked sidetab, zero dead strips.
for w in $(tmux -L "$SOCKET" list-windows -a -F '#{window_id}'); do
  m="$(count_marked "$w")"; s="$(count_strips "$w")"
  [ "$m" = "1" ] || fail "window $w has $m marked sidetabs (want 1)"
  [ "$s" = "0" ] || fail "window $w still has $s dead strip(s)"
done
pass "post-restore: exactly one sidetab per window, no dead strips"

echo "ALL RESURRECT SMOKE TESTS PASSED"
