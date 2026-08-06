#!/usr/bin/env bash
# Agent status: let a coding agent (Claude Code, codex, opencode) running inside
# a pane tell the sidebar what it is doing. The agent's own tool hooks invoke
# this script; nothing is auto-installed (see the README "Agent status" section).
#
# Two layers:
#   PER-PANE truth   @sidetabs_agent_pane        = working | attention | done
#                    @sidetabs_agent_pane_since  = epoch secs that pane ENTERED
#                                                  the state (re-asserting the
#                                                  same state keeps the original)
#                    @sidetabs_agent_pane_prev[_since]
#                                                = the state `attention`
#                                                  displaced, restored when the
#                                                  attention is consumed
#   WINDOW aggregate @sidetabs_agent / @sidetabs_agent_since — recomputed from
#                    all panes on every write: worst state wins
#                    (attention > working > done), and `since` is the OLDEST
#                    since among the panes holding the winning state.
#
# Why the aggregate exists: render must read per-window state for free, via the
# single `list-windows -F` interpolation the render loop already does. Writes are
# rare (a handful per agent turn), so paying one `list-panes` per WRITE to keep
# reads at zero cost is the right trade.
#
# Cost, measured, because agent hooks run in front of a human: re-asserting a
# state is five tmux calls (the master switch, one display-message, one
# list-panes, two show-options for the old aggregate) and stops there — no epoch
# fork, no lock, no write, and no sidebar woken. Only a real TRANSITION pays the
# lock, the set-options and the ~100ms `refresh.sh force` sweep. A window switch
# that consumes a signal pays that sweep twice, since session-window-changed[0]
# forces its own: the two hooks are backgrounded, so hook[0]'s sweep can finish
# before the aggregate is even rewritten and cannot be relied on.
#
# The aggregate is a CACHE, so every path that can invalidate it must lead back
# here: writes (mark/clear), the visit that consumes a signal, AND `reconcile`,
# fired from the window-layout-changed dispatcher when a pane — possibly the one
# holding the state — disappears. Nothing re-derives it on a timer.
#
# Usage: agent_status.sh <subcommand> [target] [json]
#   working|attention|done  mark [pane_id | $TMUX_PANE]
#   clear                   unset that pane's state (SessionEnd hook)
#   visited <window|pane>   bell semantics: you looked, so done AND attention are
#                           consumed for every pane in the window; working stays.
#                           Wired to session-window-changed[2] (and, when
#                           focus-events is on, pane-focus-in[1]) with
#                           #{window_id}.
#   reconcile <window|pane> re-derive the window aggregate from the panes that
#                           still EXIST. Wired into layout_changed.sh.
#   codex-notify [--pane <id>] <json>
#                           adapter for codex's `notify` program: maps the JSON
#                           payload (last CLI arg) onto done/attention.
set -euo pipefail

# Outside tmux entirely: exit before touching anything. This is a hard safety
# rule, not just an optimization — with $TMUX unset the tmux client would
# connect to the DEFAULT socket, i.e. some unrelated live server, and start
# writing options into whatever window happened to be current there.
[ -n "${TMUX:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

CMD="${1:-}"
[ -n "$CMD" ] || exit 0

# The master switch gates only the subcommands that RAISE a signal. clear,
# visited and reconcile exclusively REMOVE state, and they must keep working
# while the switch is off: gating them too meant flipping the switch mid-session
# FROZE whatever was on screen (a bell-red "attention" row with no user-reachable
# way to clear it). Hiding is render's job — render.sh checks the same option in
# its list-windows format, so "off" stops the feature being seen as well as
# being raised, and the clearing paths keep the stored state from getting stuck.
case "$CMD" in
    working|attention|done|codex-notify)
        [ "$(get_tmux_option "$AGENT_STATUS_OPTION" "$DEFAULT_AGENT_STATUS")" = "on" ] || exit 0
        ;;
esac

