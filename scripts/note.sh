#!/usr/bin/env bash
# Per-window free-text note, of ANY length.
#
# The note's TEXT lives in a file of its own, one per note, under a directory
# derived from the store path ("${store}.d/<id>"). The live window user option
# @sidetabs_note and the durable TSV store (@sidetabs-note-store, keyed by
# session name + window name) both hold only that note's ID — never its text.
#
# That indirection is the whole point. tmux refuses any command longer than
# ~16KB with "command too long", measured in BYTES (so a CJK note hits it three
# times sooner than an ASCII one), which capped a note kept in the option no
# matter how the cap was tuned. An id is ~11 characters, so the ceiling is gone
# and a note file can be megabytes.
#
# The sidebar shows PRESENCE only — a sticky-note glyph on the row, expanded
# mode only — never the text, which is why the render format can test the
# option for non-emptiness and stay indifferent to what it holds.
#
# Text is sanitized on the way in: control chars die, trailing whitespace goes,
# and blank lines at the very start and end are dropped. Tabs, indentation and
# interior blank lines all survive — a long note holds indented lists and code,
# and nothing downstream is whitespace-sensitive once the text is out of the
# option and out of the TSV.
#
# Bound (sidebar-focused): @sidetabs-note-key opens the edit popup.
# Usage: note.sh <set|clear|edit-popup|restore|gc> [window_id] [text...]
#   set <wid> <text...>  sanitize + store + render (empty = clear)
#   clear <wid>          unset the option, delete the file, drop the store row
#   edit-popup <wid>     $EDITOR on a temp file seeded with the note's text;
#                        on exit the whole file becomes the note
#   restore              re-seed live windows from the store (never clobbers)
#   gc                   delete note files nothing references
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

CMD="${1:-edit-popup}"
TAB="$(printf '\t')"
US=$'\x1f'

store_path() { get_tmux_option '@sidetabs-note-store' "$DEFAULT_NOTE_STORE"; }

# Text lives one file per note, in a directory derived from the store path so
# the two move together when @sidetabs-note-store is repointed. Deriving it
# from the store PATH rather than its dirname keeps two stores in one directory
# from sharing a note pool — which gc would then resolve by deleting the other
# store's files.
notes_dir() { printf '%s.d' "$(store_path)"; }
note_path() { printf '%s/%s' "$(notes_dir)" "$1"; }

# A note id is the option's entire value and a bare filename. The character
# class is the security boundary: it admits no '/' and no '..', so a hostile or
# corrupt store row can never aim note_path outside the notes dir. The n1-
# prefix is what lets a LEGACY inline-text value (see decode_note) be told apart
# from an id without a version field in the store.
valid_id() {
    case "$1" in
        n1-*[!A-Za-z0-9]*) return 1 ;;
        n1-?*)             return 0 ;;
        *)                 return 1 ;;
    esac
}

# new_id -> NEW_ID, with the (empty) file already created. mktemp is what makes
# minting atomic: two concurrent sets can never settle on the same id.
new_id() {
    local d f
    NEW_ID=""
    d="$(notes_dir)"
    mkdir -p "$d" 2>/dev/null || return 1
    f="$(mktemp "$d/n1-XXXXXXXX" 2>/dev/null)" || return 1
    case "${f##*/}" in
        n1-*[!A-Za-z0-9]*) rm -f "$f" 2>/dev/null; return 1 ;;
    esac
    NEW_ID="${f##*/}"
    return 0
}

# decode_note <encoded> -> DEC. LEGACY ONLY. Before notes moved to files the
# option and the store held the text inline, escape-encoded to keep it on one
# line (\ -> \\, LF -> \n). Such values are still readable, and convert to a
# file the first time they are saved; nothing writes this form any more.
#
# Sequential replacement would corrupt an escaped backslash (\\n is a literal
# backslash followed by "n", not a newline), so escaped backslashes are first
# parked on a sentinel. US (0x1f) is safe: the encoded form was control-char-free
# by construction, so it can never contain one.
decode_note() {
    DEC="$1"
    DEC="${DEC//\\\\/$US}"
    DEC="${DEC//\\n/$'\n'}"
    DEC="${DEC//$US/\\}"
}

