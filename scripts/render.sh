#!/usr/bin/env bash
# Long-lived render loop. Runs inside the sidetab pane.
#
# Visibility-gated: only a sidebar someone can SEE (a client is viewing its
# window — or, with zero clients on the whole server, its window is the active
# one, mirroring timer_focus.sh's detached-server rule) rebuilds on the fast
# 0.5s tick. Hidden sidebars block on a long sleep and rebuild only when
# refresh.sh signals USR1 (window switches, renames, bells, attach, …), so an
# idle server does no per-hidden-pane work. All rendered state is recomputed
# from tmux options at build time, so a sidebar waking after minutes is
# instantly correct (timers included).
#
# The draw is flicker-free: it homes the cursor and overwrites each line with a
# clear-to-EOL, then clears below — no full-screen wipe. Reprinting identical
# content is therefore invisible, which also lets us recover transparently when
# tmux repaints the pane (e.g. right after the pane is created or resized).
#
# Layout (expanded):
#   [ session-name ‹cap› ]          header pill (like status-left)
#   ────────────────────            rule
#   ` N ‹thin› name flags … ‹cap›`  one full-width pill per window
#   <summary lines>                 under the ACTIVE window only
# State colors (nord by default): bell = red, flag = user preset, active = teal, activity = yellow text, idle = grey. Precedence: bell > flag > active > activity. Only the number is bold.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/icons.sh"

MY_PANE_ID="$TMUX_PANE"

# Determine which session's windows to list from our OWN pane. Passing the id
# as a command argument is unreliable: tmux's command parser strips quoting and
# then sh expands tokens like `$0`, corrupting it. Querying the pane is robust.
SESSION_ID="$(tmux display-message -p -t "$MY_PANE_ID" '#{session_id}' 2>/dev/null)"
[ -z "$SESSION_ID" ] && SESSION_ID="$1"

# Fully-qualified target for format reads. A bare pane target lets tmux pick
# the session context by best-match, which for a window linked into grouped
# sessions can be a DIFFERENT session than SESSION_ID — session-scoped options
# (@sidetabs_collapsed, summary cache) and #{window_active} would then come
# from the wrong session. Qualifying with session:window.pane pins the context
# to the same session everything else in this script uses.
MY_WINDOW_ID="$(tmux display-message -p -t "$MY_PANE_ID" '#{window_id}' 2>/dev/null)"
if [ -n "$MY_WINDOW_ID" ]; then
    MY_TARGET="${SESSION_ID}:${MY_WINDOW_ID}.${MY_PANE_ID}"
else
    MY_TARGET="$MY_PANE_ID"
fi

# USR1 = "state changed, redraw now". The trap marks the wake AND kills the
# in-flight sleep so a signal landing between the visibility check and `wait`
# can't be swallowed by the no-op-trap race (`wait` would block the full
# interval with the signal already consumed). Known microscopic hazard: between
# `wait` reaping the child and SLEEP_PID being cleared, the trap could kill a
# reused PID — accepted; bash 3.2 offers no atomic alternative (no sub-second
# read -t for a self-pipe), and the window is a single statement wide.
WOKEN=0
SLEEP_PID=""
trap 'WOKEN=1; [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null' USR1

set_pane_option "$MY_PANE_ID" "$RENDER_PID_OPTION" "$$"

# Click-to-select (self-mouse): when @sidetabs-mouse is on, THIS pane enables its
# own mouse reporting and reads its own clicks — no global tmux `mouse` needed.
# tmux forwards mouse events to the focused pane's app that requested them, so
# clicks only register while this sidebar pane is focused (the workflow: C-h into
# the sidebar, then click a row). Clicks-only modes (1000 + SGR 1006); no
# 1002/1003 motion tracking, so no motion spam.
MOUSE_ON="$(get_tmux_option '@sidetabs-mouse' "$DEFAULT_MOUSE")"
SAVED_STTY=""
MOUSE_READER_PID=""
if [ "$MOUSE_ON" = "on" ]; then
    SAVED_STTY="$(stty -g 2>/dev/null || true)"
    stty -echo -icanon min 1 time 0 2>/dev/null || true
    printf '\033[?1000h\033[?1006h'
    # The background mouse_reader (started before the main loop) consumes clicks;
    # the main loop is free to redraw on a timer. They must be separate: bash 3.2
    # has no sub-second read -t, and a blocking read ignores USR1 — so a single
    # read-driven loop can't also redraw on the 0.5s tick / refresh events.
