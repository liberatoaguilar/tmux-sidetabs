#!/usr/bin/env bash
# Timer state survives a server death: timer_restore.sh replays the durable TSV
# event log and re-seeds @sidetabs_timer_* window options, matching windows by
# (session name, window name) — window IDs do not survive a restart. Verifies:
# sticky manual pause comes back as pause, a running/held timer comes back as
# hold (the focus engine resumes it on focus), reset timers stay gone, live
# state is never clobbered, and a second run is a no-op.
#
# Also covers the C6 re-seed set beyond state+total: the attribution tag from
# v3 col 10 (v2 rows come back untagged, legacy 6-col rows are ignored), the
# DERIVED @sidetabs_timer_last_reset (date of the key's last `reset` row, else
# of its first row) and the fact that it makes the next cycle check fire iff a
# billing boundary really was crossed while the server was down — plus the
# once-per-generation semantics of the `boot` fallback delivery path.
set -euo pipefail

SOCKET="sidetab_trez_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPLOG="${TMPDIR:-/tmp}/sidetabs_trez_$$.tsv"
TMPTAGS="${TMPDIR:-/tmp}/sidetabs_trez_tags_$$.tsv"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "$TMPLOG" "$TMPTAGS"; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
winopt() { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$@" >> "$TMPLOG"; }  # v3: col10 tag defaults to "-"
rowt() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$TMPLOG"; }  # v3 with an explicit tag
row9() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$TMPLOG"; }      # v2: no tag column
lognorows() { grep -vc '^#' "$TMPLOG" || true; }
resets_for() { awk -F'\t' -v w="$1" '!/^#/ && $2=="reset" && $7==w' "$TMPLOG" | wc -l | tr -d ' '; }

# --- Synthetic history. Clock times are irrelevant to the state replay (col5
# --- is authoritative at every event), but the DATE part drives the derived
# --- last_reset, so these are real stamps in the shape epoch_to_iso emits. ----
printf '#ts\tevent\tinterval_start\tinterval_s\ttotal_s\tsession\twindow\twindow_id\tcwd\ttag\n' > "$TMPLOG"
# alpha: ran, manual pause at 100s, adjusted to 160s -> pause/160 (sticky)
row 2026-07-02T09:00:00-0600 start       -  0   0   main alpha @90 /tmp
row 2026-07-02T09:01:40-0600 pause       t1 100 100 main alpha @90 /tmp
row 2026-07-02T09:02:00-0600 adjust      -  60  160 main alpha @90 /tmp
# beta: auto-held then resumed; running at death -> hold/50
row 2026-07-02T09:00:00-0600 start       -  0   0   main beta  @91 /tmp
row 2026-07-02T09:00:50-0600 auto-pause  t1 50  50  main beta  @91 /tmp
row 2026-07-02T09:01:00-0600 auto-resume -  0   50  main beta  @91 /tmp
# gamma: reset was the last word -> nothing comes back
row 2026-07-02T09:00:00-0600 start       -  0   0   main gamma @92 /tmp
row 2026-07-02T09:03:20-0600 pause       t1 200 200 main gamma @92 /tmp
row 2026-07-02T09:03:21-0600 reset       -  200 0   main gamma @92 /tmp
# delta: window won't exist on the live server -> ignored
row 2026-07-02T09:00:40-0600 pause       t0 40  40  main delta @93 /tmp
# livewin: log says 999 but the live window already has state -> not clobbered
row 2026-07-02T09:16:39-0600 pause       t0 999 999 main livewin @94 /tmp
# tagged (cust-A): reset on 07-15, then more time -> last_reset = 2026-07-15
rowt 2026-07-02T09:00:00-0600 start -  0   0   main tagged @95 /tmp cust-A
rowt 2026-07-02T09:02:00-0600 pause t1 120 120 main tagged @95 /tmp cust-A
rowt 2026-07-15T08:00:00-0600 reset -  120 0   main tagged @95 /tmp cust-A
rowt 2026-07-16T08:00:00-0600 start -  0   0   main tagged @95 /tmp cust-A
rowt 2026-07-16T08:05:00-0600 pause t1 300 300 main tagged @95 /tmp cust-A
# tagfirst (cust-B): never reset -> last_reset falls back to its first row date
rowt 2026-08-18T10:00:00-0600 start      -  0   0   main tagfirst @96 /tmp cust-B
rowt 2026-08-18T10:02:00-0600 auto-pause t1 120 120 main tagfirst @96 /tmp cust-B
# oldschool: v2 rows (9 cols, no tag) -> restores state+total, stays untagged
row9 2026-07-02T09:00:00-0600 start -  0  0  main oldschool @97 /tmp
row9 2026-07-02T09:01:10-0600 pause t1 70 70 main oldschool @97 /tmp
# legacy: a pre-v2 6-col row (no event column at all) -> ignored entirely
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    2026-07-02T09:00:00-0600 2026-07-02T08:00:00-0600 3600 /tmp main legacy >> "$TMPLOG"
# bootwin: its live window is created later, for the `boot` fallback section
row 2026-07-02T09:00:00-0600 start -  0  0  main bootwin @98 /tmp
row 2026-07-02T09:00:45-0600 pause t1 45 45 main bootwin @98 /tmp

# --- Server with matching windows; no plugin load needed (pure state work) ----
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n alpha -x 200 -y 50
tmux -L "$SOCKET" set -g @sidetabs-timer-log "$TMPLOG"
for w in beta gamma tagged tagfirst oldschool legacy livewin; do
    tmux -L "$SOCKET" new-window -t main -n "$w"
done
winid() { tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk -v n="$1" '$1==n{print $2}'; }
wa="$(winid alpha)"; wb="$(winid beta)"; wg="$(winid gamma)"; wl="$(winid livewin)"
wt="$(winid tagged)"; wf="$(winid tagfirst)"; wo="$(winid oldschool)"; wy="$(winid legacy)"
[ -n "$wa" ] && [ -n "$wb" ] && [ -n "$wg" ] && [ -n "$wl" ] || fail "setup: missing windows"
[ -n "$wt" ] && [ -n "$wf" ] && [ -n "$wo" ] && [ -n "$wy" ] || fail "setup: missing tag windows"

# livewin: live running timer; keep it the ACTIVE window so the focus-engine
# kick inside timer_restore leaves it running (0 clients -> window_active rules).
tmux -L "$SOCKET" set -w -t "$wl" @sidetabs_timer_state run
tmux -L "$SOCKET" set -w -t "$wl" @sidetabs_timer_acc 5
tmux -L "$SOCKET" set -w -t "$wl" @sidetabs_timer_start "$(date +%s)"
tmux -L "$SOCKET" select-window -t "$wl"

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

# --- 5. One restore row per seeded window, 10 fields each --------------------
# alpha, beta, tagged, tagfirst, oldschool — not gamma/delta/livewin/legacy.
nres="$(awk -F'\t' '!/^#/ && $2=="restore"' "$TMPLOG" | wc -l | tr -d ' ')"
[ "$nres" = "5" ] || fail "expected 5 restore rows, got $nres"
awk -F'\t' '!/^#/ && $2=="restore" && $7=="alpha" && $5=="160"' "$TMPLOG" | grep -q . || fail "no restore row for alpha/160"
awk -F'\t' '!/^#/ && $2=="restore" && $7=="beta" && $5=="50"' "$TMPLOG" | grep -q . || fail "no restore row for beta/50"
nf="$(awk -F'\t' '!/^#/ && $2=="restore" {print NF}' "$TMPLOG" | sort -u)"
[ "$nf" = "10" ] || fail "expected 10 TSV fields on every restore row, got: $nf"
pass "restore rows logged (5, schema intact)"

# --- 6. Tag + derived last_reset re-seeded (C6) ------------------------------
[ "$(winopt "$wt" @sidetabs_timer_acc)" = "300" ] || fail "tagged acc: '$(winopt "$wt" @sidetabs_timer_acc)' (want 300)"
[ "$(winopt "$wt" @sidetabs_timer_tag)" = "cust-A" ] || fail "tagged tag: '$(winopt "$wt" @sidetabs_timer_tag)' (want cust-A)"
[ "$(winopt "$wt" @sidetabs_timer_last_reset)" = "2026-07-15" ] \
    || fail "tagged last_reset: '$(winopt "$wt" @sidetabs_timer_last_reset)' (want 2026-07-15, its last reset row)"
[ "$(winopt "$wf" @sidetabs_timer_tag)" = "cust-B" ] || fail "tagfirst tag: '$(winopt "$wf" @sidetabs_timer_tag)'"
[ "$(winopt "$wf" @sidetabs_timer_last_reset)" = "2026-08-18" ] \
    || fail "tagfirst last_reset: '$(winopt "$wf" @sidetabs_timer_last_reset)' (want 2026-08-18, its first row)"
# The restore row carries the tag: the option is written before the row is logged.
awk -F'\t' '!/^#/ && $2=="restore" && $7=="tagged" && $10=="cust-A"' "$TMPLOG" | grep -q . \
    || fail "restore row for tagged does not carry the tag in col 10"
pass "tag and derived last_reset re-seeded; restore row carries the tag"

# --- 7. v2 rows restore untagged; legacy 6-col rows are ignored --------------
[ "$(winopt "$wo" @sidetabs_timer_acc)" = "70" ] || fail "oldschool acc: '$(winopt "$wo" @sidetabs_timer_acc)' (want 70)"
[ -z "$(winopt "$wo" @sidetabs_timer_tag)" ] || fail "oldschool tagged from a v2 row: '$(winopt "$wo" @sidetabs_timer_tag)'"
[ -z "$(winopt "$wo" @sidetabs_timer_last_reset)" ] \
    || fail "oldschool got a last_reset with no tag: '$(winopt "$wo" @sidetabs_timer_last_reset)'"
[ -z "$(winopt "$wy" @sidetabs_timer_state)" ] || fail "legacy 6-col row drove a restore"
pass "v2 rows restore untagged (and without last_reset); 6-col rows ignored"

# --- 8. Second run is a no-op ------------------------------------------------
nrows_mid="$(lognorows)"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer_restore.sh"
sleep 0.6
[ "$(lognorows)" = "$nrows_mid" ] || fail "second run appended rows ($nrows_mid -> $(lognorows))"
[ "$(winopt "$wa" @sidetabs_timer_state)" = "pause" ] || fail "alpha state changed on second run"
[ "$(winopt "$wa" @sidetabs_timer_acc)" = "160" ] || fail "alpha acc changed on second run"
pass "second run is a no-op"

# --- 9. The re-seeded last_reset makes the next cycle check honest -----------
# Both windows are tagged to a 15th-of-the-month cycle. On a simulated 08-20
# the current cycle started 08-15: `tagged` (last reset 07-15) is a cycle
# behind and must reset on its next interaction; `tagfirst` (08-18) is inside
# the current cycle and must not. Seeding last_reset to "now", or leaving it
# unset, would both swallow the reset that is genuinely due here.
printf '# tag\tlabel\treset_day\ncust-A\tClient A\t15\ncust-B\tClient B\t15\n' > "$TMPTAGS"
tmux -L "$SOCKET" set -g @sidetabs-timer-tags-file "$TMPTAGS"
rt_before="$(resets_for tagged)"; rf_before="$(resets_for tagfirst)"
tmux -L "$SOCKET" run-shell "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' toggle $wt"
tmux -L "$SOCKET" run-shell "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' toggle $wf"
sleep 0.6
[ "$(resets_for tagged)" = "$((rt_before + 1))" ] \
    || fail "tagged did not reset across the 08-15 boundary ($rt_before -> $(resets_for tagged))"
[ "$(resets_for tagfirst)" = "$rf_before" ] \
    || fail "tagfirst reset inside its own cycle ($rf_before -> $(resets_for tagfirst))"
[ "$(winopt "$wt" @sidetabs_timer_last_reset)" = "2026-08-15" ] \
    || fail "tagged last_reset not advanced: '$(winopt "$wt" @sidetabs_timer_last_reset)'"
pass "derived last_reset drives exactly the cycle reset that was due"

# --- 10. `boot` fallback: young server, once per generation ------------------
# The runs above claimed the generation, so the fallback stands down.
[ "$(tmux -L "$SOCKET" show-option -gqv @sidetabs_timer_restored)" = "1" ] \
    || fail "restore did not claim @sidetabs_timer_restored"
tmux -L "$SOCKET" new-window -t main -n bootwin
wbt="$(winid bootwin)"
[ -n "$wbt" ] || fail "setup: missing bootwin"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer_restore.sh boot"
sleep 0.5
[ -z "$(winopt "$wbt" @sidetabs_timer_state)" ] \
    || fail "boot mode seeded despite a claimed generation flag"
pass "boot mode stands down once the generation is claimed"

# Released flag but outside the boot window (age budget forced to 0): stands
# down without claiming. This is the overcount guard — a window created long
# after boot must never inherit an old same-named window's total.
tmux -L "$SOCKET" set -g @sidetabs_timer_restored 0
tmux -L "$SOCKET" run-shell "SIDETABS_TIMER_BOOT_MAX_AGE_S=0 '$PLUGIN_DIR/scripts/timer_restore.sh' boot"
sleep 0.5
[ -z "$(winopt "$wbt" @sidetabs_timer_state)" ] || fail "boot mode seeded on an old server"
[ "$(tmux -L "$SOCKET" show-option -gqv @sidetabs_timer_restored)" = "0" ] \
    || fail "boot mode claimed the generation despite standing down on age"
pass "boot mode stands down (without claiming) outside the boot window"

# Inside the boot window: seeds and re-claims. This is the path that covers
# tmux-continuum skipping auto-restore altogether.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer_restore.sh boot"
sleep 0.5
[ "$(winopt "$wbt" @sidetabs_timer_acc)" = "45" ] || fail "boot mode did not seed bootwin"
[ "$(tmux -L "$SOCKET" show-option -gqv @sidetabs_timer_restored)" = "1" ] \
    || fail "boot mode did not claim the generation flag"
pass "boot mode seeds a young server and claims the generation"

# The resurrect path never stands down for the fallback: losing that race (a
# client attaching before continuum restores) would leave every timer unseeded.
tmux -L "$SOCKET" set -w -t "$wbt" -u @sidetabs_timer_state
tmux -L "$SOCKET" set -w -t "$wbt" -u @sidetabs_timer_acc
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer_restore.sh"
sleep 0.5
[ "$(winopt "$wbt" @sidetabs_timer_acc)" = "45" ] \
    || fail "default (resurrect) mode stood down for a claimed generation"
pass "resurrect path still restores after the fallback claimed the generation"

echo "ALL TIMER RESTORE TESTS PASSED"
