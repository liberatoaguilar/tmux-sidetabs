#!/usr/bin/env bash
# Per-window focus-aware stopwatch. State lives in window user options
# (session-only; not saved by tmux-resurrect). A started timer counts ONLY while
# its window is focused: the focus engine (timer_focus.sh) auto-holds it when the
# tab loses focus and auto-resumes it on return. A manual C-t pause is sticky and
# never auto-resumes.
#
# States (@sidetabs_timer_state):
#   run    - counting (live interval open; start epoch in @sidetabs_timer_start)
#   hold   - auto-paused because the window is unfocused; resumes on focus
#   pause  - manually paused (C-t); never auto-resumes, only C-t resumes it
#   unset  - no timer
#
# Event log v3 (@sidetabs-timer-log, TSV, one row per event, `#` header line):
#   ts_iso  event  interval_start_iso|-  interval_s  total_s  session  window_name  window_id  cwd  tag
# tag is the window's @sidetabs_timer_tag at write time, or `-` when untagged.
# Every reader (this script, timer_restore.sh, the CLI replay) must also accept
# v2 (9-col, no tag) and legacy 6-col rows; v2 rows are treated as tag `-`.
# Events: start resume pause auto-pause auto-resume adjust cancel reset restore.
# Logging is best-effort: an unwritable log never aborts a state transition.
#
# Per-tag billing-cycle reset (C5): before any interaction, a tagged window
# whose tag carries a reset day (tags file) and whose @sidetabs_timer_last_reset
# predates the current cycle start is zeroed in-process by cycle_check below.
#
# Popup config (C7): the menu subcommand always offers "assign client…"
# (opens tag_picker.sh, a submenu over the tags file) and, only when the tags
# file exists and the window already carries a tag, "register repo for
# <label>…" (backgrounds register_repo.sh, a passthrough to the aguilabs CLI).
# Both are absent for plugin users who never set @sidetabs-timer-tags-file.
#
# Bound (sidebar-focused): @sidetabs-timer-key toggle, @sidetabs-timer-menu-key menu.
# Usage: timer.sh <toggle|cancel|reset|menu|adjust|adjust-prompt|retag|auto-hold|auto-resume|cycle-check|restore-state> [window_id] [arg] [arg2] [arg3] [arg4]
#   arg  = adjust value (adjust), client_name (menu / adjust-prompt), the new
#          tag or `none` (retag), or accumulated seconds (restore-state).
#   arg2 = state to seed, hold|pause (restore-state only).
#   arg3 = tag to seed, `-` for untagged (restore-state only).
#   arg4 = @sidetabs_timer_last_reset to seed, ISO date (restore-state only).
#
# Test hook: SIDETABS_TIMER_MENU_PRINT=1 makes the `menu` subcommand print its
# constructed ITEMS as "key<TAB>label" lines instead of opening a display-menu,
# and exit before touching tmux's overlay. This is `menu`'s only testable seam
# — an overlay menu never lands in capture-pane output (flag_picker.sh:7-9) —
# same inline-env-var convention as SIDETABS_TIMER_TODAY (helpers.sh) and
# search.sh's SIDETABS_SEARCH_LIST/PICK: run-shell does not inherit the test
# shell's exports, so tests set it inline on the run-shell command string.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/tags.sh"

CMD="${1:-toggle}"
WID="${2:-$(tmux display-message -p '#{window_id}')}"
ARG="${3:-}"
ARG2="${4:-}"
ARG3="${5:-}"
ARG4="${6:-}"
[ -z "$WID" ] && exit 0
TAB="$(printf '\t')"

nudge_redraw() { "$CURRENT_DIR/refresh.sh" force; }
num_or() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

