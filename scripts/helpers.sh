#!/usr/bin/env bash

get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local value
    value="$(tmux show-option -gqv "$option" 2>/dev/null)"
    [ -z "$value" ] && echo "$default_value" || echo "$value"
}

set_tmux_option() {
    tmux set-option -gq "$1" "$2"
}

get_session_option() {
    local session_id="$1" option="$2" default_value="$3" value
    value="$(tmux show-option -t "$session_id" -qv "$option" 2>/dev/null)"
    [ -z "$value" ] && echo "$default_value" || echo "$value"
}

set_session_option() {
    tmux set-option -t "$1" -q "$2" "$3"
}

get_pane_option() {
    local pane_id="$1" option="$2" default_value="$3" value
    value="$(tmux show-option -p -t "$pane_id" -qv "$option" 2>/dev/null)"
    [ -z "$value" ] && echo "$default_value" || echo "$value"
}

set_pane_option() {
    tmux set-option -p -t "$1" -q "$2" "$3"
}

unset_pane_option() {
    tmux set-option -p -t "$1" -qu "$2" 2>/dev/null || true
}

get_window_option() {
    local window_id="$1" option="$2" default_value="$3" value
    value="$(tmux show-option -w -t "$window_id" -qv "$option" 2>/dev/null)"
    [ -z "$value" ] && echo "$default_value" || echo "$value"
}

set_window_option() {
    tmux set-option -w -t "$1" -q "$2" "$3"
}

unset_window_option() {
    tmux set-option -w -t "$1" -qu "$2"
}

# epoch seconds -> ISO-8601 with UTC offset. GNU form FIRST: GNU `date -r N`
# treats N as a filename (silent wrong answers), while the GNU -d form fails
# cleanly on BSD/macOS and falls through to -r.
epoch_to_iso() {
    date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
        || date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null
}

# Days in (year, month): fixed table + Gregorian leap rule for Feb. Only used
# to clamp cycle_start's reset_day; y/m are already base-10-forced by the caller.
cycle_days_in_month() {
    local y="$1" m="$2"
    case "$m" in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11) echo 30 ;;
        2)
            if (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); then
                echo 29
            else
                echo 28
            fi
            ;;
        *) echo 30 ;;  # unreachable: caller only ever passes 1-12
    esac
}

# cycle_start <reset_day> -> ISO YYYY-MM-DD of the most recent billing-cycle
# boundary <= today, local wall-clock time. reset_day is a day-of-month
# (1-31, leading zeros tolerated; clamped to the target month's real length —
# 31 lands on Feb 28/29). reset_day that is 0, empty, or not a plain integer
# means "never auto-reset" and prints nothing on stdout — always rc 0, so a
# caller can safely do `cs=$(cycle_start "$reset_day")` under `set -e`.
#
# Deliberately avoids GNU `date -d '-1 month'` / BSD `date -v-1m` (neither
# runs on the other): the previous-month step is plain shell integer
# arithmetic on the y/m/d already pulled out of an ISO date, the same
# dual-path-free spirit as epoch_to_iso's GNU-then-BSD fallback above (reused
# here to turn "now" into today's date in local time).
#
# Test hook: SIDETABS_TIMER_TODAY=YYYY-MM-DD overrides "today" (validated;
# malformed values are ignored and the real clock wins). Documented here per
# the search.sh:7-8 convention — run-shell does not inherit the test shell's
# exports, so tests must pass it inline on the run-shell command string.
cycle_start() {
    local reset_day="$1" re today y m d cur_dim boundary py pm pdim

    re='^[0-9]+$'
    [[ "$reset_day" =~ $re ]] || return 0
    reset_day=$((10#$reset_day))
    { [ "$reset_day" -ge 1 ] && [ "$reset_day" -le 31 ]; } || return 0

    today="${SIDETABS_TIMER_TODAY:-}"
    re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    if [[ ! "$today" =~ $re ]]; then
        today="$(epoch_to_iso "$(date +%s)")"
        today="${today:0:10}"
    fi

    y="${today%%-*}"; d="${today##*-}"
    m="${today#*-}"; m="${m%-*}"
    y=$((10#$y)); m=$((10#$m)); d=$((10#$d))

    cur_dim="$(cycle_days_in_month "$y" "$m")"
    boundary="$reset_day"; [ "$boundary" -gt "$cur_dim" ] && boundary="$cur_dim"

    if [ "$d" -ge "$boundary" ]; then
        printf '%04d-%02d-%02d\n' "$y" "$m" "$boundary"
        return 0
    fi

    # Boundary hasn't happened yet this month: the most recent one was last
    # month's (clamped to ITS length, independently of this month's clamp).
    pm=$((m - 1)); py="$y"
    if [ "$pm" -lt 1 ]; then pm=12; py=$((y - 1)); fi
    pdim="$(cycle_days_in_month "$py" "$pm")"
    boundary="$reset_day"; [ "$boundary" -gt "$pdim" ] && boundary="$pdim"
    printf '%04d-%02d-%02d\n' "$py" "$pm" "$boundary"
}

# Returns the pane_id of the sidetab pane in a window, or empty.
find_sidetab_pane() {
    local window_id="$1"
    tmux list-panes -t "$window_id" -F '#{pane_id} #{@is_sidetab}' 2>/dev/null \
        | awk '$2 == "1" { print $1; exit }'
}

window_has_sidetab() {
    local window_id="$1"
    [ -n "$(find_sidetab_pane "$window_id")" ]
}

pane_is_sidetab() {
    local pane_id="$1"
    [ "$(get_pane_option "$pane_id" "@is_sidetab" "0")" = "1" ]
}

# Number of clients attached to this server (always prints a number). The
# SINGLE definition of "how clients are counted" for both the timer focus
# engine (timer_focus.sh) and render.sh's visibility gate — they must agree,
# or a window's timer could run as "focused" while its sidebar sleeps as
# hidden. `|| true` guards callers running under set -e/pipefail (grep -c
# exits 1 on zero matches after printing 0).
server_client_count() {
    tmux list-clients 2>/dev/null | grep -c . || true
}

# Current epoch ms. Runs on every refresh hook, so startup cost matters: prefer
# perl (~0-2ms, ms precision) over python3 (~30ms cold-start, ~15x slower) to avoid
# a process-spawn storm. date fallback is seconds-only — too coarse for the 100ms
# REFRESH_DEBOUNCE_MS, so it's a last resort only.
now_ms() {
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(int(time.time()*1000))'
    else
        # macOS date doesn't support %N; fall back to seconds*1000.
        echo $(( $(date +%s) * 1000 ))
    fi
}
