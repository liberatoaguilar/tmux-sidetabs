#!/usr/bin/env bash
# Per-window stopwatch. State lives in window user options (session-only; not
# saved by tmux-resurrect). Every pause appends one interval to the TSV log:
#   end_iso  start_iso  duration_s  cwd  session_name  window_name
# Bound (sidebar-focused): @sidetabs-timer-key toggle, @sidetabs-timer-menu-key menu.
# Usage: timer.sh <toggle|reset|cancel|menu> [window_id] [client_name]
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

CMD="${1:-toggle}"
WID="${2:-$(tmux display-message -p '#{window_id}')}"
CLIENT="${3:-}"
[ -z "$WID" ] && exit 0
TAB="$(printf '\t')"

nudge_redraw() {
    set_tmux_option "$LAST_REFRESH_OPTION" "0"
    "$CURRENT_DIR/refresh.sh"
}

# Append one TSV line. cwd = the window's active content (non-sidetab) pane —
# same selection as render.sh's summary (render.sh:205-207).
log_interval() {
    local start="$1" end="$2" dur="$3" logfile cwd names sname wname
    logfile="$(get_tmux_option '@sidetabs-timer-log' "$DEFAULT_TIMER_LOG")"
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || return 0
    cwd="$(tmux list-panes -t "$WID" \
        -F "#{pane_active}${TAB}#{@is_sidetab}${TAB}#{pane_current_path}" 2>/dev/null \
        | awk -F"$TAB" '$2 != "1"' | sort -r | cut -d"$TAB" -f3 | head -1)"
    names="$(tmux display-message -p -t "$WID" "#{session_name}${TAB}#{window_name}" 2>/dev/null)"
    sname="${names%%"$TAB"*}"; wname="${names#*"$TAB"}"
    # Tabs inside values would corrupt the TSV.
    cwd="${cwd//$TAB/ }"; sname="${sname//$TAB/ }"; wname="${wname//$TAB/ }"
    # Best-effort append: an unwritable log must not abort (set -e) before the
    # pause state transition below — logging never blocks the stopwatch.
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(epoch_to_iso "$end")" "$(epoch_to_iso "$start")" "$dur" \
        "$cwd" "$sname" "$wname" >> "$logfile" 2>/dev/null || return 0
}

state="$(get_window_option "$WID" "$TIMER_STATE_OPTION" "")"
now="$(date +%s)"

case "$CMD" in
toggle)
    if [ "$state" = "run" ]; then
        start="$(get_window_option "$WID" "$TIMER_START_OPTION" "$now")"
        case "$start" in ''|*[!0-9]*) start="$now" ;; esac
        acc="$(get_window_option "$WID" "$TIMER_ACC_OPTION" "0")"
        case "$acc" in ''|*[!0-9]*) acc=0 ;; esac
        dur=$((now - start)); [ "$dur" -lt 0 ] && dur=0   # clock stepped back
        log_interval "$start" "$now" "$dur"
        set_window_option "$WID" "$TIMER_ACC_OPTION" "$((acc + dur))"
        set_window_option "$WID" "$TIMER_STATE_OPTION" "pause"
        unset_window_option "$WID" "$TIMER_START_OPTION"
    else
        acc="$(get_window_option "$WID" "$TIMER_ACC_OPTION" "")"
        case "$acc" in ''|*[!0-9]*) set_window_option "$WID" "$TIMER_ACC_OPTION" "0" ;; esac
        set_window_option "$WID" "$TIMER_START_OPTION" "$now"
        set_window_option "$WID" "$TIMER_STATE_OPTION" "run"
    fi
    nudge_redraw
    ;;
cancel)
    if [ "$state" = "run" ]; then
        set_window_option "$WID" "$TIMER_STATE_OPTION" "pause"
        unset_window_option "$WID" "$TIMER_START_OPTION"
        nudge_redraw
    fi
    ;;
reset)
    unset_window_option "$WID" "$TIMER_STATE_OPTION"
    unset_window_option "$WID" "$TIMER_START_OPTION"
    unset_window_option "$WID" "$TIMER_ACC_OPTION"
    nudge_redraw
    ;;
menu)
    if [ -n "$CLIENT" ]; then
        tmux display-menu -c "$CLIENT" -T " timer " \
            "reset (zero, discard interval)"     r "run-shell '$CURRENT_DIR/timer.sh reset $WID'" \
            "cancel interval (keep accumulated)" c "run-shell '$CURRENT_DIR/timer.sh cancel $WID'"
    else
        tmux display-menu -T " timer " \
            "reset (zero, discard interval)"     r "run-shell '$CURRENT_DIR/timer.sh reset $WID'" \
            "cancel interval (keep accumulated)" c "run-shell '$CURRENT_DIR/timer.sh cancel $WID'"
    fi
    ;;
esac
