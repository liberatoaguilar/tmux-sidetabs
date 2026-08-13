#!/usr/bin/env bash
# Re-seed per-window timer state after a tmux server restart. The live state
# (window user options) dies with the server; the TSV event log is the durable
# record. Replay it to each (session, window-name)'s final state and hand the
# result to `timer.sh restore-state`, which fills the options — never clobbering
# live state — and logs a `restore` row marking the boundary. Re-seeded: state,
# total, the attribution tag (v3 col 10; v2 rows come back untagged) and the
# cycle marker @sidetabs_timer_last_reset, which is NOT a logged column and is
# therefore derived (see the awk below).
#
# Matching is by session + window NAME (window ids change across restarts):
# windows renamed since their last logged event simply don't match, and when
# two live windows share a name only the lowest-indexed one is seeded.
#
# Two delivery paths, deliberately not symmetric:
#   (default)  resurrect_post.sh, after a tmux-resurrect restore. Always runs —
#              also safe to run by hand any time (seeding is blank-slate-only
#              and idempotent) — and claims the generation flag on the way in.
#   boot       the client-attached fallback registered by sidetabs.tmux, for
#              the case where tmux-continuum skips auto-restore entirely (it
#              does that whenever another tmux server was running at startup,
#              or the server is older than @continuum-restore-max-delay) and
#              the resurrect hook therefore never fires at all. This mode only
#              runs while the server is YOUNG (< BOOT_MAX_AGE_S) and only once
#              per server generation: firing later would let a freshly created
#              window whose name matches old log rows be seeded with a stale
#              total, which flows into billing as a silent OVERCOUNT.
# The claim is one-directional on purpose: `boot` stands down once anything has
# restored this generation, but a resurrect restore never stands down for
# `boot` — losing that race (attach before continuum restores) would leave
# every timer unseeded, and re-seeding an already-seeded window is a no-op.
#
# Disable both with:  set -g @sidetabs-timer-restore off
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

MODE="${1:-}"
# Test hook: SIDETABS_TIMER_BOOT_MAX_AGE_S overrides the boot window in seconds
# (a non-integer is ignored). Documented here per the search.sh:7-8 convention —
# run-shell does not inherit a test shell's exports, so tests pass it inline on
# the run-shell command string.
BOOT_MAX_AGE_S="${SIDETABS_TIMER_BOOT_MAX_AGE_S:-120}"
case "$BOOT_MAX_AGE_S" in ''|*[!0-9]*) BOOT_MAX_AGE_S=120 ;; esac

[ "$(get_tmux_option '@sidetabs-timer-restore' "$DEFAULT_TIMER_RESTORE")" = "on" ] || exit 0

if [ "$MODE" = "boot" ]; then
    [ "$(get_tmux_option "$TIMER_RESTORED_OPTION" '0')" = "1" ] && exit 0
    # A restore in flight owns this generation; the post hook will claim it.
    [ "$(get_tmux_option "$RESTORING_OPTION" '0')" = "1" ] && exit 0
    # #{start_time} is raw epoch seconds. Fail CLOSED: an unreadable or
    # nonsense server age means we cannot prove we are inside the boot window.
    started="$(tmux display-message -p '#{start_time}' 2>/dev/null || true)"
    case "$started" in ''|*[!0-9]*) exit 0 ;; esac
    [ "$(( $(date +%s) - started ))" -lt "$BOOT_MAX_AGE_S" ] || exit 0
fi
set_tmux_option "$TIMER_RESTORED_OPTION" "1"

logfile="$(get_tmux_option '@sidetabs-timer-log' "$DEFAULT_TIMER_LOG")"
[ -f "$logfile" ] || exit 0

TAB="$(printf '\t')"
US=$'\x1f'   # never appears in the log (log_event strips control chars)

