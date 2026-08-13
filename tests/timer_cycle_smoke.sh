#!/usr/bin/env bash
# C5 smoke test: lazy per-tag billing-cycle reset. A tagged window's timer
# zeroes itself the first time it is interacted with on or after its tag's
# cycle boundary (tags-file reset_day), and never otherwise. Covers: rollout
# seeding (first sighting never zeroes a live total), a real boundary crossing
# (logged `reset` immediately followed by `resume` — D7 — keeps the window
# running through the reset), untagged windows and reset_day 0 tags never
# firing, day-31 clamping onto Feb 28 in a non-leap year, BOTH focus-engine
# delivery paths (section 7: the auto-hold arm, which runs the check in-process;
# section 11: the ambient `cycle_due` arm, which fires on a window purely
# because focus changed on a DIFFERENT one), same-day idempotence, and a
# `cancel` that lands ON a boundary still discarding its interval instead of
# banking it as billable seconds.
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
STMPOUT="${TMPDIR:-/tmp}/sidetabs_cycle_stmp_$$"      # server-side TMPDIR probe (section 12)
LOCKDIR=""                                            # pre-held window lock (section 12)

# `if`, not `&&`: a failing AND-list inside an EXIT trap aborts the handler
# under `set -e` (verified), which would strand the temp files on any failure
# path that leaves the section-12 lock dir already released.
cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    if [ -n "$LOCKDIR" ]; then
        rmdir "$LOCKDIR" 2>/dev/null || true
    fi
    rm -f "$TMPLOG" "$TMPTAGS" "$STMPOUT"
    return 0
}
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

# =============================================================================
# 9. Boundary crossing on a HELD window (auto-paused because unfocused). This
#    is the dominant case — every tagged window except the focused one is in
#    `hold` at any instant, and boundaries are normally crossed overnight — and
#    a held timer is LIVE, not stopped: the focus engine puts it straight back
#    to run. So the reset must keep the slot alive exactly like the running
#    case (D7), differing only in that there is no open interval to close.
#    Treating hold as stopped unset all three options and blanked cycle_check's
#    `state` global, so the auto-resume that triggered the check aborted on its
#    own `[ "$state" = "hold" ]` guard and the window silently stopped tracking
#    for the whole new cycle — zero rows, hence nothing for C9/D5's untagged
#    abort to catch, hence a plausible-looking zero in the nightly push.
#    Fixture per section 7: seed last_reset through the cycle-check seam, then
#    write the live state directly, so the dated cycle-check below is the first
#    real interaction this window ever sees.
# =============================================================================
wheld="$(newwin heldwin)"
tmux -L "$SOCKET" select-window -t "$away"    # a held window is UNFOCUSED by definition
sleep 0.4
run "$PLUGIN_DIR/scripts/tag_set.sh $wheld cust-A"    # reset_day 15
run "SIDETABS_TIMER_TODAY=2026-07-20 '$PLUGIN_DIR/scripts/timer.sh' cycle-check $wheld"   # seeds 2026-07-15
[ "$(winopt "$wheld" @sidetabs_timer_last_reset)" = "2026-07-15" ] \
    || fail "heldwin: seeding failed: '$(winopt "$wheld" @sidetabs_timer_last_reset)'"
tmux -L "$SOCKET" set-option -w -t "$wheld" @sidetabs_timer_state hold
tmux -L "$SOCKET" set-option -w -t "$wheld" @sidetabs_timer_acc 1800

run "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' cycle-check $wheld"
[ "$(winopt "$wheld" @sidetabs_timer_state)" = "hold" ] \
    || fail "heldwin: boundary reset dropped the held timer: state '$(winopt "$wheld" @sidetabs_timer_state)'"
[ "$(winopt "$wheld" @sidetabs_timer_acc)" = "0" ] \
    || fail "heldwin: acc not zeroed: '$(winopt "$wheld" @sidetabs_timer_acc)'"
[ -z "$(winopt "$wheld" @sidetabs_timer_start)" ] \
    || fail "heldwin: a held timer must have no live interval start"
[ "$(winopt "$wheld" @sidetabs_timer_last_reset)" = "2026-08-15" ] \
    || fail "heldwin: last_reset not advanced: '$(winopt "$wheld" @sidetabs_timer_last_reset)'"
[ "$(resets_for heldwin)" = "1" ] || fail "heldwin: expected exactly 1 reset row, got $(resets_for heldwin)"
htail="$(events_for heldwin | tail -2 | tr '\n' ',')"
[ "$htail" = "reset,auto-pause," ] \
    || fail "heldwin: expected the last two events to be reset,auto-pause (D7), got: $htail"
