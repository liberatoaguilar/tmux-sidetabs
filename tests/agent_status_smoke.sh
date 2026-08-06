#!/usr/bin/env bash
# Smoke test for AGENT STATUS: temporary tmux server, sources the plugin, drives
# scripts/agent_status.sh via run-shell, asserts per-pane truth + the per-window
# aggregate via show-option -p/-w, the visit-clear hook via a real select-window,
# and rendering via capture-pane -e.
#
# -f /dev/null is required: without it a new server on this socket still
# auto-loads the user's ~/.tmux.conf (which run-shells this plugin AND others),
# polluting hooks/keys and defeating test isolation.
#
# Detached scratch servers have 0 clients, so render.sh's visibility gate treats
# the session's ACTIVE window's sidebar as visible (fast 0.5s tick). Every render
# assertion therefore captures the ACTIVE window's sidebar — which lists every
# window, so a state parked on a non-active window is still observable there.
# That matters: selecting a window IS the visit that consumes done/attention.
set -euo pipefail

SOCKET="sidetab_agent_$$"
# A second, throwaway server used purely as a TERMINAL: the "you are already
# looking at it" and pane-focus-in rules only exist when a client is attached,
# and a tmux pane is the most reliable pty to attach from.
OUTER="sidetab_agent_term_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/sidetabs_agentwork_$$"

cleanup() {
    tmux -L "$OUTER" kill-server 2>/dev/null || true
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK"

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
winopt()  { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }
paneopt() { tmux -L "$SOCKET" show-option -p -t "$1" -qv "$2"; }
run() { tmux -L "$SOCKET" run-shell "$*"; }
agent() { tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/agent_status.sh $*"; }

AG="@sidetabs_agent"; AGS="@sidetabs_agent_since"
PAG="@sidetabs_agent_pane"; PAGS="@sidetabs_agent_pane_since"

# Spinner frames (U+280B U+2819 U+2839 U+2838) and the done check (U+F00C).
S1="$(printf '\xe2\xa0\x8b')"; S2="$(printf '\xe2\xa0\x99')"
S3="$(printf '\xe2\xa0\xb9')"; S4="$(printf '\xe2\xa0\xb8')"
CHECK="$(printf '\xef\x80\x8c')"
BELL_SGR='48;2;191;97;106'      # @sidetabs-bell-bg #bf616a
FLAG1_SGR='48;2;235;203;139'    # flag palette slot 1 #ebcb8b
DONE_SGR='38;2;163;190;140'     # agent done fg #a3be8c
has_spinner() { grep -q -e "$S1" -e "$S2" -e "$S3" -e "$S4"; }
# Which frame a rendered line carries (empty if none).
spin_of() {
  local line="$1" f
  for f in "$S1" "$S2" "$S3" "$S4"; do
    case "$line" in *"$f"*) printf '%s' "$f"; return 0 ;; esac
  done
}
# The rendered row for window $2 as seen from sidebar pane $1.
rowof() { tmux -L "$SOCKET" capture-pane -p -t "$1" | grep -- "$2" | head -1; }

# --- 1. Boot: 2 named windows, summary off (deterministic layout) ------------
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n alpha -x 200 -y 50
tmux -L "$SOCKET" set-option -g @sidetabs-summary off
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.4
tmux -L "$SOCKET" new-window -n beta
sleep 0.6
w0="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="alpha"{print $2}')"
w1="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="beta"{print $2}')"
sb0="$(tmux -L "$SOCKET" list-panes -t "$w0" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
sb1="$(tmux -L "$SOCKET" list-panes -t "$w1" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
p0="$(tmux -L "$SOCKET" list-panes -t "$w0" -F '#{pane_id} #{@is_sidetab}' | awk '$2!=1{print $1}')"
p1="$(tmux -L "$SOCKET" list-panes -t "$w1" -F '#{pane_id} #{@is_sidetab}' | awk '$2!=1{print $1}')"
[ -n "$w0" ] && [ -n "$w1" ] && [ -n "$sb0" ] && [ -n "$sb1" ] && [ -n "$p0" ] && [ -n "$p1" ] \
  || fail "setup: expected 2 windows with sidebars and content panes"

# --- 2. The visit hook is registered on load (index 2 of session-window-changed)
tmux -L "$SOCKET" show-hooks -g | grep -Eq '^session-window-changed\[2\] +.*agent_status\.sh' \
  || fail "session-window-changed[2] visit hook not registered on load"
pass "visit hook registered on session-window-changed[2]"

# --- 3. working: pane truth + window aggregate + since ----------------------
agent "working $p1"
sleep 0.3
[ "$(paneopt "$p1" "$PAG")" = "working" ] || fail "pane state not 'working': '$(paneopt "$p1" "$PAG")'"
since_p="$(paneopt "$p1" "$PAGS")"
case "$since_p" in ''|*[!0-9]*) fail "pane since not an epoch: '$since_p'" ;; esac
[ "$(winopt "$w1" "$AG")" = "working" ] || fail "window aggregate not 'working': '$(winopt "$w1" "$AG")'"
[ "$(winopt "$w1" "$AGS")" = "$since_p" ] || fail "window since != pane since"
pass "working sets pane state + window aggregate + since"

