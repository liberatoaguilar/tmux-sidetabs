#!/usr/bin/env bash
# The bottom session strip: one pill per session, coloured by what is actually
# happening in it, joined by solid arrows. Opt-in via @sidetabs-session-strip.
#
# THIS SCRIPT GENERATES A LITERAL status-left AND INSTALLS IT. It is not a
# template and there is no #{S:} loop, which is the whole point:
#
#   A #{S:} loop cannot see its own neighbours, and a powerline separator needs
#   BOTH of the colours it sits between. The previous (hand-written, outside
#   this repo) strip worked around that by keeping a per-session @strip_next
#   option naming the successor, refreshed by hooks that existed only in a
#   RUNNING server — so after a machine restart the options were stale and the
#   separators rendered with the wrong colours until something happened to
#   rewrite them. That is the reported bug. A generator knows every neighbour
#   directly, so no neighbour bookkeeping exists to go stale.
#
# ONE STRING PER SESSION. status-left is a per-session option (verified on tmux
# 3.6b: `set-option -t A status-left AAA` and `-t B ... BBB` hold
# independently), and a session's string is only ever rendered by clients
# attached to THAT session. So "is this pill the current session" is known
# statically at generation time and no #{?#{==:...,#{client_session}}} ternary
# survives into the output — which is also how two clients on two different
# sessions each see their own session highlighted.
#
# Usage: strip.sh [force]
#   force  skip the 100ms debounce. Required for events whose result must never
#          be dropped (a resurrect restore, an agent attention transition):
#          nothing re-renders the strip on a timer, so a swallowed final event
#          would leave the wrong strip on screen until the next unrelated one.
#
# IT FITS, IT DOES NOT CLIP. tmux truncates a status line by HARD CUT at the
# client edge — no ellipsis, no marker, and a 2-column glyph that does not fit
# is dropped whole — so a clipped strip is indistinguishable from a short one
# and you cannot tell that three sessions fell off the right-hand edge. Section
# 6b therefore fits the strip to a per-session width budget by shedding detail
# in a fixed, predictable order (marker, then right pills, then left pills, then
# name truncation, then initials, then colour blocks, then a floor that still
# names the session you are in and counts the ones it could not show).
#
# Deliberately NOT `set -e`: this runs from `run-shell` hooks, and a non-zero
# exit makes tmux surface the failure by dropping the pane into view-mode (the
# "[0/0]" overlay) — refresh.sh carries the same note for the same reason.
# Errors are handled explicitly instead, and the file ends with `exit 0`.
#
# HOUSE RULE: a failed generation is a NO-OP, never a clear. The whole batch is
# built in memory first and only handed to tmux once every session produced a
# string; anything that goes wrong on the way returns early and leaves the
# status line exactly as it was, rather than installing a truncated one.
set -uo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

MODE="${1:-}"

# --- 1. master switch --------------------------------------------------------
# Off is the default, and while off this returns before touching a single tmux
# option: the plugin ships TPM install instructions, so an unasked-for status
# bar takeover would be a hostile default. Note the switch is checked BEFORE the
# debounce stamp is written, so an off strip leaves no trace at all.
[ "$(get_tmux_option '@sidetabs-session-strip' "$DEFAULT_SESSION_STRIP")" = "on" ] || exit 0

# --- 2. debounce -------------------------------------------------------------
# Same shape as refresh.sh's: a global epoch-ms stamp, a `force` escape, and a
# stamp written even by a forced run so trailing events in a burst coalesce into
# it. A resurrect restore creating eight sessions fires eight session-created
# hooks; without this the strip would be regenerated eight times over.
now="$(now_ms)"
case "$now" in ''|*[!0-9]*) exit 0 ;; esac
if [ "$MODE" != "force" ]; then
    last="$(get_tmux_option "$STRIP_LAST_OPTION" "0")"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ "$((now - last))" -lt "$STRIP_DEBOUNCE_MS" ]; then
        exit 0
    fi
fi
set_tmux_option "$STRIP_LAST_OPTION" "$now"

TAB="$(printf '\t')"
US="$(printf '\x1f')"
# RS, the record separator for the reserve measurement in section 5c. A
# status-right's value can legitimately contain a newline, so records there
# cannot be newline-delimited the way every other tmux -F loop in this file is.
RS="$(printf '\x1e')"
NL="
"
# U+E0B0, the SOLID powerline arrow. Spelled as bytes: macOS ships bash 3.2,
# where $'\uXXXX' is not a thing (it arrived in 4.2). This is the glyph for a
# real colour BOUNDARY and it is deliberately not configurable; the
# same-background separator (SEP_GLYPH, read in section 3) is.
ARROW="$(printf '\xee\x82\xb0')"

# --- 3. theme ----------------------------------------------------------------
# Every colour value is lowercased in ONE tr pass rather than one per value.
#
# WHY LOWERCASE MATTERS (verified, and not obvious): tmux's format parser treats
# `#` followed by certain UPPERCASE letters as a legacy single-character alias —
# #D is pane_id, #S session_name, #W window_name, #H hostname, and so on. A hex
# colour like #D08770 therefore expands to "<pane_id>08770" the moment the
# string is expanded a second time, silently corrupting the style. Lowercase
# letters have no such alias, so #d08770 survives. tmux colour NAMES ("blue",
# "brightblack") are lowercase already, so lowercasing the lot is safe.
theme="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$(get_tmux_option '@sidetabs-strip-bell-bg'    "$DEFAULT_STRIP_BELL_BG")" \
    "$(get_tmux_option '@sidetabs-strip-bell-fg'    "$DEFAULT_STRIP_BELL_FG")" \
    "$(get_tmux_option '@sidetabs-strip-current-bg' "$DEFAULT_STRIP_CURRENT_BG")" \
    "$STRIP_CURRENT_FG" \
    "$(get_tmux_option '@sidetabs-strip-idle-bg'    "$DEFAULT_STRIP_IDLE_BG")" \
    "$(get_tmux_option '@sidetabs-strip-idle-fg'    "$DEFAULT_STRIP_IDLE_FG")" \
    "$(get_tmux_option '@sidetabs-strip-bg'         "$DEFAULT_STRIP_BG")" \
    "$(get_tmux_option '@sidetabs-strip-sep-fg'     "$DEFAULT_STRIP_SEP_FG")" \
    "$(get_tmux_option '@sidetabs-flag-fg'          '#2e3440')" \
    | tr '[:upper:]' '[:lower:]')"
{
    read -r BELL_BG; read -r BELL_FG
    read -r CUR_BG;  read -r CUR_FG
    read -r IDLE_BG; read -r IDLE_FG
    read -r STRIP_BG; read -r SEP_FG
    read -r FLAG_FG
} <<< "$theme"

MARKER="$(get_tmux_option '@sidetabs-strip-current-marker' "$DEFAULT_STRIP_MARKER")"
# The glyph drawn where two adjacent pills SHARE a background. Read outside the
# theme block above on purpose: that block exists to lowercase colour values,
# and running `tr '[:upper:]' '[:lower:]'` over a multibyte glyph is a locale
# question nobody needs to have. One display column, exactly like ARROW, so the
# width cascade's "a join costs 1" holds whichever of the two is emitted.
SEP_GLYPH="$(get_tmux_option '@sidetabs-strip-sep-glyph' "$DEFAULT_STRIP_SEP_GLYPH")"