# log_event <event> <interval_start_epoch|-> <interval_s> <total_s>
log_event() {
    local event="$1" istart="$2" is="$3" total="$4" logfile ts istart_iso cwd names sname wname tag
    logfile="$(get_tmux_option '@sidetabs-timer-log' "$DEFAULT_TIMER_LOG")"
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || return 0
    if [ ! -f "$logfile" ]; then
        printf '#ts\tevent\tinterval_start\tinterval_s\ttotal_s\tsession\twindow\twindow_id\tcwd\ttag\n' \
            >> "$logfile" 2>/dev/null || return 0
    fi
    ts="$(epoch_to_iso "$(date +%s)")"
    istart_iso="-"; [ "$istart" != "-" ] && istart_iso="$(epoch_to_iso "$istart")"
    cwd="$(tmux list-panes -t "$WID" \
        -F "#{pane_active}${TAB}#{@is_sidetab}${TAB}#{pane_current_path}" 2>/dev/null \
        | awk -F"$TAB" '$2 != "1"' | sort -r | cut -d"$TAB" -f3 | head -1)"
    names="$(tmux display-message -p -t "$WID" "#{session_name}${TAB}#{window_name}" 2>/dev/null)"
    sname="${names%%"$TAB"*}"; wname="${names#*"$TAB"}"
    cwd="${cwd//$TAB/ }"; sname="${sname//$TAB/ }"; wname="${wname//$TAB/ }"
    # Tag read once per event (this fires on every auto-hold/auto-resume tick,
    # so no loop, no second show-option). Strip TABs and other control chars —
    # it lands in a TSV column and, per C7, may be interpolated into a menu.
    tag="$(get_window_option "$WID" "$TIMER_TAG_OPTION" "-")"
    tag="$(printf '%s' "$tag" | tr '\011' ' ' | tr -d '\000-\037' | tr -s ' ')"
    [ -z "$tag" ] && tag="-"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$event" "$istart_iso" "$is" "$total" "$sname" "$wname" "$WID" "$cwd" "$tag" \
        >> "$logfile" 2>/dev/null || return 0
}