# Replay every event in order to a final (state, total, tag, last_reset) per
# session+window. col5 (total_s) is authoritative at every row; `reset` clears
# the slot. `cancel` maps to pause (its only state-changing form is run ->
# pause). `adjust`/`restore` keep the current state and only move the total —
# with no prior state they are ignored (an adjust on a stateless window shows
# nothing). The NF < 8 gate keeps the 12 legacy 6-col rows out: they have no
# event column, so they cannot drive state (C1 "accept" = ignore, not error).
#
# tag is col 10 where present; a v2 (9-col) row means untagged, i.e. `-`.
#
# last_reset is derived, not logged: the date of the key's last `reset` row,
# else the date of its first row. Both naive alternatives are wrong — seeding
# it to the CURRENT cycle start, or leaving it unset (which trips C5's rollout
# seeding), each suppress a reset that came due while the server was down,
# which is precisely the case lazy cycle checking exists for. Timestamps that
# are not ISO dates (hand-edited rows) yield `-`, which restore-state drops.
finals="$(awk -F'\t' -v US="$US" '
    /^#/ { next }
    NF < 8 { next }
    $5 !~ /^[0-9]+$/ { next }
    {
        key = $6 US $7
        day = ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) ? substr($1, 1, 10) : "-"
        if (!(key in FIRST) && day != "-") FIRST[key] = day
        ev = $2
        if (ev == "start" || ev == "resume" || ev == "auto-resume") S[key] = "run"
        else if (ev == "auto-pause")                                S[key] = "hold"
        else if (ev == "pause" || ev == "cancel")                   S[key] = "pause"
        else if (ev == "reset") {
            delete S[key]; delete A[key]
            if (day != "-") LR[key] = day
            next
        }
        else if (ev == "adjust" || ev == "restore") { if (!(key in S)) next }
        else next
        A[key] = $5 + 0
        T[key] = (NF >= 10 && $10 != "") ? $10 : "-"
    }
    END {
        # Every key still in S[] is a live slot, INCLUDING one whose running
        # total is 0. The pre-D7 `if (A[k] > 0)` filter here left D7 silently
        # unimplemented: cycle_check logs `reset` + a re-establishing row
        # exactly so a crash mid-cycle restores something, and BOTH of those
        # rows carry total 0, so the slot D7 re-opened was dropped again here
        # — state, tag and last_reset all lost, while the abandoned open
        # interval stayed in the log for the CLI replay to bill as an
        # OVERCOUNT (the worse of the two failure directions). A genuinely
        # zeroed key is not in S[] at all: `reset` deletes it above, and only
        # a later row can put it back.
        for (k in S) {
            lr = (k in LR) ? LR[k] : ((k in FIRST) ? FIRST[k] : "-")
            print k US S[k] US A[k] US T[k] US lr
        }
    }
' "$logfile")"
[ -n "$finals" ] || exit 0

applied="$US"    # keys already seeded — first window with a given name wins
changed=0
while IFS="$TAB" read -r sname wname wid; do
    [ -n "$wid" ] || continue
    key="${sname}${US}${wname}"
    case "$applied" in *"${US}${key}${US}"*) continue ;; esac
    # Names go in through ENVIRON, not -v: awk expands backslash escapes in a
    # -v value, so a window named with a backslash would never match itself.
    # Fed by here-string rather than `printf | awk`: awk's early `exit` can
    # SIGPIPE the writer, and under `set -euo pipefail` that 141 would abort
    # the whole restore instead of skipping one window (`|| true` on top).
    hit="$(s="$sname" w="$wname" awk -F"$US" -v US="$US" \
        '$1==ENVIRON["s"] && $2==ENVIRON["w"] {print $3 US $4 US $5 US $6; exit}' \
        <<< "$finals" || true)"
    [ -n "$hit" ] || continue
    IFS="$US" read -r state total tag last_reset <<< "$hit"
    # A timer that was running when the server died comes back as hold: there is
    # no live interval to resume, and the focus engine re-runs it on focus.
    [ "$state" = "run" ] && state="hold"
    applied="${applied}${key}${US}"
    "$CURRENT_DIR/timer.sh" restore-state "$wid" "$total" "$state" "$tag" "$last_reset" || true
    changed=1
done <<< "$(tmux list-windows -a -F "#{session_name}${TAB}#{window_name}${TAB}#{window_id}" 2>/dev/null)"

if [ "$changed" = "1" ]; then
    "$CURRENT_DIR/timer_focus.sh" || true    # focused window: hold -> run now
    "$CURRENT_DIR/refresh.sh" force
fi
