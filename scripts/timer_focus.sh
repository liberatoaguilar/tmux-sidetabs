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

while :; do
    rm -f "${LOCK}.rerun" 2>/dev/null || true

    clients="$(tmux list-clients 2>/dev/null | grep -c . || true)"
    case "$clients" in ''|*[!0-9]*) clients=0 ;; esac

    # One decision per window: linked windows (grouped sessions) appear once per
    # linkage in list-windows -a, so OR the focused predicate across linkages —
    # judging rows independently would flip-flop hold/run on the focused window.
    rows="$(tmux list-windows -a \
        -F "#{window_id}${TAB}#{window_active}${TAB}#{session_attached}${TAB}#{?${TIMER_STATE_OPTION},#{${TIMER_STATE_OPTION}},-}" \
        2>/dev/null | awk -F"$TAB" -v clients="$clients" '
        {
            wid=$1; active=$2; attached=$3; state=$4
            if (attached !~ /^[0-9]+$/) attached=0
            f = (active=="1" && (clients==0 || attached>0)) ? 1 : 0
            if (wid in F) { if (f) F[wid]=1 } else { F[wid]=f; S[wid]=state; O[++n]=wid }
        }
        END { for (i=1;i<=n;i++) { w=O[i]; printf "%s\t%s\t%s\n", w, F[w], S[w] } }')"

    case "$rows" in *run*|*hold*) : ;; *) break ;; esac   # no live timers

    changed=0
    while IFS="$TAB" read -r wid focused state; do
        if [ "$state" = "run" ] && [ "$focused" = "0" ]; then
            "$CURRENT_DIR/timer.sh" auto-hold "$wid" || true; changed=1
        elif [ "$state" = "hold" ] && [ "$focused" = "1" ]; then
            "$CURRENT_DIR/timer.sh" auto-resume "$wid" || true; changed=1
        fi
    done <<< "$rows"

    if [ "$changed" = "1" ]; then
        set_tmux_option "$LAST_REFRESH_OPTION" "0"
        "$CURRENT_DIR/refresh.sh"
    fi

    [ -e "${LOCK}.rerun" ] || break
done