# The palette is shared with window flags on purpose (a session colour and a
# window flag set to slot 3 look the same), and both store an INDEX, so
# reordering @sidetabs-flag-colors recolours everything already set.
palette="$(get_tmux_option '@sidetabs-flag-colors' "$DEFAULT_FLAG_COLORS" \
    | tr '[:upper:]' '[:lower:]')"
# Unquoted on purpose — word splitting is how the space-separated list becomes
# an array. Palette entries never contain spaces.
# shellcheck disable=SC2206
PALETTE=($palette)
NPAL="${#PALETTE[@]}"

# --- 3b. edge pills ------------------------------------------------------
# Content pinned to either side of the strip — system load, memory, disk, a
# clock, anything else — each its own individually coloured pill.
#
# NUMBERED options (@sidetabs-strip-left-1, -2, ...), not a delimited list. A
# pill's VALUE is free-form tmux FORMAT syntax — typically a #(shell command),
# sometimes a #{...} or a strftime %-spec — and any of those can legitimately
# contain "|" or other characters a delimiter would have to escape around. A
# numbered option needs no escaping at all: "#(foo | bar)" simply cannot break
# the parse, because there is no delimiter for it to be confused with.
#
# Scanned 1..16 (a sane upper bound), stopping at the first gap. A side whose
# -1 is unset comes out of this with N=0, and section 7b/8 below skip writing
# that side's tmux option AT ALL — not even an unset — matching this file's
# house rule that an unconfigured path is a no-op, never a clear.
scan_side() {
    local prefix="$1" i=1 val bg fg
    N=0; VALS=(); BGS=(); FGS=()
    while [ "$i" -le 16 ]; do
        val="$(get_tmux_option "@sidetabs-strip-${prefix}-${i}" "")"
        [ -n "$val" ] || break
        # Per-pill colour, falling back to the same idle theme an unflagged
        # session pill already uses — a "sensible default" that also means an
        # uncoloured edge pill blends in rather than clashing with the strip.
        bg="$(get_tmux_option "@sidetabs-strip-${prefix}-${i}-bg" "$IDLE_BG")"
        fg="$(get_tmux_option "@sidetabs-strip-${prefix}-${i}-fg" "$IDLE_FG")"
        N=$((N + 1))
        VALS[$N]="$val"
        # Lowercased for the same reason the theme block is (fact 7): #D08770
        # corrupts under a second format expansion, #d08770 does not.
        BGS[$N]="$(printf '%s' "$bg" | tr '[:upper:]' '[:lower:]')"
        FGS[$N]="$(printf '%s' "$fg" | tr '[:upper:]' '[:lower:]')"
        i=$((i + 1))
    done
}
# scan_side fills the globals N/VALS/BGS/FGS; copied out by hand (not
# `arr=("${VALS[@]}")`, which would silently re-index from 0) so LEFT_*/
# RIGHT_* keep the same 1-based indexing every array in this file uses.
scan_side left
LEFT_N="$N"; LEFT_VAL=(); LEFT_BG=(); LEFT_FG=()
i=1
while [ "$i" -le "$LEFT_N" ]; do
    LEFT_VAL[$i]="${VALS[$i]}"; LEFT_BG[$i]="${BGS[$i]}"; LEFT_FG[$i]="${FGS[$i]}"
    i=$((i + 1))
done
scan_side right
RIGHT_N="$N"; RIGHT_VAL=(); RIGHT_BG=(); RIGHT_FG=()
i=1
while [ "$i" -le "$RIGHT_N" ]; do
    RIGHT_VAL[$i]="${VALS[$i]}"; RIGHT_BG[$i]="${BGS[$i]}"; RIGHT_FG[$i]="${FGS[$i]}"
    i=$((i + 1))
done

# A pill's rendered width cannot be known in bash when its value is a tmux
# FORMAT rather than literal text. Verified against a scratch server: a
# #(shell) job is scheduled ASYNCHRONOUSLY, and `display-message -p
# '#{T:@opt}'` on an option holding one answers empty even after the job has
# had time to finish, because a one-off display-message is not the
# status-line context tmux schedules the job's redraw against — there is no
# synchronous way to ask tmux "how wide will this render". #{...} references
# and strftime %-specs are lumped in with the same fallback rather than
# threading a second tmux round-trip through a temp option just for those.
#
# So: a literal pill (no specials) is measured exactly, off its raw character
# count — same convention a session name uses. Anything with a special gets a
# fixed, generous placeholder instead, sized so status-left/-right-length
# stays big enough not to clip a pill that renders longer than this guess.
# This is deliberately NOT the same thing as the reserve computed for an
# UNOWNED side in section 5c: that side is measured for real (its value is
# already fully expanded by the time we see it), while these are OUR pills,
# whose values we hold only as unexpanded format source.
DYNAMIC_PILL_WIDTH="$STRIP_JOB_RESERVE"
pill_display_width() {
    case "$1" in
        *'#('*|*'#{'*|*%[A-Za-z]*) printf '%s' "$DYNAMIC_PILL_WIDTH" ;;
        *) printf '%s' "${#1}" ;;
    esac
}

# --- 3c. edge-pill costs, precomputed ----------------------------------------
# A pill costs   1 (pad) + body + 1 (pad) + 1 (its own trailing arrow).
# The arrow belongs to the pill on its LEFT, so dropping any pill removes
# exactly its own cost and leaves every other pill's cost untouched — which is
# what makes the cumulative sums below correct however many are sacrificed.
#
# Measured ONCE here rather than inside the cascade: pill_display_width forks a
# subshell, and the cascade evaluates up to ~25 candidate states per session.
LEFT_COST=(); RIGHT_COST=()
# LEFT_SUFFIX[j] = total cost of left pills j..LEFT_N, i.e. the width left after
# the j-1 OUTERMOST (leftmost) ones have been dropped. LEFT_SUFFIX[LEFT_N+1]=0.
LEFT_SUFFIX=()
# RIGHT_PREFIX[j] = total cost of right pills 1..j, i.e. the width left after
# the RIGHT_N-j OUTERMOST (rightmost) ones have been dropped. RIGHT_PREFIX[0]=0.
RIGHT_PREFIX=()
i=1
while [ "$i" -le "$LEFT_N" ]; do
    LEFT_COST[$i]=$(($(pill_display_width "${LEFT_VAL[$i]}") + 3))
    i=$((i + 1))
done
LEFT_SUFFIX[$((LEFT_N + 1))]=0
i="$LEFT_N"
while [ "$i" -ge 1 ]; do
    LEFT_SUFFIX[$i]=$((${LEFT_COST[$i]} + ${LEFT_SUFFIX[$((i + 1))]}))
    i=$((i - 1))