TAB="$(printf '\t')"
US=$'\x1f'   # field separator for the multi-field display-message read

# Epoch seconds, fetched at most once and only when something is actually
# written: `visited` runs on every window switch and must not pay a fork to
# discover it has nothing to do.
NOW=""
set_now() { [ -n "$NOW" ] || NOW="$(date +%s)"; }

# tmux server pid, read out of $TMUX ("socket_path,server_pid,session_id") —
# same answer as `display-message -p '#{pid}'` with no fork. Only used to
# namespace the per-window lock so window ids reused across servers (@0, @1, …)
# can't share, and leak, a lock. A comma in the socket path is the one case the
# cheap parse gets wrong, so fall back when it isn't a number.
SERVER_PID="${TMUX#*,}"; SERVER_PID="${SERVER_PID%%,*}"
case "$SERVER_PID" in
    ''|*[!0-9]*) SERVER_PID="$(tmux display-message -p '#{pid}' 2>/dev/null || true)" ;;
esac

# state -> rank; anything else ranks 0 ("no state"). The single definition of
# the precedence attention > working > done.
rank_of() {
    case "$1" in
        attention) RANK=3 ;;
        working)   RANK=2 ;;
        done)      RANK=1 ;;
        *)         RANK=0 ;;
    esac
}

# Re-derive window $1's aggregate from its panes and write it. Nudges refresh.sh
# ONLY on a real change, so the common case (an agent re-asserting "working" on
# every prompt) never wakes a sidebar.
#
# DEAD panes are skipped: with remain-on-exit on, a pane whose agent died stays
# in the window holding its last state, and the row would keep spinning for a
# process that no longer exists.
recompute_window_locked() {
    local wid="$1" dead st since best=0 bestsince="" newstate="" newsince="" oldstate oldsince
    while IFS="$TAB" read -r dead st since; do
        [ "$dead" = "1" ] && continue
        rank_of "$st"
        [ "$RANK" -eq 0 ] && continue
        case "$since" in ''|*[!0-9]*|0) set_now; since="$NOW" ;; esac
        if [ "$RANK" -gt "$best" ]; then
            best="$RANK"; bestsince="$since"
        elif [ "$RANK" -eq "$best" ] && [ "$since" -lt "$bestsince" ]; then
            bestsince="$since"
        fi
    done <<< "$(tmux list-panes -t "$wid" \
        -F "#{?pane_dead,1,0}${TAB}#{?${AGENT_PANE_OPTION},#{${AGENT_PANE_OPTION}},-}${TAB}#{?${AGENT_PANE_SINCE_OPTION},#{${AGENT_PANE_SINCE_OPTION}},0}" \
        2>/dev/null)"

    case "$best" in
        3) newstate="attention" ;;
        2) newstate="working" ;;
        1) newstate="done" ;;
        *) newstate="" ;;
    esac
    if [ -n "$newstate" ]; then newsince="$bestsince"; fi

    oldstate="$(get_window_option "$wid" "$AGENT_OPTION" "")"
    oldsince="$(get_window_option "$wid" "$AGENT_SINCE_OPTION" "")"
    if [ "$newstate" = "$oldstate" ] && [ "$newsince" = "$oldsince" ]; then
        return 0
    fi

    if [ -n "$newstate" ]; then
        # `since` FIRST: the two set-options are separate round-trips, and a
        # render tick landing between them must never see a state with no since
        # (it would date the row from the epoch — "working · 496118h51m").
        set_window_option "$wid" "$AGENT_SINCE_OPTION" "$newsince"
        set_window_option "$wid" "$AGENT_OPTION" "$newstate"
    else
        unset_window_option "$wid" "$AGENT_OPTION"
        unset_window_option "$wid" "$AGENT_SINCE_OPTION"
    fi
    # The sidebar nudge is the caller's job, AFTER the lock is dropped: it is a
    # ~100ms sweep, and holding a lock across it would serialize agents that
    # only ever wanted to write one option.
    CHANGED=1
}