# --- 4. Re-asserting the SAME state keeps the original since ----------------
sleep 1.2
agent "working $p1"
sleep 0.3
[ "$(paneopt "$p1" "$PAGS")" = "$since_p" ] || fail "re-assert moved the pane since"
[ "$(winopt "$w1" "$AGS")" = "$since_p" ] || fail "re-assert moved the window since"
pass "re-asserting the same state keeps the original since"

# --- 5. A real transition DOES move since ----------------------------------
agent "done $p1"
sleep 0.3
[ "$(paneopt "$p1" "$PAG")" = "done" ] || fail "pane state not 'done'"
[ "$(winopt "$w1" "$AG")" = "done" ] || fail "window aggregate not 'done'"
new_since="$(paneopt "$p1" "$PAGS")"
[ "$new_since" -gt "$since_p" ] 2>/dev/null || fail "transition did not move since ($since_p -> $new_since)"
pass "a state transition moves since"

# --- 6. Aggregation across panes: attention > working > done ---------------
tmux -L "$SOCKET" split-window -t "$p1" -d
sleep 0.8
p1b="$(tmux -L "$SOCKET" list-panes -t "$w1" -F '#{pane_id} #{@is_sidetab}' | awk '$2!=1{print $1}' | sed -n 2p)"
[ -n "$p1b" ] || fail "setup: second content pane missing in beta"

agent "working $p1"
agent "done $p1b"
sleep 0.3
[ "$(winopt "$w1" "$AG")" = "working" ] || fail "working+done should aggregate to working: '$(winopt "$w1" "$AG")'"

agent "attention $p1b"
sleep 0.3
[ "$(winopt "$w1" "$AG")" = "attention" ] || fail "working+attention should aggregate to attention"
pass "aggregate takes the worst state (attention > working > done)"

# --- 6b. Aggregate since = the OLDEST since among panes holding the winner --
agent "clear $p1"; agent "clear $p1b"
sleep 0.3
agent "attention $p1"
old_since="$(paneopt "$p1" "$PAGS")"
sleep 1.2
agent "attention $p1b"
sleep 0.3
[ "$(paneopt "$p1b" "$PAGS")" -gt "$old_since" ] 2>/dev/null || fail "setup: second pane since not newer"
[ "$(winopt "$w1" "$AGS")" = "$old_since" ] || \
  fail "aggregate since should be the oldest winner ($old_since), got '$(winopt "$w1" "$AGS")'"
pass "aggregate since is the oldest among panes holding the winning state"

# --- 7. clear unsets only the calling pane; empty window unsets both --------
agent "clear $p1"
sleep 0.3
[ -z "$(paneopt "$p1" "$PAG")" ] || fail "clear left the pane state set"
[ "$(winopt "$w1" "$AG")" = "attention" ] || fail "clear dropped the OTHER pane's state"
agent "clear $p1b"
sleep 0.3
[ -z "$(winopt "$w1" "$AG")" ] || fail "last clear left the window aggregate set"
[ -z "$(winopt "$w1" "$AGS")" ] || fail "last clear left the window since set"
pass "clear is per-pane; the last one unsets the window aggregate"

