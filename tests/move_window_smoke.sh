#!/usr/bin/env bash
# Smoke test for sidebar survival of `move-window`: a sidetab's render loop
# pins its session id at startup, so moving its window into ANOTHER session
# must make the loop re-pin — otherwise the sidebar keeps listing the OLD
# session's windows forever (and, worse, its qualified read target goes
# invalid, degrading the sidebar to blank rows). Temporary tmux server, two
# sessions, real move-window, asserts rendering via capture-pane. Hooks run
# async (run-shell -b) and a hidden sidebar rebuilds on refresh.sh's USR1, so
# sleeps of >=1s follow every state change before asserting.
set -euo pipefail

SOCKET="sidetab_move_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPLOG="${TMPDIR:-/tmp}/sidetabs_timelog_$$.tsv"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "$TMPLOG"; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
sbcap() { tmux -L "$SOCKET" capture-pane -p -t "$1" 2>/dev/null; }

# 1. Boot: session "main" with windows alpha+keep, session "other" with window
#    bravo, summary off (deterministic layout), hermetic log path. -f /dev/null
#    is required: without it a new server on this socket still auto-loads the
#    user's ~/.tmux.conf, polluting hooks/keys and defeating test isolation.
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n alpha -x 200 -y 50
tmux -L "$SOCKET" set-option -g @sidetabs-summary off
tmux -L "$SOCKET" set-option -g @sidetabs-timer-log "$TMPLOG"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.4
tmux -L "$SOCKET" new-window -t main -n keep
tmux -L "$SOCKET" new-session -d -s other -n bravo -x 200 -y 50
sleep 1

w_alpha="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id} #{window_name}' | awk '$2=="alpha"{print $1}')"
[ -n "$w_alpha" ] || fail "setup: window alpha not found"
sb_alpha="$(tmux -L "$SOCKET" list-panes -t "$w_alpha" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
[ -n "$sb_alpha" ] || fail "setup: alpha has no sidebar pane"

# 2. Baseline: before the move, alpha's sidebar lists its home session.
sbcap "$sb_alpha" | grep -q 'keep' || fail "baseline: alpha's sidebar should list sibling window 'keep'"
pass "baseline: alpha's sidebar lists session main"

# 3. Move alpha into session "other". The window-linked hook fires a forced
#    refresh, so even the now-hidden sidebar is signalled; select-window then
#    makes it the active window (visible on a 0-client server), so the fast
#    tick keeps it converging even if that one signal were swallowed.
tmux -L "$SOCKET" move-window -s "$w_alpha" -t 'other:'
sleep 1.2
tmux -L "$SOCKET" select-window -t "$w_alpha"
sleep 1.2

# 4. The sidebar must now render session "other": its header pill, the sibling
#    window bravo, and NO window of the abandoned session.
cap="$(sbcap "$sb_alpha")"
printf '%s\n' "$cap" | grep -q 'other' || fail "after move: header should show session 'other', got: $(printf '%s' "$cap" | head -3 | tr '\n' '|')"
printf '%s\n' "$cap" | grep -q 'bravo' || fail "after move: sidebar should list new sibling 'bravo'"
printf '%s\n' "$cap" | grep -q 'keep' && fail "after move: sidebar still lists 'keep' from the old session"
pass "moved window's sidebar re-pinned to session other"

echo "ALL PASS"
