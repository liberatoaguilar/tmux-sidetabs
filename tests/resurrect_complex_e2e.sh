#!/usr/bin/env bash
# Complex-layout end-to-end resurrect test — reproduces the real-world shape that
# the first (2-pane) e2e missed: multi-pane windows (sidebar + main + stacked
# splits). Asserts that across a real save/kill/restart/restore the integration:
#   * yields exactly one sidetab per window,
#   * leaves NO sliver panes (width <= 3), and
#   * preserves every content pane (by working directory).
set -euo pipefail
SOCK="sidetabs_cx_$$"
PLUGIN=/Users/liberatoaguilar/Desktop/Aguilabs/tmux-sidetabs
REZ="$HOME/.tmux/plugins/tmux-resurrect"
RDIR="$(mktemp -d)"
D1="$(mktemp -d)"; D2="$(mktemp -d)"; D3="$(mktemp -d)"   # distinct content cwds

cleanup(){ tmux -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$RDIR" "$D1" "$D2" "$D3"; }
trap cleanup EXIT
fail(){ echo "CX-E2E FAIL: $*"; exit 1; }

setup_server() {
  tmux -L "$SOCK" set-option -g @resurrect-dir "$RDIR"
  tmux -L "$SOCK" set-option -g @resurrect-hook-pre-restore-all  "bash $PLUGIN/scripts/resurrect_pre.sh"
  tmux -L "$SOCK" set-option -g @resurrect-hook-post-restore-all "bash $PLUGIN/scripts/resurrect_post.sh"
  tmux -L "$SOCK" run-shell "$REZ/resurrect.tmux"
  tmux -L "$SOCK" run-shell "$PLUGIN/sidetabs.tmux"
}
content_pane() { tmux -L "$SOCK" list-panes -t "$1" -F '#{pane_id} #{@is_sidetab}' | awk '$2!="1"{print $1; exit}'; }
# sorted content-pane cwds for a window (excludes the marked sidetab)
content_sig() {
  # DATA/SIDE sentinel keeps the first field a single token even when the
  # unmarked panes' @is_sidetab is empty (a bare space-split would misalign).
  tmux -L "$SOCK" list-panes -t "$1" -F '#{?@is_sidetab,SIDE,DATA} #{pane_current_path}' \
    | awk '$1=="DATA"{print $2}' | sort | tr '\n' ',';
}
marked_in(){ tmux -L "$SOCK" list-panes -t "$1" -F '#{@is_sidetab}' | grep -c '^1$' || true; }
slivers_any(){ tmux -L "$SOCK" list-panes -a -F '#{pane_width}' | awk '$1<=3' | wc -l | tr -d ' '; }

# --- Build: window 1 = sidebar + main + two stacked (4 panes); window 2 = sidebar + 1 split ---
tmux -L "$SOCK" new-session -d -s cx -x 200 -y 50
setup_server; sleep 0.4
# window 1
c=$(content_pane @0 2>/dev/null || true); c=$(tmux -L "$SOCK" list-panes -t cx:0 -F '#{pane_id} #{@is_sidetab}' | awk '$2!="1"{print $1; exit}')
tmux -L "$SOCK" split-window -h -c "$D1" -t "$c";            sleep 0.3   # main + right
right=$(tmux -L "$SOCK" list-panes -t cx:0 -F '#{pane_id} #{pane_current_path}' | awk -v d="$D1" '$2==d{print $1; exit}')
tmux -L "$SOCK" split-window -v -c "$D2" -t "$right";        sleep 0.3   # right -> top/bottom
# window 2
tmux -L "$SOCK" new-window; sleep 0.4
c2=$(tmux -L "$SOCK" list-panes -t cx:1 -F '#{pane_id} #{@is_sidetab}' | awk '$2!="1"{print $1; exit}')
tmux -L "$SOCK" split-window -h -c "$D3" -t "$c2";           sleep 0.3
sleep 0.3

w0=$(tmux -L "$SOCK" list-windows -F '#{window_id}' | sed -n 1p)
w1=$(tmux -L "$SOCK" list-windows -F '#{window_id}' | sed -n 2p)
[ "$(marked_in "$w0")" = "1" ] && [ "$(marked_in "$w1")" = "1" ] || fail "setup: each window should have 1 sidetab"
[ "$(slivers_any)" = "0" ] || fail "setup produced a sliver already"
sig0_before="$(content_sig "$w0")"; sig1_before="$(content_sig "$w1")"
echo "before: w0 panes=$(tmux -L "$SOCK" list-panes -t "$w0" | wc -l|tr -d ' ') content=[$sig0_before]"
echo "before: w1 panes=$(tmux -L "$SOCK" list-panes -t "$w1" | wc -l|tr -d ' ') content=[$sig1_before]"

# --- Save ---
tmux -L "$SOCK" run-shell "$REZ/scripts/save.sh"; sleep 0.6
[ -f "$RDIR/last" ] || fail "no snapshot produced"

# --- Simulate reboot: kill + fresh server + restore ---
tmux -L "$SOCK" kill-server; sleep 0.3
tmux -L "$SOCK" new-session -d -s cx -x 200 -y 50
setup_server; sleep 0.4
tmux -L "$SOCK" run-shell "$REZ/scripts/restore.sh"; sleep 1.8

# --- Assert ---
fails=0
echo "after restore:"
[ "$(slivers_any)" = "0" ] || { echo "  SLIVER(S) present!"; fails=1; }
for w in $(tmux -L "$SOCK" list-windows -a -F '#{window_id}'); do
  m=$(marked_in "$w"); sig="$(content_sig "$w")"
  echo "  window $w: sidetabs=$m content=[$sig]"
  [ "$m" = "1" ] || { echo "    ^ expected 1 sidetab"; fails=1; }
done
# content of the restored windows must match what we built (order of windows preserved)
rw0=$(tmux -L "$SOCK" list-windows -a -F '#{window_id}' | sed -n 1p)
rw1=$(tmux -L "$SOCK" list-windows -a -F '#{window_id}' | sed -n 2p)
[ "$(content_sig "$rw0")" = "$sig0_before" ] || { echo "  w0 content changed: [$(content_sig "$rw0")] != [$sig0_before]"; fails=1; }
[ "$(content_sig "$rw1")" = "$sig1_before" ] || { echo "  w1 content changed: [$(content_sig "$rw1")] != [$sig1_before]"; fails=1; }

[ "$fails" = "0" ] || fail "restored layout not clean / content not preserved"
echo "CX-E2E PASS: complex layouts restore with one sidetab each, no slivers, content preserved"
