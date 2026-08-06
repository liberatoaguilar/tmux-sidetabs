#!/usr/bin/env bash
# Re-seed per-window timer state after a tmux server restart. The live state
# (window user options) dies with the server; the TSV event log is the durable
# record. Replay it to each (session, window-name)'s final state and hand the
# result to `timer.sh restore-state`, which fills the options — never clobbering
# live state — and logs a `restore` row marking the boundary.
#
# Matching is by session + window NAME (window ids change across restarts):
# windows renamed since their last logged event simply don't match, and when
# two live windows share a name only the lowest-indexed one is seeded.
#
# Called from resurrect_post.sh after a tmux-resurrect restore; safe to run by
# hand any time. Disable with:  set -g @sidetabs-timer-restore off
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

[ "$(get_tmux_option '@sidetabs-timer-restore' "$DEFAULT_TIMER_RESTORE")" = "on" ] || exit 0
logfile="$(get_tmux_option '@sidetabs-timer-log' "$DEFAULT_TIMER_LOG")"
[ -f "$logfile" ] || exit 0

TAB="$(printf '\t')"
US=$'\x1f'   # never appears in the log (log_event strips control chars)

# Replay every event in order to a final (state, total) per session+window.
# col5 (total_s) is authoritative at every row; `reset` clears the slot.
# `cancel` maps to pause (its only state-changing form is run -> pause).
# `adjust`/`restore` keep the current state and only move the total — with no
# prior state they are ignored (an adjust on a stateless window shows nothing).
finals="$(awk -F'\t' -v US="$US" '
    /^#/ { next }
    NF < 8 { next }
    $5 !~ /^[0-9]+$/ { next }
    {
        key = $6 US $7
        ev = $2
        if (ev == "start" || ev == "resume" || ev == "auto-resume") S[key] = "run"
        else if (ev == "auto-pause")                                S[key] = "hold"
        else if (ev == "pause" || ev == "cancel")                   S[key] = "pause"
        else if (ev == "reset")               { delete S[key]; delete A[key]; next }
        else if (ev == "adjust" || ev == "restore") { if (!(key in S)) next }
        else next
        A[key] = $5 + 0
    }
    END { for (k in S) if (A[k] > 0) print k US S[k] US A[k] }
' "$logfile")"
[ -n "$finals" ] || exit 0

applied="$US"    # keys already seeded — first window with a given name wins
changed=0
while IFS="$TAB" read -r sname wname wid; do
    [ -n "$wid" ] || continue
    key="${sname}${US}${wname}"
    case "$applied" in *"${US}${key}${US}"*) continue ;; esac
    hit="$(printf '%s\n' "$finals" \
        | awk -F"$US" -v US="$US" -v s="$sname" -v w="$wname" '$1==s && $2==w {print $3 US $4; exit}')"
    [ -n "$hit" ] || continue
    state="${hit%%"$US"*}"
    total="${hit#*"$US"}"
    # A timer that was running when the server died comes back as hold: there is
    # no live interval to resume, and the focus engine re-runs it on focus.
    [ "$state" = "run" ] && state="hold"
    applied="${applied}${key}${US}"
    "$CURRENT_DIR/timer.sh" restore-state "$wid" "$total" "$state" || true
    changed=1
done <<< "$(tmux list-windows -a -F "#{session_name}${TAB}#{window_name}${TAB}#{window_id}" 2>/dev/null)"

if [ "$changed" = "1" ]; then
    "$CURRENT_DIR/timer_focus.sh" || true    # focused window: hold -> run now
    "$CURRENT_DIR/refresh.sh" force
fi