# sanitize_file <in> <out>: normalize a raw editor buffer into the durable form.
# Everything is streamed. The bash accumulation loop this replaced was O(n^2)
# — 50KB took a second, so 200KB would have taken ~16 — and notes are now
# unbounded.
#
# Stage order matters. NULs die FIRST, because a NUL reaching sed truncates the
# line on BSD. CR is deliberately spared by that pass so the next two can tell
# CRLF (strip the CR) from a lone CR (a line break in its own right); deleting
# CR outright would silently join every line of an old-Mac file.
#
# Failure is REPORTED, never swallowed, and the OR-list is what keeps errexit
# from firing on the way out. Swallowing it would be actively destructive: a
# pipeline that died partway (ENOSPC on <out> is the realistic case) leaves an
# empty stage file, apply_note reads empty as "the user emptied the buffer", and
# a transient write error would delete a note the user still has. Returning
# non-zero lets apply_note bail before that test is ever reached.
sanitize_file() {
    tr -d '\000-\010\013-\014\016-\037\177' < "$1" 2>/dev/null \
        | sed -e 's/'$'\r''$//' 2>/dev/null \
        | tr '\015' '\012' 2>/dev/null \
        | awk '
            # Trailing whitespace goes; LEADING whitespace stays.
            { sub(/[[:space:]]+$/, "") }
            # A blank line before the first real one is never counted, and a run
            # after the last one is never flushed — so both edges are trimmed in
            # this single pass while interior runs survive verbatim.
            $0 == "" { if (started) pending++; next }
            { while (pending > 0) { print ""; pending-- }
              started = 1; print }
          ' > "$2" 2>/dev/null || return 1
    return 0
}

# seed_file <option value> <out>: write the note's CURRENT text to <out>.
# An id reads its file; anything else is a legacy inline value and is decoded in
# place. That legacy branch is the entire migration story — the value becomes a
# file the next time it is saved, so no eager migration pass is needed.
seed_file() {
    local v="$1" out="$2" p
    : > "$out" 2>/dev/null || return 0
    [ -n "$v" ] || return 0
    if valid_id "$v"; then
        p="$(note_path "$v")"
        [ -f "$p" ] && { cat "$p" > "$out" 2>/dev/null || true; }
    else
        decode_note "$v"
        printf '%s\n' "$DEC" > "$out" 2>/dev/null || true
    fi
    return 0
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
# store_write <sname> <wname> [note_id]   (no id = delete only)
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
# store_rewrite <storefile> <sname> <wname> [note_id]
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

# apply_note <window_id> <srcfile>: the shared set/clear body. It takes a FILE,
# never a string, so note text is never held in a shell variable and can never
# reach a tmux command line.
#
# An empty result after sanitizing is a clear — "set it to nothing" and "clear
# it" are the same user intent, and it is the only sane reading of an emptied
# editor buffer.
#
# The window's EXISTING id is reused on overwrite. That keeps the option value
# stable, makes the write a single rename, and means routine editing leaves no
# orphan files behind at all.
apply_note() {
    local wid="$1" src="$2" cur id d stage
    d="$(notes_dir)"
    mkdir -p "$d" 2>/dev/null || return 0
    # Stage inside the notes dir so the mv below is same-filesystem, hence
    # atomic: a reader never sees a half-written note.
    stage="$(mktemp "$d/.stage-XXXXXXXX" 2>/dev/null)" || return 0
    # A failed sanitize must be a NO-OP, not a clear. Falling through would hand
    # the empty-means-clear test below a stage file that is empty only because
    # the write died, and delete a note the user never asked to lose.
    sanitize_file "$src" "$stage" || { rm -f "$stage" 2>/dev/null; return 0; }
    window_key "$wid"
    cur="$(get_window_option "$wid" "$NOTE_OPTION" "")"
    if [ ! -s "$stage" ]; then
        rm -f "$stage" 2>/dev/null
        valid_id "$cur" && rm -f "$(note_path "$cur")" 2>/dev/null
        unset_window_option "$wid" "$NOTE_OPTION"
        [ -n "$WNAME" ] && store_write "$SNAME" "$WNAME"
    else
        if valid_id "$cur"; then
            id="$cur"
        else
            new_id || { rm -f "$stage" 2>/dev/null; return 0; }
            id="$NEW_ID"
        fi
        mv "$stage" "$(note_path "$id")" 2>/dev/null \
            || { rm -f "$stage" 2>/dev/null; return 0; }
        set_window_option "$wid" "$NOTE_OPTION" "$id"
        [ -n "$WNAME" ] && store_write "$SNAME" "$WNAME" "$id"
    fi
    "$CURRENT_DIR/refresh.sh" force
}

case "$CMD" in
set)
    WID="${2:-}"
    [ -z "$WID" ] && WID="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    [ -z "$WID" ] && exit 0
    shift 2 2>/dev/null || shift $#
    SRC="$(mktemp "${TMPDIR:-/tmp}/sidetabs_noteset.XXXXXX")" || exit 0
    trap 'rm -f "$SRC" 2>/dev/null' EXIT INT TERM HUP
    printf '%s\n' "$*" > "$SRC"
    apply_note "$WID" "$SRC"
    ;;