# --- 8. visited (driven by the REAL hook): done + attention are consumed,
#        working survives the visit ----------------------------------------
tmux -L "$SOCKET" select-window -t "$w0"; sleep 0.6
agent "done $p1"
agent "working $p1b"
sleep 0.3
[ "$(winopt "$w1" "$AG")" = "working" ] || fail "setup: expected working aggregate before visit"
tmux -L "$SOCKET" select-window -t "$w1"
sleep 0.8
[ -z "$(paneopt "$p1" "$PAG")" ] || fail "visit did not consume 'done': '$(paneopt "$p1" "$PAG")'"
[ "$(paneopt "$p1b" "$PAG")" = "working" ] || fail "visit killed 'working'"
[ "$(winopt "$w1" "$AG")" = "working" ] || fail "aggregate after visit should stay working"

agent "attention $p1"
sleep 0.3
[ "$(winopt "$w1" "$AG")" = "attention" ] || fail "setup: expected attention before the second visit"
tmux -L "$SOCKET" select-window -t "$w0"; sleep 0.6
tmux -L "$SOCKET" select-window -t "$w1"; sleep 0.8
[ -z "$(paneopt "$p1" "$PAG")" ] || fail "visit did not consume 'attention'"
[ "$(paneopt "$p1b" "$PAG")" = "working" ] || fail "visit killed 'working' (second visit)"
pass "a visit consumes done + attention; working survives"

agent "clear $p1b"
sleep 0.3

# --- 9. Render: working shows a spinner frame on the row + a 'working ·' line
# beta's states are viewed from alpha's sidebar so that selecting a window never
# consumes what we are about to assert on.
tmux -L "$SOCKET" select-window -t "$w0"; sleep 0.6
agent "working $p1"
sleep 1.2
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
betaline="$(printf '%s\n' "$cap" | grep -- 'beta' | head -1)"
[ -n "$betaline" ] || fail "beta row not rendered at all"
printf '%s\n' "$betaline" | has_spinner || fail "no spinner frame on the working row: [$betaline]"
printf '%s\n' "$cap" | grep -q 'working ·' || fail "no 'working ·' sub-line rendered"
printf '%s\n' "$cap" | grep -q 'working ·' && printf '%s\n' "$cap" | grep 'working ·' | has_spinner \
  || fail "the working sub-line carries no spinner"
pass "working renders a spinner on the row and a 'working ·' sub-line"

# --- 10. Render: done shows the green check; a visit makes it disappear -----
agent "done $p1"
sleep 1.2
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
betaline="$(printf '%s\n' "$cap" | grep -- 'beta' | head -1)"
case "$betaline" in *"$CHECK"*) : ;; *) fail "no check glyph on the done row: [$betaline]" ;; esac
case "$betaline" in *"$DONE_SGR"*) : ;; *) fail "check glyph not painted with the done fg" ;; esac
if printf '%s\n' "$cap" | grep -q 'working ·'; then fail "done row still shows a working sub-line"; fi

tmux -L "$SOCKET" select-window -t "$w1"; sleep 0.8
tmux -L "$SOCKET" select-window -t "$w0"; sleep 1.2
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
betaline="$(printf '%s\n' "$cap" | grep -- 'beta' | head -1)"
case "$betaline" in *"$CHECK"*) fail "check glyph survived the visit: [$betaline]" ;; esac
pass "done renders the green check; a visit clears it from the row"

