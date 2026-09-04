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
# NO WIDTH HANDLING YET. The strip clips at the client edge; the shrink cascade
# (drop the marker, then edge pills, then truncate names, ...) is a later
# ticket. status-left-length is set to the strip's own visible width, because
# tmux's default of 10 would otherwise cut it off after the first pill.
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
# U+E0B0, the SOLID powerline arrow. Spelled as bytes: macOS ships bash 3.2,
# where $'\uXXXX' is not a thing (it arrived in 4.2). U+E0B1, the thin bar, is
# never emitted anywhere in this file — every separator is this glyph.
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
# This is deliberately NOT the precise "measure and reserve" machinery the
# design doc describes for an UNOWNED side (@sidetabs-strip-reserve) — that
# reservation is ticket 07's shrink-cascade job; this only has to keep OUR OWN
# pills from being cut off by tmux's length cap.
DYNAMIC_PILL_WIDTH=12
pill_display_width() {
    case "$1" in
        *'#('*|*'#{'*|*%[A-Za-z]*) printf '%s' "$DYNAMIC_PILL_WIDTH" ;;
        *) printf '%s' "${#1}" ;;
    esac
}

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
SIDS=(); SNAMES=(); SFLAGS=(); BELLS=(); ATTNS=()
IDMAP="$US"
while IFS="$TAB" read -r sid fval sname; do
    [ -n "$sid" ] || continue
    case "$sid" in *[!0-9]*) continue ;; esac
    n=$((n + 1))
    SIDS[$n]="$sid"
    SNAMES[$n]="$sname"
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
PBG=(); PFG=(); PATTR=(); MARK=0
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
        elif [ "$idx" -ge 1 ]; then
            PBG[$k]="${PALETTE[$((idx - 1))]}"; PFG[$k]="$FLAG_FG"; PATTR[$k]="bold"
        elif [ "$k" = "$v" ]; then
            PBG[$k]="$CUR_BG"; PFG[$k]="$CUR_FG"; PATTR[$k]="bold"
        else
            PBG[$k]="$IDLE_BG"; PFG[$k]="$IDLE_FG"; PATTR[$k]="nobold"
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

# --- 7. build one status-left per session ------------------------------------
# Separator rule, applied uniformly: every separator is the TRAILING cell of the
# pill to its left, always the solid arrow.
#   - backgrounds differ : fg = left pill's bg, bg = right pill's bg (standard
#                          powerline; the arrow reads as the left pill's edge)
#   - backgrounds MATCH  : fg = @sidetabs-strip-sep-fg, bg = the shared bg.
#                          Without this the arrow would be drawn in the same
#                          ink as the surface under it and simply vanish, which
#                          is what the thin U+E0B1 bar normally solves — but the
#                          decided look is a solid arrow everywhere.
#   - the LAST pill      : the "right pill" is the bar background itself, and
#                          the same match/differ test applies to it too.
BATCH=""
# A single quote, and the four characters that stand in for one inside a
# single-quoted string: close, backslash-escaped quote, reopen.
SQ="'"
SQ_ESCAPED="'\\''"

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
    local bg="$1" fg="$2" attr="$3" body="$4" bw="$5" nbg="$6" sfg
    out="${out}#[fg=${fg},bg=${bg},${attr}]${body}"
    width=$((width + bw))
    if [ "$bg" = "$nbg" ]; then sfg="$SEP_FG"; else sfg="$bg"; fi
    out="${out}#[fg=${sfg},bg=${nbg},nobold]${ARROW}"
    width=$((width + 1))
}

# --- 7b. the right pill chain, built ONCE ------------------------------------
# Edge pills carry no "current" concept, so — unlike the session chain — this
# side's content and colours are IDENTICAL for every session's string; only
# the TARGET of the set-option differs, because status-right is a per-session
# option exactly like status-left (fact 3), so every session still needs its
# own copy set or clients on that session would see none. Built once here and
# reused (already single-quote-escaped) inside build_one below, rather than
# repeating the same string work once per session.
RIGHT_OUT=""; RIGHT_Q=""; RIGHT_WIDTH=0
if [ "$RIGHT_N" -gt 0 ]; then
    out=""; width=0
    k=1
    while [ "$k" -le "$RIGHT_N" ]; do
        esc="${RIGHT_VAL[$k]}"
        body=" ${esc} "
        if [ "$k" -lt "$RIGHT_N" ]; then rnbg="${RIGHT_BG[$((k + 1))]}"; else rnbg="$STRIP_BG"; fi
        append_pill "${RIGHT_BG[$k]}" "${RIGHT_FG[$k]}" "nobold" "$body" \
            "$(($(pill_display_width "$esc") + 2))" "$rnbg"
        k=$((k + 1))
    done
    RIGHT_OUT="$out"
    RIGHT_WIDTH="$width"
    RIGHT_Q="${RIGHT_OUT//$SQ/$SQ_ESCAPED}"