done
RIGHT_PREFIX[0]=0
i=1
while [ "$i" -le "$RIGHT_N" ]; do
    RIGHT_COST[$i]=$(($(pill_display_width "${RIGHT_VAL[$i]}") + 3))
    RIGHT_PREFIX[$i]=$((${RIGHT_PREFIX[$((i - 1))]} + ${RIGHT_COST[$i]}))
    i=$((i + 1))
done

# --- 3d. cascade inputs ------------------------------------------------------
# Every one of these is validated to a number here rather than at the point of
# use: an option holding garbage must degrade to the documented default, never
# make the arithmetic below evaluate a non-number (which under `set -u` would
# abort the generation and leave the strip stale).
NAME_MAX="$(get_tmux_option '@sidetabs-strip-name-max' "$DEFAULT_STRIP_NAME_MAX")"
case "$NAME_MAX" in ''|*[!0-9]*) NAME_MAX=0 ;; esac

ASSUMED_WIDTH="$(get_tmux_option '@sidetabs-strip-assumed-width' "$DEFAULT_STRIP_ASSUMED_WIDTH")"
case "$ASSUMED_WIDTH" in ''|*[!0-9]*|0) ASSUMED_WIDTH="$DEFAULT_STRIP_ASSUMED_WIDTH" ;; esac

RESERVE_OPT="$(get_tmux_option '@sidetabs-strip-reserve' "$DEFAULT_STRIP_RESERVE")"

# TEST SEAM. Exercising the cascade for real would mean attaching terminals of
# a dozen different widths; this forces the budget for every session instead, so
# a test can walk the whole ladder against one detached scratch server. It is an
# ENVIRONMENT variable rather than a tmux option deliberately: a stray option
# would persist in a live server and silently mis-fit the user's real strip,
# while an env var reaches only the one `run-shell` that set it.
TEST_WIDTH="${SIDETABS_STRIP_TEST_WIDTH:-}"
case "$TEST_WIDTH" in ''|*[!0-9]*|0) TEST_WIDTH="" ;; esac

# --- 4. enumerate sessions in creation order ---------------------------------
# STABLE CREATION ORDER, which is session_id order — `list-sessions` sorts by
# NAME, so a rename would reshuffle the whole strip under the user. The id is
# "$N"; strip the "$" so `sort -n` sees a plain number (ids are not contiguous,
# so a lexical sort would put $10 between $1 and $2).
#
# The session's colour rides this same call: @sidetabs_sflag interpolates in the
# format, so reading it costs nothing extra. It is prefixed with a literal "f"
# and the NAME is last, for two reasons that are easy to trip over and that
# flag_store.sh documents at length: `read` with IFS=TAB treats tab as IFS
# *whitespace*, so an empty middle field silently shifts every field after it
# (the "f" makes the field non-empty whether or not the option is set), and a
# session name in last position is handed to one variable whole.
sess="$(tmux list-sessions -F "#{session_id}${TAB}f#{$SFLAG_OPTION}${TAB}#{session_name}" 2>/dev/null \
    | sed 's/^\$//' | sort -n)"
# A live server always has at least one session, so an empty answer means the
# tmux call failed, not that there is nothing to draw. No-op, never a clear.
[ -n "$sess" ] || exit 0

n=0
SIDS=(); SNAMES=(); SFLAGS=(); BELLS=(); ATTNS=(); NAMELEN=()
IDMAP="$US"
while IFS="$TAB" read -r sid fval sname; do
    [ -n "$sid" ] || continue
    case "$sid" in *[!0-9]*) continue ;; esac
    n=$((n + 1))
    SIDS[$n]="$sid"
    SNAMES[$n]="$sname"
    # Width is counted in CHARACTERS off the RAW name, matching render.sh's
    # convention (${#label}, ${label:0:avail}) and section 7's escaping: "#"
    # is doubled for tmux but still occupies one column. A CJK name will
    # misalign here exactly as a CJK window name misaligns in the sidebar
    # today — a known limitation, not this cascade's problem to solve.
    NAMELEN[$n]="${#sname}"
    SFLAGS[$n]="${fval#f}"
    BELLS[$n]=0
    ATTNS[$n]=0
    # "\x1f<id>=<slot>\x1f" — a lookup table for the window pass below, since
    # bash 3.2 has no associative arrays. Both delimiters are present so a
    # search for "\x1f1=" cannot match inside "\x1f21=".
    IDMAP="${IDMAP}${sid}=${n}${US}"
done <<< "$sess"
[ "$n" -gt 0 ] || exit 0

# session id -> slot index in the arrays above; sets IDX, returns 1 if unknown.
sess_slot() {
    local rest="${IDMAP#*${US}$1=}"
    [ "$rest" = "$IDMAP" ] && return 1
    IDX="${rest%%${US}*}"
    case "$IDX" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# --- 5. aggregate bell + agent attention, in ONE call ------------------------
# #{session_bell_flag} IS BROKEN ON TMUX 3.6b AND ALWAYS RETURNS 0. Upstream's
# format_cb_session_bell_flag has an RB_FOREACH whose body returns
# unconditionally on the first iteration, so only the lowest-index window of the
# session is ever examined. #{session_activity_flag} and #{session_silence_flag}
# are worse still: they test the format TARGET's winlink rather than the loop
# variable, so they merely mirror the per-window flag. Do not reach for any of
# the three. Measured: a session whose window 2 was ringing reported
# session_bell_flag=0 while #{session_alerts} said "1!".
#
# The per-window #{window_bell_flag} IS correct, so the rollup happens here in
# bash. The same call carries the window's agent aggregate, so bell and
# attention cost one tmux invocation between them rather than one each.
#
# Agent attention is invisible to tmux's own alert machinery — agent_status.sh
# mimics bell semantics rather than using them (see its comment at the
# mark_pane bell-semantics block) — which is why agent_status.sh has to call
# this script itself on an attention transition.
agent_on="$(get_tmux_option "$AGENT_STATUS_OPTION" "$DEFAULT_AGENT_STATUS")"
wins="$(tmux list-windows -a \
    -F "#{session_id}${TAB}#{window_bell_flag}${TAB}a#{$AGENT_OPTION}" 2>/dev/null)"
# Same reasoning as the empty session list: every live server has a window, so
# nothing here means the call failed. Generating a strip that claims no session
# is ringing would be worse than leaving the previous one up.
[ -n "$wins" ] || exit 0
while IFS="$TAB" read -r wsid wbell wagent; do
    [ -n "$wsid" ] || continue
    wsid="${wsid#\$}"
    sess_slot "$wsid" || continue
    [ "$wbell" = "1" ] && BELLS[$IDX]=1
    # The agent master switch gates the strip exactly as it gates render.sh:
    # "off" must stop stored state being SEEN, not just being raised, or
    # flipping the switch mid-session would freeze whatever was on screen.
    if [ "$agent_on" = "on" ] && [ "${wagent#a}" = "attention" ]; then
        ATTNS[$IDX]=1
    fi
done <<< "$wins"

# --- 5b. per-session width budget --------------------------------------------
# The budget is the width of the NARROWEST client attached to that session.
# Narrowest, because ONE string is generated per session (status-left is a
# per-session option) and every client on it renders that same string: fitting
# the widest would clip the narrowest, which is precisely the invisible failure
# this whole section exists to prevent. Two clients on one session therefore
# share the narrowest budget — accepted, and recorded as a known limitation.
#
# A session with NO attached client still gets a strip — it has to, or attaching
# would show whatever was generated when it last had one — budgeted at
# @sidetabs-strip-assumed-width.
BUDGETS=()
k=1
while [ "$k" -le "$n" ]; do BUDGETS[$k]=0; k=$((k + 1)); done
if [ -z "$TEST_WIDTH" ]; then
    # #{session_id} resolves in a CLIENT format because tmux's format_defaults
    # falls back to the client's own session when no session target was given.
    # #{client_session} (the NAME) is carried too, purely as a fallback for a
    # build where that does not hold: losing the mapping would silently push
    # every session onto the assumed width, which is the one failure mode that
    # would make the whole cascade untrustworthy. The name is LAST so a name
    # containing whitespace still arrives in one piece.
    clients="$(tmux list-clients -F "#{client_width}${TAB}#{session_id}${TAB}#{client_session}" 2>/dev/null)"
    while IFS="$TAB" read -r cw csid cname; do
        [ -n "$cw" ] || continue
        case "$cw" in *[!0-9]*) continue ;; esac
        [ "$cw" -gt 0 ] || continue
        csid="${csid#\$}"
        if ! sess_slot "$csid"; then
            IDX=0
            j=1
            while [ "$j" -le "$n" ]; do
                if [ "${SNAMES[$j]}" = "$cname" ]; then IDX="$j"; break; fi
                j=$((j + 1))
            done
            [ "$IDX" -ge 1 ] || continue
        fi
        if [ "${BUDGETS[$IDX]}" -eq 0 ] || [ "$cw" -lt "${BUDGETS[$IDX]}" ]; then
            BUDGETS[$IDX]="$cw"
        fi
    done <<< "$clients"