clear)
    WID="${2:-}"
    [ -z "$WID" ] && WID="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    [ -z "$WID" ] && exit 0
    SRC="$(mktemp "${TMPDIR:-/tmp}/sidetabs_noteclr.XXXXXX")" || exit 0
    trap 'rm -f "$SRC" 2>/dev/null' EXIT INT TERM HUP
    : > "$SRC"
    apply_note "$WID" "$SRC"
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
    seed_file "$(get_window_option "$WID" "$NOTE_OPTION" "")" "$TMPF"
    ED="${EDITOR:-${VISUAL:-vi}}"
    # Unquoted so an EDITOR carrying flags ("code -w") still works.
    $ED "$TMPF" || true
    apply_note "$WID" "$TMPF"
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
        # A row pointing at a deleted note file would set the option and light
        # the row's glyph for a note with no text. Drop it instead.
        if valid_id "$note" && [ ! -f "$(note_path "$note")" ]; then
            continue
        fi
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

gc)
    # Sweep note files that neither the durable store nor any live window points
    # at. Deliberately a COMMAND and never a timer: an orphan costs a few KB,
    # while deleting a wanted note is unrecoverable. Routine editing produces no
    # orphans at all anyway, because apply_note reuses a window's existing id.
    #
    # The reference set is the UNION of both sources, because either alone is
    # incomplete: a window renamed since its note was set is referenced only by
    # the live option (its store row still sits under the old name), and a note
    # whose window is gone is referenced only by the store.
    NDIR="$(notes_dir)"
    [ -d "$NDIR" ] || exit 0
    STORE="$(store_path)"
    REFS="$US"
    if [ -f "$STORE" ]; then
        while IFS= read -r rid; do
            [ -n "$rid" ] && REFS="${REFS}${rid}${US}"
        done <<< "$(awk -F"$TAB" 'NF>=3 && $3 != "" { print $3 }' "$STORE" 2>/dev/null || true)"
    fi
    while IFS= read -r rid; do
        [ -n "$rid" ] && REFS="${REFS}${rid}${US}"
    done <<< "$(tmux list-windows -a -F "#{${NOTE_OPTION}}" 2>/dev/null || true)"
    removed=0
    for f in "$NDIR"/n1-*; do
        [ -f "$f" ] || continue
        fid="${f##*/}"
        valid_id "$fid" || continue
        case "$REFS" in *"${US}${fid}${US}"*) continue ;; esac
        rm -f "$f" 2>/dev/null && removed=$((removed + 1))
    done
    # Staging files are transient; one older than a day is debris from a save
    # that was killed mid-write. The age guard is what keeps this from racing a
    # save that is in flight right now.
    find "$NDIR" -maxdepth 1 -name '.stage-*' -type f -mtime +1 -exec rm -f {} \; 2>/dev/null || true
    echo "removed $removed orphaned note file(s)"
    ;;
esac