fi

build_one() {
    local v="$1" k out="" width=0 bg fg attr body name esc nbg width_add
    resolve_pills "$v"

    # Left edge pills, outermost (1) first, prepended directly into the SAME
    # status-left string as the session pills — this is the "join" the design
    # doc means: the last left pill's separator arrow is computed against the
    # FIRST session pill's background exactly as if it were just another
    # neighbour, because that is exactly what it is. A live server always has
    # at least one session (guarded above), so PBG[1] always exists.
    #
    # A pill's VALUE is NOT escaped the way a session name is: a session name
    # is literal text a stray "#" would corrupt, but a pill's value IS tmux
    # format syntax on purpose (typically a #(shell command)) and must reach
    # the option unmangled for tmux to expand it at render time.
    k=1
    while [ "$k" -le "$LEFT_N" ]; do
        esc="${LEFT_VAL[$k]}"
        body=" ${esc} "
        if [ "$k" -lt "$LEFT_N" ]; then nbg="${LEFT_BG[$((k + 1))]}"; else nbg="${PBG[1]}"; fi
        append_pill "${LEFT_BG[$k]}" "${LEFT_FG[$k]}" "nobold" "$body" \
            "$(($(pill_display_width "$esc") + 2))" "$nbg"
        k=$((k + 1))
    done

    k=1
    while [ "$k" -le "$n" ]; do
        bg="${PBG[$k]}"; fg="${PFG[$k]}"; attr="${PATTR[$k]}"
        name="${SNAMES[$k]}"
        # A literal "#" in a session name would be read as the start of a format
        # sequence ("#{", "#[", or a single-letter alias) when tmux expands the
        # status line. Doubling it is tmux's own escape for a literal hash.
        esc="${name//#/##}"
        body=" ${esc} "
        # Width is counted in CHARACTERS off the RAW name — "##" is one column
        # on screen, and style escapes do not count toward status-left-length at
        # all. Same convention render.sh uses for the sidebar.
        width_add=$((${#name} + 2))
        if [ "$k" = "$v" ] && [ "$MARK" = "1" ]; then
            body="${MARKER}${body}"
            width_add=$((width_add + 1))
        fi
        if [ "$k" -lt "$n" ]; then nbg="${PBG[$((k + 1))]}"; else nbg="$STRIP_BG"; fi
        append_pill "$bg" "$fg" "$attr" "$body" "$width_add" "$nbg"
        k=$((k + 1))
    done
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
    # DELIVERED AS ONE BATCH, not one `tmux set-option` per session. The argv
    # path caps at ~16KB ("command too long", measured in bytes — the ceiling
    # that once capped notes), while `source-file` has no such ceiling; and each
    # tmux PROCESS invocation costs ~5ms while each command inside one costs
    # ~nothing. So a ten-session server pays one fork, not twenty.
    BATCH="${BATCH}set-option -t '\$${SIDS[$v]}' status-left '${q}'
set-option -t '\$${SIDS[$v]}' status-left-length ${width}
"
    # status-right is written ONLY when at least one right pill is configured
    # (RIGHT_N > 0) — a side whose -1 is unset is NEVER touched by this
    # plugin, not even to clear it, so a status-right the USER owns (or that a
    # different plugin owns) is left exactly alone. This is the same house
    # rule section 14 of the smoke test exercises for the strip's own master
    # switch: an unconfigured/off path is a no-op, never a clear.
    if [ "$RIGHT_N" -gt 0 ]; then
        BATCH="${BATCH}set-option -t '\$${SIDS[$v]}' status-right '${RIGHT_Q}'
set-option -t '\$${SIDS[$v]}' status-right-length ${RIGHT_WIDTH}
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