pass "boundary crossing while held: reset + re-establishing row, acc 0, still held"

# The whole point of staying in `hold`: the next focus tick resumes it into the
# new cycle instead of finding a window with no timer at all.
run "$PLUGIN_DIR/scripts/timer.sh auto-resume $wheld"
[ "$(winopt "$wheld" @sidetabs_timer_state)" = "run" ] \
    || fail "heldwin: auto-resume after the boundary reset did not resume: '$(winopt "$wheld" @sidetabs_timer_state)'"
[ -n "$(winopt "$wheld" @sidetabs_timer_start)" ] || fail "heldwin: resumed without a live interval start"
[ "$(events_for heldwin | tail -1)" = "auto-resume" ] \
    || fail "heldwin: no auto-resume row after the boundary reset: $(events_for heldwin | tail -1)"
[ "$(resets_for heldwin)" = "1" ] || fail "heldwin: auto-resume logged another reset"
pass "a held window that crossed a boundary still auto-resumes into the new cycle"
run "$PLUGIN_DIR/scripts/timer.sh toggle $wheld"   # leave nothing running behind us

# =============================================================================
# 10. `cancel` ACROSS a boundary must still discard the interval. cancel exists
#     to throw away time that was never worked ("the timer I left running
#     overnight"), which is precisely when a boundary gets crossed. cycle_check
#     runs before the cancel arm, so a fold logged as `auto-pause` there would
#     BILL those seconds — the CLI replay bills pause/auto-pause and ignores
#     cancel — while the cancel arm then discarded a zero-length interval and
#     the sidebar showed 0, making the cancel look like it worked. Silent
#     overcount, the mirror of the undercount C9 refuses.
#
#     The invariant asserted is the billing one, not a row shape: the sum of
#     interval seconds over this window's BILLABLE closing rows (pause /
#     auto-pause) must be 0, while the boundary itself still fired.
#     No new-window/select-window inside this section: either would fire the
#     focus engine, whose real-clock auto-hold would close the interval and
#     leave the dated cancel below testing nothing.
# =============================================================================
billable_secs_for() {
    awk -F'\t' -v w="$1" '!/^#/ && $7==w && ($2=="pause" || $2=="auto-pause") {s+=$4} END {print s+0}' "$TMPLOG"
}
wcan="$(newwin cancelwin)"
run "$PLUGIN_DIR/scripts/tag_set.sh $wcan cust-A"    # reset_day 15
run "SIDETABS_TIMER_TODAY=2026-07-20 '$PLUGIN_DIR/scripts/timer.sh' cycle-check $wcan"   # seeds 2026-07-15
[ "$(winopt "$wcan" @sidetabs_timer_last_reset)" = "2026-07-15" ] \
    || fail "cancelwin: seeding failed: '$(winopt "$wcan" @sidetabs_timer_last_reset)'"
run "$PLUGIN_DIR/scripts/timer.sh toggle $wcan"     # real clock: 07-15 is not stale yet
[ "$(winopt "$wcan" @sidetabs_timer_state)" = "run" ] || fail "cancelwin: expected running before the cancel"
sleep 2                                             # accrue a non-zero interval to be discarded

# The real flow reaches cancel through the timer menu, so opening the menu must
# not commit the boundary fold before the user has chosen anything — `menu` is
# not in the cycle_check dispatch list for exactly this reason. Asserted via the
# MENU_PRINT seam, which still goes through dispatch (an overlay menu never
# lands in capture-pane output).
mstart="$(winopt "$wcan" @sidetabs_timer_start)"
run "SIDETABS_TIMER_TODAY=2026-08-20 SIDETABS_TIMER_MENU_PRINT=1 '$PLUGIN_DIR/scripts/timer.sh' menu $wcan > /dev/null"
[ "$(resets_for cancelwin)" = "0" ] \
    || fail "cancelwin: merely opening the menu committed a boundary reset"
[ "$(billable_secs_for cancelwin)" = "0" ] \
    || fail "cancelwin: opening the menu banked the open interval as billable seconds"
[ "$(winopt "$wcan" @sidetabs_timer_state)" = "run" ] \
    || fail "cancelwin: opening the menu changed state to '$(winopt "$wcan" @sidetabs_timer_state)'"
[ "$(winopt "$wcan" @sidetabs_timer_start)" = "$mstart" ] \
    || fail "cancelwin: opening the menu rewrote the live interval start"

run "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' cancel $wcan"

[ "$(billable_secs_for cancelwin)" = "0" ] \
    || fail "cancelwin: a cancelled interval was billed as pause/auto-pause seconds: $(billable_secs_for cancelwin)"