fi

# Hide cursor; restore cursor + mouse + tty on exit.
printf '\033[?25l'
cleanup() {
    printf '\033[?25h'
    [ "$MOUSE_ON" = "on" ] && printf '\033[?1000l\033[?1006l'
    [ -n "$SAVED_STTY" ] && stty "$SAVED_STTY" 2>/dev/null
    [ -n "$MOUSE_READER_PID" ] && kill "$MOUSE_READER_PID" 2>/dev/null
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
}
trap 'cleanup; exit 0' EXIT INT TERM

# --- Theme -----------------------------------------------------------------
ESC="$(printf '\033')"
ARROW="$(printf '\xee\x82\xb0')"   # U+E0B0 powerline right cap (solid)
THIN="$(printf '\xee\x82\xb1')"    # U+E0B1 powerline right separator (thin)
RULE="$(printf '\xe2\x94\x80')"    # U+2500 box-drawing horizontal
GIT_ICON="$(printf '\xee\x82\xa0')"  # U+E0A0 powerline branch
DIR_ICON="$(printf '\xef\x81\xbb')"  # U+F07B folder
TIMER_RUN_ICON="$(printf '\xef\x81\x8b')"    # U+F04B nerd-font play
TIMER_PAUSE_ICON="$(printf '\xef\x81\x8c')"  # U+F04C nerd-font pause
TIMER_HOLD_ICON="$(printf '\xef\x89\x92')"   # U+F252 nerd-font hourglass-half (auto-held)
NOTE_ICON="$(get_tmux_option '@sidetabs-note-icon' "$DEFAULT_NOTE_ICON")"  # U+F249 sticky-note
# Display width of the note icon, measured ONCE at startup (emit_row runs ~N
# times per tick, so no forks in there). Unlike every other glyph here,
# @sidetabs-note-icon is documented as "any string" — hardcoding its width
# under-reserves columns for anything but a single glyph and the row's cap +
# arrow wrap onto the next screen line. ${#…} can't be used directly either: it
# counts BYTES outside a UTF-8 locale, so the default 3-byte glyph would claim 3
# columns. Deleting UTF-8 continuation bytes (0x80-0xbf) leaves exactly one byte
# per codepoint in ANY locale. Codepoints, not columns: a double-width icon
# (emoji) still under-counts — that is the documented cost of choosing one.
NOTE_ICON_W=0
if [ -n "$NOTE_ICON" ]; then
    NOTE_ICON_W="$(printf '%s' "$NOTE_ICON" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' ')"
    case "$NOTE_ICON_W" in ''|*[!0-9]*|0) NOTE_ICON_W=1 ;; esac
fi
TAB="$(printf '\t')"
US=$'\x1f'   # field separator for multi-value option reads (never in content)
BOLD="${ESC}[1m"; NOBOLD="${ESC}[22m"; RESET="${ESC}[0m"
hex_rgb() { local h="${1#\#}"; printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }

active_bg="$(get_tmux_option '@sidetabs-active-bg' '#88c0d0')"
active_fg="$(get_tmux_option '@sidetabs-active-fg' '#2e3440')"
idle_bg="$(get_tmux_option '@sidetabs-idle-bg' '#4c566a')"
idle_fg="$(get_tmux_option '@sidetabs-fg' '#d8dee9')"
bell_bg="$(get_tmux_option '@sidetabs-bell-bg' '#bf616a')"
bell_fg="$(get_tmux_option '@sidetabs-bell-fg' '#eceff4')"
activity_fg="$(get_tmux_option '@sidetabs-activity-fg' '#ebcb8b')"
rule_fg="$(get_tmux_option '@sidetabs-rule-fg' '#616e88')"
header_bg="$(get_tmux_option '@sidetabs-header-bg' '#5e81ac')"
header_fg="$(get_tmux_option '@sidetabs-header-fg' '#2e3440')"
summary_fg="$(get_tmux_option '@sidetabs-summary-fg' '#81a1c1')"
summary_on="$(get_tmux_option '@sidetabs-summary' 'on')"
icons_on="$(get_tmux_option '@sidetabs-icons' "$DEFAULT_ICONS")"
flag_fg="$(get_tmux_option '@sidetabs-flag-fg' '#2e3440')"
flag_colors="$(get_tmux_option '@sidetabs-flag-colors' "$DEFAULT_FLAG_COLORS")"

