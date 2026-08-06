#!/usr/bin/env bash
# Per-window free-text note. Live state is the window user option
# @sidetabs_note; the durable record is a TSV store (@sidetabs-note-store) keyed
# by (session name, window name), so notes come back after a server restart via
# `note.sh restore` (called from resurrect_post.sh).
#
# The sidebar shows PRESENCE only — a sticky-note glyph on the row, expanded
# mode only — never the text. Text is sanitized on the way in (control chars
# stripped, spaces collapsed, capped) so it can never break the TAB-separated
# render format or the TSV store.
#
# Bound (sidebar-focused): @sidetabs-note-key opens the edit popup.
# Usage: note.sh <set|clear|edit-popup|restore> [window_id] [text...]
#   set <wid> <text...>  sanitize + store + render (empty after sanitizing = clear)
#   clear <wid>          unset the option and drop the store row
#   edit-popup <wid>     $EDITOR on a temp file seeded with the current note;
#                        on exit the whole file becomes one sanitized line
#   restore              re-seed live windows from the store (never clobbers)
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

CMD="${1:-edit-popup}"
TAB="$(printf '\t')"
US=$'\x1f'

store_path() { get_tmux_option '@sidetabs-note-store' "$DEFAULT_NOTE_STORE"; }

# Sanitize $1 into the global NOTE: TAB/newline/CR become spaces (so a multi-line
# editor buffer collapses to a readable single line instead of running words
# together), every remaining control char is dropped, runs of spaces collapse,
# ends are trimmed, and the result is capped at NOTE_MAX_CHARS. The result is
# guaranteed free of TAB/US/newline — the invariant both the render format and
# the TSV store depend on.
sanitize_note() {
    NOTE="$(printf '%s' "$1" | tr '\011\012\015' '   ' | tr -d '\000-\037' | tr -s ' ')"
    NOTE="${NOTE# }"; NOTE="${NOTE% }"
    if [ "${#NOTE}" -gt "$NOTE_MAX_CHARS" ]; then
        NOTE="${NOTE:0:$NOTE_MAX_CHARS}"
        NOTE="${NOTE% }"
    fi
}

# Sets SNAME/WNAME for window $1 (empty if it is gone). Tabs are squashed the
# way timer.sh's log_event does it — window/session names may legally contain
# one, and the store row must stay exactly three fields.
window_key() {
    local names
    names="$(tmux display-message -p -t "$1" "#{session_name}${TAB}#{window_name}" 2>/dev/null)"
    SNAME="${names%%"$TAB"*}"; WNAME="${names#*"$TAB"}"
    SNAME="${SNAME//$TAB/ }"; WNAME="${WNAME//$TAB/ }"
}

# Serialize the read-modify-write below. Without it two note.sh runs for
# DIFFERENT windows (two clients pressing the key at once, or a loop tagging
# several windows) can both read the store before either writes back, and the
# second mv silently drops the first one's row — the live window option survives
# but the durable record used by `note.sh restore` does not. mkdir is the atomic
# primitive available everywhere (macOS has no flock(1)); timer.sh's lock_win
# uses the same pattern. Best-effort in both directions: after ~1s we assume the
# holder died mid-write, break the lock and proceed, because losing a row to a
# rare race still beats hanging a keypress or refusing to save the note.
store_lock() {
    local d="$1" i=0
    while ! mkdir "$d" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -ge 20 ]; then
            rmdir "$d" 2>/dev/null || return 1
            mkdir "$d" 2>/dev/null || return 1
            return 0
        fi
        sleep 0.05
    done
    return 0
}

# Rewrite the store without the (session, window) key, optionally appending a
# new row. Temp file + mv so a reader never sees a half-written store; the lock
# is what keeps two concurrent rewrites from clobbering each other. Every
# failure path is best-effort: an unwritable store must not abort the live
# state change.
# store_write <sname> <wname> [note]   (no note = delete only)
store_write() {
    local f lockd held=0
    f="$(store_path)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    lockd="${f}.lock"
    store_lock "$lockd" && held=1
    store_rewrite "$f" "$@"
    [ "$held" = "1" ] && rmdir "$lockd" 2>/dev/null
    return 0
}

