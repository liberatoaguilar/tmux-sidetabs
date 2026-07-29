#!/usr/bin/env bash
# Smoke test for flag colors + per-tab focus-aware timers (v2): temporary tmux
# server, sources the plugin, drives flag_cycle.sh / timer.sh via run-shell,
# asserts state via show-option -w, log rows via the TSV event log, and
# rendering via capture-pane. Detached scratch servers have 0 clients, so the
# focus engine treats window_active alone as "focused" — select-window drives
# auto-hold/auto-resume transitions. Hooks run async (run-shell -b), so tests
# sleep >=0.5s after select-window before asserting on engine-driven state.
set -euo pipefail

SOCKET="sidetab_feat_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPLOG="${TMPDIR:-/tmp}/sidetabs_timelog_$$.tsv"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "$TMPLOG"; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
winopt() { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }
lognorows() { grep -vc '^#' "$TMPLOG" 2>/dev/null || true; }
lastrow() { grep -v '^#' "$TMPLOG" | tail -1; }

# 1. Boot: 2 windows, summary off (deterministic layout), hermetic log path.
#    -f /dev/null is required: without it a new server on this socket still
#    auto-loads the user's ~/.tmux.conf (which run-shells this plugin AND
#    others), polluting hooks/keys and defeating test isolation.
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -x 200 -y 50
tmux -L "$SOCKET" set-option -g @sidetabs-summary off
tmux -L "$SOCKET" set-option -g @sidetabs-timer-log "$TMPLOG"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.4
tmux -L "$SOCKET" new-window
sleep 0.4
w0="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 1p)"
w1="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 2p)"
sb0="$(tmux -L "$SOCKET" list-panes -t "$w0" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
sb1="$(tmux -L "$SOCKET" list-panes -t "$w1" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
[ -n "$w0" ] && [ -n "$w1" ] && [ -n "$sb0" ] && [ -n "$sb1" ] || fail "setup: expected 2 windows with sidebars"

# 2. Flag cycles 1..8 then unsets (default palette has 8 colors).
for want in 1 2 3 4 5 6 7 8; do
  tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_cycle.sh $w0"
  got="$(winopt "$w0" @sidetabs_flag)"
  [ "$got" = "$want" ] || fail "flag cycle: expected $want, got '$got'"
done
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_cycle.sh $w0"
got="$(winopt "$w0" @sidetabs_flag)"
[ -z "$got" ] || fail "flag cycle: expected unset after full cycle, got '$got'"
pass "flag cycles 1->8->unset"

# 2b. flag_set: direct index set, clear via none/0, invalid input ignored.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 5"
got="$(winopt "$w0" @sidetabs_flag)"
[ "$got" = "5" ] || fail "flag_set 5: expected 5, got '$got'"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 none"
got="$(winopt "$w0" @sidetabs_flag)"
[ -z "$got" ] || fail "flag_set none: expected unset, got '$got'"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 3"
got="$(winopt "$w0" @sidetabs_flag)"
[ "$got" = "3" ] || fail "flag_set 3: expected 3, got '$got'"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 99"
got="$(winopt "$w0" @sidetabs_flag)"
[ "$got" = "3" ] || fail "flag_set 99 (out of range) changed flag: '$got'"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 garbage"
got="$(winopt "$w0" @sidetabs_flag)"
[ "$got" = "3" ] || fail "flag_set garbage changed flag: '$got'"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 0"
got="$(winopt "$w0" @sidetabs_flag)"
[ -z "$got" ] || fail "flag_set 0: expected unset, got '$got'"
pass "flag_set sets/clears; out-of-range and garbage ignored"