# --- 11. Render: attention paints the row bell-red and beats a flag; a
#         DIFFERENT flagged row keeps its own flag color --------------------
agent "attention $p1"
run "$PLUGIN_DIR/scripts/flag_set.sh $w0 1"
run "$PLUGIN_DIR/scripts/flag_set.sh $w1 2"
sleep 1.2
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
betaline="$(printf '%s\n' "$cap" | grep -- 'beta' | head -1)"
alphaline="$(printf '%s\n' "$cap" | grep -- 'alpha' | head -1)"
case "$betaline" in *"$BELL_SGR"*) : ;; *) fail "attention row is not bell-red: [$betaline]" ;; esac
case "$alphaline" in *"$FLAG1_SGR"*) : ;; *) fail "flagged non-attention row lost its flag color" ;; esac
case "$alphaline" in *"$BELL_SGR"*) fail "a non-attention row was painted red" ;; esac
# At the default width of 20 the sub-line truncates like any summary line, so
# only the label survives; widen the pane to see the whole "· <age>" tail.
printf '%s\n' "$cap" | grep -q 'waiting for you' || fail "no 'waiting for you' sub-line rendered"
tmux -L "$SOCKET" resize-pane -t "$sb0" -x 34
sleep 1.2
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
printf '%s\n' "$cap" | grep -Eq 'waiting for you · [0-9]+[smh]' \
  || fail "widened sidebar does not show 'waiting for you · <age>'"
tmux -L "$SOCKET" resize-pane -t "$sb0" -x 20
sleep 1.0
pass "attention paints the row bell-red (beats flags); flagged rows keep their color"

# --- 12. Collapsed mode still shows attention-red (pill color, no glyphs) ---
run "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 1.2
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
printf '%s\n' "$cap" | grep -q "$BELL_SGR" || fail "collapsed attention row is not red"
if printf '%s\n' "$cap" | grep -q -- "$CHECK"; then fail "check glyph leaked into collapsed mode"; fi
run "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 1.0
pass "collapsed mode keeps the attention red pill and drops the glyphs"

# --- 13. Narrow sidebar: the status glyph must not push the cap arrow off ---
ARROW="$(printf '\xee\x82\xb0')"
agent "clear $p1"; agent "working $p1"
run "$PLUGIN_DIR/scripts/flag_set.sh $w0 none"
run "$PLUGIN_DIR/scripts/flag_set.sh $w1 none"
tmux -L "$SOCKET" resize-pane -t "$sb0" -x 8
sleep 1.5
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
nrows=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    *"$ARROW") nrows=$((nrows + 1)) ;;
    *"$ARROW"*) fail "a row wrapped at width 8: [$line]" ;;
  esac
done <<< "$cap"
[ "$nrows" -ge 2 ] || fail "expected at least 2 capped rows at width 8, got $nrows"
if printf '%s\n' "$cap" | grep -q "^ *${ARROW} *$"; then
  fail "an orphaned cap/arrow fragment landed on its own line (row overflowed)"
fi
tmux -L "$SOCKET" resize-pane -t "$sb0" -x 20
sleep 1.0
pass "status glyph joins the shrink cascade; rows keep their cap arrow at width 8"

# --- 14. Master switch off: no writes at all -------------------------------
agent "clear $p1"
sleep 0.3
tmux -L "$SOCKET" set-option -g @sidetabs-agent-status off
agent "working $p1"
sleep 0.3
[ -z "$(paneopt "$p1" "$PAG")" ] || fail "master switch off still wrote the pane state"
[ -z "$(winopt "$w1" "$AG")" ] || fail "master switch off still wrote the window aggregate"
tmux -L "$SOCKET" set-option -g @sidetabs-agent-status on
agent "working $p1"
sleep 0.3
[ "$(paneopt "$p1" "$PAG")" = "working" ] || fail "master switch back on did not restore writes"
agent "clear $p1"
pass "master switch off suppresses every write"

# --- 15. Outside tmux entirely: exit 0, silent, and NO tmux call at all -----
out="$(env -u TMUX -u TMUX_PANE "$PLUGIN_DIR/scripts/agent_status.sh" working 2>&1)" || \
  fail "outside tmux: non-zero exit"
[ -z "$out" ] || fail "outside tmux: produced output: [$out]"
out="$(env -u TMUX -u TMUX_PANE "$PLUGIN_DIR/scripts/agent_status.sh" clear 2>&1)" || \
  fail "outside tmux (clear): non-zero exit"
[ -z "$out" ] || fail "outside tmux (clear): produced output: [$out]"
pass "outside tmux: silent exit 0"

# --- 16. Unknown/garbage subcommand is a silent no-op ----------------------
agent "bogus $p1"
sleep 0.2
[ -z "$(paneopt "$p1" "$PAG")" ] || fail "an unknown subcommand wrote state"
pass "unknown subcommand is a no-op"

