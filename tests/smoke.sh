#!/usr/bin/env bash
# Smoke test: spins up a temporary tmux server, sources the plugin,
# asserts the sidetab is created and the toggle works.
set -euo pipefail

SOCKET="sidetab_test_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

# 1. Start detached tmux session.
tmux -L "$SOCKET" new-session -d -s main -x 200 -y 50

# 2. Source the plugin.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.4

# 3. Sidetab pane should exist in the only window.
sidetab="$(tmux -L "$SOCKET" list-panes -F '#{pane_id} #{@is_sidetab}' \
            | awk '$2 == "1" { print $1 }')"
[ -n "$sidetab" ] || fail "no sidetab created on initial setup"
pass "sidetab created — $sidetab"

# 4. Width approximately matches EXPANDED_WIDTH (20).
w="$(tmux -L "$SOCKET" display-message -p -t "$sidetab" '#{pane_width}')"
[ "$w" -ge 18 ] && [ "$w" -le 22 ] || fail "expanded width unexpected: $w"
pass "expanded width = $w"

# 5. Create a new window — hook should auto-spawn another sidetab.
tmux -L "$SOCKET" new-window
sleep 0.4
count="$(tmux -L "$SOCKET" list-panes -a -F '#{@is_sidetab}' | grep -c '^1$' || true)"
[ "$count" = "2" ] || fail "expected 2 sidetabs after new-window, got $count"
pass "auto-created sidetab on new window"

# 6. Toggle collapse.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 0.3
w2="$(tmux -L "$SOCKET" display-message -p -t "$sidetab" '#{pane_width}')"
[ "$w2" -le 6 ] || fail "collapsed width unexpected: $w2"
pass "collapsed width = $w2"

# 7. Toggle back.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 0.3
w3="$(tmux -L "$SOCKET" display-message -p -t "$sidetab" '#{pane_width}')"
[ "$w3" -ge 18 ] && [ "$w3" -le 22 ] || fail "re-expanded width unexpected: $w3"
pass "re-expanded width = $w3"

# 8. Self-mouse click-to-select: render.sh reads its OWN mouse (no global tmux
#    `mouse`). We inject synthetic SGR clicks into a sidebar pane's stdin (via
#    send-keys -H, which needs no real mouse and no focus) and assert it switches
#    windows. @sidetabs-summary off makes the layout deterministic:
#      line 0 header, line 1 rule, line 2 = window[0] row (SGR y=3),
#      line 3 rule, line 4 = window[1] row (SGR y=5).
tmux -L "$SOCKET" set-option -g @sidetabs-mouse on
tmux -L "$SOCKET" set-option -g @sidetabs-summary off
# Restart every sidebar render loop so it picks up the options + enables self-mouse.
for p in $(tmux -L "$SOCKET" list-panes -a -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}'); do
  tmux -L "$SOCKET" respawn-pane -k -t "$p" "$PLUGIN_DIR/scripts/render.sh"
done
sleep 1

w0="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 1p)"
w1="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 2p)"
[ -n "$w0" ] && [ -n "$w1" ] || fail "expected 2 windows for the click test"

# Make w1 active, then click window[0]'s row (SGR y=3) in w1's sidebar.
tmux -L "$SOCKET" select-window -t "$w1"
sb1="$(tmux -L "$SOCKET" list-panes -t "$w1" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
tmux -L "$SOCKET" send-keys -t "$sb1" -H 1b 5b 3c 30 3b 33 3b 33 4d   # ESC [ < 0 ; 3 ; 3 M
sleep 1
sel="$(tmux -L "$SOCKET" display-message -p -t main '#{window_id} #{@is_sidetab}')"
sel_win="${sel%% *}"; sel_mark="${sel##* }"
[ "$sel_win" = "$w0" ] || fail "self-mouse click selected $sel_win, expected $w0"
[ "$sel_mark" = "1" ] || fail "self-mouse click should keep focus in the sidebar (got non-sidetab)"
pass "self-mouse click switched to window $w0 and kept focus in the sidebar"

# 9. A click on a non-row line (header, SGR y=1) does NOT change the window.
sb0="$(tmux -L "$SOCKET" list-panes -t "$w0" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
tmux -L "$SOCKET" send-keys -t "$sb0" -H 1b 5b 3c 30 3b 33 3b 31 4d   # ESC [ < 0 ; 3 ; 1 M (header)
sleep 1
now_win="$(tmux -L "$SOCKET" display-message -p -t main '#{window_id}')"
[ "$now_win" = "$w0" ] || fail "header click changed window ($now_win), expected no change"
pass "self-mouse header click is a no-op"

echo "ALL SMOKE TESTS PASSED"