# A segment paints bg+fg (no bold); its cap paints the segment's bg as fg over a
# default bg so the trailing arrow "points" out of the colored block.
seg_sgr() { printf '%s[48;2;%s;38;2;%sm' "$ESC" "$(hex_rgb "$1")" "$(hex_rgb "$2")"; }
cap_sgr() { printf '%s[49;38;2;%sm' "$ESC" "$(hex_rgb "$1")"; }

SEG_ACTIVE="$(seg_sgr "$active_bg" "$active_fg")"; CAP_ACTIVE="$(cap_sgr "$active_bg")"
SEG_IDLE="$(seg_sgr "$idle_bg" "$idle_fg")";       CAP_IDLE="$(cap_sgr "$idle_bg")"
SEG_BELL="$(seg_sgr "$bell_bg" "$bell_fg")";       CAP_BELL="$(cap_sgr "$bell_bg")"
SEG_ACT="$(seg_sgr "$idle_bg" "$activity_fg")";    CAP_ACT="$(cap_sgr "$idle_bg")"
SEG_HDR="$(seg_sgr "$header_bg" "$header_fg")";    CAP_HDR="$(cap_sgr "$header_bg")"
RULE_SGR="${ESC}[49;38;2;$(hex_rgb "$rule_fg")m"
SUMMARY_SGR="${ESC}[49;38;2;$(hex_rgb "$summary_fg")m"

# Flag pill colors: 1-based indexed arrays (bash 3.2 — no assoc arrays); the
# index matches the @sidetabs_flag window option directly, no translation.
SEG_FLAG=(); CAP_FLAG=(); FLAG_N=0
for _c in $flag_colors; do
    FLAG_N=$((FLAG_N + 1))
    SEG_FLAG[$FLAG_N]="$(seg_sgr "$_c" "$flag_fg")"
    CAP_FLAG[$FLAG_N]="$(cap_sgr "$_c")"
done

# The emit_* helpers set the global ROW instead of printing: build_lines runs
# them ~2N times per tick, and a $(...) capture is a fork each — printf -v
# keeps the whole row construction fork-free (bash 3.1+).