# Serialize the read-modify-write above. Two hooks firing at once (pane A's turn
# ends while pane B asks for permission) can otherwise interleave list-panes and
# set-option so that the loser's stale snapshot lands last. The aggregate is a
# cache with no reconciliation timer, so a wrong value would simply stay wrong.
AGENT_LOCK=""
CHANGED=0
recompute_window() {
    local wid="$1" lock held=0 tries=0 rc=0
    CHANGED=0
    lock="${TMPDIR:-/tmp}/sidetabs_agent_${SERVER_PID}_${wid//[^a-zA-Z0-9]/_}"
    while [ "$tries" -lt 12 ]; do
        if mkdir "$lock" 2>/dev/null; then held=1; break; fi
        tries=$((tries + 1))
        sleep 0.02
    done
    if [ "$held" = "0" ]; then
        # ~240ms is more than ten times the critical section: the holder was
        # almost certainly killed mid-write, so take the lock rather than either
        # spin forever or skip the update.
        rmdir "$lock" 2>/dev/null || true
        if mkdir "$lock" 2>/dev/null; then held=1; fi
    fi
    if [ "$held" = "1" ]; then
        AGENT_LOCK="$lock"
        trap 'rmdir "$AGENT_LOCK" 2>/dev/null || true' EXIT
    fi
    recompute_window_locked "$wid" || rc=$?
    if [ "$held" = "1" ]; then
        trap - EXIT
        rmdir "$lock" 2>/dev/null || true
        AGENT_LOCK=""
    fi
    if [ "$CHANGED" = "1" ]; then "$CURRENT_DIR/refresh.sh" force || true; fi
    return "$rc"
}

clear_pane_state() {
    unset_pane_option "$1" "$AGENT_PANE_OPTION"
    unset_pane_option "$1" "$AGENT_PANE_SINCE_OPTION"
    unset_pane_option "$1" "$AGENT_PANE_PREV_OPTION"
    unset_pane_option "$1" "$AGENT_PANE_PREV_SINCE_OPTION"
}

# Set pane $1 to state $2. Re-asserting the same state is a no-op on `since`:
# the elapsed time the sidebar shows is "how long has it been like this", so an
# agent hammering UserPromptSubmit must not keep resetting the clock.
#
# One display-message answers everything this needs: the window, whether you are
# looking at it, and the pane's current/displaced state.
mark_pane() {
    local pane="$1" state="$2" info wid wactive attached cur cursince prev
    info="$(tmux display-message -p -t "$pane" \
        "#{window_id}${US}#{window_active}${US}#{session_attached}${US}#{${AGENT_PANE_OPTION}}${US}#{${AGENT_PANE_SINCE_OPTION}}${US}#{${AGENT_PANE_PREV_OPTION}}" \
        2>/dev/null)" || info=""
    IFS="$US" read -r wid wactive attached cur cursince prev <<< "$info" || true
    [ -n "${wid:-}" ] || exit 0

    # Bell semantics at the SOURCE. tmux never raises window_bell_flag on the
    # window you are already on, and a signal raised on the tab you are watching
    # has the same problem here: no window change follows, so nothing would ever
    # consume it and the row stays lit forever. Consuming it the instant it is
    # raised is exactly what a visit would have done. `session_attached` is part
    # of the test on purpose — with nobody attached, nobody is looking.
    if [ "$wactive" = "1" ] && [ -n "${attached:-}" ] && [ "$attached" != "0" ]; then
        case "$state" in
            attention)
                # A visit restores the `working` that attention displaced, so
                # "raise then consume" means: change nothing at all.
                return 0
                ;;
            done)
                # done ends the turn, so the consumed result is "no state" — the
                # spinner has to stop even though the ✓ never appears.
                if [ -n "${cur:-}" ]; then
                    clear_pane_state "$pane"
                    recompute_window "$wid"
                fi
                return 0
                ;;
        esac
    fi

    if [ "${cur:-}" != "$state" ]; then
        set_now
        if [ "$state" = "attention" ] && [ "${cur:-}" = "working" ]; then
            # Remember what attention displaced. A pane holds ONE state, so
            # without this the visit that consumes the attention leaves the pane
            # blank for the rest of the turn — the agent goes back to work and
            # the tab shows nothing, contradicting "working survives a visit".
            case "${cursince:-}" in ''|*[!0-9]*|0) cursince="$NOW" ;; esac
            set_pane_option "$pane" "$AGENT_PANE_PREV_OPTION" "$cur"
            set_pane_option "$pane" "$AGENT_PANE_PREV_SINCE_OPTION" "$cursince"
        elif [ -n "${prev:-}" ]; then
            # Any other transition ends the displaced state's life.
            unset_pane_option "$pane" "$AGENT_PANE_PREV_OPTION"
            unset_pane_option "$pane" "$AGENT_PANE_PREV_SINCE_OPTION"
        fi
        set_pane_option "$pane" "$AGENT_PANE_SINCE_OPTION" "$NOW"
        set_pane_option "$pane" "$AGENT_PANE_OPTION" "$state"
    fi
    recompute_window "$wid"
}