fi
k=1
while [ "$k" -le "$n" ]; do
    if [ -n "$TEST_WIDTH" ]; then
        BUDGETS[$k]="$TEST_WIDTH"
    elif [ "${BUDGETS[$k]}" -eq 0 ]; then
        BUDGETS[$k]="$ASSUMED_WIDTH"
    fi
    k=$((k + 1))
done

# --- 5c. reserve for a side the plugin does not own --------------------------
# The budget covers left + right + reserve COMBINED — it is one status line, not
# two independent ones.
#
# The plugin always owns status-left; it owns status-right only when at least
# one @sidetabs-strip-right-N is configured. An UNOWNED status-right is content
# somebody else put there (the user's clock, another plugin, or tmux's own
# default) and the cascade has no business dropping it — so it is measured and
# subtracted from the budget, never touched. Its stage in the ladder simply does
# not exist: with RIGHT_N=0 the stage-2 loop below is empty.
#
# ONE tmux call measures every session, because status-right is a per-session
# option and a session may well override the global. Both the RAW value and its
# expansion are read in the same format:
#
#   #{status-right}     the option verbatim, unexpanded
#   #{T:status-right}   fully expanded — #{...} resolved, strftime %-specs
#                       resolved, #[...] style runs still present (we strip
#                       those; they cost no columns), and any #(shell) job
#                       silently GONE. Verified on 3.6b: an option holding
#                       "#(echo hi) %H:%M" expands to " 11:36".
#
# That last point is why the job test runs on the RAW value: ticket 06 already
# established that #(shell) jobs are scheduled asynchronously and cannot be
# measured synchronously, and the expansion does not even leave a "#(" behind to
# notice. Records are RS-delimited, not newline-delimited, because a
# status-right may contain a newline; a US-delimited field split then avoids
# `read`'s IFS-whitespace collapsing entirely.
RESERVES=()
k=1
while [ "$k" -le "$n" ]; do RESERVES[$k]=0; k=$((k + 1)); done

# measure_reserve <raw> <expanded> -> RW, the columns to keep clear.
measure_reserve() {
    local raw="$1" exp="$2" s clean="" njobs=0
    s="$exp"
    while :; do
        case "$s" in *'#['*) ;; *) break ;; esac
        clean="${clean}${s%%'#['*}"
        s="${s#*'#['}"
        # A "]" inside a style value would terminate the style early for tmux
        # too, so cutting at the first one matches what tmux itself does.
        s="${s#*]}"
    done
    clean="${clean}${s}"
    # Newlines occupy no columns on the status line.
    clean="${clean//$NL/}"
    RW="${#clean}"
    s="$raw"
    while :; do
        case "$s" in *'#('*) ;; *) break ;; esac
        njobs=$((njobs + 1))
        s="${s#*'#('}"
    done
    # A job whose output tmux has already CACHED does appear in the expansion,
    # so its columns get counted twice: once measured, once allowed for. That is
    # the safe direction to be wrong in — over-reserving costs our own strip one
    # cascade stage, under-reserving overruns somebody else's content — and it
    # keeps the reserve stable rather than jumping about as jobs complete.
    if [ "$njobs" -gt 0 ]; then
        case "$RESERVE_OPT" in
            # "auto" (or anything non-numeric): what could be measured, plus a
            # generous allowance for each job that could not.
            ''|*[!0-9]*) RW=$((RW + njobs * STRIP_JOB_RESERVE)) ;;
            # An explicit number is the user telling us how wide their side
            # really renders; it replaces the estimate outright.
            *) RW="$RESERVE_OPT" ;;
        esac
    fi
}

if [ "$RIGHT_N" -eq 0 ]; then
    # One extra tmux invocation (~5ms), and only when the plugin does not own
    # the right side. It cannot be folded into section 4's list-sessions: a
    # status-right can contain anything at all, including tabs and newlines,
    # which would wreck that call's tab-delimited, name-last parse.
    recs="$(tmux list-sessions \
        -F "#{session_id}${US}#{status-right}${US}#{T:status-right}${RS}" 2>/dev/null)"
    # The format always emits its separators, so a live server cannot answer
    # empty here — that means the call failed. Generating a strip with no
    # reserve at all would overrun content the plugin does not own, so this is
    # a no-op like every other failed tmux call in this file.
    [ -n "$recs" ] || exit 0
    while IFS= read -r -d "$RS" rec; do
        rsid="${rec%%"$US"*}"
        # tmux ends every -F line with a newline, which lands at the FRONT of
        # the next RS-delimited record. The id never contains one, so
        # everything up to the last newline is that stray prefix.
        rsid="${rsid##*"$NL"}"
        rsid="${rsid#\$}"
        case "$rsid" in ''|*[!0-9]*) continue ;; esac
        sess_slot "$rsid" || continue
        rrest="${rec#*"$US"}"
        measure_reserve "${rrest%%"$US"*}" "${rrest#*"$US"}"
        RESERVES[$IDX]="$RW"
    done <<< "$recs"
fi

