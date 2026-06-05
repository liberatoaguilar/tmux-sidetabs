#!/usr/bin/env bash
# Window search/jump popup body. Run inside `display-popup -E` with the
# originating session id as $1. Lists the session's windows for fzf; on pick,
# selects the window and focuses its sidebar pane.
#
# Test hooks (skip fzf):
#   SIDETABS_SEARCH_LIST=1     print candidate lines and exit
#   SIDETABS_SEARCH_PICK=<wid> act on that window id and exit
set -uo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/icons.sh"

SESSION_ID="${1:-}"
[ -z "$SESSION_ID" ] && SESSION_ID="$(tmux display-message -p '#{session_id}' 2>/dev/null)"
[ -z "$SESSION_ID" ] && exit 0

TAB="$(printf '\t')"
US="$(printf '\037')"   # unit separator: packs command<US>cwd in the map

# Emit "window_id<TAB><icon> <index>  <name>  <command>  <~cwd>" per window.
candidates() {
    local map wid idx name entry cmd cwd
    # window_id -> command<US>cwd for the active non-sidetab pane (else first).
    map="$(tmux list-panes -s -t "$SESSION_ID" \
        -F "#{window_id}${TAB}#{pane_active}${TAB}#{@is_sidetab}${TAB}#{pane_current_command}${TAB}#{pane_current_path}" \
        2>/dev/null \
        | awk -F"$TAB" -v US="$US" '
            $3=="1"{next}
            { v=$4 US $5; if($2=="1"){c[$1]=v} else if(!($1 in c)){c[$1]=v} }
            END{ for(w in c) print w "\t" c[w] }')"
    while IFS="$TAB" read -r wid idx name; do
        entry="$(printf '%s\n' "$map" | awk -F"$TAB" -v w="$wid" '$1==w{print $2; exit}')"
        cmd="${entry%%${US}*}"
        cwd="${entry#*${US}}"
        [ "$cwd" = "$entry" ] && cwd=""        # no US -> no entry found
        case "$cwd" in "$HOME"/*|"$HOME") cwd="~${cwd#$HOME}" ;; esac
        icon_for "$cmd"
        printf '%s\t%s %s  %s  %s  %s\n' "$wid" "$ICON" "$idx" "$name" "$cmd" "$cwd"
    done < <(tmux list-windows -t "$SESSION_ID" \
                 -F "#{window_id}${TAB}#{window_index}${TAB}#{window_name}" 2>/dev/null)
}

# Switch to window $1 and focus its sidebar pane.
do_pick() {
    local wid="$1" sp
    [ -z "$wid" ] && return 0
    tmux select-window -t "$wid" 2>/dev/null || return 0
    sp="$(find_sidetab_pane "$wid")"
    [ -n "$sp" ] && tmux select-pane -t "$sp" 2>/dev/null || true
}

[ -n "${SIDETABS_SEARCH_LIST:-}" ] && { candidates; exit 0; }
[ -n "${SIDETABS_SEARCH_PICK:-}" ] && { do_pick "$SIDETABS_SEARCH_PICK"; exit 0; }

sel="$(candidates | fzf --delimiter="$TAB" --with-nth=2 --no-sort --prompt='window> ')"
[ -z "$sel" ] && exit 0    # Esc / no match
do_pick "${sel%%${TAB}*}"
