#!/usr/bin/env bash
# Per-window free-text note. Live state is the window user option
# @sidetabs_note; the durable record is a TSV store (@sidetabs-note-store) keyed
# by (session name, window name), so notes come back after a server restart via
# `note.sh restore` (called from resurrect_post.sh).
#
# The sidebar shows PRESENCE only — a sticky-note glyph on the row, expanded
# mode only — never the text. Text is sanitized on the way in (control chars
# stripped, spaces collapsed per line, capped) and newlines are ESCAPE-ENCODED
# (\ -> \\, LF -> \n) so the stored form is always a single line that can never
# break the TAB-separated render format or the TSV store — while the editor
# still sees the note's real multi-line text, decoded on the way out.
#
# Bound (sidebar-focused): @sidetabs-note-key opens the edit popup.
# Usage: note.sh <set|clear|edit-popup|restore> [window_id] [text...]
#   set <wid> <text...>  sanitize + encode + store + render (empty = clear)
#   clear <wid>          unset the option and drop the store row
#   edit-popup <wid>     $EDITOR on a temp file seeded with the DECODED note;
#                        on exit the whole file is sanitized and re-encoded
#   restore              re-seed live windows from the store (never clobbers)
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

CMD="${1:-edit-popup}"
TAB="$(printf '\t')"
US=$'\x1f'

store_path() { get_tmux_option '@sidetabs-note-store' "$DEFAULT_NOTE_STORE"; }

# encode_note <text> -> ENC. Escapes clean multi-line text into the single-line
# STORED form: backslash first (so the newline escape it produces is not itself
# re-escaped), then LF -> the two chars \n. The input is already free of
# TAB/CR/other control chars, so the result is guaranteed single-line and
# TAB-free — the invariant the render format and the TSV store depend on.
encode_note() {
    ENC="$1"
    ENC="${ENC//\\/\\\\}"
    ENC="${ENC//$'\n'/\\n}"
}

# decode_note <encoded> -> DEC. The inverse, used ONLY to seed the editor.
# Sequential replacement would corrupt an escaped backslash (\\n is a literal
# backslash followed by "n", not a newline), so escaped backslashes are first
# parked on a sentinel. US (0x1f) is safe: the stored form is control-char-free
# by construction, so it can never contain one.
#
# Migration: rows written before notes were encoded are stored raw and are
# indistinguishable from encoded ones, so a legacy note containing the literal
# two chars \n decodes to a real newline (and \\ halves to \) the first time its
# popup opens — and saving then persists the reinterpreted text, NOT the
# original. Accepted: at the time encoding shipped this machine's store was
# verified empty, so no such note existed anywhere. A version tag could remove
# the ambiguity but isn't worth it for a store with zero legacy rows.
decode_note() {
    DEC="$1"
    DEC="${DEC//\\\\/$US}"
    DEC="${DEC//\\n/$'\n'}"
    DEC="${DEC//$US/\\}"
}

# Sanitize $1 (a raw, possibly multi-line editor buffer) into the global NOTE,
# in the ENCODED form. Line endings are normalized to LF; then per line tabs
# become spaces, every remaining control char is dropped, runs of spaces
# collapse and the ends are trimmed. Leading/trailing blank lines go and runs of
# blank lines squeeze to one, so paragraph breaks survive but the note can't be
# padded out. The DECODED text is capped at NOTE_MAX_CHARS (the encoded form may
# be a little longer — that is fine, it is not what the user counts).
sanitize_note() {
    local raw flat line clean blank=0

    raw="$1"
    raw="${raw//$'\r\n'/$'\n'}"
    raw="${raw//$'\r'/$'\n'}"

    # Tabs -> space, drop every control char EXCEPT LF, squeeze space runs.
    # tr -s can't cross a newline, so this is already per-line.
    flat="$(printf '%s' "$raw" | tr '\011' ' ' | tr -d '\000-\011\013-\037' | tr -s ' ')"

    clean=""
    while IFS= read -r line; do
        line="${line# }"; line="${line% }"
        if [ -z "$line" ]; then
            # Remember the gap instead of emitting it: trailing blanks then
            # cost nothing, and a run of them still yields a single break.
            if [ -n "$clean" ]; then blank=1; fi
            continue
        fi
        if [ -z "$clean" ]; then
            clean="$line"
        elif [ "$blank" = "1" ]; then
            clean="${clean}"$'\n\n'"$line"
        else
            clean="${clean}"$'\n'"$line"
        fi
        blank=0
    done <<< "$flat"

    if [ "${#clean}" -gt "$NOTE_MAX_CHARS" ]; then
        clean="${clean:0:$NOTE_MAX_CHARS}"
        # The cut can land on the whitespace/newlines the trimming above spared.
        while :; do
            case "$clean" in
                *' '|*$'\n') clean="${clean%?}" ;;
                *) break ;;
            esac
        done
    fi

    encode_note "$clean"
    NOTE="$ENC"
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
    # The option holds the encoded single line; the editor gets the real text.
    if [ -n "$CUR" ]; then
        decode_note "$CUR"
        printf '%s\n' "$DEC" > "$TMPF"
    fi
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
