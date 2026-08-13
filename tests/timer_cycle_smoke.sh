#!/usr/bin/env bash
# C5 smoke test: lazy per-tag billing-cycle reset. A tagged window's timer
# zeroes itself the first time it is interacted with on or after its tag's
# cycle boundary (tags-file reset_day), and never otherwise. Covers: rollout
# seeding (first sighting never zeroes a live total), a real boundary crossing
# (logged `reset` immediately followed by `resume` — D7 — keeps the window
# running through the reset), untagged windows and reset_day 0 tags never
# firing, day-31 clamping onto Feb 28 in a non-leap year, the focus-tick
# delivery path (timer_focus.sh, no toggle/cycle-check call from the test),
# and same-day idempotence.
#
# Dates are faked via SIDETABS_TIMER_TODAY, inline in every run-shell command
# string — run-shell executes in the tmux server's own environment and does
# not inherit this test shell's exports (see helpers.sh's cycle_start doc and
# search.sh:7-8 for the precedent).
set -euo pipefail

SOCKET="sidetab_cycle_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPLOG="${TMPDIR:-/tmp}/sidetabs_cycle_$$.tsv"
TMPTAGS="${TMPDIR:-/tmp}/sidetabs_cycle_tags_$$.tsv"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "$TMPLOG" "$TMPTAGS"; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
winopt() { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }
# Reset-row / event-sequence helpers, filtered by window NAME (col7) — same
# idiom as timer_restore_smoke.sh's resets_for, since one hermetic log is
# shared across every window in the suite and other windows' engine rows can
# interleave with the one under test.
resets_for() { awk -F'\t' -v w="$1" '!/^#/ && $2=="reset" && $7==w' "$TMPLOG" | wc -l | tr -d ' '; }
events_for() { awk -F'\t' -v w="$1" '!/^#/ && $7==w {print $2}' "$TMPLOG"; }
newwin() {
    tmux -L "$SOCKET" new-window -t main -n "$1"
    tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk -v n="$1" '$1==n{print $2}'
}
run() { tmux -L "$SOCKET" run-shell "$1"; sleep 0.4; }

# --- 1. Boot: hermetic log + tags file, one tag per reset-day scenario ------
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n base -x 200 -y 50
tmux -L "$SOCKET" set-option -g @sidetabs-summary off
tmux -L "$SOCKET" set-option -g @sidetabs-timer-log "$TMPLOG"
tmux -L "$SOCKET" set-option -g @sidetabs-timer-tags-file "$TMPTAGS"
printf '# tag\tlabel\treset_day\ncust-A\tClient A\t15\ncust-B\tClient B\t1\ncust-C\tClient C\t0\ncust-D\tClient D\t31\n' > "$TMPTAGS"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.4

# =============================================================================
# 2. Rollout seeding: first tagged interaction sets last_reset to the current
#    cycle start WITHOUT zeroing an existing total (C5 rollout seeding, spec
#    acceptance criterion 4).
# =============================================================================
wseed="$(newwin seedwin)"
run "$PLUGIN_DIR/scripts/timer.sh adjust $wseed +100"      # untagged: cycle_check no-ops
[ "$(winopt "$wseed" @sidetabs_timer_acc)" = "100" ] || fail "seedwin: adjust did not set acc=100"
run "$PLUGIN_DIR/scripts/tag_set.sh $wseed cust-A"
[ -z "$(winopt "$wseed" @sidetabs_timer_last_reset)" ] || fail "seedwin: last_reset set before any tagged interaction"
run "SIDETABS_TIMER_TODAY=2026-07-20 '$PLUGIN_DIR/scripts/timer.sh' cycle-check $wseed"
[ "$(winopt "$wseed" @sidetabs_timer_last_reset)" = "2026-07-15" ] \
    || fail "seedwin: last_reset not seeded to the 07-20 cycle start (07-15): '$(winopt "$wseed" @sidetabs_timer_last_reset)'"
[ "$(winopt "$wseed" @sidetabs_timer_acc)" = "100" ] || fail "seedwin: rollout seeding zeroed the total"
[ "$(resets_for seedwin)" = "0" ] || fail "seedwin: rollout seeding logged a reset row"
pass "rollout seeding: last_reset seeded, existing total untouched, no reset logged"

