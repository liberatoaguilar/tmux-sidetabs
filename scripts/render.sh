#!/usr/bin/env bash
# Long-lived render loop. Runs inside the sidetab pane.
#
# Redraws every second (and immediately on SIGUSR1 from refresh.sh). The draw
# is flicker-free: it homes the cursor and overwrites each line with a
# clear-to-EOL, then clears below — no full-screen wipe. Reprinting identical
# content is therefore invisible, which also lets us recover transparently when
# tmux repaints the pane (e.g. right after the pane is created or resized).
#
# Layout (expanded):
#   [ session-name ‹cap› ]          header pill (like status-left)
#   ────────────────────            rule
#   ` N ‹thin› name flags … ‹cap›`  one full-width pill per window
#   <summary lines>                 under the ACTIVE window only
# State colors (nord by default): bell = red, active = teal, activity = yellow
# text, idle = grey. Only the number is bold.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

MY_PANE_ID="$TMUX_PANE"

# Determine which session's windows to list from our OWN pane. Passing the id
# as a command argument is unreliable: tmux's command parser strips quoting and
# then sh expands tokens like `$0`, corrupting it. Querying the pane is robust.
SESSION_ID="$(tmux display-message -p -t "$MY_PANE_ID" '#{session_id}' 2>/dev/null)"
[ -z "$SESSION_ID" ] && SESSION_ID="$1"

# No-op handler: its only job is to interrupt `read`/`wait` so the loop redraws now.
trap ':' USR1

set_pane_option "$MY_PANE_ID" "$RENDER_PID_OPTION" "$$"

# Click-to-select (self-mouse): when @sidetabs-mouse is on, THIS pane enables its
# own mouse reporting and reads its own clicks — no global tmux `mouse` needed.
# tmux forwards mouse events to the focused pane's app that requested them, so
# clicks only register while this sidebar pane is focused (the workflow: C-h into
# the sidebar, then click a row). Clicks-only modes (1000 + SGR 1006); no
# 1002/1003 motion tracking, so no motion spam.
MOUSE_ON="$(get_tmux_option '@sidetabs-mouse' "$DEFAULT_MOUSE")"
SAVED_STTY=""
if [ "$MOUSE_ON" = "on" ]; then
    SAVED_STTY="$(stty -g 2>/dev/null || true)"
    stty -echo -icanon min 1 time 0 2>/dev/null || true
    printf '\033[?1000h\033[?1006h'
fi

# Hide cursor; restore cursor + mouse + tty on exit.
printf '\033[?25l'
cleanup() {
    printf '\033[?25h'
    [ "$MOUSE_ON" = "on" ] && printf '\033[?1000l\033[?1006l'
    [ -n "$SAVED_STTY" ] && stty "$SAVED_STTY" 2>/dev/null
}
trap 'cleanup; exit 0' EXIT INT TERM

# --- Theme -----------------------------------------------------------------
ESC="$(printf '\033')"
ARROW="$(printf '\xee\x82\xb0')"   # U+E0B0 powerline right cap (solid)
THIN="$(printf '\xee\x82\xb1')"    # U+E0B1 powerline right separator (thin)
RULE="$(printf '\xe2\x94\x80')"    # U+2500 box-drawing horizontal
GIT_ICON="$(printf '\xee\x82\xa0')"  # U+E0A0 powerline branch
DIR_ICON="$(printf '\xef\x81\xbb')"  # U+F07B folder
TAB="$(printf '\t')"
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

