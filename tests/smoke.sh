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

echo "ALL SMOKE TESTS PASSED"