clear_pane() {
    local pane="$1" wid
    wid="$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)" || wid=""
    [ -n "$wid" ] || exit 0
    clear_pane_state "$pane"
    recompute_window "$wid"
}

# The pane a hook-invoked run inherits. Hooks/`run-shell` do NOT export
# TMUX_PANE (only $TMUX), which is exactly why every tmux-side caller passes an
# explicit target; agent processes DO inherit it from their shell.
default_pane() { printf '%s' "${TMUX_PANE:-}"; }

# Window id for a target that is already a window id (what the hooks pass), or
# whatever window a pane/other target resolves to. Sets WID.
resolve_wid() {
    case "$1" in
        @[0-9]*) WID="$1" ;;
        *) WID="$(tmux display-message -p -t "$1" '#{window_id}' 2>/dev/null)" || WID="" ;;
    esac
}

case "$CMD" in
working|attention|done)
    PANE="${2:-$(default_pane)}"
    [ -n "$PANE" ] || exit 0
    mark_pane "$PANE" "$CMD"
    ;;

clear)
    PANE="${2:-$(default_pane)}"
    [ -n "$PANE" ] || exit 0
    clear_pane "$PANE"
    ;;

visited)
    # Bell semantics: looking at the tab consumes the signal. `done` and
    # `attention` both exist to pull your eye, so both die on a visit; `working`
    # is a fact about the world, not a notification, so it survives — including
    # when it was the state `attention` displaced mid-turn.
    TARGET="${2:-$(default_pane)}"
    [ -n "$TARGET" ] || exit 0
    resolve_wid "$TARGET"
    [ -n "$WID" ] || exit 0
    # Cheap gate: this runs on EVERY window switch (and every pane focus change
    # when focus-events is on). One show-option answers "does this window hold
    # any agent state at all"; for almost every window it does not, and we stop
    # here — before the list-panes and before the epoch fork.
    [ -n "$(get_window_option "$WID" "$AGENT_OPTION" "")" ] || exit 0
    changed=0
    while IFS="$TAB" read -r pid pstate pprev pprevsince; do
        [ -n "$pid" ] || continue
        case "$pstate" in
            attention)
                if [ "$pprev" = "working" ]; then
                    # Put back what attention displaced, with ITS original
                    # clock, instead of blanking the pane.
                    set_now
                    case "$pprevsince" in ''|*[!0-9]*|0) pprevsince="$NOW" ;; esac
                    set_pane_option "$pid" "$AGENT_PANE_SINCE_OPTION" "$pprevsince"
                    set_pane_option "$pid" "$AGENT_PANE_OPTION" "working"
                    unset_pane_option "$pid" "$AGENT_PANE_PREV_OPTION"
                    unset_pane_option "$pid" "$AGENT_PANE_PREV_SINCE_OPTION"
                else
                    clear_pane_state "$pid"
                fi
                changed=1
                ;;
            done)
                clear_pane_state "$pid"
                changed=1
                ;;
        esac
    done <<< "$(tmux list-panes -t "$WID" \
        -F "#{pane_id}${TAB}#{?${AGENT_PANE_OPTION},#{${AGENT_PANE_OPTION}},-}${TAB}#{?${AGENT_PANE_PREV_OPTION},#{${AGENT_PANE_PREV_OPTION}},-}${TAB}#{?${AGENT_PANE_PREV_SINCE_OPTION},#{${AGENT_PANE_PREV_SINCE_OPTION}},0}" 2>/dev/null)"
    # Skip the recompute (and its list-panes) when nothing was consumed: a
    # window can hold a `working` aggregate for hours, and every switch to it
    # would otherwise pay the full sweep.
    if [ "$changed" = "1" ]; then recompute_window "$WID"; fi
    ;;