# --- 17. codex-notify adapter ---------------------------------------------
mk_codex() {  # $1 = file, $2 = json
  cat > "$WORK/$1" <<EOF
#!/usr/bin/env bash
exec "$PLUGIN_DIR/scripts/agent_status.sh" codex-notify --pane "$p1" '$2'
EOF
  chmod +x "$WORK/$1"
}
mk_codex turn.sh '{"type":"agent-turn-complete","turn-id":"0","last-assistant-message":"done"}'
run "$WORK/turn.sh"
sleep 0.3
[ "$(paneopt "$p1" "$PAG")" = "done" ] || fail "codex agent-turn-complete did not map to done: '$(paneopt "$p1" "$PAG")'"

agent "clear $p1"
mk_codex approval.sh '{"type":"exec-approval-request","command":"rm -rf /"}'
run "$WORK/approval.sh"
sleep 0.3
[ "$(paneopt "$p1" "$PAG")" = "attention" ] || fail "codex approval request did not map to attention"

agent "clear $p1"
mk_codex unknown.sh '{"type":"some-future-event","x":1}'
run "$WORK/unknown.sh"
sleep 0.3
[ -z "$(paneopt "$p1" "$PAG")" ] || fail "codex unknown type wrote state: '$(paneopt "$p1" "$PAG")'"

mk_codex garbage.sh 'not json at all'
run "$WORK/garbage.sh"
sleep 0.3
[ -z "$(paneopt "$p1" "$PAG")" ] || fail "codex garbage payload wrote state"
pass "codex-notify maps turn-complete->done, approval->attention, unknown->no-op"

# --- 17b. A user's own configured `notify` argument is NOT read as a pane id --
# codex's notify is an array, so extra args are expected. Only `--pane` may set
# the target; anything else must fall back to $TMUX_PANE rather than silently
# writing the state to whatever window the session is currently on.
agent "clear $p1"
tmux -L "$SOCKET" select-window -t "$w0"; sleep 0.5
cat > "$WORK/extra_arg.sh" <<EOF
#!/usr/bin/env bash
export TMUX_PANE="$p1"
exec "$PLUGIN_DIR/scripts/agent_status.sh" codex-notify --my-flag '{"type":"agent-turn-complete"}'
EOF
chmod +x "$WORK/extra_arg.sh"
run "$WORK/extra_arg.sh"
sleep 0.4
[ "$(paneopt "$p1" "$PAG")" = "done" ] \
  || fail "an extra configured arg broke pane targeting: '$(paneopt "$p1" "$PAG")'"
[ -z "$(winopt "$w0" "$AG")" ] || fail "codex state landed on the wrong (current) window"
agent "clear $p1"; sleep 0.3
pass "codex-notify ignores unknown configured args instead of misreading them as a pane"

# --- 19. A dead pane can't leave the window aggregate stuck ------------------
# The aggregate is a cache; pane options die with the pane, so something has to
# re-derive it. window-layout-changed (via layout_changed.sh) is that something.
before_panes="$(tmux -L "$SOCKET" list-panes -t "$w1" -F '#{pane_id}')"
tmux -L "$SOCKET" split-window -t "$p1" -d
sleep 0.8
victim="$(tmux -L "$SOCKET" list-panes -t "$w1" -F '#{pane_id}' | grep -vxF "$before_panes")"
[ -n "$victim" ] || fail "setup: no extra pane to kill in beta"
agent "working $victim"
sleep 0.4
[ "$(winopt "$w1" "$AG")" = "working" ] || fail "setup: expected working before the kill"
tmux -L "$SOCKET" kill-pane -t "$victim"
sleep 1.0
[ -z "$(winopt "$w1" "$AG")" ] \
  || fail "killing the only agent pane left the aggregate stuck: '$(winopt "$w1" "$AG")'"
[ -z "$(winopt "$w1" "$AGS")" ] || fail "aggregate since survived the pane's death"
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
betaline="$(printf '%s\n' "$cap" | grep -- 'beta' | head -1)"
printf '%s\n' "$betaline" | has_spinner && fail "a spinner outlived the pane that set it: [$betaline]"
pass "a dead pane's state is reconciled away (no spinner on a window with no agent)"