# A full-width header pill (bold) for the session name. Sets ROW.
emit_header() {
    local label="$1" width="$2" avail used pad spaces
    avail=$((width - 1)); [ "$avail" -lt 0 ] && avail=0
    label=" ${label} "
    used=${#label}
    if [ "$used" -gt "$avail" ]; then label="${label:0:avail}"; used="$avail"; fi
    pad=$((avail - used)); [ "$pad" -lt 0 ] && pad=0
    printf -v spaces '%*s' "$pad" ''
    printf -v ROW '%s%s%s%s%s%s%s%s' "$SEG_HDR" "$BOLD" "$label" "$NOBOLD" "$spaces" "$CAP_HDR" "$ARROW" "$RESET"
}

# emit_row <active> <bell> <activity> <flagidx> <idx> <flags> <name> <width> <collapsed> [icon] [hasnote]
# New parameters go at the END: every call site passes positionally, so an
# inserted argument silently corrupts every row.
# Sets ROW.
emit_row() {
    local active="$1" bell="$2" activity="$3" flagidx="$4" idx="$5" flags="$6" name="$7" width="$8" collapsed="$9" icon="${10:-}" hasnote="${11:-0}"
    local seg cap avail nm used pad spaces icon_seg icon_w note_seg note_w
    case "$flagidx" in ''|*[!0-9]*) flagidx=0 ;; esac   # unset/garbage -> no flag
    if [ "$bell" = "1" ]; then seg="$SEG_BELL"; cap="$CAP_BELL"
    elif [ "$flagidx" -ge 1 ] && [ "$flagidx" -le "$FLAG_N" ]; then
        seg="${SEG_FLAG[$flagidx]}"; cap="${CAP_FLAG[$flagidx]}"
    elif [ "$active" = "1" ]; then seg="$SEG_ACTIVE"; cap="$CAP_ACTIVE"
    elif [ "$activity" = "1" ]; then seg="$SEG_ACT"; cap="$CAP_ACT"
    else seg="$SEG_IDLE"; cap="$CAP_IDLE"; fi

    avail=$((width - 1)); [ "$avail" -lt 0 ] && avail=0

    if [ "$collapsed" = "1" ]; then
        # " N <icon>" — space + icon (1 col) after the bold number, not bold.
        # The space is dropped when it wouldn't fit (e.g. 2-digit index at the
        # default collapsed width of 5) so the row never wraps.
        icon_seg=""; icon_w=0
        if [ -n "$icon" ]; then
            icon_seg=" ${icon}"; icon_w=2
            if [ $((1 + ${#idx} + icon_w)) -gt "$avail" ]; then
                icon_seg="$icon"; icon_w=1
            fi
        fi
        used=$((1 + ${#idx} + icon_w))
        pad=$((avail - used)); [ "$pad" -lt 0 ] && pad=0
        printf -v spaces '%*s' "$pad" ''
        printf -v ROW '%s %s%s%s%s%s%s%s%s' \
            "$seg" "$BOLD" "$idx" "$NOBOLD" "$icon_seg" "$spaces" "$cap" "$ARROW" "$RESET"
        return
    fi

    # Icon segment sits between the THIN separator and the name: " <icon>" (a
    # leading space + 1-col glyph = 2 display columns). Width is hardcoded (like
    # THIN) so it's locale-independent.
    icon_seg=""; icon_w=0
    [ -n "$icon" ] && { icon_seg=" ${icon}"; icon_w=2; }

    # Note glyph rides after the flags: a leading space + the icon's own width,
    # measured once at startup (NOTE_ICON_W) because @sidetabs-note-icon is
    # user-settable to any string — assuming one column overflows the row.
    # Presence only: the note text itself never reaches this function.
    note_seg=""; note_w=0
    [ "$hasnote" = "1" ] && [ -n "$NOTE_ICON" ] && { note_seg=" ${NOTE_ICON}"; note_w=$((1 + NOTE_ICON_W)); }

    nm=" ${name}"
    [ -n "$flags" ] && nm="${nm} ${flags}"
    used=$((1 + ${#idx} + 1 + 1 + icon_w + ${#nm} + note_w + 1))
    if [ "$used" -gt "$avail" ]; then
        # Shrink in a fixed order so a narrow sidebar (or a wide custom note
        # icon) degrades predictably instead of spilling the cap+arrow onto the
        # next screen line: name+flags first, then the command icon (derived
        # state), then the note glyph (explicitly user-set, so it goes last).
        # Each segment first gives up its leading space — same trick as the
        # collapsed branch — before being dropped entirely. Below ~" N ‹thin› "
        # nothing is left to trim and the index wins; tmux clips the remainder.
        local over=$((used - avail)) newlen
        newlen=$((${#nm} - over)); [ "$newlen" -lt 0 ] && newlen=0
        nm="${nm:0:newlen}"
        used=$((1 + ${#idx} + 1 + 1 + icon_w + ${#nm} + note_w + 1))
        if [ "$used" -gt "$avail" ] && [ "$icon_w" -gt 0 ]; then
            icon_seg="$icon"; icon_w=$((icon_w - 1)); used=$((used - 1))
            if [ "$used" -gt "$avail" ]; then
                icon_seg=""; used=$((used - icon_w)); icon_w=0
            fi
        fi
        if [ "$used" -gt "$avail" ] && [ "$note_w" -gt 0 ]; then
            note_seg="$NOTE_ICON"; note_w=$((note_w - 1)); used=$((used - 1))
            if [ "$used" -gt "$avail" ]; then
                note_seg=""; used=$((used - note_w)); note_w=0
            fi
        fi
    fi
    pad=$((avail - used)); [ "$pad" -lt 0 ] && pad=0
    printf -v spaces '%*s' "$pad" ''

    printf -v ROW '%s %s%s%s %s%s%s%s %s%s%s%s' \
        "$seg" "$BOLD" "$idx" "$NOBOLD" "$THIN" "$icon_seg" "$nm" "$note_seg" "$spaces" "$cap" "$ARROW" "$RESET"
}

# seconds -> HH:MM:SS (pure bash arithmetic; hours may exceed 99). Sets HMS.
fmt_hms() {
    local s="$1" h m
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    h=$((s / 3600)); m=$((s % 3600 / 60)); s=$((s % 60))
    printf -v HMS '%02d:%02d:%02d' "$h" "$m" "$s"
}

# One dim summary line: " <icon> <text>", truncated to width with the icon kept.
# mode=head keeps the start of the text (branch + commit start); mode=tail keeps
# the end (so a single dir keeps its basename, e.g. …/tmux-sidetabs). Sets ROW.
emit_summary_icon() {
    local icon="$1" text="$2" width="$3" mode="$4" avail maxtext keep
    avail=$((width - 1)); [ "$avail" -lt 0 ] && avail=0
    # Prefix " <icon> " is 3 display columns (space + 1-col glyph + space).
    maxtext=$((avail - 3)); [ "$maxtext" -lt 0 ] && maxtext=0
    if [ "${#text}" -gt "$maxtext" ]; then
        keep=$((maxtext - 1)); [ "$keep" -lt 0 ] && keep=0
        if [ "$mode" = "tail" ]; then
            text="…${text:$(( ${#text} - keep ))}"
        else
            text="${text:0:keep}…"
        fi
    fi
    printf -v ROW '%s %s %s%s' "$SUMMARY_SGR" "$icon" "$text" "$RESET"
}

# Summary under the active window: git (branch + last commit) and working dir(s)
# of the window's content panes. Cached per-session for SUMMARY_TTL_MS so
# redraws across a session's sidetabs don't re-spawn git; the cache values ride
# read_state's single per-iteration tmux call (CACHE_* globals). Values are
# stripped of control chars at write time so the US-joined read can never
# mis-split. Appends to LINES.
emit_summary() {
    local wid="$1" width="$2" now_s="$3"
    local gitraw="$CACHE_GIT" dirsraw="$CACHE_DIRS" now at

    now=$((now_s * 1000))
    at="$CACHE_AT"
    case "$at" in ''|*[!0-9]*) at=0 ;; esac

    if [ "$CACHE_WIN" != "$wid" ] || [ "$((now - at))" -ge "$SUMMARY_TTL_MS" ]; then
        local paths p br sub
        gitraw=""; dirsraw=""
        # Content-pane cwds, active pane first. Use the first that's a git repo
        # for the branch line (the active pane may not be the repo one).
        paths="$(tmux list-panes -t "$wid" \
            -F "#{pane_active}${TAB}#{@is_sidetab}${TAB}#{pane_current_path}" \
            2>/dev/null | awk -F"$TAB" '$2 != "1"' | sort -r | cut -d"$TAB" -f3)"

        while IFS= read -r p; do
            [ -z "$p" ] && continue
            br="$(git -C "$p" symbolic-ref --short -q HEAD 2>/dev/null \
                  || git -C "$p" rev-parse --short HEAD 2>/dev/null)"
            if [ -n "$br" ]; then
                # Subjects may legally contain control chars (even 0x1f, our
                # separator) — strip them before they enter the cache.
                sub="$(git -C "$p" log -1 --format=%s 2>/dev/null | tr -d '\000-\037')"
                gitraw="$br $sub"
                break
            fi
        done <<< "$paths"

        # Working dirs of all content panes, home-shortened, de-duped, joined by " | ".
        dirsraw="$(tmux list-panes -t "$wid" \
            -F "#{@is_sidetab}${TAB}#{pane_current_path}" 2>/dev/null \
            | awk -F"$TAB" -v home="$HOME" '
                $1 != "1" {
                    p=$2; if (index(p,home)==1) p="~" substr(p,length(home)+1)
                    if (!(p in seen)) { seen[p]=1; out=(out=="" ? p : out " | " p) }
                } END { print out }' | tr -d '\000-\037')"

        set_session_option "$SESSION_ID" "$SUMMARY_CACHE_WIN" "$wid"
        set_session_option "$SESSION_ID" "$SUMMARY_CACHE_AT" "$now"
        set_session_option "$SESSION_ID" "$SUMMARY_CACHE_GIT" "$gitraw"
        set_session_option "$SESSION_ID" "$SUMMARY_CACHE_DIRS" "$dirsraw"
    fi

    [ -n "$gitraw" ]  && { emit_summary_icon "$GIT_ICON" "$gitraw" "$width" head; LINES+=("$ROW"); }
    [ -n "$dirsraw" ] && { emit_summary_icon "$DIR_ICON" "$dirsraw" "$width" tail; LINES+=("$ROW"); }
}

# Sets the global ICON to the glyph for window $1, using CMD_MAP (built in
# build_lines): a space-separated "window_id:command" string. No subshell per
# call (sets a global) and no associative arrays (bash 3.2).
get_icon() {
    local e cmd=""
    for e in $CMD_MAP; do
        case "$e" in "$1:"*) cmd="${e#*:}"; break ;; esac
    done
    icon_for "$cmd"
}

# Serialize ROW_WIN (line-index -> window_id) to a per-pane option so the
# background mouse_reader can resolve clicks. Only called in mouse mode.
write_rowmap() {
    local k m=""
    for k in "${!ROW_WIN[@]}"; do m="${m}${k}:${ROW_WIN[$k]} "; done
    set_pane_option "$MY_PANE_ID" "$ROWMAP_OPTION" "$m"
}

# One tmux round-trip per loop iteration: visibility + everything build_lines
# and emit_summary need that isn't per-window. Sets VIS_CLIENTS, WIN_ACTIVE,
# COLLAPSED, WIDTH, CACHE_WIN, CACHE_AT, CACHE_GIT, CACHE_DIRS, SNAME.
# US-separated: the numeric fields can't contain 0x1f and the cache values are
# control-char-sanitized at write time (emit_summary). window_active_clients
# gets a 'c' prefix so an empty expansion (tmux < 3.1 doesn't know the format)
# can't shift fields; SNAME is last so read's remainder-merge absorbs any
# separator that still sneaks through.
read_state() {
    local state
    state="$(tmux display-message -p -t "$MY_TARGET" \
        "c#{window_active_clients}${US}#{window_active}${US}#{?${COLLAPSED_OPTION},#{${COLLAPSED_OPTION}},0}${US}#{pane_width}${US}#{${SUMMARY_CACHE_WIN}}${US}#{${SUMMARY_CACHE_AT}}${US}#{${SUMMARY_CACHE_GIT}}${US}#{${SUMMARY_CACHE_DIRS}}${US}#{session_name}" 2>/dev/null)"
    IFS="$US" read -r VIS_CLIENTS WIN_ACTIVE COLLAPSED WIDTH CACHE_WIN CACHE_AT CACHE_GIT CACHE_DIRS SNAME <<< "$state"
    VIS_CLIENTS="${VIS_CLIENTS#c}"
    [ -z "$WIDTH" ] && WIDTH=4
}

# Visible = a client is viewing this window; with zero clients on the server,
# the session's active window counts (detached/test servers — same rule as
# timer_focus.sh, via the shared server_client_count helper). Empty
# VIS_CLIENTS = old tmux without the format: fail open to the always-ticking
# behavior.
is_visible() {
    case "$VIS_CLIENTS" in
        '') return 0 ;;
        0)  : ;;
        *)  return 0 ;;
    esac
    [ "$WIN_ACTIVE" = "1" ] || return 1
    [ "$(server_client_count)" = "0" ]
}

# Sleep $1 seconds, waking early on USR1. The trap kills the sleep child, so a
# signal that lands anywhere after WOKEN was cleared — including between the
# WOKEN check below and `wait` — still interrupts. The post-spawn WOKEN check
# covers a signal that fired before the child existed for the trap to kill.
interruptible_sleep() {
    sleep "$1" &
    SLEEP_PID=$!
    [ "$WOKEN" = "1" ] && kill "$SLEEP_PID" 2>/dev/null
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
}

# Build the visual lines (LINES[]) and a line-index -> window_id map (ROW_WIN[])
# for click-to-select. Uses process substitution (done < <(...)) so the arrays
# accumulate in THIS shell — a piped `while` would lose them to a subshell. A
# row's line index is "${#LINES[@]} - 1" right after it's appended, which keeps the
# map correct across the header, the per-window rules, each window's timer line, and
# the active window's 0-2 summary lines (all appended as plain lines, with no
# ROW_WIN entry, so clicks on them stay no-ops).
# Reads COLLAPSED/WIDTH/SNAME from read_state (already fetched this iteration).
build_lines() {
    LINES=(); ROW_WIN=()
    local collapsed="$COLLAPSED" width="$WIDTH" i fmt flags icon now_s telapsed tlive tic

    # Rule line: rebuilt only when the pane width changes.
    if [ "$width" != "$RULE_WIDTH" ]; then
        RULE_LINE=""; i=0
        while [ "$i" -lt "$width" ]; do RULE_LINE="${RULE_LINE}${RULE}"; i=$((i + 1)); done
        RULE_LINE="${RULE_SGR}${RULE_LINE}${RESET}"
        RULE_WIDTH="$width"
    fi

    # window_id -> content command (active non-sidetab pane first), one query.
    CMD_MAP=""
    if [ "$icons_on" = "on" ]; then
        CMD_MAP="$(tmux list-panes -s -t "$SESSION_ID" \
            -F "#{window_id}${TAB}#{pane_active}${TAB}#{@is_sidetab}${TAB}#{pane_current_command}" \
            2>/dev/null \
            | awk -F"$TAB" '$3=="1"{next}
                {if($2=="1"){c[$1]=$4} else if(!($1 in c)){c[$1]=$4}}
                END{for(w in c) printf "%s:%s ", w, c[w]}')"
    fi

    if [ "$collapsed" = "1" ]; then
        LINES+=("")                       # line 0: leading blank
        fmt="#{window_active}${TAB}#{window_bell_flag}${TAB}#{window_activity_flag}${TAB}#{?${FLAG_OPTION},#{${FLAG_OPTION}},0}${TAB}#{window_index}${TAB}#{window_id}"
        while IFS="$TAB" read -r active bell activity flagidx idx wid; do
            icon=""; [ "$icons_on" = "on" ] && { get_icon "$wid"; icon="$ICON"; }
            # hasnote is hardcoded 0: the collapsed strip is ~5 columns wide —
            # number + command icon already fill it, so there is no room for a
            # note glyph. Notes are an expanded-mode affordance.
            emit_row "$active" "$bell" "$activity" "$flagidx" "$idx" "" "" "$width" 1 "$icon" 0
            LINES+=("$ROW")
            ROW_WIN[$(( ${#LINES[@]} - 1 ))]="$wid"
        done < <(tmux list-windows -t "$SESSION_ID" -F "$fmt" 2>/dev/null)
        [ "$MOUSE_ON" = "on" ] && write_rowmap
        return
    fi

    emit_header "$SNAME" "$width"
    LINES+=("$ROW")                       # line 0: header
    now_s="$(date +%s)"

    # All fields are non-empty booleans/numbers/ids (no #{window_flags}, which can
    # be empty and would collapse under tab-splitting). Flags are rebuilt below.
    # hasnote is the note's PRESENCE (1/0) — never the text. The text is
    # sanitized at write time, but keeping it out of this TAB-split format
    # removes the whole class of "a note broke every row" failures.
    # It uses #{!=:…,} (is the value a non-empty string?) rather than the
    # #{?OPT,…} truthiness test the other options use: those hold a constrained
    # domain (flag indices >= 1, timer states run/pause/hold), but a note is free
    # text, and tmux's ternary reads the literal value "0" as FALSE — a note of
    # "0" is set yet would show no glyph. The comparison splits on the literal
    # comma before expanding, so a comma inside the note text is safe.
    fmt="#{window_active}${TAB}#{window_bell_flag}${TAB}#{window_activity_flag}${TAB}#{window_last_flag}${TAB}#{window_zoomed_flag}${TAB}#{?${FLAG_OPTION},#{${FLAG_OPTION}},0}${TAB}#{?${TIMER_STATE_OPTION},#{${TIMER_STATE_OPTION}},-}${TAB}#{?${TIMER_START_OPTION},#{${TIMER_START_OPTION}},0}${TAB}#{?${TIMER_ACC_OPTION},#{${TIMER_ACC_OPTION}},0}${TAB}#{!=:#{${NOTE_OPTION}},}${TAB}#{window_index}${TAB}#{window_id}${TAB}#{window_name}"
    while IFS="$TAB" read -r active bell activity last zoomed flagidx tstate tstart tacc hasnote idx wid name; do
        flags=""
        [ "$active" = "1" ] && flags="*"
        [ "$last" = "1" ] && flags="${flags}-"
        [ "$zoomed" = "1" ] && flags="${flags}Z"
        LINES+=("$RULE_LINE")                         # rule line
        icon=""; [ "$icons_on" = "on" ] && { get_icon "$wid"; icon="$ICON"; }
        emit_row "$active" "$bell" "$activity" "$flagidx" "$idx" "$flags" "$name" "$width" 0 "$icon" "$hasnote"
        LINES+=("$ROW")
        ROW_WIN[$(( ${#LINES[@]} - 1 ))]="$wid"       # index of the row just added
        if [ "$tstate" = "run" ] || [ "$tstate" = "pause" ] || [ "$tstate" = "hold" ]; then
            case "$tacc" in ''|*[!0-9]*) tacc=0 ;; esac
            telapsed="$tacc"
            case "$tstate" in
                run)  tic="$TIMER_RUN_ICON" ;;
                hold) tic="$TIMER_HOLD_ICON" ;;
                *)    tic="$TIMER_PAUSE_ICON" ;;
            esac
            if [ "$tstate" = "run" ]; then
                case "$tstart" in ''|*[!0-9]*) tstart="$now_s" ;; esac
                tlive=$((now_s - tstart)); [ "$tlive" -lt 0 ] && tlive=0   # clock skew clamp
                telapsed=$((tacc + tlive))
            fi
            fmt_hms "$telapsed"
            emit_summary_icon "$tic" "$HMS" "$width" head
            LINES+=("$ROW")
        fi
        # Summary only when someone can see it: a hidden sidebar's self-heal
        # rebuild would otherwise re-run the git/cwd probes (the shared cache
        # is usually past TTL by then) for lines nobody is looking at. The
        # wake-on-visible rebuild restores them instantly.
        if [ "$active" = "1" ] && [ "$summary_on" = "on" ] && [ "$VISIBLE" = "1" ]; then
            emit_summary "$wid" "$width" "$now_s"
        fi
    done < <(tmux list-windows -t "$SESSION_ID" -F "$fmt" 2>/dev/null)
    [ "$MOUSE_ON" = "on" ] && write_rowmap
}

draw_lines() {
    printf '\033[H'
    local line
    for line in "${LINES[@]}"; do
        printf '%s\033[K\n' "$line"
    done
    printf '\033[J'
}

# Background click handler (mouse mode), run as a child so the main loop stays
# free to redraw on a timer. Blocks reading SGR mouse sequences; a left-button
# press maps SGR row Y (1-based, pane-relative -> line index Y-1) to a window via
# the @sidetabs_rowmap pane option (written each draw by write_rowmap), selects
# it, and keeps focus in that window's sidebar so you can keep clicking. A click
# on a non-row line (header/rule/summary) maps to no window and is a no-op.
mouse_reader() {
    local c d seq idx wid sp rowmap e
    while IFS= read -rsn1 c; do
        [ "$c" = "$ESC" ] || continue
        seq=""
        while IFS= read -rsn1 d; do
            seq+="$d"
            case "$d" in [a-zA-Z]) break ;; esac
        done
        [[ "$seq" =~ ^\[\<([0-9]+)\;([0-9]+)\;([0-9]+)M$ ]] || continue
        [ "${BASH_REMATCH[1]}" = "0" ] || continue
        idx=$(( ${BASH_REMATCH[3]} - 1 ))
        rowmap="$(get_pane_option "$MY_PANE_ID" "$ROWMAP_OPTION" "")"
        wid=""
        for e in $rowmap; do
            case "$e" in "$idx:"*) wid="${e#*:}"; break ;; esac
        done
        [ -z "$wid" ] && continue
        tmux select-window -t "$wid" 2>/dev/null || continue
        sp="$(find_sidetab_pane "$wid")"
        [ -n "$sp" ] && tmux select-pane -t "$sp" 2>/dev/null || true
    done
}

# In mouse mode a background reader consumes clicks; the main loop just redraws on
# a timer, woken early by refresh.sh's USR1 for instant updates on window
# switches, bells, renames, etc.
if [ "$MOUSE_ON" = "on" ]; then
    # < /dev/tty because bash redirects a backgrounded job's stdin to /dev/null
    # (job control off); without this the reader hits EOF and exits immediately.
    mouse_reader < /dev/tty &
    MOUSE_READER_PID="$!"
fi

RULE_WIDTH=""; RULE_LINE=""

# Main loop. Every iteration rebuilds and redraws; only the sleep differs:
# visible sidebars tick fast (live timers, activity), hidden ones sleep
# HIDDEN_TICK_SECS and are woken early by refresh.sh's USR1. Rebuilding
# unconditionally means a USR1 can never be LOST — one landing anywhere in the
# iteration either kills the in-flight sleep (trap) or leaves WOKEN=1 so
# interruptible_sleep returns immediately; worst case is one redundant rebuild.
# It also makes the hidden tick a true staleness bound after a swallowed
# debounced signal, and guarantees a freshly spawned sidebar draws (and writes
# its mouse rowmap) before its first sleep.
while true; do
    WOKEN=0
    read_state
    VISIBLE=0; is_visible && VISIBLE=1
    build_lines
    draw_lines
    if [ "$VISIBLE" = "1" ]; then
        interruptible_sleep 0.5
    else
        interruptible_sleep "$HIDDEN_TICK_SECS"
    fi
done
