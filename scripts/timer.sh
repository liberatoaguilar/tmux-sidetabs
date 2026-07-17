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
# Event log v2 (@sidetabs-timer-log, TSV, one row per event, `#` header line):
#   ts_iso  event  interval_start_iso|-  interval_s  total_s  session  window_name  window_id  cwd
# Events: start resume pause auto-pause auto-resume adjust cancel reset.
# Logging is best-effort: an unwritable log never aborts a state transition.
#
# Bound (sidebar-focused): @sidetabs-timer-key toggle, @sidetabs-timer-menu-key menu.
# Usage: timer.sh <toggle|cancel|reset|menu|adjust|adjust-prompt|auto-hold|auto-resume> [window_id] [arg]
#   arg = adjust value (adjust), or client_name (menu / adjust-prompt).
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

CMD="${1:-toggle}"
WID="${2:-$(tmux display-message -p '#{window_id}')}"
ARG="${3:-}"
[ -z "$WID" ] && exit 0
TAB="$(printf '\t')"

nudge_redraw() { "$CURRENT_DIR/refresh.sh" force; }
num_or() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

# log_event <event> <interval_start_epoch|-> <interval_s> <total_s>
log_event() {
    local event="$1" istart="$2" is="$3" total="$4" logfile ts istart_iso cwd names sname wname
    logfile="$(get_tmux_option '@sidetabs-timer-log' "$DEFAULT_TIMER_LOG")"
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || return 0
    if [ ! -f "$logfile" ]; then
        printf '#ts\tevent\tinterval_start\tinterval_s\ttotal_s\tsession\twindow\twindow_id\tcwd\n' \
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
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$event" "$istart_iso" "$is" "$total" "$sname" "$wname" "$WID" "$cwd" \
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
    auto-hold|auto-resume)
        lock_win || { touch "${ENGINE_LOCK}.rerun" 2>/dev/null || true; exit 0; }
        ;;
    toggle|cancel|reset|adjust)
        lock_win || true
        ;;
esac

state="$(get_window_option "$WID" "$TIMER_STATE_OPTION" "")"
now="$(date +%s)"
acc="$(num_or "$(get_window_option "$WID" "$TIMER_ACC_OPTION" 0)" 0)"

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
adjust-prompt)
    if [ -n "$ARG" ]; then
        tmux command-prompt -t "$ARG" -p 'adjust (+15m / -90 / 1:30:00 sets):' \
            "run-shell \"$CURRENT_DIR/timer.sh adjust $WID '%%'\""
    else
        tmux command-prompt -p 'adjust (+15m / -90 / 1:30:00 sets):' \
            "run-shell \"$CURRENT_DIR/timer.sh adjust $WID '%%'\""
    fi
    ;;
menu)
    if [ -n "$ARG" ]; then
        tmux display-menu -c "$ARG" -T ' timer ' \
            "adjust total…"                a "run-shell '$CURRENT_DIR/timer.sh adjust-prompt $WID $ARG'" \
            "cancel interval (keep total)" c "run-shell '$CURRENT_DIR/timer.sh cancel $WID'" \
            "reset (zero the timer)"       r "run-shell '$CURRENT_DIR/timer.sh reset $WID'"
    else
        tmux display-menu -T ' timer ' \
            "adjust total…"                a "run-shell '$CURRENT_DIR/timer.sh adjust-prompt $WID'" \
            "cancel interval (keep total)" c "run-shell '$CURRENT_DIR/timer.sh cancel $WID'" \
            "reset (zero the timer)"       r "run-shell '$CURRENT_DIR/timer.sh reset $WID'"
    fi
    ;;
esac