# 2c. Picker menu construction (--print: one 'key<TAB>value<TAB>label' line per
#     item): 8 color items + 1 clear item, swatch colors present, the current
#     selection marked, clear item on key 0.
PICKOUT="${TMPDIR:-/tmp}/sidetabs_picker_$$.out"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 3"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_picker.sh --print $w0 > $PICKOUT"
nitems="$(grep -c . "$PICKOUT" || true)"
[ "$nitems" = "9" ] || fail "picker --print: expected 9 items (8 colors + clear), got $nitems"
head -1 "$PICKOUT" | grep -q '#ebcb8b' || fail "picker item 1 missing first palette color"
head -1 "$PICKOUT" | cut -f1 | grep -qx '1' || fail "picker item 1 not on key 1"
awk -F'\t' '$2 == "3"' "$PICKOUT" | grep -q '(current)' \
  || fail "picker did not mark index 3 as current"
if awk -F'\t' '$2 != "3"' "$PICKOUT" | grep -q '(current)'; then
  fail "picker marked a non-current item as current"
fi
clearline="$(awk -F'\t' '$2 == "none"' "$PICKOUT")"
[ -n "$clearline" ] || fail "picker has no clear item"
echo "$clearline" | cut -f1 | grep -qx '0' || fail "clear item not on key 0"
nkeys="$(cut -f1 "$PICKOUT" | sort -u | grep -c . || true)"
[ "$nkeys" = "9" ] || fail "picker shortcut keys not unique: $nkeys distinct of 9"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 none"
rm -f "$PICKOUT"
pass "picker menu: 9 items, keys unique, current marked, clear on 0"

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

# 3b. A slot from the extended palette renders too (index 7 = #9d7cd8 ->
#     48;2;157;124;216). render.sh builds its SEG_FLAG array from the palette,
#     so this guards the list growing past the original 4 slots. Restore index 1
#     afterwards: the collapsed-mode check below asserts on #ebcb8b.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 7"
sleep 0.8
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
echo "$cap" | grep -q '48;2;157;124;216' \
  || fail "extended palette index 7 (#9d7cd8) not rendered in the pill"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_set.sh $w0 1"
sleep 0.5
pass "extended palette index 7 renders"

# 4. Flag renders in collapsed mode too.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 0.8
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
echo "$cap" | grep -q '48;2;235;203;139' || fail "flag bg missing in collapsed mode"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 0.8
pass "flag renders collapsed"

# 5. Timer start (unset -> run, event 'start'): log has exactly 1 row (sans
#    header), and every logged row (of any event) has 9 TSV fields.
tmux -L "$SOCKET" select-window -t "$w0"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "run" ] || fail "timer state after start: '$st'"
[ -f "$TMPLOG" ] || fail "no log file written"
nrows="$(lognorows)"
[ "$nrows" = "1" ] || fail "expected 1 log row after start, got $nrows"
ev="$(lastrow | cut -f2)"
[ "$ev" = "start" ] || fail "expected start event, got '$ev'"
nf="$(awk -F'\t' '!/^#/{print NF}' "$TMPLOG" | sort -u)"
[ "$nf" = "9" ] || fail "expected 9 TSV fields on every row, got: $nf"
pass "timer start logs 1 row (event=start, 9 fields)"

# 6. Live tick renders.
sleep 2
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
echo "$cap" | grep -Eq '00:00:0[1-9]' || fail "live timer line not found"
pass "timer ticks live"

# 7. C-t pause (run -> pause, manual): acc >= 1, new 'pause' row with numeric
#    interval_s (col4) >= 1 and total_s (col5) == acc.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"
st="$(winopt "$w0" @sidetabs_timer_state)"
acc="$(winopt "$w0" @sidetabs_timer_acc)"
[ "$st" = "pause" ] || fail "timer state after pause: '$st'"
[ "$acc" -ge 1 ] 2>/dev/null || fail "timer acc after pause: '$acc'"
row="$(lastrow)"
ev="$(echo "$row" | cut -f2)"; c4="$(echo "$row" | cut -f4)"; c5="$(echo "$row" | cut -f5)"
[ "$ev" = "pause" ] || fail "expected pause event, got '$ev'"
[ "$c4" -ge 1 ] 2>/dev/null || fail "pause interval_s not numeric >=1: '$c4'"
[ "$c5" = "$acc" ] || fail "pause total_s mismatch: $c5 != $acc"
pass "pause logs pause row (acc=$acc)"