# --- 6. colour resolution ----------------------------------------------------
# resolve_pills <viewer slot>: fill PBG/PFG/PATTR for every pill, from the point
# of view of the session whose string is being generated. First match wins:
#
#   bell OR agent attention  ->  bell colours, bold
#   @sidetabs_sflag set      ->  palette[idx], @sidetabs-flag-fg, bold
#   is the current session   ->  current colours, bold
#   otherwise                ->  idle colours, nobold
#
# Same precedence the sidebar's window rows use, so a session pill and a window
# row never disagree about what matters most.
#
# DEGRADE[k] is set here too: 1 for an ORDINARY pill (no session colour, no
# bell, no agent attention), 0 for one carrying information. Cascade stages 5
# and 6 — the ones that shorten a name to an initial and then blank it to a bare
# colour block — may only touch an ordinary pill, so a pill you deliberately
# coloured, or one that is asking for your attention, is the LAST thing to lose
# its text rather than the first. It does not depend on which session is
# viewing, so it is computed once per generation like the rest of this pass.
PBG=(); PFG=(); PATTR=(); DEGRADE=(); MARK=0
resolve_pills() {
    local v="$1" k idx
    MARK=0
    k=1
    while [ "$k" -le "$n" ]; do
        idx="${SFLAGS[$k]}"
        # An index that is not a number, or that points past the end of a
        # palette shortened since the colour was set, means "no colour" — the
        # same reading flag_restore.sh and render.sh give it, rather than
        # indexing off the end of the array and painting nothing.
        case "$idx" in ''|*[!0-9]*) idx=0 ;; esac
        if [ "$idx" -gt "$NPAL" ]; then idx=0; fi

        if [ "${BELLS[$k]}" = "1" ] || [ "${ATTNS[$k]}" = "1" ]; then
            PBG[$k]="$BELL_BG"; PFG[$k]="$BELL_FG"; PATTR[$k]="bold"
            DEGRADE[$k]=0
        elif [ "$idx" -ge 1 ]; then
            PBG[$k]="${PALETTE[$((idx - 1))]}"; PFG[$k]="$FLAG_FG"; PATTR[$k]="bold"
            DEGRADE[$k]=0
        elif [ "$k" = "$v" ]; then
            PBG[$k]="$CUR_BG"; PFG[$k]="$CUR_FG"; PATTR[$k]="bold"
            # An uncoloured CURRENT session is "ordinary" by this flag, and is
            # still never shortened — every use site excludes the viewer's own
            # pill explicitly, because the whole point of the floor is that you
            # can always read where you are.
            DEGRADE[$k]=1
        else
            PBG[$k]="$IDLE_BG"; PFG[$k]="$IDLE_FG"; PATTR[$k]="nobold"
            DEGRADE[$k]=1
        fi

        # The marker is drawn ONLY when the current session carries a colour of
        # its own. An uncoloured current session already renders in
        # @sidetabs-strip-current-bg, which is what identifies it, and adding a
        # marker there would change how today's strip looks for everyone who
        # never sets a session colour. A coloured current session has given that
        # slot away, so the marker is the only thing left saying "you are here".
        # Note this keys off the COLOUR, not off which branch won above: a
        # coloured session that is also ringing renders red and still keeps its
        # marker, because the bell is transient and the colour is not.
        if [ "$k" = "$v" ] && [ "$idx" -ge 1 ]; then MARK=1; fi
        k=$((k + 1))
    done
}

# --- 6b. the width cascade ---------------------------------------------------
# tmux does not warn you that it truncated: it cuts at the client edge, mid-pill
# if that is where the edge falls, with no ellipsis and no marker, and it drops
# a 2-column glyph whole if only one column is left. A strip that ran out of
# room therefore looks exactly like a strip that had nothing more to say. So
# instead of being cut, the strip SHEDS detail, in this order, each stage
# applied only if the one before it did not fit:
#
#   0  everything: marker, full names, all edge pills
#   1  drop the current-session marker
#   2  drop right-side pills, OUTERMOST (rightmost) first, one per stage
#   3  drop left-side pills, OUTERMOST (leftmost) first, one per stage
#   4  truncate session names: 12, then 8, then 6, then 4
#   5  non-current UNFLAGGED sessions -> single initial
#   6  non-current UNFLAGGED sessions -> colour block, no text
#   7  floor: marker + current session name + " +N"
#
# WHY THE RIGHT SIDE GOES BEFORE THE LEFT PILLS: on the machine this was
# designed for, the right side carries the clock and user@host, both of which
# are already in the macOS menu bar two centimetres higher up. The left pills
# (load, memory, disk) are not duplicated anywhere, so they are worth more.
#
# WHY 5 AND 6 SKIP FLAGGED PILLS: a session colour is something you set on
# purpose and a bell/attention pill is something asking for you. Those are the
# pills a narrow bar exists to show. An ordinary session that you have said
# nothing about is what gets shortened first, and every ordinary pill is spent
# before an informative one is touched at all — stage 6 blanks only ordinary
# pills too, so an informative pill keeps its full name even when its neighbours
# are bare colour blocks.
#
# WHY THE FLOOR ALWAYS DRAWS THE MARKER: normally it appears only on a coloured
# current session (an uncoloured one is identified by its own blue), but at the
# floor the strip is a single pill and the marker is the only thing saying that
# pill is where you are, rather than the only session that would fit.
#
# The stage is chosen by ARITHMETIC ONLY — no candidate string is ever built —
# so walking the whole ladder costs a couple of dozen integer loops per session,
# not a couple of dozen string concatenations.
ST_MARK=0; ST_RDROP=0; ST_LDROP=0; ST_NAMEMAX=0; ST_INITIALS=0; ST_BLOCKS=0; ST_FLOOR=0

# sess_width <viewer slot> -> SW, the width of the session-pill chain under the
# stage state currently in ST_*. Each pill is 1 pad + body + 1 pad + 1 arrow.
sess_width() {
    local v="$1" k len w=0
    k=1
    while [ "$k" -le "$n" ]; do
        if [ "$k" != "$v" ] && [ "${DEGRADE[$k]}" = "1" ] && [ "$ST_BLOCKS" = "1" ]; then
            # A colour block is one column of pill plus its arrow. No padding:
            # padding on a body with no text is just a wider block.
            w=$((w + 2))
        elif [ "$k" != "$v" ] && [ "${DEGRADE[$k]}" = "1" ] && [ "$ST_INITIALS" = "1" ]; then
            w=$((w + 4))
        else
            len="${NAMELEN[$k]}"
            if [ "$ST_NAMEMAX" -gt 0 ] && [ "$len" -gt "$ST_NAMEMAX" ]; then
                len="$ST_NAMEMAX"
            fi
            w=$((w + len + 3))
        fi
        k=$((k + 1))
    done
    if [ "$ST_MARK" = "1" ]; then w=$((w + 1)); fi
    SW="$w"
}