# parse "<H:MM:SS|MM:SS|Nh|Nm|Ns|N>" -> seconds on stdout; rc 1 on garbage.
# bash 3.2: regex must live in a variable.
parse_duration() {
    local v="$1" re
    re='^([0-9]+):([0-9]{1,2}):([0-9]{1,2})$'
    if [[ "$v" =~ $re ]]; then echo $(( ${BASH_REMATCH[1]}*3600 + ${BASH_REMATCH[2]}*60 + ${BASH_REMATCH[3]} )); return 0; fi
    re='^([0-9]+):([0-9]{1,2})$'
    if [[ "$v" =~ $re ]]; then echo $(( ${BASH_REMATCH[1]}*60 + ${BASH_REMATCH[2]} )); return 0; fi
    re='^([0-9]+)h$'; if [[ "$v" =~ $re ]]; then echo $(( ${BASH_REMATCH[1]}*3600 )); return 0; fi
    re='^([0-9]+)m$'; if [[ "$v" =~ $re ]]; then echo $(( ${BASH_REMATCH[1]}*60 )); return 0; fi
    re='^([0-9]+)s?$'; if [[ "$v" =~ $re ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
    return 1
}

# Fold the open live interval into acc; export FOLD_START / FOLD_DUR (dur clamped
# to 0 on clock skew). Leaves the start option in place — callers unset/rewrite it.
fold_interval() {
    local start
    start="$(num_or "$(get_window_option "$WID" "$TIMER_START_OPTION" "$now")" "$now")"
    FOLD_START="$start"
    FOLD_DUR=$((now - start)); [ "$FOLD_DUR" -lt 0 ] && FOLD_DUR=0
    acc=$((acc + FOLD_DUR))
}

# C5 lazy per-tag billing-cycle reset. Runs before every interaction
# subcommand (dispatch below): when the window's tag has a reset day and a
# cycle boundary fell after this window's last reset, zero the timer HERE,
# in-process. Never a `timer.sh reset` child (D8) — an engine op's child loses
# lock_win and exits 0 silently, so the reset would simply vanish. Checking
# lazily is also what gives sleep/offline catch-up for free: no daemon, the
# boundary is noticed on the first interaction after it passed.
# Reads and updates the state/now/acc globals, so the subcommand that follows
# sees the post-reset world.
cycle_check() {
    local tag cs last re was_run was_hold
    tag="$(get_window_option "$WID" "$TIMER_TAG_OPTION" "")"
    [ -n "$tag" ] && [ "$tag" != "-" ] || return 0
    cs="$(cycle_start "$(tag_reset_day "$tag")")"   # empty = never auto-reset
    [ -n "$cs" ] || return 0

    # get_window_option cannot tell empty from unset, so both look the same
    # here — and both mean "first sighting": adopt the current cycle start
    # WITHOUT resetting. Deploying mid-cycle must not zero a live total (C5
    # rollout seeding). A malformed value (only reachable via a bad restore
    # seed) takes the same safe path.
    last="$(get_window_option "$WID" "$TIMER_LAST_RESET_OPTION" "")"
    re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    if [[ ! "$last" =~ $re ]]; then
        set_window_option "$WID" "$TIMER_LAST_RESET_OPTION" "$cs"
        return 0
    fi
    # Two same-shape ISO dates: compare as plain integers rather than with
    # `<`, whose collation depends on the locale. Not stale -> nothing due.
    [ "${last//-/}" -lt "${cs//-/}" ] || return 0

    # Nothing accrued and no timer to keep alive: just move the marker, so an
    # idle tagged window does not log an empty `reset` every cycle (the reset
    # arm's own `[ -z "$state" ] && exit 0` precedent). acc > 0 with no state
    # is unreachable today (adjust seeds `pause`); if it ever happens it falls
    # through to the real clearing path below.
    if [ -z "$state" ] && [ "$acc" -eq 0 ]; then
        set_window_option "$WID" "$TIMER_LAST_RESET_OPTION" "$cs"
        return 0
    fi

    # `run` and `hold` are both LIVE timers — hold only means the window is
    # unfocused right now, and the focus engine puts it straight back to run.
    # They differ in exactly one respect: only `run` has an open interval to
    # close. Treating hold as stopped (the pre-fix `was_run` alone) unset its
    # three options and blanked the `state` global, so the very call that
    # triggered this check (auto-resume / auto-hold) then aborted on its own
    # `[ "$state" = ... ] || exit 0` and the window silently stopped tracking
    # for the rest of the cycle — with no untagged time for C9/D5's abort to
    # catch, i.e. a plausible-looking zero in the nightly push. Every tagged
    # window except the focused one is in hold at any instant, and boundaries
    # are usually crossed overnight, so that was the DOMINANT case.
    # A sticky `pause` deliberately keeps the else branch: it accrues nothing,
    # and zeroing it matches the user-invoked `reset` arm below.
    was_run=0; was_hold=0
    case "$state" in
        run)  was_run=1 ;;
        hold) was_hold=1 ;;
    esac
    if [ "$was_run" = "1" ]; then
        # Close the open interval as its own row FIRST. Replay attributes
        # seconds on closing events only and treats `reset` as a boundary
        # marker, so folding a long head-down interval into the reset row
        # alone would drop it from the cycle it belongs to.
        fold_interval
        if [ "$CMD" = "cancel" ]; then
            # The caller is about to DISCARD this interval. Logging it as
            # `auto-pause` would bill the very seconds cancel exists to throw
            # away — the CLI replay bills pause/auto-pause and ignores cancel —
            # so a `cancel` that happened to land on a billing boundary became a
            # silent OVERCOUNT, while the cancel arm below then discarded a
            # zero-length interval and the sidebar showed 0 as if it had worked.
            # Cancel's primary use is "throw away the interval I left running
            # overnight", which is exactly when a boundary is crossed.
            # Unfold it too, so the `reset` row's cleared total excludes it.
            acc=$((acc - FOLD_DUR))
            log_event cancel "$FOLD_START" "$FOLD_DUR" "$acc"
        else
            log_event auto-pause "$FOLD_START" "$FOLD_DUR" "$acc"
        fi
    fi
    log_event reset - "$acc" 0   # col4 = cleared total, logged before zeroing
    acc=0
    if [ "$was_run" = "1" ]; then
        # D7: reset immediately followed by resume. A lone `reset` deletes the
        # key in timer_restore.sh's replay, so a crash before the next closing
        # event would restore nothing for a window that is in fact running.
        set_window_option "$WID" "$TIMER_ACC_OPTION" 0
        set_window_option "$WID" "$TIMER_START_OPTION" "$now"
        set_window_option "$WID" "$TIMER_STATE_OPTION" "run"
        log_event resume - 0 0
    elif [ "$was_hold" = "1" ]; then
        # Same D7 pair for the auto-paused case, minus the interval: stay in
        # hold (the `state` global is left alone on purpose — the auto-resume
        # arm below reads it after this returns) so refocusing resumes
        # normally. The companion row is an `auto-pause`, which is what the
        # restore replay maps back to hold; it carries a real interval start
        # with a zero-length interval, so it re-establishes the slot without
        # contributing any billable seconds.
        set_window_option "$WID" "$TIMER_ACC_OPTION" 0
        set_window_option "$WID" "$TIMER_STATE_OPTION" "hold"
        unset_window_option "$WID" "$TIMER_START_OPTION"   # hold has none; idempotent
        log_event auto-pause "$now" 0 0
    else
        state=""
        unset_window_option "$WID" "$TIMER_STATE_OPTION"
        unset_window_option "$WID" "$TIMER_START_OPTION"
        unset_window_option "$WID" "$TIMER_ACC_OPTION"
    fi
    set_window_option "$WID" "$TIMER_LAST_RESET_OPTION" "$cs"
    nudge_redraw
}

