#!/usr/bin/env bash
# Long-lived render loop. Runs inside the sidetab pane.
#
# Redraws every second (and immediately on SIGUSR1 from refresh.sh). The draw
# is flicker-free: it homes the cursor and overwrites each line with a
# clear-to-EOL, then clears below — no full-screen wipe. Reprinting identical
# content is therefore invisible, which also lets us recover transparently when
# tmux repaints the pane (e.g. right after the pane is created or resized).
#
# Each window is a full-width powerline pill:  ` N ‹arrow› name flags … ‹cap› `
# All pills are the same width so the trailing caps line up. Only the number is
# bold. State colors (nord by default): bell = red, active = teal, activity =
# yellow text, idle = grey. A blank line sits above the first window and a thin
# rule divides the entries.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

MY_PANE_ID="$TMUX_PANE"

# Determine which session's windows to list from our OWN pane. Passing the id
# as a command argument is unreliable: tmux's command parser strips quoting and
# then sh expands tokens like `$0`, corrupting it. Querying the pane is robust.
SESSION_ID="$(tmux display-message -p -t "$MY_PANE_ID" '#{session_id}' 2>/dev/null)"
[ -z "$SESSION_ID" ] && SESSION_ID="$1"

# No-op handler: its only job is to interrupt `wait` so the loop redraws now.
trap ':' USR1

set_pane_option "$MY_PANE_ID" "$RENDER_PID_OPTION" "$$"

# Hide cursor + restore on exit.
printf '\033[?25l'
trap 'printf "\033[?25h"; exit 0' EXIT INT TERM

# --- Theme -----------------------------------------------------------------
ESC="$(printf '\033')"
ARROW="$(printf '\xee\x82\xb0')"   # U+E0B0 powerline right cap (solid)
THIN="$(printf '\xee\x82\xb1')"    # U+E0B1 powerline right separator (thin)
RULE="$(printf '\xe2\x94\x80')"    # U+2500 box-drawing horizontal
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

# A segment paints bg+fg (no bold); its cap paints the segment's bg as fg over a
# default bg so the trailing arrow "points" out of the colored block.
seg_sgr() { printf '%s[48;2;%s;38;2;%sm' "$ESC" "$(hex_rgb "$1")" "$(hex_rgb "$2")"; }
cap_sgr() { printf '%s[49;38;2;%sm' "$ESC" "$(hex_rgb "$1")"; }

SEG_ACTIVE="$(seg_sgr "$active_bg" "$active_fg")"; CAP_ACTIVE="$(cap_sgr "$active_bg")"
SEG_IDLE="$(seg_sgr "$idle_bg" "$idle_fg")";       CAP_IDLE="$(cap_sgr "$idle_bg")"
SEG_BELL="$(seg_sgr "$bell_bg" "$bell_fg")";       CAP_BELL="$(cap_sgr "$bell_bg")"
SEG_ACT="$(seg_sgr "$idle_bg" "$activity_fg")";    CAP_ACT="$(cap_sgr "$idle_bg")"
RULE_SGR="${ESC}[49;38;2;$(hex_rgb "$rule_fg")m"

# emit_row <active> <bell> <activity> <idx> <flags> <name> <width> <collapsed>
emit_row() {
    local active="$1" bell="$2" activity="$3" idx="$4" flags="$5" name="$6" width="$7" collapsed="$8"
    local seg cap avail nm used pad spaces
    if [ "$bell" = "1" ]; then seg="$SEG_BELL"; cap="$CAP_BELL"
    elif [ "$active" = "1" ]; then seg="$SEG_ACTIVE"; cap="$CAP_ACTIVE"
    elif [ "$activity" = "1" ]; then seg="$SEG_ACT"; cap="$CAP_ACT"
    else seg="$SEG_IDLE"; cap="$CAP_IDLE"; fi

    avail=$((width - 1))            # reserve the last column for the trailing cap
    [ "$avail" -lt 0 ] && avail=0

    if [ "$collapsed" = "1" ]; then
        # ` N ` padded to the column, then cap.
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
    # Visible cols before padding: " " + idx + " " + arrow(1) + nm
    used=$((1 + ${#idx} + 1 + 1 + ${#nm}))
    if [ "$used" -gt "$avail" ]; then
        local over=$((used - avail)) newlen
        newlen=$((${#nm} - over)); [ "$newlen" -lt 0 ] && newlen=0
        nm="${nm:0:newlen}"
        used=$((1 + ${#idx} + 1 + 1 + ${#nm}))
    fi
    pad=$((avail - used)); [ "$pad" -lt 0 ] && pad=0
    spaces="$(printf '%*s' "$pad" '')"

    # seg ' ' BOLD idx NOBOLD ' ' thin-sep nm spaces cap solid-arrow reset
    printf '%s %s%s%s %s%s%s%s%s%s\n' \
        "$seg" "$BOLD" "$idx" "$NOBOLD" "$THIN" "$nm" "$spaces" "$cap" "$ARROW" "$RESET"
}

emit_lines() {
    local collapsed width fmt rule first i
    collapsed="$(get_session_option "$SESSION_ID" "$COLLAPSED_OPTION" "0")"
    width="$(tmux display-message -p -t "$MY_PANE_ID" '#{pane_width}' 2>/dev/null)"
    [ -z "$width" ] && width=4

    rule=""; i=0
    while [ "$i" -lt "$width" ]; do rule="${rule}${RULE}"; i=$((i + 1)); done
    rule="${RULE_SGR}${rule}${RESET}"

    printf '\n'   # one blank row above the first window

    if [ "$collapsed" = "1" ]; then
        fmt="#{window_active}${TAB}#{window_bell_flag}${TAB}#{window_activity_flag}${TAB}#{window_index}"
        tmux list-windows -t "$SESSION_ID" -F "$fmt" 2>/dev/null \
            | while IFS="$TAB" read -r active bell activity idx; do
                emit_row "$active" "$bell" "$activity" "$idx" "" "" "$width" 1
              done
    else
        fmt="#{window_active}${TAB}#{window_bell_flag}${TAB}#{window_activity_flag}${TAB}#{window_index}${TAB}#{window_flags}${TAB}#{window_name}"
        first=1
        tmux list-windows -t "$SESSION_ID" -F "$fmt" 2>/dev/null \
            | while IFS="$TAB" read -r active bell activity idx flags name; do
                [ "$first" -eq 0 ] && printf '%s\n' "$rule"
                first=0
                emit_row "$active" "$bell" "$activity" "$idx" "$flags" "$name" "$width" 0
              done
    fi
}

draw() {
    printf '\033[H'
    emit_lines | while IFS= read -r line; do
        printf '%s\033[K\n' "$line"
    done
    printf '\033[J'
}

while true; do
    draw
    sleep 1 &
    wait $! 2>/dev/null
done