# total_width <viewer slot> -> TW. Left pills + session pills + right pills.
# The unowned-side reserve is NOT included here; it is subtracted from the
# budget instead, which is the same arithmetic said the way it actually is: the
# reserve is not ours to spend.
total_width() {
    local lw rw
    lw="${LEFT_SUFFIX[$((ST_LDROP + 1))]}"
    rw="${RIGHT_PREFIX[$((RIGHT_N - ST_RDROP))]}"
    sess_width "$1"
    TW=$((lw + SW + rw))
}

# fit_stage <viewer slot> <avail>: walk the ladder, stop at the first stage that
# fits, leave that stage in ST_*. Always succeeds — the floor is a stage, not a
# failure — because a strip that cannot be fitted must still be a strip.
fit_stage() {
    local v="$1" avail="$2" i t

    ST_MARK="$MARK"; ST_RDROP=0; ST_LDROP=0; ST_NAMEMAX="$NAME_MAX"
    ST_INITIALS=0; ST_BLOCKS=0; ST_FLOOR=0
    total_width "$v"; [ "$TW" -le "$avail" ] && return 0

    # 1 — the marker. A no-op when the current session is unflagged, since none
    # was drawn; the cascade just falls through to the next stage.
    ST_MARK=0
    total_width "$v"; [ "$TW" -le "$avail" ] && return 0

    # 2 — right pills, rightmost first. Empty when the plugin does not own that
    # side: an unowned side is reserved, never dropped, so it has no stage.
    i=1
    while [ "$i" -le "$RIGHT_N" ]; do
        ST_RDROP="$i"
        total_width "$v"; [ "$TW" -le "$avail" ] && return 0
        i=$((i + 1))
    done

    # 3 — left pills, leftmost first.
    i=1
    while [ "$i" -le "$LEFT_N" ]; do
        ST_LDROP="$i"
        total_width "$v"; [ "$TW" -le "$avail" ] && return 0
        i=$((i + 1))
    done

    # 4 — name truncation. A step at or above a cap already in force by
    # @sidetabs-strip-name-max would be a no-op, so it is skipped rather than
    # burning a whole stage on an unchanged width.
    # Unquoted on purpose — word splitting is how the space-separated ladder
    # becomes a sequence of steps.
    # shellcheck disable=SC2086
    for t in $STRIP_NAME_STEPS; do
        if [ "$ST_NAMEMAX" -gt 0 ] && [ "$t" -ge "$ST_NAMEMAX" ]; then continue; fi
        ST_NAMEMAX="$t"
        total_width "$v"; [ "$TW" -le "$avail" ] && return 0
    done

    # 5 / 6 — ordinary pills give up their text, first to an initial and then
    # to a bare block of their colour.
    ST_INITIALS=1
    total_width "$v"; [ "$TW" -le "$avail" ] && return 0
    ST_BLOCKS=1
    total_width "$v"; [ "$TW" -le "$avail" ] && return 0

    # 7 — the floor. One pill: which session you are in, and how many you cannot
    # see. Truthful at any width, and it never leaves you guessing where you are.
    ST_FLOOR=1
    ST_MARK=1
    return 0
}

# --- 7. build one status-left per session ------------------------------------
# Separator rule, applied uniformly: every separator is the TRAILING cell of the
# pill to its left, and WHICH GLYPH it is depends on whether there is a colour
# boundary there at all. This is the classic powerline rule.
#   - backgrounds differ : the SOLID arrow. fg = left pill's bg, bg = right
#                          pill's bg — the arrow reads as the left pill's own
#                          edge cutting into the right one. This is the ">" look
#                          and it is not configurable.
#   - backgrounds MATCH  : there is no boundary to draw, so a THIN chevron
#                          ($SEP_GLYPH, U+E0B1 by default) on the shared
#                          background instead. A solid arrow here would be drawn
#                          in the same ink as the surface under it and vanish;
#                          forcing a contrasting ink on it instead (which this
#                          strip used to do) just turns every same-colour join
#                          into a heavy dark wedge between two pills that are
#                          the same colour — the thing the thin chevron exists
#                          to avoid.
#                          Ink = $SEP_FG, whose default is the sentinel "match"
#                          meaning DERIVED FROM THE PILL ITSELF: that pill's own
#                          background blended 40% of the way toward its own
#                          foreground (sep_ink below). A grey session pill gets a
#                          muted grey chevron, a cyan sysinfo pill a deeper cyan
#                          one — a shade OF the pill rather than a colour laid on
#                          top of it. (Copying the pill's fg outright, which is
#                          what "match" used to mean, puts plain white on every
#                          grey session pill: stark, and foreign to the pill.) An
#                          explicit colour overrides it everywhere.
#   - the LAST pill      : the "right pill" is the bar background itself, and
#                          the same match/differ test applies to it too.
# Both glyphs are ONE display column, so the cascade's arithmetic (a join costs
# 1, section 6b) is the same either way and nothing above needs to know which
# one a given join will use.
BATCH=""
# A single quote, and the four characters that stand in for one inside a
# single-quoted string: close, backslash-escaped quote, reopen.
SQ="'"
SQ_ESCAPED="'\\''"