# Serialize per-window state mutations against the focus engine: an auto-hold
# racing a C-t keypress could otherwise clobber the just-folded total and turn
# a sticky manual pause back into an auto-resuming hold. Engine ops skip when
# busy (a user op is mid-flight and supersedes them) but ask the engine to
# reconcile again; user keypress ops proceed unlocked after ~250ms rather than
# ever eating the key. State is read AFTER the lock, so it is always fresh.
SERVER_PID="$(tmux display-message -p '#{pid}' 2>/dev/null)"
ENGINE_LOCK="${TMPDIR:-/tmp}/sidetabs_timerfocus_${SERVER_PID}"
lock_win() {
    LOCKW="${TMPDIR:-/tmp}/sidetabs_timerwin_${SERVER_PID}_${WID#@}"
    local i=0
    while ! mkdir "$LOCKW" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -ge 5 ] && return 1
        sleep 0.05
    done
    trap 'rmdir "$LOCKW" 2>/dev/null' EXIT
    return 0
}
case "$CMD" in
    auto-hold|auto-resume|cycle-check)
        lock_win || { touch "${ENGINE_LOCK}.rerun" 2>/dev/null || true; exit 0; }
        ;;
    toggle|cancel|reset|adjust|menu|restore-state|retag)
        lock_win || true
        ;;
esac

state="$(get_window_option "$WID" "$TIMER_STATE_OPTION" "")"
now="$(date +%s)"
acc="$(num_or "$(get_window_option "$WID" "$TIMER_ACC_OPTION" 0)" 0)"

# Every interaction is a chance to notice a crossed billing-cycle boundary.
# restore-state is deliberately absent: it seeds a blank slate from the log and
# gets its own derived last_reset (C6); resetting before that lands would zero
# a total the restore is in the middle of putting back.
#
# `menu` is deliberately absent too, even though it is a user interaction: it
# mutates no timer state, and running the check here committed the boundary
# fold BEFORE the user had chosen anything — so merely opening the menu banked
# the open interval as a billable `auto-pause` row, and then picking "cancel
# interval (keep total)" discarded a zero-length one. Every mutating action
# reachable from the menu runs the check itself (cancel and adjust are in this
# list; reset folds into its own reset row; assign-client goes through `retag`),
# and the focus engine's cycle_due arm still delivers C5's lazy reset to windows
# nobody interacts with, so nothing is lost by opening a menu and escaping.
#
# `retag` runs the check BEFORE the tag is rewritten, so it evaluates the OLD
# tag's boundary — the cycle that is actually closing.
case "$CMD" in
    toggle|cancel|adjust|retag|auto-hold|auto-resume|cycle-check) cycle_check ;;
esac