[ "$(resets_for cancelwin)" = "1" ] \
    || fail "cancelwin: the boundary reset did not fire, got $(resets_for cancelwin) reset rows"
[ "$(winopt "$wcan" @sidetabs_timer_last_reset)" = "2026-08-15" ] \
    || fail "cancelwin: last_reset not advanced: '$(winopt "$wcan" @sidetabs_timer_last_reset)'"
[ "$(winopt "$wcan" @sidetabs_timer_state)" = "pause" ] \
    || fail "cancelwin: cancel left state '$(winopt "$wcan" @sidetabs_timer_state)', want pause"
[ "$(winopt "$wcan" @sidetabs_timer_acc)" = "0" ] \
    || fail "cancelwin: total not zeroed by the boundary reset: '$(winopt "$wcan" @sidetabs_timer_acc)'"
[ -z "$(winopt "$wcan" @sidetabs_timer_start)" ] \
    || fail "cancelwin: a cancelled timer must have no live interval start"
# D7's crash-window guard still holds: the `reset` is followed by a row that
# re-establishes the slot, so a restore replay finds a live (paused) slot with
# the tag and last_reset intact rather than a deleted key.
ctail="$(events_for cancelwin | tail -3 | tr '\n' ',')"
[ "$ctail" = "reset,resume,cancel," ] \
    || fail "cancelwin: expected the last three events to be reset,resume,cancel (D7), got: $ctail"
pass "cancel across a boundary discards the interval instead of billing it"

# Control: the same cancel with NO boundary crossed is unchanged (main
# behavior) — still zero billable seconds, and no second reset row.
run "$PLUGIN_DIR/scripts/timer.sh toggle $wcan"
sleep 2
run "SIDETABS_TIMER_TODAY=2026-08-20 '$PLUGIN_DIR/scripts/timer.sh' cancel $wcan"
[ "$(billable_secs_for cancelwin)" = "0" ] \
    || fail "cancelwin: non-boundary cancel billed seconds: $(billable_secs_for cancelwin)"
[ "$(resets_for cancelwin)" = "1" ] \
    || fail "cancelwin: non-boundary cancel logged another reset, got $(resets_for cancelwin)"
[ "$(winopt "$wcan" @sidetabs_timer_state)" = "pause" ] \
    || fail "cancelwin: non-boundary cancel left state '$(winopt "$wcan" @sidetabs_timer_state)'"
pass "cancel with no boundary crossed is unchanged"

# =============================================================================
# 11. AMBIENT delivery of C5's lazy reset: timer_focus.sh's third arm
#     (`elif cycle_due "$tag" "$lastreset"`), which fires a cycle-check on a
#     window purely as a side effect of focus changing on a DIFFERENT window.
#     Nothing above reaches it. Section 7 looks like it does but hits arm 1
#     instead: the select-window away leaves the window run+unfocused, so the
#     engine dispatches auto-hold, and cycle_check runs in-process inside THAT
#     call regardless of the elif gate. Section 9 calls `timer.sh cycle-check`
#     directly. So a total removal of this arm — and of the cycle_due() bash
#     predicate gating it — used to ship green (verified by mutation: `return 1`
#     at the top of cycle_due passed every suite).
#
#     This arm is the complement to the other two: they already visit every
#     window the user enters or leaves, so this one carries the rest —
#     hold+unfocused, run+focused, sticky pause, untimed tagged. A missed reset
#     here is cosmetic to billing (C8 replay is log-driven and never reads tmux
#     `acc`; a held window has no open interval), but stale sidebar totals are
#     what C5 exists to prevent, and drift shows up as spurious C11 notices.
#
#     REAL CLOCK only: the hook runs in the tmux server's own environment, so
#     SIDETABS_TIMER_TODAY cannot reach a hook-driven timer_focus.sh. Hence
#     this section is last, after every date-faked one, and the oracle for the
#     positive case is the tags-file reset day (15) rather than cycle_start
#     itself. Fixtures are written as options directly (sections 7/9 idiom) so
#     the engine's own tick is the first real interaction each one ever sees.
# =============================================================================
wamb="$(newwin ambientwin)"
wfresh="$(newwin ambientfresh)"
wzeroamb="$(newwin ambientzero)"
wtick="$(newwin tickwin)"          # a plain window to bounce focus off; untagged
run "$PLUGIN_DIR/scripts/tag_set.sh $wamb cust-A"        # reset_day 15
run "$PLUGIN_DIR/scripts/tag_set.sh $wfresh cust-A"
run "$PLUGIN_DIR/scripts/tag_set.sh $wzeroamb cust-C"    # reset_day 0: never due

