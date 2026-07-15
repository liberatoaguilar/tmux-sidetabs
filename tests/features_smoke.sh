#!/usr/bin/env bash
# Smoke test for flag colors + per-tab timers: temporary tmux server, sources
# the plugin, drives flag_cycle.sh / timer.sh via run-shell, asserts state via
# show-option -w and rendering via capture-pane.
set -euo pipefail

SOCKET="sidetab_feat_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPLOG="${TMPDIR:-/tmp}/sidetabs_timelog_$$.tsv"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "$TMPLOG"; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
winopt() { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }

# 1. Boot: 2 windows, summary off (deterministic layout), hermetic log path.
tmux -L "$SOCKET" new-session -d -s main -x 200 -y 50
tmux -L "$SOCKET" set-option -g @sidetabs-summary off
tmux -L "$SOCKET" set-option -g @sidetabs-timer-log "$TMPLOG"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.4
tmux -L "$SOCKET" new-window
sleep 0.4
w0="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 1p)"
w1="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 2p)"
sb0="$(tmux -L "$SOCKET" list-panes -t "$w0" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
[ -n "$w0" ] && [ -n "$w1" ] && [ -n "$sb0" ] || fail "setup: expected 2 windows with sidebars"

# 2. Flag cycles 1..4 then unsets (default palette has 4 colors).
for want in 1 2 3 4; do
  tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_cycle.sh $w0"
  got="$(winopt "$w0" @sidetabs_flag)"
  [ "$got" = "$want" ] || fail "flag cycle: expected $want, got '$got'"
done
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_cycle.sh $w0"
got="$(winopt "$w0" @sidetabs_flag)"
[ -z "$got" ] || fail "flag cycle: expected unset after full cycle, got '$got'"
pass "flag cycles 1->4->unset"

# 3. Flag renders (preset 1 #ebcb8b -> SGR 48;2;235;203;139) and beats ACTIVE
#    (#88c0d0 -> 48;2;136;192;208 must be absent from the flagged row).
tmux -L "$SOCKET" select-window -t "$w0"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_cycle.sh $w0"
sleep 0.8
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
echo "$cap" | grep -q '48;2;235;203;139' || fail "flag bg SGR not found in render"
row="$(echo "$cap" | grep '48;2;235;203;139' | head -1)"
if echo "$row" | grep -q '48;2;136;192;208'; then
  fail "active bg present on flagged row (flag should beat active)"
fi
pass "flag color renders and beats active"

# 4. Flag renders in collapsed mode too.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 0.8
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
echo "$cap" | grep -q '48;2;235;203;139' || fail "flag bg missing in collapsed mode"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 0.8
pass "flag renders collapsed"

# 5. Timer start: state=run, live line ticks under the tab.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "run" ] || fail "timer state after start: '$st'"
sleep 2
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
echo "$cap" | grep -Eq '00:00:0[1-9]' || fail "live timer line not found"
pass "timer starts and ticks live"

# 6. Pause: state=pause, acc >= 1, exactly one 6-field TSV log line.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"
st="$(winopt "$w0" @sidetabs_timer_state)"
acc="$(winopt "$w0" @sidetabs_timer_acc)"
[ "$st" = "pause" ] || fail "timer state after pause: '$st'"
[ "$acc" -ge 1 ] 2>/dev/null || fail "timer acc after pause: '$acc'"
[ -f "$TMPLOG" ] || fail "no log file written"
nl="$(wc -l < "$TMPLOG" | tr -d ' ')"
[ "$nl" = "1" ] || fail "expected 1 log line, got $nl"
nf="$(awk -F'\t' '{print NF}' "$TMPLOG")"
[ "$nf" = "6" ] || fail "expected 6 TSV fields, got $nf"
awk -F'\t' '$3 !~ /^[0-9]+$/ {exit 1}' "$TMPLOG" || fail "duration field not numeric"
pass "pause logs one 6-field TSV interval (acc=$acc)"

# 7. Cancel discards the running interval: acc unchanged, no new log line.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh cancel $w0"
st="$(winopt "$w0" @sidetabs_timer_state)"
acc2="$(winopt "$w0" @sidetabs_timer_acc)"
[ "$st" = "pause" ] || fail "state after cancel: '$st'"
[ "$acc2" = "$acc" ] || fail "acc changed on cancel: $acc -> $acc2"
nl="$(wc -l < "$TMPLOG" | tr -d ' ')"
[ "$nl" = "1" ] || fail "cancel must not log (lines: $nl)"
pass "cancel keeps acc, logs nothing"

# 8. Reset clears all state and the rendered line; logs nothing.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh reset $w0"
sleep 0.8
for o in @sidetabs_timer_state @sidetabs_timer_start @sidetabs_timer_acc; do
  v="$(winopt "$w0" "$o")"
  [ -z "$v" ] || fail "reset left $o='$v'"
done
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
if echo "$cap" | grep -Eq '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'; then
  fail "timer line still rendered after reset"
fi
nl="$(wc -l < "$TMPLOG" | tr -d ' ')"
[ "$nl" = "1" ] || fail "reset must not log (lines: $nl)"
pass "reset clears state and display"

# 9. Timer renders under an INACTIVE tab (ungated by active).
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"
tmux -L "$SOCKET" select-window -t "$w1"
sleep 1
sb1="$(tmux -L "$SOCKET" list-panes -t "$w1" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb1")"
echo "$cap" | grep -Eq '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' || fail "timer not shown under inactive tab"
pass "timer visible under inactive tab"

# 10. Collapsed hides the timer line but state keeps running.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 0.8
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb1")"
if echo "$cap" | grep -Eq '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'; then
  fail "timer line visible in collapsed mode"
fi
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "run" ] || fail "timer stopped by collapse: '$st'"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
pass "collapsed hides timer, state keeps running"

# 11. Keys bound on load; uninstall removes them.
tmux -L "$SOCKET" list-keys -T root | grep -q 'flag_cycle.sh' || fail "flag key not bound"
tmux -L "$SOCKET" list-keys -T root | grep -q 'timer.sh' || fail "timer key not bound"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.3
if tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'flag_cycle.sh'; then
  fail "flag key survived uninstall"
fi
if tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'timer.sh'; then
  fail "timer key survived uninstall"
fi
pass "keys bound on load, removed on uninstall"

echo "ALL FEATURE SMOKE TESTS PASSED"