case "$CMD" in
toggle)
    if [ "$state" = "run" ]; then
        fold_interval
        set_window_option "$WID" "$TIMER_ACC_OPTION" "$acc"
        set_window_option "$WID" "$TIMER_STATE_OPTION" "pause"
        unset_window_option "$WID" "$TIMER_START_OPTION"
        log_event pause "$FOLD_START" "$FOLD_DUR" "$acc"
    else
        set_window_option "$WID" "$TIMER_ACC_OPTION" "$acc"
        set_window_option "$WID" "$TIMER_START_OPTION" "$now"
        set_window_option "$WID" "$TIMER_STATE_OPTION" "run"
        if [ -z "$state" ]; then
            log_event start - 0 "$acc"
        else
            log_event resume - 0 "$acc"
        fi
    fi
    nudge_redraw
    ;;
auto-hold)
    [ "$state" = "run" ] || exit 0
    fold_interval
    set_window_option "$WID" "$TIMER_ACC_OPTION" "$acc"
    set_window_option "$WID" "$TIMER_STATE_OPTION" "hold"
    unset_window_option "$WID" "$TIMER_START_OPTION"
    log_event auto-pause "$FOLD_START" "$FOLD_DUR" "$acc"
    ;;
auto-resume)
    [ "$state" = "hold" ] || exit 0
    set_window_option "$WID" "$TIMER_START_OPTION" "$now"
    set_window_option "$WID" "$TIMER_STATE_OPTION" "run"
    log_event auto-resume - 0 "$acc"
    ;;
cancel)
    if [ "$state" = "run" ]; then
        cstart="$(num_or "$(get_window_option "$WID" "$TIMER_START_OPTION" "$now")" "$now")"
        cdur=$((now - cstart)); [ "$cdur" -lt 0 ] && cdur=0
        set_window_option "$WID" "$TIMER_STATE_OPTION" "pause"
        unset_window_option "$WID" "$TIMER_START_OPTION"
        log_event cancel "$cstart" "$cdur" "$acc"   # discarded interval; acc unchanged
        nudge_redraw
    elif [ "$state" = "hold" ]; then
        set_window_option "$WID" "$TIMER_STATE_OPTION" "pause"
        log_event cancel - 0 "$acc"
        nudge_redraw
    fi
    ;;
reset)
    [ -z "$state" ] && exit 0
    [ "$state" = "run" ] && fold_interval   # cleared amount includes the live interval
    unset_window_option "$WID" "$TIMER_STATE_OPTION"
    unset_window_option "$WID" "$TIMER_START_OPTION"
    unset_window_option "$WID" "$TIMER_ACC_OPTION"
    log_event reset - "$acc" 0
    nudge_redraw
    ;;
adjust)
    mode=set; val="$ARG"
    case "$ARG" in
        +*) mode='+'; val="${ARG#+}" ;;
        -*) mode='-'; val="${ARG#-}" ;;
    esac
    if ! secs="$(parse_duration "$val")"; then
        tmux display-message "sidetabs: bad duration '$ARG' (try +15m, -90, 1:30:00)"
        exit 0
    fi
    if [ "$state" = "run" ]; then
        fold_interval
        set_window_option "$WID" "$TIMER_START_OPTION" "$now"   # compose with live timer
    fi
    old="$acc"
    case "$mode" in
        '+') acc=$((acc + secs)) ;;
        '-') acc=$((acc - secs)) ;;
        set) acc="$secs" ;;
    esac
    [ "$acc" -lt 0 ] && acc=0
    set_window_option "$WID" "$TIMER_ACC_OPTION" "$acc"
    [ -z "$state" ] && set_window_option "$WID" "$TIMER_STATE_OPTION" "pause"
    log_event adjust - "$((acc - old))" "$acc"
    nudge_redraw
    ;;