# Negative control: seeded through the cycle-check seam on the REAL clock, so
# last_reset is the current cycle start without the test having to compute a
# date. Honest about its reach — cycle_check re-validates staleness itself, so
# this catches a regression where the child fires and acts, not merely one
# where cycle_due's comparison inverts.
run "$PLUGIN_DIR/scripts/timer.sh cycle-check $wfresh"
fresh_lr="$(winopt "$wfresh" @sidetabs_timer_last_reset)"
[ -n "$fresh_lr" ] || fail "ambientfresh: control seeding produced no last_reset"
tmux -L "$SOCKET" set-option -w -t "$wfresh" @sidetabs_timer_state hold
tmux -L "$SOCKET" set-option -w -t "$wfresh" @sidetabs_timer_acc 1800
tmux -L "$SOCKET" set-option -w -t "$wzeroamb" @sidetabs_timer_state hold
tmux -L "$SOCKET" set-option -w -t "$wzeroamb" @sidetabs_timer_acc 1800

# Positive case, seeded LAST so no earlier fixture's new-window tick delivers
# the reset before the deliberate trigger below.
tmux -L "$SOCKET" set-option -w -t "$wamb" @sidetabs_timer_last_reset 2020-01-15
tmux -L "$SOCKET" set-option -w -t "$wamb" @sidetabs_timer_state hold
tmux -L "$SOCKET" set-option -w -t "$wamb" @sidetabs_timer_acc 1800
[ "$(resets_for ambientwin)" = "0" ] || fail "ambientwin: reset fired before the trigger"

# Trigger: focus moves between two windows that are NEITHER fixture, so no
# fixture is ever focused, toggled, or the subject of a cycle-check call. The
# two targets must be DISTINCT — select-window onto the already-current window
# returns early inside tmux and fires no hook at all.
tmux -L "$SOCKET" select-window -t "$away"
sleep 0.8
tmux -L "$SOCKET" select-window -t "$wtick"
sleep 0.8

amb_lr="$(winopt "$wamb" @sidetabs_timer_last_reset)"
[ "$amb_lr" != "2020-01-15" ] \
    || fail "ambientwin: the ambient cycle_due arm never delivered a reset (last_reset still 2020-01-15)"
case "$amb_lr" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-15) ;;
    *) fail "ambientwin: last_reset '$amb_lr' is not a cust-A (reset_day 15) cycle start" ;;
esac
[ "$(winopt "$wamb" @sidetabs_timer_acc)" = "0" ] \
    || fail "ambientwin: total not zeroed: '$(winopt "$wamb" @sidetabs_timer_acc)'"
[ "$(winopt "$wamb" @sidetabs_timer_state)" = "hold" ] \
    || fail "ambientwin: a boundary reset must keep a held slot LIVE (D7), got '$(winopt "$wamb" @sidetabs_timer_state)'"
[ "$(resets_for ambientwin)" = "1" ] \
    || fail "ambientwin: expected exactly 1 reset row, got $(resets_for ambientwin)"
atail="$(events_for ambientwin | tail -2 | tr '\n' ',')"
[ "$atail" = "reset,auto-pause," ] \
    || fail "ambientwin: expected reset + the D7 re-establishing row, got: $atail"
pass "ambient focus ticks deliver a due cycle reset to a window nobody touched"

[ "$(winopt "$wfresh" @sidetabs_timer_acc)" = "1800" ] \
    || fail "ambientfresh: a not-due window was reset by the ambient arm"
[ "$(winopt "$wfresh" @sidetabs_timer_last_reset)" = "$fresh_lr" ] \
    || fail "ambientfresh: last_reset moved on a window that owed no reset"
[ "$(resets_for ambientfresh)" = "0" ] \
    || fail "ambientfresh: ambient tick logged a reset for a not-due window"
[ "$(winopt "$wzeroamb" @sidetabs_timer_acc)" = "1800" ] \
    || fail "ambientzero: a reset_day 0 tag was reset by the ambient arm"
[ -z "$(winopt "$wzeroamb" @sidetabs_timer_last_reset)" ] \
    || fail "ambientzero: reset_day 0 seeded last_reset via the ambient arm"
[ "$(resets_for ambientzero)" = "0" ] \
    || fail "ambientzero: ambient tick logged a reset for a reset_day 0 tag"
pass "the same ambient ticks leave not-due and never-reset windows alone"