# --- 20. attention displaces working, and a visit puts working BACK ---------
# The pane holds one state, so a mid-turn permission prompt overwrites
# `working`. Consuming the attention must restore what it displaced — with its
# original clock — or the tab goes blank for the rest of the turn.
agent "working $p1"
sleep 0.4
work_since="$(paneopt "$p1" "$PAGS")"
sleep 1.2
agent "attention $p1"
sleep 0.4
[ "$(winopt "$w1" "$AG")" = "attention" ] || fail "setup: attention did not displace working"
tmux -L "$SOCKET" select-window -t "$w1"; sleep 0.9
[ "$(paneopt "$p1" "$PAG")" = "working" ] \
  || fail "visiting after a permission prompt blanked the pane: '$(paneopt "$p1" "$PAG")'"
[ "$(paneopt "$p1" "$PAGS")" = "$work_since" ] || fail "restored working restarted its clock"
[ "$(winopt "$w1" "$AG")" = "working" ] || fail "aggregate not back to working after the visit"
[ -z "$(paneopt "$p1" "@sidetabs_agent_pane_prev")" ] || fail "the prev-state slot was not consumed"
tmux -L "$SOCKET" select-window -t "$w0"; sleep 1.2
betaline="$(rowof "$sb0" beta)"
printf '%s\n' "$betaline" | has_spinner || fail "restored working does not render: [$betaline]"
agent "clear $p1"; sleep 0.3
pass "a consumed attention restores the working it displaced, clock intact"

# --- 21. A half-written aggregate (state, no since) is not dated from 1970 ---
# Widen FIRST: a resize is a layout change, and a layout change re-derives the
# aggregate — which would legitimately reconcile this hand-written state away.
tmux -L "$SOCKET" resize-pane -t "$sb0" -x 34
sleep 0.8
tmux -L "$SOCKET" set-option -w -t "$w1" "$AG" working
run "$PLUGIN_DIR/scripts/refresh.sh force"
sleep 1.2
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
printf '%s\n' "$cap" | grep -q 'working ·' || fail "setup: no working sub-line for the since-less state"
printf '%s\n' "$cap" | grep -Eq 'working · [0-9]{3,}h' \
  && fail "a missing since rendered as an epoch age: [$(printf '%s\n' "$cap" | grep 'working ·')]"
printf '%s\n' "$cap" | grep -Eq 'working · [0-9]+[sm]' \
  || fail "a missing since should read as a fresh age: [$(printf '%s\n' "$cap" | grep 'working ·')]"
tmux -L "$SOCKET" set-option -w -t "$w1" -u "$AG"
tmux -L "$SOCKET" resize-pane -t "$sb0" -x 20
sleep 1.0
pass "an aggregate written without a since renders a fresh age, not the epoch"

# --- 22. The master switch hides state that is ALREADY showing --------------
# Flipping it off must not freeze the row it was drawing at the time, and the
# clearing paths have to keep working while off or the state can never leave.
agent "attention $p1"
sleep 1.2
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
printf '%s\n' "$cap" | grep -q "$BELL_SGR" || fail "setup: attention row is not red before the switch"
tmux -L "$SOCKET" set-option -g @sidetabs-agent-status off
run "$PLUGIN_DIR/scripts/refresh.sh force"
sleep 1.2
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
printf '%s\n' "$cap" | grep -q "$BELL_SGR" && fail "switch off left the row painted bell-red"
printf '%s\n' "$cap" | grep -q 'waiting for you' && fail "switch off left the attention sub-line"
[ "$(winopt "$w1" "$AG")" = "attention" ] || fail "setup: the stored state should be untouched, just hidden"
# …and a visit still consumes it while off, so nothing can get stuck.
tmux -L "$SOCKET" select-window -t "$w1"; sleep 0.9
[ -z "$(winopt "$w1" "$AG")" ] || fail "a visit did not consume the signal while the switch was off"
tmux -L "$SOCKET" set-option -g @sidetabs-agent-status on
tmux -L "$SOCKET" select-window -t "$w0"; sleep 0.8
pass "master switch off hides live state and still lets a visit clear it"