retag)
    # Reassign (or clear) the window's attribution tag. tag_set.sh delegates
    # here rather than writing @sidetabs_timer_tag itself, because a tag change
    # is an ATTRIBUTION BOUNDARY and the open interval has to be closed on it.
    #
    # log_event stamps the tag at write time (C1), and the CLI replay attributes
    # a whole interval to the tag it OPENED under. So rewriting the option
    # underneath a running timer used to leave one interval spanning the change:
    # every second worked AFTER the reassignment billed to the PREVIOUS client,
    # bounded only by the next focus change. Both endpoints are attributable in
    # an A -> B retag, so the replay's late-tagging warning never fired either —
    # an inflated row for A and a short row for B, and every guard passed.
    # Clearing the tag was the same root: the post-clear seconds kept going to
    # the old tag instead of the unattributed bucket D5's global abort watches.
    #
    # The fix is cycle_check's own fold/close/re-establish pattern (D7): close
    # the interval under the old tag, rewrite the option, reopen under the new
    # one. Ordering is load-bearing — the closing row must be written BEFORE the
    # option changes and the reopening row AFTER. auto-pause/auto-resume, not
    # pause/resume: timer_restore.sh maps `pause` to a sticky manual pause,
    # which would strand the window unresumable if the server died between the
    # two rows. hold/pause/unset need no rows at all — their interval is already
    # closed, so the past stays with the old tag and the next resume opens under
    # the new one.
    #
    # A tag CHANGE also clears @sidetabs_timer_last_reset (C5's marker):
    # reassigning from customer A (reset day 26) to B (reset day 1) must not
    # carry A's marker forward — cycle_check would compare it against B's
    # boundary and could either zero a total the user just meant to relabel, or
    # silently skip a reset B genuinely owes. Unsetting sends the next
    # cycle_check down C5's first-sighting path (adopt the new tag's current
    # cycle start, don't reset). Re-picking the SAME tag (the menu marks it
    # "(current)") exits before any of that: an unconditional unset would
    # re-seed to "now" and swallow a reset that was actually due.
    old_tag="$(get_window_option "$WID" "$TIMER_TAG_OPTION" "")"
    case "$ARG" in
        none) new_tag="" ;;
        '')   exit 0 ;;
        *)    # Strip TAB and other control chars before the write: the value
              # lands in a TSV log column, in timer_focus.sh's TAB-separated
              # list-windows format, and (per C7) in a menu label.
              new_tag="$(printf '%s' "$ARG" | tr '\011' ' ' | tr -d '\000-\037' | tr -s ' ')"
              [ -z "$new_tag" ] && exit 0   # garbage never changes state (C4)
              ;;
    esac
    [ "$new_tag" = "$old_tag" ] && exit 0
    if [ "$state" = "run" ]; then
        fold_interval
        set_window_option "$WID" "$TIMER_ACC_OPTION" "$acc"
        log_event auto-pause "$FOLD_START" "$FOLD_DUR" "$acc"   # carries the OLD tag
    fi
    if [ -n "$new_tag" ]; then
        set_window_option "$WID" "$TIMER_TAG_OPTION" "$new_tag"
    else
        unset_window_option "$WID" "$TIMER_TAG_OPTION"
    fi
    unset_window_option "$WID" "$TIMER_LAST_RESET_OPTION"
    if [ "$state" = "run" ]; then
        set_window_option "$WID" "$TIMER_START_OPTION" "$now"
        log_event auto-resume - 0 "$acc"   # carries the NEW tag; re-establishes the slot (D7)
    fi
    nudge_redraw
    ;;
cycle-check)
    # Focus-engine entry point (timer_focus.sh): the cycle_check above is the
    # whole job. Locked like the other engine ops so it defers to a user
    # keypress instead of racing it, and asks for a rerun when it does.
    ;;
adjust-prompt)
    if [ -n "$ARG" ]; then
        tmux command-prompt -t "$ARG" -p 'adjust (+15m / -90 / 1:30:00 sets):' \
            "run-shell \"$CURRENT_DIR/timer.sh adjust $WID '%%'\""
    else
        tmux command-prompt -p 'adjust (+15m / -90 / 1:30:00 sets):' \
            "run-shell \"$CURRENT_DIR/timer.sh adjust $WID '%%'\""
    fi
    ;;