# =============================================================================
# 12. LOCK REFUSAL. cycle_check is the first engine op that irreversibly zeroes
#     a total, and a user op that ran out of lock budget used to proceed
#     UNLOCKED. It then re-read stale state/acc/start/last_reset — cycle_check
#     writes last_reset LAST — ran its own cycle_check, and both processes
#     folded the SAME open interval, each logging its own auto-pause + reset +
#     resume. D1's dedup hides the duplicated interval, but the second row's
#     stale total lands after the first `reset` zeroed the baseline, so the CLI
#     replay recovers the difference from the total delta: 1300 billed seconds
#     for 300 worked, with errors=[] and window options that look correct.
#
#     Deterministic by construction: the lock dir is held from OUTSIDE (the same
#     mkdir primitive timer.sh uses), so no load or timing luck is needed. The
#     lock path is computed from the SERVER's pid and TMPDIR, not this shell's —
#     run-shell children live in the server's environment.
#
#     Real clock, and after section 11 by the same rule: no date faking here.
#     Order matters — newwin, then tag_set, then the option seeds, then mkdir,
#     with no window/session hook in between, so the ambient engine arm cannot
#     deliver this window's due reset before the deliberate toggle does.
# =============================================================================
wlk="$(newwin lockwin)"
run "$PLUGIN_DIR/scripts/tag_set.sh $wlk cust-A"          # reset_day 15
SPID="$(tmux -L "$SOCKET" display-message -p '#{pid}')"
tmux -L "$SOCKET" run-shell "printf '%s' \"\${TMPDIR:-/tmp}\" > $STMPOUT"
sleep 0.3
LOCKDIR="$(cat "$STMPOUT")/sidetabs_timerwin_${SPID}_${wlk#@}"

# A running timer with 1000s banked, a 300s interval open, and a last_reset old
# enough that a boundary reset is unambiguously due.
tmux -L "$SOCKET" set-option -w -t "$wlk" @sidetabs_timer_acc 1000
tmux -L "$SOCKET" set-option -w -t "$wlk" @sidetabs_timer_start "$(( $(date +%s) - 300 ))"
tmux -L "$SOCKET" set-option -w -t "$wlk" @sidetabs_timer_state run
tmux -L "$SOCKET" set-option -w -t "$wlk" @sidetabs_timer_last_reset 2020-01-15
start_seed="$(winopt "$wlk" @sidetabs_timer_start)"
rows_before="$(events_for lockwin | grep -c . || true)"

mkdir "$LOCKDIR" || fail "lockwin: could not pre-hold the window lock at $LOCKDIR"
run "$PLUGIN_DIR/scripts/timer.sh toggle $wlk"   # exhausts the budget -> must refuse
[ "$(winopt "$wlk" @sidetabs_timer_acc)" = "1000" ] \
    || fail "lockwin: a refused toggle rewrote acc: '$(winopt "$wlk" @sidetabs_timer_acc)'"
[ "$(winopt "$wlk" @sidetabs_timer_state)" = "run" ] \
    || fail "lockwin: a refused toggle changed state: '$(winopt "$wlk" @sidetabs_timer_state)'"
[ "$(winopt "$wlk" @sidetabs_timer_start)" = "$start_seed" ] \
    || fail "lockwin: a refused toggle moved the interval start"
[ "$(winopt "$wlk" @sidetabs_timer_last_reset)" = "2020-01-15" ] \
    || fail "lockwin: a refused toggle ran cycle_check and advanced last_reset"
[ "$(events_for lockwin | grep -c . || true)" = "$rows_before" ] \
    || fail "lockwin: a refused toggle logged rows: $(events_for lockwin | tr '\n' ',')"
pass "a user op that cannot take the window lock refuses instead of mutating on stale reads"

rmdir "$LOCKDIR"
run "$PLUGIN_DIR/scripts/timer.sh toggle $wlk"   # same op, uncontended
[ "$(resets_for lockwin)" = "1" ] \
    || fail "lockwin: expected exactly 1 reset row once serialized, got $(resets_for lockwin)"
ltail="$(events_for lockwin | tail -4 | tr '\n' ',')"
[ "$ltail" = "auto-pause,reset,resume,pause," ] \
    || fail "lockwin: expected the boundary fold once (auto-pause,reset,resume,pause), got: $ltail"
banked="$(awk -F'\t' '!/^#/ && ($2=="pause" || $2=="auto-pause") && $7=="lockwin" {s+=$4} END {print s+0}' "$TMPLOG")"
[ "$banked" -ge 300 ] && [ "$banked" -lt 600 ] \
    || fail "lockwin: the 300s interval was billed $banked seconds (double-folded?)"
pass "the deferred op then folds the boundary exactly once: one interval, one reset"

echo "ALL TIMER CYCLE SMOKE TESTS PASSED"