reconcile)
    # A pane holding agent state can simply disappear — kill-pane, a crashed
    # agent, a shell that exited. Its pane options die with it, but the window
    # aggregate is a cache that only the write paths ever rewrite, so the row
    # would keep spinning a live-looking spinner on a window that no longer
    # contains a working agent (and `working` outranks `done`, so a later finish
    # in a sibling pane could not surface either). Wired into layout_changed.sh,
    # the existing window-layout-changed dispatcher, so it costs no extra hook.
    TARGET="${2:-$(default_pane)}"
    [ -n "$TARGET" ] || exit 0
    resolve_wid "$TARGET"
    [ -n "$WID" ] || exit 0
    # Same cheap gate as `visited`: layout changes are frequent (every split,
    # every resize) and almost never concern a window holding agent state.
    [ -n "$(get_window_option "$WID" "$AGENT_OPTION" "")" ] || exit 0
    recompute_window "$WID"
    ;;

codex-notify)
    # codex invokes `notify` as: <program> <configured args…> <json>. So the
    # payload is always the LAST argument.
    JSON=""
    for _a in "$@"; do JSON="$_a"; done
    if [ "$JSON" = "codex-notify" ]; then exit 0; fi   # invoked with no payload
    PANE="$(default_pane)"
    # An explicit flag, NOT "if there are 3+ arguments": codex's `notify` is an
    # array, so a user adding their own argument to it is expected — an argc
    # rule would read that argument as a pane id and silently write the state to
    # whatever window the session happens to be on.
    if [ "${2:-}" = "--pane" ]; then PANE="${3:-}"; fi
    [ -n "$PANE" ] || exit 0
    # Deliberately no jq dependency: the payload is a flat object and we only
    # need one string field. bash's own regex engine takes the FIRST "type" pair
    # with no pipeline at all — a `grep … | head -1` under `set -o pipefail`
    # loses a correctly parsed type whenever head exits first and grep dies of
    # SIGPIPE, and dropping a real signal is exactly what this must not do.
    TYPE=""
    TYPE_RE='"type"[[:space:]]*:[[:space:]]*"([^"]*)"'
    if [[ "$JSON" =~ $TYPE_RE ]]; then TYPE="${BASH_REMATCH[1]}"; fi
    case "$TYPE" in
        agent-turn-complete) mark_pane "$PANE" done ;;
        # codex's approval/permission events are not a stable, documented set,
        # so match the shape rather than an exact list. Anything unrecognized is
        # a silent no-op — a wrong signal is worse than no signal.
        *approval*|*permission*|*confirm*) mark_pane "$PANE" attention ;;
        *) exit 0 ;;
    esac
    ;;
esac

exit 0