# 8. C-t resume (pause -> run) logs 'resume'; cancel discards the live
#    interval: state -> pause, acc unchanged, 'cancel' row, total unchanged.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"
ev="$(lastrow | cut -f2)"
[ "$ev" = "resume" ] || fail "expected resume event, got '$ev'"
sleep 1
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh cancel $w0"
st="$(winopt "$w0" @sidetabs_timer_state)"
acc2="$(winopt "$w0" @sidetabs_timer_acc)"
[ "$st" = "pause" ] || fail "state after cancel: '$st'"
[ "$acc2" = "$acc" ] || fail "acc changed on cancel: $acc -> $acc2"
row="$(lastrow)"
ev="$(echo "$row" | cut -f2)"; c5="$(echo "$row" | cut -f5)"
[ "$ev" = "cancel" ] || fail "expected cancel event, got '$ev'"
[ "$c5" = "$acc" ] || fail "cancel total_s changed: $c5 != $acc"
pass "resume logs resume row; cancel discards interval, keeps total"

# 9. Auto engine: losing focus auto-holds a running timer; regaining it
#    auto-resumes. w1's sidebar renders w0's timer line (timers show under
#    inactive tabs too).
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"   # pause -> run
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "run" ] || fail "expected run before auto-engine test: '$st'"
tmux -L "$SOCKET" select-window -t "$w1"
sleep 1
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "hold" ] || fail "expected auto-hold on focus loss: '$st'"
ev="$(lastrow | cut -f2)"
[ "$ev" = "auto-pause" ] || fail "expected auto-pause event, got '$ev'"
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb1")"
echo "$cap" | grep -Eq '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' || fail "w0 timer line not shown on w1's sidebar"
tmux -L "$SOCKET" select-window -t "$w0"
sleep 1
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "run" ] || fail "expected auto-resume on focus return: '$st'"
ev="$(lastrow | cut -f2)"
[ "$ev" = "auto-resume" ] || fail "expected auto-resume event, got '$ev'"
pass "focus engine auto-holds on blur, auto-resumes on focus"

# 10. Sticky manual pause: a C-t pause NEVER auto-resumes, only C-t does.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"   # run -> pause (manual)
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "pause" ] || fail "expected manual pause: '$st'"
nrows_before="$(lognorows)"
tmux -L "$SOCKET" select-window -t "$w1"; sleep 1
tmux -L "$SOCKET" select-window -t "$w0"; sleep 1
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "pause" ] || fail "manual pause did not stick: '$st'"
nrows_after="$(lognorows)"
[ "$nrows_after" = "$nrows_before" ] || \
  fail "unexpected new log rows after focus churn on manual pause ($nrows_before -> $nrows_after)"
pass "manual pause is sticky (no auto-resume)"

# 11. Adjust: relative '+N', absolute duration string (sets), relative '-N',
#     and invalid input (rejected, no state/log change).
accbase="$(winopt "$w0" @sidetabs_timer_acc)"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh adjust $w0 '+300'"
acc="$(winopt "$w0" @sidetabs_timer_acc)"
[ "$acc" = "$((accbase + 300))" ] || fail "adjust +300: expected $((accbase + 300)), got $acc"
row="$(lastrow)"
ev="$(echo "$row" | cut -f2)"; c4="$(echo "$row" | cut -f4)"
[ "$ev" = "adjust" ] || fail "expected adjust event, got '$ev'"
[ "$c4" = "300" ] || fail "adjust +300 interval_s: expected 300, got '$c4'"

tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh adjust $w0 '10:00'"
acc="$(winopt "$w0" @sidetabs_timer_acc)"
[ "$acc" = "600" ] || fail "adjust '10:00' (set): expected 600, got $acc"
c5="$(lastrow | cut -f5)"
[ "$c5" = "600" ] || fail "adjust '10:00' total_s: expected 600, got '$c5'"

tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh adjust $w0 '-90'"
acc="$(winopt "$w0" @sidetabs_timer_acc)"
[ "$acc" = "510" ] || fail "adjust -90: expected 510, got $acc"

nrows_before="$(lognorows)"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh adjust $w0 'garbage'"
acc="$(winopt "$w0" @sidetabs_timer_acc)"
[ "$acc" = "510" ] || fail "invalid adjust changed acc: $acc"
nrows_after="$(lognorows)"
[ "$nrows_after" = "$nrows_before" ] || fail "invalid adjust logged a row ($nrows_before -> $nrows_after)"
pass "adjust: relative +/-, absolute set, invalid input rejected"

# 12. Reset clears all three window options and logs a 'reset' row with
#     total_s=0; the rendered timer line disappears. Every row logged so far
#     (start..reset, across all event kinds) still has 9 TSV fields.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh reset $w0"
sleep 0.8
for o in @sidetabs_timer_state @sidetabs_timer_start @sidetabs_timer_acc; do
  v="$(winopt "$w0" "$o")"
  [ -z "$v" ] || fail "reset left $o='$v'"
done
row="$(lastrow)"
ev="$(echo "$row" | cut -f2)"; c5="$(echo "$row" | cut -f5)"
[ "$ev" = "reset" ] || fail "expected reset event, got '$ev'"
[ "$c5" = "0" ] || fail "reset total_s: expected 0, got '$c5'"
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
if echo "$cap" | grep -Eq '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'; then
  fail "timer line still rendered after reset"
fi
nf="$(awk -F'\t' '!/^#/{print NF}' "$TMPLOG" | sort -u)"
[ "$nf" = "9" ] || fail "expected 9 TSV fields on every logged row, got: $nf"
pass "reset clears state, logs reset row (total_s=0), display cleared"

# 13. Collapsed hides the timer line but state keeps evolving under the focus
#     engine (re-establish preconditions: start fresh, move focus to w1).
tmux -L "$SOCKET" select-window -t "$w0"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"   # unset -> run
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "run" ] || fail "expected run before collapse test: '$st'"
tmux -L "$SOCKET" select-window -t "$w1"
sleep 1
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 0.8
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb1")"
if echo "$cap" | grep -Eq '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'; then
  fail "timer line visible in collapsed mode"
fi
st="$(winopt "$w0" @sidetabs_timer_state)"
[ "$st" = "hold" ] || fail "timer state unexpected during collapse (w1 focused, w0 unfocused): '$st'"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 0.8
pass "collapsed hides timer line; focus-held state persists"

# 14. Keys bound on load; uninstall removes them AND all v2 focus-engine hooks.
tmux -L "$SOCKET" list-keys -T root | grep -q 'flag_cycle.sh' || fail "flag key not bound"
tmux -L "$SOCKET" list-keys -T root | grep -q 'flag_picker.sh' || fail "flag picker key not bound"
tmux -L "$SOCKET" list-keys -T root | grep -q 'timer.sh' || fail "timer key not bound"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.3
if tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'flag_cycle.sh'; then
  fail "flag key survived uninstall"
fi
if tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'flag_picker.sh'; then
  fail "flag picker key survived uninstall"
fi
if tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'timer.sh'; then
  fail "timer key survived uninstall"
fi
## show-hooks -g lists every hook TYPE tmux knows about, bound or not (a bare
## unbound line is just the name, e.g. "session-window-changed" with nothing
## after it) — so a plain name grep always "matches". Assert no BOUND command
## remains instead: name (optionally "[N]") followed by a command.
hooks="$(tmux -L "$SOCKET" show-hooks -g 2>/dev/null)"
for h in session-window-changed client-attached client-detached client-session-changed; do
  if echo "$hooks" | grep -Eq "^${h}(\[[0-9]+\])? +\S"; then
    fail "hook '$h' survived uninstall (still has a bound command)"
  fi
done
pass "keys bound on load, removed on uninstall; v2 focus hooks removed"

echo "ALL FEATURE SMOKE TESTS PASSED"
