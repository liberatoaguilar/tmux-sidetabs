#!/usr/bin/env bash
# Focus engine: auto-holds running timers on unfocused windows and auto-resumes
# held timers on the focused one. Fired by hooks (session-window-changed,
# client-{attached,detached,session-changed}). Manual 'pause' is never touched.
# Focused = active window of an attached session; if the server has NO clients
# at all (detached/test servers), plain window_active counts.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/tags.sh"

[ "$(get_tmux_option '@sidetabs-timer-autofocus' "${DEFAULT_TIMER_AUTOFOCUS:-on}")" = "on" ] || exit 0
TAB="$(printf '\t')"

# Serialize concurrent hook bursts (same mkdir-lock pattern as create_sidebar.sh).
# A busy exit leaves a rerun marker: the lock holder reconciles once more with
# fresh state before releasing, so a dropped burst can't strand a focused
# window in hold (e.g. rapid C-j/C-k window cycling).
SERVER_PID="$(tmux display-message -p '#{pid}' 2>/dev/null)"
LOCK="${TMPDIR:-/tmp}/sidetabs_timerfocus_${SERVER_PID}"
if ! mkdir "$LOCK" 2>/dev/null; then
    touch "${LOCK}.rerun" 2>/dev/null || true
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# C5 filter: is a billing-cycle reset due for this window? Answers from the
# two values the format below already carries, so only windows that answer yes
# pay for a timer.sh fork. `-` is the format's unset sentinel; an unset or
# malformed last_reset answers yes and the child decides what it means (it
# seeds without resetting) — the child is the authority, this is only a filter.
cycle_due() {
    local tag="$1" last="$2" cs re
    [ -n "$tag" ] && [ "$tag" != "-" ] || return 1
    cs="$(cycle_start "$(tag_reset_day "$tag")")"   # empty = never auto-reset
    [ -n "$cs" ] || return 1
    re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    [[ "$last" =~ $re ]] || return 0
    [ "${last//-/}" -lt "${cs//-/}" ]
}

while :; do
    rm -f "${LOCK}.rerun" 2>/dev/null || true

    clients="$(server_client_count)"
    case "$clients" in ''|*[!0-9]*) clients=0 ;; esac

    # One decision per window: linked windows (grouped sessions) appear once per
    # linkage in list-windows -a, so OR the focused predicate across linkages —
    # judging rows independently would flip-flop hold/run on the focused window.
    # The format and the `read` below are a lockstep pair: append fields at the
    # END only, or every later variable silently shifts. `#{?OPT,#{OPT},-}` is
    # deliberate — a bare #{OPT} on an unset option yields an empty field, and
    # the ternary also keeps a literal `0` from reading as unset.
    rows="$(tmux list-windows -a \
        -F "#{window_id}${TAB}#{window_active}${TAB}#{session_attached}${TAB}#{?${TIMER_STATE_OPTION},#{${TIMER_STATE_OPTION}},-}${TAB}#{?${TIMER_TAG_OPTION},#{${TIMER_TAG_OPTION}},-}${TAB}#{?${TIMER_LAST_RESET_OPTION},#{${TIMER_LAST_RESET_OPTION}},-}" \
        2>/dev/null | awk -F"$TAB" -v clients="$clients" '
        {
            wid=$1; active=$2; attached=$3; state=$4; tag=$5; lastreset=$6
            if (attached !~ /^[0-9]+$/) attached=0
            f = (active=="1" && (clients==0 || attached>0)) ? 1 : 0
            if (wid in F) { if (f) F[wid]=1 }
            else { F[wid]=f; S[wid]=state; T[wid]=tag; L[wid]=lastreset; O[++n]=wid }
        }
        END { for (i=1;i<=n;i++) { w=O[i]; printf "%s\t%s\t%s\t%s\t%s\n", w, F[w], S[w], T[w], L[w] } }')"

    case "$rows" in *run*|*hold*) : ;; *) break ;; esac   # no live timers

    changed=0
    while IFS="$TAB" read -r wid focused state tag lastreset; do
        if [ "$state" = "run" ] && [ "$focused" = "0" ]; then
            "$CURRENT_DIR/timer.sh" auto-hold "$wid" || true; changed=1
        elif [ "$state" = "hold" ] && [ "$focused" = "1" ]; then
            "$CURRENT_DIR/timer.sh" auto-resume "$wid" || true; changed=1
        elif cycle_due "$tag" "$lastreset"; then
            # Windows the two arms above already visit run the same check
            # in-process, so this arm only picks up the rest: run+focused,
            # hold+unfocused, sticky pause, and untimed tagged windows.
            # cycle-check redraws itself when it actually resets, so no
            # `changed=1` here.
            # Known limitation: the early break above means that when NO window
            # anywhere on the server has a live timer, this loop is never
            # reached at all — a lone sticky-paused window therefore resets on
            # its next toggle instead of on a focus tick. Nothing is accruing
            # in the meantime, so the only cost is a late `reset` row.
            "$CURRENT_DIR/timer.sh" cycle-check "$wid" || true
        fi
    done <<< "$rows"

    if [ "$changed" = "1" ]; then
        "$CURRENT_DIR/refresh.sh" force
    fi

    [ -e "${LOCK}.rerun" ] || break
done
