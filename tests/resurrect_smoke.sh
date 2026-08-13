#!/usr/bin/env bash
# Resurrect-integration smoke test. Reproduces the mess tmux-resurrect leaves —
# unmarked, full-height, left-edge "dead" sidebar strips (the @is_sidetab marker
# is a pane option resurrect does not save) — and asserts that:
#   * the restoring flag suppresses sidebar creation during a restore,
#   * resurrect_post.sh converges every window to exactly one marked sidetab
#     with no leftover dead strip, and
#   * the post hook actually REACHES the timer restore. That call used to sit
#     behind two cosmetic pane sweeps in a script running under `set -euo
#     pipefail`, and its failures were swallowed by `|| true` — a restore that
#     never ran looked exactly like one that found nothing to do.
set -euo pipefail

SOCKET="sidetab_rez_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
TMPLOG="${TMPDIR:-/tmp}/sidetabs_rez_$$.tsv"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "$TMPLOG"; }
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

# 0. Durable timer history for a window this test will restore into, so the
#    post hook has something to re-seed (matched by session + window NAME).
printf '#ts\tevent\tinterval_start\tinterval_s\ttotal_s\tsession\twindow\twindow_id\tcwd\ttag\n' > "$TMPLOG"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  2026-07-02T09:00:00-0600 start - 0  0  main rezwin @70 /tmp cust-A \
  >> "$TMPLOG"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  2026-07-02T09:01:17-0600 pause t1 77 77 main rezwin @70 /tmp cust-A \
  >> "$TMPLOG"

# 1. Start server + load plugin -> one marked sidetab in the window.
tmux -L "$SOCKET" new-session -d -s main -x 200 -y 50
tmux -L "$SOCKET" set-option -g @sidetabs-timer-log "$TMPLOG"
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
tmux -L "$SOCKET" rename-window -t "$w1" rezwin   # matches the synthetic history
pass "restoring flag suppresses creation"

# 3. Stage resurrect's leftover: an unmarked full-height left strip in w1, and
#    leave focus ON the strips (resurrect restores the saved active pane, which
#    is usually the sidebar — that's how sidebar navigation leaves it).
strip1="$(tmux -L "$SOCKET" split-window -hbf -l 20 -t "$w1" -P -F '#{pane_id}' \
  'sh -c "while :; do sleep 1; done"')"
sleep 0.2
[ "$(count_strips "$w1")" -ge 1 ] || fail "could not stage a dead strip"
tmux -L "$SOCKET" select-pane -t "$strip1"
sb0="$(tmux -L "$SOCKET" list-panes -t "$w0" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
tmux -L "$SOCKET" select-pane -t "$sb0"
pass "staged a dead strip in w1 (focus parked on both strips)"

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

# 7. Focus correction: no window may be left with its ACTIVE pane on the
#    sidebar — the user should land in a content pane after a restore.
for w in $(tmux -L "$SOCKET" list-windows -a -F '#{window_id}'); do
  act_sb="$(tmux -L "$SOCKET" list-panes -t "$w" -F '#{pane_active} #{@is_sidetab}' | awk '$1==1{print $2}')"
  [ "$act_sb" != "1" ] || fail "window $w still has the sidebar as its active pane"
done
pass "post-restore: focus moved off the sidebar in every window"

# 8. The timer restore was reached: rezwin's total is back from the log, its
#    tag with it, and a `restore` row marks the boundary. This is the assertion
#    that would have caught a chain aborting in an earlier sweep.
[ "$(tmux -L "$SOCKET" show-option -w -t "$w1" -qv @sidetabs_timer_acc)" = "77" ] \
  || fail "rezwin timer not re-seeded by the post hook (acc='$(tmux -L "$SOCKET" show-option -w -t "$w1" -qv @sidetabs_timer_acc)')"
[ "$(tmux -L "$SOCKET" show-option -w -t "$w1" -qv @sidetabs_timer_tag)" = "cust-A" ] \
  || fail "rezwin tag not re-seeded by the post hook"
awk -F'\t' '!/^#/ && $2=="restore" && $7=="rezwin" && $5=="77"' "$TMPLOG" | grep -q . \
  || fail "no restore row logged for rezwin — the post hook never reached timer_restore.sh"
pass "post-restore: timers re-seeded from the log and a restore row logged"

echo "ALL RESURRECT SMOKE TESTS PASSED"