restore-state)
    # Post-restore re-seed (timer_restore.sh): only ever fills a blank slate —
    # any live state wins. Seeds acc + a resumable state, never a live interval;
    # the focus engine turns hold -> run when the window has focus.
    #
    # A total of ZERO is a legitimate slot, not "nothing to restore": that is
    # exactly what D7's post-boundary `reset` + re-establishing row leave
    # behind, and refusing it here (the old `-gt 0`) dropped the state, tag and
    # last_reset of every window that crossed a billing boundary shortly before
    # the server died — while the abandoned open interval stayed in the log to
    # be billed. `-ge 0` with the numeric check above still rejects garbage;
    # timer_restore.sh's replay is what decides a slot exists at all.
    [ -n "$state" ] && exit 0
    case "$ARG" in ''|*[!0-9]*) exit 0 ;; esac
    [ "$ARG" -ge 0 ] || exit 0
    case "$ARG2" in hold|pause) ;; *) exit 0 ;; esac
    set_window_option "$WID" "$TIMER_ACC_OPTION" "$ARG"
    set_window_option "$WID" "$TIMER_STATE_OPTION" "$ARG2"
    # Tag (C6): `-`/empty means the log only ever knew this window as untagged.
    # Sanitized the way log_event sanitizes its read — the log is a plain text
    # file, and a hand-edited row must not smuggle control chars into a TSV
    # column or a menu. A live tag wins here too (the window may have been
    # re-tagged before the restore landed), and the tag is written BEFORE the
    # restore row so that row carries it.
    rtag="$(printf '%s' "$ARG3" | tr '\011' ' ' | tr -d '\000-\037' | tr -s ' ')"
    if [ -n "$rtag" ] && [ "$rtag" != "-" ] \
       && [ -z "$(get_window_option "$WID" "$TIMER_TAG_OPTION" "")" ]; then
        set_window_option "$WID" "$TIMER_TAG_OPTION" "$rtag"
        # last_reset is only meaningful next to a tag: seeded onto an untagged
        # window it would make the first cycle_check after someone assigns a
        # tag see a stale date and zero the total that C5's rollout seeding
        # exists to preserve. Re-validated here — the derivation upstream is
        # only as trustworthy as the log rows it read.
        rre='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        if [[ "$ARG4" =~ $rre ]]; then
            set_window_option "$WID" "$TIMER_LAST_RESET_OPTION" "$ARG4"
        fi
    fi
    log_event restore - 0 "$ARG"
    ;;
menu)
    # One ITEMS array feeds both display-menu branches below instead of two
    # literal lists drifting apart (the with-client and without-client forms
    # only ever differed in adjust-prompt's trailing $ARG). C7 adds two more
    # entries here: "assign client…" always, and "register repo for <label>…"
    # only when the tags file exists AND the window is already tagged — the
    # latter keeps the plugin generic for non-aguilabs users.
    ITEMS=(
        "adjust total…"                a "run-shell '$CURRENT_DIR/timer.sh adjust-prompt $WID${ARG:+ $ARG}'"
        "cancel interval (keep total)" c "run-shell '$CURRENT_DIR/timer.sh cancel $WID'"
        "reset (zero the timer)"       r "run-shell '$CURRENT_DIR/timer.sh reset $WID'"
        "assign client…"               t "run-shell -b '$CURRENT_DIR/tag_picker.sh $WID $ARG'"
    )
    mtag="$(get_window_option "$WID" "$TIMER_TAG_OPTION" "")"
    if [ -n "$mtag" ] && [ "$mtag" != "-" ] && [ -f "$(tags_file)" ]; then
        mlabel="$(tag_label "$mtag")"
        [ -n "$mlabel" ] || mlabel="$mtag"
        mlabel="$(printf '%s' "$mlabel" | tr '\011' ' ' | tr -d '\000-\037' | tr -s ' ')"
        ITEMS+=("register repo for ${mlabel}…" g "run-shell -b '$CURRENT_DIR/register_repo.sh $WID'")
    fi
    if [ "${SIDETABS_TIMER_MENU_PRINT:-}" = "1" ]; then
        i=0
        while [ "$i" -lt "${#ITEMS[@]}" ]; do
            printf '%s\t%s\n' "${ITEMS[$((i + 1))]}" "${ITEMS[$i]}"
            i=$((i + 3))
        done
        exit 0
    fi
    if [ -n "$ARG" ]; then
        tmux display-menu -c "$ARG" -T ' timer ' "${ITEMS[@]}"
    else
        tmux display-menu -T ' timer ' "${ITEMS[@]}"
    fi
    ;;
esac
