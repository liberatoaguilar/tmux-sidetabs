#!/usr/bin/env bash
# Visibility-gated rendering: sidebars in windows nobody is viewing must NOT
# rebuild on a timer (only on refresh events), while the viewed sidebar keeps
# its fast tick. Uses -f /dev/null so ~/.tmux.conf can't autoload other copies
# of the plugin, and a control-mode client (stdin held open on a fifo) to
# simulate an attached client without a tty.
set -euo pipefail

SOCKET="sidetab_vis_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIFO="${TMPDIR:-/tmp}/sidetab_vis_fifo_$$"
CLIENT_PID=""

cleanup() {
    exec 3>&- 2>/dev/null || true
    [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -f "$FIFO"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

# Distinct child PIDs a process spawns over N seconds (tight sampling loop).
count_children() {
    local ppid="$1" secs="$2" end
    end=$((SECONDS + secs))
    while [ "$SECONDS" -lt "$end" ]; do
        ps -ax -o pid=,ppid= 2>/dev/null | awk -v p="$ppid" '$2 == p { print $1 }'
    done | sort -u | grep -c . || true
}

sidebar_of() {  # window_id -> sidetab pane_id
    tmux -L "$SOCKET" list-panes -t "$1" -F '#{pane_id} #{@is_sidetab}' \
        | awk '$2 == "1" { print $1; exit }'
}

render_pid_of() {  # window_id -> render loop PID
    tmux -L "$SOCKET" show-option -p -t "$(sidebar_of "$1")" -qv '@sidetabs_render_pid'
}

# --- Setup: clean server, plugin, 3 windows, attached control client ---------
tmux -f /dev/null -L "$SOCKET" new-session -d -s main -x 200 -y 50
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.5
tmux -L "$SOCKET" new-window -t main
tmux -L "$SOCKET" new-window -t main
sleep 0.8

w0="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 1p)"
w1="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 2p)"
w2="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 3p)"
[ -n "$w0" ] && [ -n "$w1" ] && [ -n "$w2" ] || fail "setup: expected 3 windows"

mkfifo "$FIFO"
tmux -L "$SOCKET" -C attach-session -t main < "$FIFO" > /dev/null 2>&1 &
CLIENT_PID=$!
exec 3>"$FIFO"
tmux -L "$SOCKET" select-window -t "$w2"
sleep 1.2   # let sidebars observe the attach/switch and settle

clients="$(tmux -L "$SOCKET" list-clients 2>/dev/null | grep -c . || true)"
[ "$clients" = "1" ] || fail "setup: expected 1 control client, got $clients"

rp0="$(render_pid_of "$w0")"; rp2="$(render_pid_of "$w2")"
[ -n "$rp0" ] && [ -n "$rp2" ] || fail "setup: missing render PIDs (w0=$rp0 w2=$rp2)"

# --- 1. Idle churn: hidden sidebar spawns ~nothing; viewed one keeps ticking -
# A hidden sidebar may catch at most ONE self-heal rebuild (~6 children) in
# the 4s window (HIDDEN_TICK_SECS=5); a 0.5s-ticking regression shows ~25.
hidden_kids="$(count_children "$rp0" 4)"
visible_kids="$(count_children "$rp2" 4)"
[ "$hidden_kids" -le 12 ] \
    || fail "hidden sidebar ($w0) spawned $hidden_kids children in 4s — still rebuilding on the fast tick"
[ "$hidden_kids" -lt "$visible_kids" ] \
    || fail "hidden sidebar churn ($hidden_kids) not below viewed sidebar churn ($visible_kids)"
pass "hidden sidebar idle churn: $hidden_kids children in 4s"
[ "$visible_kids" -ge 4 ] \
    || fail "viewed sidebar ($w2) spawned only $visible_kids children in 4s — tick appears dead"
pass "viewed sidebar still ticks: $visible_kids children in 4s"

# --- 2. Hidden sidebars still update on refresh events (USR1) ----------------
tmux -L "$SOCKET" rename-window -t "$w0" RENAMED0
sleep 0.8
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$(sidebar_of "$w0")")"
echo "$cap" | grep -q 'RENAMED0' \
    || fail "hidden sidebar ($w0) did not pick up rename via refresh event"
pass "hidden sidebar updated on rename event while hidden"

# --- 3. Switching to a hidden window: sidebar correct promptly ---------------
tmux -L "$SOCKET" select-window -t "$w0"
sleep 0.5
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$(sidebar_of "$w0")")"
echo "$cap" | grep -q 'RENAMED0.*\*' \
    || fail "after switching to $w0 its sidebar lacks the active '*' on RENAMED0"
pass "newly viewed sidebar shows correct active row"

# --- 4. Rapid double-switch (debounce swallow guard) -------------------------
# Two switches ~back-to-back: the second lands inside the 100ms refresh
# debounce. The final window's sidebar must still be correct well before any
# slow hidden-tick would heal it.
tmux -L "$SOCKET" select-window -t "$w1"
tmux -L "$SOCKET" select-window -t "$w2"
sleep 0.7
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$(sidebar_of "$w2")")"
echo "$cap" | grep -Eq '^[^*]*\*' && echo "$cap" | awk '/\*/{found=1} END{exit !found}' \
    || fail "no active '*' anywhere in $w2 sidebar after rapid double-switch"
w2row="$(echo "$cap" | grep '\*' || true)"
w2idx="$(tmux -L "$SOCKET" display-message -p -t "$w2" '#{window_index}')"
echo "$w2row" | grep -q " $w2idx " \
    || fail "active '*' is not on window index $w2idx after rapid double-switch (row: $w2row)"
pass "rapid double-switch leaves the viewed sidebar correct"

# --- 5. Fully detached server: the active window's sidebar stays live --------
exec 3>&-
kill "$CLIENT_PID" 2>/dev/null || true; CLIENT_PID=""
sleep 1.2
rp2="$(render_pid_of "$w2")"
detached_active_kids="$(count_children "$rp2" 3)"
[ "$detached_active_kids" -ge 3 ] \
    || fail "detached server: active-window sidebar stopped ticking ($detached_active_kids children in 3s)"
pass "detached server keeps the active-window sidebar live ($detached_active_kids children in 3s)"

echo "ALL VISIBILITY TESTS PASSED"