# A full-width header pill (bold) for the session name.
emit_header() {
    local label="$1" width="$2" avail used pad spaces
    avail=$((width - 1)); [ "$avail" -lt 0 ] && avail=0
    label=" ${label} "
    used=${#label}
    if [ "$used" -gt "$avail" ]; then label="${label:0:avail}"; used="$avail"; fi
    pad=$((avail - used)); [ "$pad" -lt 0 ] && pad=0
    spaces="$(printf '%*s' "$pad" '')"
    printf '%s%s%s%s%s%s%s%s\n' "$SEG_HDR" "$BOLD" "$label" "$NOBOLD" "$spaces" "$CAP_HDR" "$ARROW" "$RESET"
}

# emit_row <active> <bell> <activity> <idx> <flags> <name> <width> <collapsed>
emit_row() {
    local active="$1" bell="$2" activity="$3" idx="$4" flags="$5" name="$6" width="$7" collapsed="$8"
    local seg cap avail nm used pad spaces
    if [ "$bell" = "1" ]; then seg="$SEG_BELL"; cap="$CAP_BELL"
    elif [ "$active" = "1" ]; then seg="$SEG_ACTIVE"; cap="$CAP_ACTIVE"
    elif [ "$activity" = "1" ]; then seg="$SEG_ACT"; cap="$CAP_ACT"
    else seg="$SEG_IDLE"; cap="$CAP_IDLE"; fi

    avail=$((width - 1)); [ "$avail" -lt 0 ] && avail=0

    if [ "$collapsed" = "1" ]; then
        used=$((1 + ${#idx}))
        pad=$((avail - used)); [ "$pad" -lt 0 ] && pad=0
        spaces="$(printf '%*s' "$pad" '')"
        printf '%s %s%s%s%s%s%s%s\n' \
            "$seg" "$BOLD" "$idx" "$NOBOLD" "$spaces" "$cap" "$ARROW" "$RESET"
        return
    fi

    nm=" ${name}"
    [ -n "$flags" ] && nm="${nm} ${flags}"
    nm="${nm} "
    used=$((1 + ${#idx} + 1 + 1 + ${#nm}))
    if [ "$used" -gt "$avail" ]; then
        local over=$((used - avail)) newlen
        newlen=$((${#nm} - over)); [ "$newlen" -lt 0 ] && newlen=0
        nm="${nm:0:newlen}"
        used=$((1 + ${#idx} + 1 + 1 + ${#nm}))
    fi
    pad=$((avail - used)); [ "$pad" -lt 0 ] && pad=0
    spaces="$(printf '%*s' "$pad" '')"

    printf '%s %s%s%s %s%s%s%s%s%s\n' \
        "$seg" "$BOLD" "$idx" "$NOBOLD" "$THIN" "$nm" "$spaces" "$cap" "$ARROW" "$RESET"
}

# One dim summary line: " <icon> <text>", truncated to width with the icon kept.
# mode=head keeps the start of the text (branch + commit start); mode=tail keeps
# the end (so a single dir keeps its basename, e.g. …/tmux-sidetabs).
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
    printf '%s %s %s%s\n' "$SUMMARY_SGR" "$icon" "$text" "$RESET"
}

# Summary under the active window: git (branch + last commit) and working dir(s)
# of the window's content panes. Cached per-session for SUMMARY_TTL_MS so the
# 1s redraw across all sidetabs doesn't re-spawn git.
emit_summary() {
    local wid="$1" width="$2"
    local gitraw dirsraw now cw at

    now="$(now_ms)"
    cw="$(get_session_option "$SESSION_ID" "$SUMMARY_CACHE_WIN" "")"
    at="$(get_session_option "$SESSION_ID" "$SUMMARY_CACHE_AT" "0")"

    if [ "$cw" = "$wid" ] && [ "$((now - at))" -lt "$SUMMARY_TTL_MS" ]; then
        gitraw="$(get_session_option "$SESSION_ID" "$SUMMARY_CACHE_GIT" "")"
        dirsraw="$(get_session_option "$SESSION_ID" "$SUMMARY_CACHE_DIRS" "")"
    else
        local paths p br sub
        # Content-pane cwds, active pane first. Use the first that's a git repo
        # for the branch line (the active pane may not be the repo one).
        paths="$(tmux list-panes -t "$wid" \
            -F "#{pane_active}${TAB}#{@is_sidetab}${TAB}#{pane_current_path}" \
            2>/dev/null | awk -F"$TAB" '$2 != "1"' | sort -r | cut -d"$TAB" -f3)"

        gitraw=""
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            br="$(git -C "$p" symbolic-ref --short -q HEAD 2>/dev/null \
                  || git -C "$p" rev-parse --short HEAD 2>/dev/null)"
            if [ -n "$br" ]; then
                sub="$(git -C "$p" log -1 --format=%s 2>/dev/null)"
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
                } END { print out }')"

        set_session_option "$SESSION_ID" "$SUMMARY_CACHE_WIN" "$wid"
        set_session_option "$SESSION_ID" "$SUMMARY_CACHE_AT" "$now"
        set_session_option "$SESSION_ID" "$SUMMARY_CACHE_GIT" "$gitraw"
        set_session_option "$SESSION_ID" "$SUMMARY_CACHE_DIRS" "$dirsraw"
    fi

    [ -n "$gitraw" ]  && emit_summary_icon "$GIT_ICON" "$gitraw" "$width" head
    [ -n "$dirsraw" ] && emit_summary_icon "$DIR_ICON" "$dirsraw" "$width" tail
}

# Build the visual lines (LINES[]) and a line-index -> window_id map (ROW_WIN[])
# for click-to-select. Uses process substitution (done < <(...)) so the arrays
# accumulate in THIS shell — a piped `while` would lose them to a subshell. A
# row's line index is "${#LINES[@]} - 1" right after it's appended, which keeps the
# map correct across the header, the per-window rules, and the active window's 0-2
# summary lines (appended as plain lines, with no ROW_WIN entry).
build_lines() {
    LINES=(); ROW_WIN=()
    local collapsed width rule i sname fmt flags summ sline
    collapsed="$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")"
    width="$(tmux display-message -p -t "$MY_PANE_ID" '#{pane_width}' 2>/dev/null)"
    [ -z "$width" ] && width=4

    rule=""; i=0
    while [ "$i" -lt "$width" ]; do rule="${rule}${RULE}"; i=$((i + 1)); done
    rule="${RULE_SGR}${rule}${RESET}"

    if [ "$collapsed" = "1" ]; then
        LINES+=("")                       # line 0: leading blank
        fmt="#{window_active}${TAB}#{window_bell_flag}${TAB}#{window_activity_flag}${TAB}#{window_index}${TAB}#{window_id}"
        while IFS="$TAB" read -r active bell activity idx wid; do
            LINES+=("$(emit_row "$active" "$bell" "$activity" "$idx" "" "" "$width" 1)")
            ROW_WIN[$(( ${#LINES[@]} - 1 ))]="$wid"
        done < <(tmux list-windows -t "$SESSION_ID" -F "$fmt" 2>/dev/null)
        return
    fi

    sname="$(tmux display-message -p -t "$SESSION_ID" '#{session_name}' 2>/dev/null)"
    LINES+=("$(emit_header "$sname" "$width")")   # line 0: header

    # All fields are non-empty booleans/numbers/ids (no #{window_flags}, which can
    # be empty and would collapse under tab-splitting). Flags are rebuilt below.
    fmt="#{window_active}${TAB}#{window_bell_flag}${TAB}#{window_activity_flag}${TAB}#{window_last_flag}${TAB}#{window_zoomed_flag}${TAB}#{window_index}${TAB}#{window_id}${TAB}#{window_name}"
    while IFS="$TAB" read -r active bell activity last zoomed idx wid name; do
        flags=""
        [ "$active" = "1" ] && flags="*"
        [ "$last" = "1" ] && flags="${flags}-"
        [ "$zoomed" = "1" ] && flags="${flags}Z"
        LINES+=("$rule")                              # rule line
        LINES+=("$(emit_row "$active" "$bell" "$activity" "$idx" "$flags" "$name" "$width" 0)")
        ROW_WIN[$(( ${#LINES[@]} - 1 ))]="$wid"       # index of the row just added
        if [ "$active" = "1" ] && [ "$summary_on" = "on" ]; then
            summ="$(emit_summary "$wid" "$width")"
            if [ -n "$summ" ]; then
                while IFS= read -r sline; do LINES+=("$sline"); done <<< "$summ"
            fi
        fi
    done < <(tmux list-windows -t "$SESSION_ID" -F "$fmt" 2>/dev/null)
}

draw_lines() {
    printf '\033[H'
    local line
    for line in "${LINES[@]}"; do
        printf '%s\033[K\n' "$line"
    done
    printf '\033[J'
}

# Map a click at SGR row Y (1-based) to a window and switch to it. SGR mouse
# coordinates are pane-relative, so line index = Y - 1. Clicks on non-row lines
# (header/rule/summary) map to no window and are a no-op (you're already here).
on_click() {
    local idx=$(( $1 - 1 )) wid cp
    wid="${ROW_WIN[$idx]:-}"
    [ -z "$wid" ] && return
    tmux select-window -t "$wid" 2>/dev/null || return
    cp="$(find_content_pane "$wid" || true)"
    [ -n "$cp" ] && tmux select-pane -t "$cp" 2>/dev/null || true
}

# Wait up to ~1s for input. On a left-button SGR press (ESC [ < 0 ; x ; y M),
# switch windows. On timeout or USR1 (the immediate-redraw signal) just return so
# the loop redraws — preserving the 1s cadence.
read_mouse() {
    local c d seq b y
    IFS= read -rsn1 -t 1 c || return
    [ "$c" = "$ESC" ] || return
    seq=""
    while IFS= read -rsn1 -t 1 d; do
        seq+="$d"
        case "$d" in [a-zA-Z]) break ;; esac
    done
    if [[ "$seq" =~ ^\[\<([0-9]+)\;([0-9]+)\;([0-9]+)M$ ]]; then
        b="${BASH_REMATCH[1]}"; y="${BASH_REMATCH[3]}"
        [ "$b" = "0" ] && on_click "$y"
    fi
}

while true; do
    build_lines
    draw_lines
    if [ "$MOUSE_ON" = "on" ]; then
        read_mouse
    else
        sleep 1 &
        wait $! 2>/dev/null
    fi
done