# =============================================================================
# 3. Boundary crossing on a RUNNING window: logged reset immediately followed
#    by resume (D7), acc back to 0, timer still running afterward.
# =============================================================================
run "$PLUGIN_DIR/scripts/timer.sh toggle $wseed"   # pause -> run (real clock; tag's cs isn't stale yet vs 07-15)
[ "$(winopt "$wseed" @sidetabs_timer_state)" = "run" ] || fail "seedwin: expected running before the boundary test"
run "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' cycle-check $wseed"   # cust-A cycle start now 08-15: stale
[ "$(winopt "$wseed" @sidetabs_timer_last_reset)" = "2026-08-15" ] \
    || fail "seedwin: last_reset not advanced across the boundary: '$(winopt "$wseed" @sidetabs_timer_last_reset)'"
[ "$(winopt "$wseed" @sidetabs_timer_acc)" = "0" ] || fail "seedwin: acc not zeroed on boundary reset: '$(winopt "$wseed" @sidetabs_timer_acc)'"
[ "$(winopt "$wseed" @sidetabs_timer_state)" = "run" ] || fail "seedwin: timer stopped running across a boundary reset"
[ -n "$(winopt "$wseed" @sidetabs_timer_start)" ] || fail "seedwin: no live interval start after the reset+resume"
tail2="$(events_for seedwin | tail -2 | tr '\n' ',' )"
[ "$tail2" = "reset,resume," ] || fail "seedwin: expected the last two logged events to be reset,resume (D7), got: $tail2"
[ "$(resets_for seedwin)" = "1" ] || fail "seedwin: expected exactly 1 reset row, got $(resets_for seedwin)"
pass "boundary crossing while running: reset+resume pair logged, acc 0, still running"

# Pause seedwin before moving on. Leaving it running would keep it "focused"
# and every later new-window in this script fires session-window-changed ->
# timer_focus.sh; with SOME window run/hold the engine's early break doesn't
# fire, so it evaluates every OTHER tagged window's cycle_due using the REAL
# clock — racing ahead of the deliberately-dated cycle-check calls below and
# corrupting an unrelated window's first-sighting seed with the wrong date
# (verified empirically: this raced tagwin/clampwin's own seeding call and
# silently won). Sections 4-6 below want zero background engine activity.
run "$PLUGIN_DIR/scripts/timer.sh toggle $wseed"
[ "$(winopt "$wseed" @sidetabs_timer_state)" = "pause" ] || fail "seedwin: failed to pause before the untagged/zero-day/clamp sections"

# =============================================================================
# 4. Untagged windows never reset, no matter how many interactions or how far
#    the fake dates span a boundary.
# =============================================================================
wun="$(newwin untaggedwin)"
run "SIDETABS_TIMER_TODAY=2026-07-10 '$PLUGIN_DIR/scripts/timer.sh' toggle $wun"
run "SIDETABS_TIMER_TODAY=2026-07-20 '$PLUGIN_DIR/scripts/timer.sh' toggle $wun"
run "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' cycle-check $wun"
[ "$(resets_for untaggedwin)" = "0" ] || fail "untaggedwin: reset fired despite no tag"
[ -z "$(winopt "$wun" @sidetabs_timer_last_reset)" ] || fail "untaggedwin: last_reset was set despite no tag"
pass "untagged windows never reset"

# =============================================================================
# 5. A tag whose reset_day is 0 (never auto-reset) never resets or even seeds
#    last_reset — cycle_start(0) returns empty, so cycle_check returns before
#    the rollout-seeding branch is reached at all.
# =============================================================================
wzero="$(newwin zerowin)"
run "$PLUGIN_DIR/scripts/tag_set.sh $wzero cust-C"
run "SIDETABS_TIMER_TODAY=2026-07-10 '$PLUGIN_DIR/scripts/timer.sh' toggle $wzero"
run "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' toggle $wzero"
[ "$(resets_for zerowin)" = "0" ] || fail "zerowin: reset_day 0 fired a reset"
[ -z "$(winopt "$wzero" @sidetabs_timer_last_reset)" ] || fail "zerowin: reset_day 0 still seeded last_reset"
pass "reset_day 0 never resets and never seeds last_reset"