# --- 23. Every sidebar shows the SAME spinner frame at the same instant -----
# One render.sh runs per window, each on its own tick (0.5s visible, 5s hidden),
# so the frame has to come from the wall clock: otherwise switching into a
# working window makes its spinner jump to an unrelated phase.
agent "working $p1"
sleep 1.0
mismatch=0
for round in 1 2 3 4 5; do
  sleep 0.7                                   # let the two loops drift apart
  run "$PLUGIN_DIR/scripts/refresh.sh force"  # both redraw within a few ms
  sleep 0.35
  fa="$(spin_of "$(rowof "$sb0" beta)")"
  fb="$(spin_of "$(rowof "$sb1" beta)")"
  [ -n "$fa" ] && [ -n "$fb" ] || fail "no spinner frame in round $round (sb0='$fa' sb1='$fb')"
  [ "$fa" = "$fb" ] || mismatch=$((mismatch + 1))
done
# One tolerated mismatch: the two redraws are milliseconds apart and can
# straddle a frame boundary. Two means the frames are unrelated.
[ "$mismatch" -le 1 ] || fail "spinner frames disagree across sidebars ($mismatch/5 rounds)"
agent "clear $p1"; sleep 0.3
pass "the spinner frame is wall-clock derived: every sidebar shows it in step"

# --- 24. With a client ATTACHED, a signal raised on the window you are
#         already looking at is consumed on the spot (bell semantics) --------
tmux -L "$SOCKET" set-option -g focus-events on
tmux -L "$SOCKET" select-window -t "$w1"; sleep 0.6
agent "attention $p1"
sleep 0.4
[ "$(winopt "$w1" "$AG")" = "attention" ] || fail "setup: no attention raised while detached"
tmux -L "$OUTER" -f /dev/null new-session -d -x 200 -y 50 \
  "tmux -f /dev/null -L $SOCKET attach -t main"
sleep 1.2
[ "$(tmux -L "$SOCKET" display-message -p -t "$w1" '#{session_attached}')" = "1" ] \
  || fail "setup: could not attach a client"
# Moving between panes of the window you are on is "you looked" too — the only
# other consumer, session-window-changed, never fires without a window change.
tmux -L "$SOCKET" select-pane -t "$sb1"; sleep 0.9
[ -z "$(winopt "$w1" "$AG")" ] \
  || fail "pane-focus-in did not consume the signal: '$(winopt "$w1" "$AG")'"
pass "focusing another pane of the current window consumes the signal"

# --- 25. …and a signal RAISED on the watched window never lights up at all --
agent "working $p1"
sleep 0.4
[ "$(winopt "$w1" "$AG")" = "working" ] || fail "working must still be raised on a watched window"
agent "attention $p1"
sleep 0.4
[ "$(paneopt "$p1" "$PAG")" = "working" ] \
  || fail "attention on the watched window was not consumed on the spot: '$(paneopt "$p1" "$PAG")'"
[ "$(winopt "$w1" "$AG")" = "working" ] || fail "watched-window attention reached the aggregate"
agent "done $p1"
sleep 0.4
[ -z "$(paneopt "$p1" "$PAG")" ] \
  || fail "done on the watched window was not consumed: '$(paneopt "$p1" "$PAG")'"
[ -z "$(winopt "$w1" "$AG")" ] || fail "watched-window done reached the aggregate"
tmux -L "$OUTER" kill-server 2>/dev/null || true
sleep 0.6
pass "done/attention raised on the window you are watching are consumed at the source"

# --- 26. Uninstall drops the visit hook (the whole hook name is unset) ------
run "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.4
hooks="$(tmux -L "$SOCKET" show-hooks -g 2>/dev/null)"
if printf '%s\n' "$hooks" | grep -Eq '^session-window-changed(\[[0-9]+\])? +\S'; then
  fail "session-window-changed hooks survived uninstall"
fi
pass "uninstall removes the visit hook"

echo "ALL AGENT STATUS SMOKE TESTS PASSED"