# The critical section of store_write: everything between reading the store and
# replacing it. Split out so every early return still releases the lock.
# store_rewrite <storefile> <sname> <wname> [note]
store_rewrite() {
    local f tmpf
    f="$1"; shift
    tmpf="${f}.tmp.$$"
    if [ -f "$f" ]; then
        awk -F"$TAB" -v s="$1" -v w="$2" '!($1 == s && $2 == w)' "$f" > "$tmpf" 2>/dev/null \
            || { rm -f "$tmpf" 2>/dev/null; return 0; }
    else
        : > "$tmpf" 2>/dev/null || return 0
    fi
    if [ "$#" -ge 3 ]; then
        printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmpf" 2>/dev/null \
            || { rm -f "$tmpf" 2>/dev/null; return 0; }
    fi
    mv "$tmpf" "$f" 2>/dev/null || rm -f "$tmpf" 2>/dev/null || true
}

# apply_note <window_id> <raw text>: the shared set/clear body. An empty result
# after sanitizing is a clear — "set it to nothing" and "clear it" are the same
# user intent, and it's the only sane reading of an emptied editor buffer.
apply_note() {
    local wid="$1" raw="$2"
    sanitize_note "$raw"
    window_key "$wid"
    if [ -z "$NOTE" ]; then
        unset_window_option "$wid" "$NOTE_OPTION"
        [ -n "$WNAME" ] && store_write "$SNAME" "$WNAME"
    else
        set_window_option "$wid" "$NOTE_OPTION" "$NOTE"
        [ -n "$WNAME" ] && store_write "$SNAME" "$WNAME" "$NOTE"
    fi
    "$CURRENT_DIR/refresh.sh" force
}

case "$CMD" in
set)
    WID="${2:-}"
    [ -z "$WID" ] && WID="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    [ -z "$WID" ] && exit 0
    shift 2 2>/dev/null || shift $#
    apply_note "$WID" "$*"
    ;;

clear)
    WID="${2:-}"
    [ -z "$WID" ] && WID="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    [ -z "$WID" ] && exit 0
    apply_note "$WID" ""
    ;;

edit-popup)
    # Runs inside `display-popup -E`, so $EDITOR gets a real terminal. Honoring
    # $EDITOR (and $VISUAL) is also the test seam: a non-interactive fake editor
    # drives the whole set/clear path.
    WID="${2:-}"
    [ -z "$WID" ] && WID="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    [ -z "$WID" ] && exit 0
    TMPF="$(mktemp "${TMPDIR:-/tmp}/sidetabs_note.XXXXXX")" || exit 0
    trap 'rm -f "$TMPF" 2>/dev/null' EXIT INT TERM HUP
    CUR="$(get_window_option "$WID" "$NOTE_OPTION" "")"
    [ -n "$CUR" ] && printf '%s\n' "$CUR" > "$TMPF"
    ED="${EDITOR:-${VISUAL:-vi}}"
    # Unquoted so an EDITOR carrying flags ("code -w") still works.
    $ED "$TMPF" || true
    apply_note "$WID" "$(cat "$TMPF" 2>/dev/null || true)"
    ;;

restore)
    # Re-seed after a server restart: window ids do not survive, so match by
    # (session name, window name). First window with a given name wins, and a
    # window that already has a live note is never touched — same rules (and
    # shape) as timer_restore.sh.
    STORE="$(store_path)"
    [ -f "$STORE" ] || exit 0
    applied="$US"
    changed=0
    while IFS="$TAB" read -r sname wname wid; do
        [ -n "$wid" ] || continue
        key="${sname}${US}${wname}"
        case "$applied" in *"${US}${key}${US}"*) continue ;; esac
        note="$(awk -F"$TAB" -v s="$sname" -v w="$wname" \
            '$1 == s && $2 == w { print $3; exit }' "$STORE" 2>/dev/null)"
        [ -n "$note" ] || continue
        applied="${applied}${key}${US}"
        if [ -n "$(get_window_option "$wid" "$NOTE_OPTION" "")" ]; then
            continue
        fi
        set_window_option "$wid" "$NOTE_OPTION" "$note"
        changed=1
    done <<< "$(tmux list-windows -a -F "#{session_name}${TAB}#{window_name}${TAB}#{window_id}" 2>/dev/null)"
    if [ "$changed" = "1" ]; then
        "$CURRENT_DIR/refresh.sh" force
    fi
    ;;
esac