# =============================================================================
# 6. Day-31 clamps onto Feb 28 in a non-leap year (2026). Seed far in the past
#    first (rollout seeding, immune to how stale the seeded date itself is),
#    then cross into March: the most recent boundary <= 2026-03-01 is the
#    CLAMPED Feb value (2026-02-28), not 2026-02-31 or a March rollover.
# =============================================================================
wclamp="$(newwin clampwin)"
run "$PLUGIN_DIR/scripts/tag_set.sh $wclamp cust-D"
run "SIDETABS_TIMER_TODAY=2026-01-15 '$PLUGIN_DIR/scripts/timer.sh' cycle-check $wclamp"   # seeds 2025-12-31 (Dec clamps to itself)
[ "$(winopt "$wclamp" @sidetabs_timer_last_reset)" = "2025-12-31" ] \
    || fail "clampwin: seeding at 01-15 gave '$(winopt "$wclamp" @sidetabs_timer_last_reset)', want 2025-12-31"
run "SIDETABS_TIMER_TODAY=2026-03-01 '$PLUGIN_DIR/scripts/timer.sh' cycle-check $wclamp"
[ "$(winopt "$wclamp" @sidetabs_timer_last_reset)" = "2026-02-28" ] \
    || fail "clampwin: Feb clamp gave '$(winopt "$wclamp" @sidetabs_timer_last_reset)', want 2026-02-28"
# clampwin was never toggled/adjusted (only cycle-check, which never sets
# state), so it hits cycle_check's "idle tagged window" short-circuit: the
# marker moves but no `reset` row is logged (nothing accrued to clear, and an
# untouched tagged window would otherwise log an empty reset every cycle).
[ "$(resets_for clampwin)" = "0" ] || fail "clampwin: idle window logged a reset row, got $(resets_for clampwin)"
pass "day-31 reset_day clamps onto 2026-02-28 in a non-leap year"

# =============================================================================
# 7. Focus-tick delivery: a boundary reset fires through timer_focus.sh (the
#    session-window-changed hook), never via an explicit toggle/cycle-check
#    call from the test. last_reset is seeded stale via the cycle-check seam
#    (untouched state); the window is then put into a live running state by
#    writing its options directly (same pattern as timer_restore_smoke.sh's
#    "livewin" fixture) so the FIRST timer.sh invocation this window ever
#    sees is the engine's own auto-hold call on the select-window away.
# =============================================================================
wfocus="$(newwin focuswin)"
run "$PLUGIN_DIR/scripts/tag_set.sh $wfocus cust-B"    # reset_day 1
run "SIDETABS_TIMER_TODAY=2020-06-15 '$PLUGIN_DIR/scripts/timer.sh' cycle-check $wfocus"   # seeds 2020-06-01, no reset (first sighting)
[ "$(winopt "$wfocus" @sidetabs_timer_last_reset)" = "2020-06-01" ] \
    || fail "focuswin: seeding failed: '$(winopt "$wfocus" @sidetabs_timer_last_reset)'"
tmux -L "$SOCKET" set-option -w -t "$wfocus" @sidetabs_timer_state run
tmux -L "$SOCKET" set-option -w -t "$wfocus" @sidetabs_timer_acc 30
tmux -L "$SOCKET" set-option -w -t "$wfocus" @sidetabs_timer_start "$(date +%s)"
tmux -L "$SOCKET" select-window -t "$wfocus"
sleep 0.4
away="$(newwin awaywin)"
tmux -L "$SOCKET" select-window -t "$away"    # focus lost -> timer_focus.sh dispatches auto-hold, which runs cycle_check first
sleep 0.6
today_cycle="$(date +%Y-%m)-01"
[ "$(winopt "$wfocus" @sidetabs_timer_last_reset)" = "$today_cycle" ] \
    || fail "focuswin: focus-tick did not advance last_reset to $today_cycle: '$(winopt "$wfocus" @sidetabs_timer_last_reset)'"
[ "$(resets_for focuswin)" = "1" ] || fail "focuswin: expected exactly 1 reset row from the focus tick, got $(resets_for focuswin)"
pass "cycle reset fires via the focus-tick path (select-window), no toggle/cycle-check call"

# =============================================================================
# 8. Same-day idempotence: a second interaction on the same fake day logs no
#    additional reset row (toggle itself may still log pause/resume — that's
#    real timer activity, not a second cycle reset).
# =============================================================================
before="$(resets_for seedwin)"
run "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' toggle $wseed"
run "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' toggle $wseed"
[ "$(resets_for seedwin)" = "$before" ] \
    || fail "seedwin: a same-day re-interaction logged another reset ($before -> $(resets_for seedwin))"
pass "same-day idempotence: no additional reset row"

echo "ALL TIMER CYCLE SMOKE TESTS PASSED"