# resolve_hex <colour> -> HEXV, its "#rrggbb" form. Returns 1 for anything that
# cannot be resolved — a "colour123" index, an unknown name, "default" — because
# a blend needs numbers and there is nothing to be gained by guessing at them.
#
# The literal-hex test also insists on LOWERCASE, which everything reaching here
# already is: the theme block and the edge-pill scan both run a tr pass, for the
# reason section 3 documents at length (#D is tmux's pane_id alias, so an
# uppercase #D08770 corrupts under a second format expansion). An uppercase value
# that somehow got this far is therefore treated as unresolvable and falls back,
# rather than being blended into an ink this file would then emit uppercase.
resolve_hex() {
    local rest
    case "$1" in
        '#'[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) HEXV="$1"; return 0 ;;
    esac
    # The space-delimited table from variables.sh. Its leading/trailing spaces
    # are load-bearing: " black=" cannot match inside " brightblack=", and the
    # value is cut at the next space.
    rest="${STRIP_COLOR_NAMES#* $1=}"
    [ "$rest" = "$STRIP_COLOR_NAMES" ] && return 1
    HEXV="${rest%% *}"
    case "$HEXV" in
        '#'[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    esac
    return 1
}

# sep_ink <pill bg> <pill fg> -> SEP_INK, the ink for a same-background join
# under the "match" sentinel: the pill's BACKGROUND carried STRIP_SEP_MIX percent
# of the way toward its own FOREGROUND, per RGB channel. Visible enough to read
# as a divider, close enough to the pill to belong to it.
#
# HOUSE RULE, a failed operation is a no-op: SEP_INK is seeded with the
# foreground FIRST, so every early return leaves the previous behaviour (the
# pill's own fg) in place rather than an empty or invalid style value. A colour
# neither side can resolve therefore degrades to a chevron that is merely stark,
# never to a broken #[fg=] or a blank separator.
#
# Integer arithmetic throughout — bash has no floats — and `printf -v` rather
# than a $(printf) subshell, because this runs once per join per session string.
SEP_INK=""
sep_ink() {
    local hbg hfg r g b
    SEP_INK="$2"
    resolve_hex "$1" || return 0
    hbg="$HEXV"
    resolve_hex "$2" || return 0
    hfg="$HEXV"
    r=$(( (16#${hbg:1:2} * (100 - STRIP_SEP_MIX) + 16#${hfg:1:2} * STRIP_SEP_MIX) / 100 ))
    g=$(( (16#${hbg:3:2} * (100 - STRIP_SEP_MIX) + 16#${hfg:3:2} * STRIP_SEP_MIX) / 100 ))
    b=$(( (16#${hbg:5:2} * (100 - STRIP_SEP_MIX) + 16#${hfg:5:2} * STRIP_SEP_MIX) / 100 ))
    # %02x is lowercase by definition, which is the whole point (see section 3).
    printf -v SEP_INK '#%02x%02x%02x' "$r" "$g" "$b"
}

# append_pill <bg> <fg> <attr> <body> <bodywidth> <next_bg>
# Appends one "#[style]body" cell plus its trailing separator arrow to the
# CALLER's $out, and adds <bodywidth> + 1 (the arrow) to the CALLER's $width.
# Deliberately not `local out`/`local width` itself: by bash's ordinary
# dynamic scoping this reads and writes whichever $out/$width are in scope at
# the call site, so ONE copy of the separator rule serves the left-pill
# chain, the session-pill chain and the right-pill chain below, instead of
# three. <next_bg> is the neighbour to the right — the pill that follows this
# one, or the bar background / next chain's first pill for whatever sits at
# the end of that particular chain.
append_pill() {
    local bg="$1" fg="$2" attr="$3" body="$4" bw="$5" nbg="$6" sfg sep
    out="${out}#[fg=${fg},bg=${bg},${attr}]${body}"
    width=$((width + bw))
    if [ "$bg" = "$nbg" ]; then
        # No colour boundary: thin chevron, and by default in an ink DERIVED
        # from this pill's own colours, so it reads as a shade of the pill
        # rather than as something laid on top of it.
        sep="$SEP_GLYPH"
        if [ "$SEP_FG" = "match" ]; then
            sep_ink "$bg" "$fg"; sfg="$SEP_INK"
        else
            sfg="$SEP_FG"
        fi
    else
        sep="$ARROW"
        sfg="$bg"
    fi
    out="${out}#[fg=${sfg},bg=${nbg},nobold]${sep}"
    # Both glyphs are one display column, so this is 1 either way.
    width=$((width + 1))
}

# --- 7b. the right pill chain ------------------------------------------------
# build_right_chain <keep>: the first <keep> right pills, in order, into
# R_OUT/R_WIDTH. Edge pills carry no "current" concept, so this side's content
# and colours are identical for every session — but the CASCADE is not, because
# each session has its own width budget, so a session on a 90-column laptop can
# be showing two right pills while one on a 200-column display shows four. It is
# therefore built per session rather than once.
#
# status-right is a per-session option exactly like status-left (fact 3), so
# every session needs its own copy set regardless.
#
# `local out`/`local width` here on purpose: append_pill writes to whichever
# $out/$width is in scope at the call site, so these locals keep the right
# chain's string out of the caller's status-left.
R_OUT=""; R_WIDTH=0
build_right_chain() {
    local keep="$1" k out="" width=0 nbg
    k=1
    while [ "$k" -le "$keep" ]; do
        if [ "$k" -lt "$keep" ]; then nbg="${RIGHT_BG[$((k + 1))]}"; else nbg="$STRIP_BG"; fi
        # A pill's VALUE is NOT escaped the way a session name is: a session
        # name is literal text a stray "#" would corrupt, but a pill's value IS
        # tmux format syntax on purpose (typically a #(shell command)) and must
        # reach the option unmangled for tmux to expand it at render time.
        append_pill "${RIGHT_BG[$k]}" "${RIGHT_FG[$k]}" "nobold" " ${RIGHT_VAL[$k]} " \
            "$((${RIGHT_COST[$k]} - 1))" "$nbg"
        k=$((k + 1))
    done
    R_OUT="$out"; R_WIDTH="$width"
}

# build_floor <viewer slot>: cascade stage 7. One pill, the current session, and
# a count of everything that did not fit. Appends to the CALLER's $out/$width.
build_floor() {
    local v="$1" avail="$2" others=$((n - 1)) name esc suffix bw over newlen
    suffix=""
    # "+0" would be a lie dressed as information; a one-session server's floor
    # is just the session.
    if [ "$others" -gt 0 ]; then suffix=" +${others}"; fi
    name="${SNAMES[$v]}"
    # marker + pad + name + suffix + pad, then append_pill adds the arrow.
    bw=$((2 + ${#name} + ${#suffix} + 1))
    if [ $((bw + 1)) -gt "$avail" ]; then
        # Below the floor there is nothing left to shed, so the NAME gives way
        # rather than the count: a hard cut would take the "+N" off the end,
        # and "how many sessions am I not seeing" is the part you cannot infer
        # from anything else on screen. One character of name is the minimum;
        # narrower than that tmux clips, and nothing can be done about it.
        over=$((bw + 1 - avail))
        newlen=$((${#name} - over))
        if [ "$newlen" -lt 1 ]; then newlen=1; fi
        name="${name:0:newlen}"
        bw=$((2 + ${#name} + ${#suffix} + 1))
    fi
    esc="${name//#/##}"
    append_pill "${PBG[$v]}" "${PFG[$v]}" "${PATTR[$v]}" \
        "${MARKER} ${esc}${suffix} " "$bw" "$STRIP_BG"
}

build_one() {
    local v="$1" k out="" width=0 bg fg attr body name esc nbg width_add len
    local budget reserve avail ll
    resolve_pills "$v"

    # BUDGET = what this session's narrowest client can show, MINUS the columns
    # reserved for a side the plugin does not own. What is left is what the
    # cascade may spend on left pills + session pills + our own right pills.
    budget="${BUDGETS[$v]}"
    reserve="${RESERVES[$v]}"
    avail=$((budget - reserve))
    # A reserve wider than the whole client (a mis-set @sidetabs-strip-reserve,
    # or a genuinely enormous status-right) must not make the arithmetic go
    # negative and produce a nonsense stage: clamp, fall to the floor, and let
    # tmux clip. Still a strip, still says where you are.
    if [ "$avail" -lt 1 ]; then avail=1; fi
    fit_stage "$v" "$avail"

    build_right_chain $((RIGHT_N - ST_RDROP))

    # Left edge pills, outermost (1) first, prepended directly into the SAME
    # status-left string as the session pills — this is the "join" the design
    # doc means: the last left pill's separator arrow is computed against the
    # FIRST session pill's background exactly as if it were just another
    # neighbour, because that is exactly what it is. A live server always has
    # at least one session (guarded above), so PBG[1] always exists.
    #
    # ST_LDROP of them have been sacrificed by cascade stage 3, outermost
    # (leftmost) first, so this starts at ST_LDROP+1 rather than at 1. Reaching
    # the floor (stage 7) means stage 3 ran to completion, so ST_LDROP == LEFT_N
    # and this loop does not run at all there — the floor's pill is always the
    # first thing in the string, and its own neighbour arithmetic is build_floor's.
    #
    # A pill's VALUE is NOT escaped the way a session name is: a session name
    # is literal text a stray "#" would corrupt, but a pill's value IS tmux
    # format syntax on purpose (typically a #(shell command)) and must reach
    # the option unmangled for tmux to expand it at render time.
    k=$((ST_LDROP + 1))
    while [ "$k" -le "$LEFT_N" ]; do
        body=" ${LEFT_VAL[$k]} "
        if [ "$k" -lt "$LEFT_N" ]; then
            nbg="${LEFT_BG[$((k + 1))]}"
        else
            nbg="${PBG[1]}"
        fi
        append_pill "${LEFT_BG[$k]}" "${LEFT_FG[$k]}" "nobold" "$body" \
            "$((${LEFT_COST[$k]} - 1))" "$nbg"
        k=$((k + 1))
    done

    if [ "$ST_FLOOR" = "1" ]; then
        build_floor "$v" "$((avail - width - R_WIDTH))"
    else
        k=1
        while [ "$k" -le "$n" ]; do
            bg="${PBG[$k]}"; fg="${PFG[$k]}"; attr="${PATTR[$k]}"
            name="${SNAMES[$k]}"
            if [ "$k" != "$v" ] && [ "${DEGRADE[$k]}" = "1" ] && [ "$ST_BLOCKS" = "1" ]; then
                # Cascade stage 6: no text at all, just a block of the pill's own
                # colour. Still one pill per session, so the strip still tells you
                # how many there are and which one is ringing.
                body=" "
                width_add=1
            elif [ "$k" != "$v" ] && [ "${DEGRADE[$k]}" = "1" ] && [ "$ST_INITIALS" = "1" ]; then
                # Cascade stage 5. First CHARACTER, not first byte — bash's
                # substring operator is character-based in a UTF-8 locale, the same
                # assumption render.sh's ${label:0:avail} already makes.
                esc="${name:0:1}"
                body=" ${esc//#/##} "
                width_add=3
            else
                len="${#name}"
                # Cascade stage 4, and the @sidetabs-strip-name-max hard cap, which
                # is the same operation applied before the cascade starts.
                if [ "$ST_NAMEMAX" -gt 0 ] && [ "$len" -gt "$ST_NAMEMAX" ]; then
                    name="${name:0:$ST_NAMEMAX}"
                    len="$ST_NAMEMAX"
                fi
                # A literal "#" in a session name would be read as the start of a
                # format sequence ("#{", "#[", or a single-letter alias) when tmux
                # expands the status line. Doubling it is tmux's own escape for a
                # literal hash.
                esc="${name//#/##}"
                body=" ${esc} "
                # Width is counted in CHARACTERS off the RAW name — "##" is one
                # column on screen, and style escapes do not count toward
                # status-left-length at all. Same convention render.sh uses.
                width_add=$((len + 2))
                if [ "$k" = "$v" ] && [ "$ST_MARK" = "1" ]; then
                    body="${MARKER}${body}"
                    width_add=$((width_add + 1))
                fi
            fi
            if [ "$k" -lt "$n" ]; then nbg="${PBG[$((k + 1))]}"; else nbg="$STRIP_BG"; fi
            append_pill "$bg" "$fg" "$attr" "$body" "$width_add" "$nbg"
            k=$((k + 1))
        done
    fi
    [ -n "$out" ] || return 1

    # Single quotes, and every embedded quote closed-escaped-reopened the shell
    # way ('\''), because tmux's config parser expands #{...} formats AND its
    # own environment variables inside DOUBLE quotes (verified: "a $FOO b"
    # arrives as "a  b") but treats a single-quoted string as literal. The
    # generated string is full of #[...] and may well contain a $ from a session
    # name, so it must arrive verbatim. tmux concatenates the adjacent quoted
    # runs exactly as sh does — verified on 3.6b: it's here round-trips intact.
    #
    # Built out of named characters rather than written as an escape soup
    # (${out//\'/\'\\\'\'} looks right and is not — it yields "\'\\'\'").
    local q="${out//$SQ/$SQ_ESCAPED}"

    # status-left-length is the COLUMNS THE LEFT SIDE MAY OCCUPY, not the width
    # it actually came out at. tmux's default is 10, which would cut the strip
    # off after the first pill, so it has to be set to something; the question
    # is what.
    #
    # The budget minus the reserved columns minus our own right chain is what
    # the cascade just fitted the left side into, so it is never smaller than
    # the string above — the cap can never clip content the cascade decided to
    # keep. And it is never larger, which makes tmux's own cap a HARD BACKSTOP
    # on overrunning a side we do not own: if one of our own #(shell) edge pills
    # renders wider than the placeholder width guessed for it, tmux cuts our
    # pill rather than letting it run over the user's clock. (The design doc
    # says "set each length to the full budget"; this is that, tightened by the
    # part of the budget that was never ours to spend.)
    ll=$((avail - R_WIDTH))
    if [ "$ll" -lt 1 ]; then ll=1; fi

    # DELIVERED AS ONE BATCH, not one `tmux set-option` per session. The argv
    # path caps at ~16KB ("command too long", measured in bytes — the ceiling
    # that once capped notes), while `source-file` has no such ceiling; and each
    # tmux PROCESS invocation costs ~5ms while each command inside one costs
    # ~nothing. So a ten-session server pays one fork, not twenty.
    BATCH="${BATCH}set-option -t '\$${SIDS[$v]}' status-left '${q}'
set-option -t '\$${SIDS[$v]}' status-left-length ${ll}
"
    # status-right is written ONLY when at least one right pill is configured
    # (RIGHT_N > 0) — a side whose -1 is unset is NEVER touched by this
    # plugin, not even to clear it, so a status-right the USER owns (or that a
    # different plugin owns) is left exactly alone. This is the same house
    # rule section 14 of the smoke test exercises for the strip's own master
    # switch: an unconfigured/off path is a no-op, never a clear. That side is
    # measured and RESERVED in section 5c instead, which is why it can be left
    # alone and still not be overrun.
    #
    # When the plugin DOES own it, an empty write is correct rather than a
    # violation of that rule: the cascade dropping every right pill at a narrow
    # width is a decision about our own content, not a failure.
    if [ "$RIGHT_N" -gt 0 ]; then
        local rq="${R_OUT//$SQ/$SQ_ESCAPED}"
        BATCH="${BATCH}set-option -t '\$${SIDS[$v]}' status-right '${rq}'
set-option -t '\$${SIDS[$v]}' status-right-length ${R_WIDTH}
"
    fi
    return 0
}

v=1
while [ "$v" -le "$n" ]; do
    # A single failed pill would make a truncated strip, so the whole batch is
    # abandoned instead. The status line keeps whatever it already had.
    build_one "$v" || exit 0
    v=$((v + 1))
done
[ -n "$BATCH" ] || exit 0

printf '%s' "$BATCH" | tmux source-file /dev/stdin 2>/dev/null || true

exit 0
