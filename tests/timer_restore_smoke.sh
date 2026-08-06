#!/usr/bin/env bash
# Timer state survives a server death: timer_restore.sh replays the durable TSV
# event log and re-seeds @sidetabs_timer_* window options, matching windows by
# (session name, window name) — window IDs do not survive a restart. Verifies:
# sticky manual pause comes back as pause, a running/held timer comes back as
# hold (the focus engine resumes it on focus), reset timers stay gone, live
# state is never clobbered, and a second run is a no-op.
set -euo pipefail

SOCKET="sidetab_trez_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPLOG="${TMPDIR:-/tmp}/sidetabs_trez_$$.tsv"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "$TMPLOG"; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
winopt() { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$TMPLOG"; }
lognorows() { grep -vc '^#' "$TMPLOG" || true; }

# --- Synthetic history (timestamps are irrelevant to the replay; the total in
# --- col5 is authoritative at every event) ------------------------------------
printf '#ts\tevent\tinterval_start\tinterval_s\ttotal_s\tsession\twindow\twindow_id\tcwd\n' > "$TMPLOG"
# alpha: ran, manual pause at 100s, adjusted to 160s -> pause/160 (sticky)
row t1 start       -  0   0   main alpha @90 /tmp
row t2 pause       t1 100 100 main alpha @90 /tmp
row t3 adjust      -  60  160 main alpha @90 /tmp
# beta: auto-held then resumed; running at death -> hold/50
row t1 start       -  0   0   main beta  @91 /tmp
row t2 auto-pause  t1 50  50  main beta  @91 /tmp
row t3 auto-resume -  0   50  main beta  @91 /tmp
# gamma: reset was the last word -> nothing comes back
row t1 start       -  0   0   main gamma @92 /tmp
row t2 pause       t1 200 200 main gamma @92 /tmp
row t3 reset       -  200 0   main gamma @92 /tmp
# delta: window won't exist on the live server -> ignored
row t1 pause       t0 40  40  main delta @93 /tmp
# livewin: log says 999 but the live window already has state -> not clobbered
row t1 pause       t0 999 999 main livewin @94 /tmp

# --- Server with matching windows; no plugin load needed (pure state work) ----
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n alpha -x 200 -y 50
tmux -L "$SOCKET" set -g @sidetabs-timer-log "$TMPLOG"
tmux -L "$SOCKET" new-window -t main -n beta
tmux -L "$SOCKET" new-window -t main -n gamma
tmux -L "$SOCKET" new-window -t main -n livewin
wa="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="alpha"{print $2}')"
wb="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="beta"{print $2}')"
wg="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="gamma"{print $2}')"
wl="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="livewin"{print $2}')"
[ -n "$wa" ] && [ -n "$wb" ] && [ -n "$wg" ] && [ -n "$wl" ] || fail "setup: missing windows"

# livewin: live running timer; keep it the ACTIVE window so the focus-engine
# kick inside timer_restore leaves it running (0 clients -> window_active rules).
tmux -L "$SOCKET" set -w -t "$wl" @sidetabs_timer_state run
tmux -L "$SOCKET" set -w -t "$wl" @sidetabs_timer_acc 5
tmux -L "$SOCKET" set -w -t "$wl" @sidetabs_timer_start "$(date +%s)"
tmux -L "$SOCKET" select-window -t "$wl"

nrows_before="$(lognorows)"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer_restore.sh"
sleep 0.6

# --- 1. alpha: sticky manual pause restored with the adjusted total ----------
[ "$(winopt "$wa" @sidetabs_timer_state)" = "pause" ] || fail "alpha state: '$(winopt "$wa" @sidetabs_timer_state)' (want pause)"
[ "$(winopt "$wa" @sidetabs_timer_acc)" = "160" ] || fail "alpha acc: '$(winopt "$wa" @sidetabs_timer_acc)' (want 160)"
pass "manual pause restored as pause with adjusted total (160)"

# --- 2. beta: was running -> comes back as hold -------------------------------
[ "$(winopt "$wb" @sidetabs_timer_state)" = "hold" ] || fail "beta state: '$(winopt "$wb" @sidetabs_timer_state)' (want hold)"
[ "$(winopt "$wb" @sidetabs_timer_acc)" = "50" ] || fail "beta acc: '$(winopt "$wb" @sidetabs_timer_acc)' (want 50)"
[ -z "$(winopt "$wb" @sidetabs_timer_start)" ] || fail "beta has a live interval start after restore"
pass "running-at-death timer restored as hold (50)"

# --- 3. gamma: reset stays reset ---------------------------------------------
[ -z "$(winopt "$wg" @sidetabs_timer_state)" ] || fail "gamma state restored despite reset"
[ -z "$(winopt "$wg" @sidetabs_timer_acc)" ] || fail "gamma acc restored despite reset"
pass "reset timer stays gone"

# --- 4. livewin: live state untouched ----------------------------------------
[ "$(winopt "$wl" @sidetabs_timer_state)" = "run" ] || fail "livewin state clobbered: '$(winopt "$wl" @sidetabs_timer_state)'"
[ "$(winopt "$wl" @sidetabs_timer_acc)" = "5" ] || fail "livewin acc clobbered: '$(winopt "$wl" @sidetabs_timer_acc)'"
pass "live timer state never clobbered"

# --- 5. Exactly two 'restore' rows (alpha, beta), 9 fields each ---------------
nres="$(awk -F'\t' '!/^#/ && $2=="restore"' "$TMPLOG" | wc -l | tr -d ' ')"
[ "$nres" = "2" ] || fail "expected 2 restore rows, got $nres"
awk -F'\t' '!/^#/ && $2=="restore" && $7=="alpha" && $5=="160"' "$TMPLOG" | grep -q . || fail "no restore row for alpha/160"
awk -F'\t' '!/^#/ && $2=="restore" && $7=="beta" && $5=="50"' "$TMPLOG" | grep -q . || fail "no restore row for beta/50"
nf="$(awk -F'\t' '!/^#/{print NF}' "$TMPLOG" | sort -u)"
[ "$nf" = "9" ] || fail "expected 9 TSV fields on every row, got: $nf"
pass "restore rows logged (2, schema intact)"

# --- 6. Second run is a no-op ------------------------------------------------
nrows_mid="$(lognorows)"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer_restore.sh"
sleep 0.6
[ "$(lognorows)" = "$nrows_mid" ] || fail "second run appended rows ($nrows_mid -> $(lognorows))"
[ "$(winopt "$wa" @sidetabs_timer_state)" = "pause" ] || fail "alpha state changed on second run"
[ "$(winopt "$wa" @sidetabs_timer_acc)" = "160" ] || fail "alpha acc changed on second run"
pass "second run is a no-op"

echo "ALL TIMER RESTORE TESTS PASSED"
