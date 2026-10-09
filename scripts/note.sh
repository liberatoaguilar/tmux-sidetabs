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
# The store row FOLLOWS THE WINDOW. Its key is (session name, window name)
# because ids do not survive a restart, so a rename changes the key a note is
# filed under; `sync` re-files it, and sidetabs.tmux runs that on window-renamed
# and session-renamed. A note id therefore has one row per window carrying it
# (one, unless the window is linked into several sessions), under that window's
# current name — never a second one left behind under an old name.
#
# Bound (sidebar-focused): @sidetabs-note-key opens the edit popup.
# Usage: note.sh <set|clear|edit-popup|sync|restore|gc> [window_id] [text...]
#   set <wid> <text...>  sanitize + store + render (empty = clear)
#   clear <wid>          unset the option, delete the file, drop its store rows
#   edit-popup <wid>     $EDITOR on a temp file seeded with the note's text;
#                        on exit the whole file becomes the note
#   sync                 re-file every live note under its window's current name
#   restore [boot]       re-seed live windows from the store (never clobbers,
#                        never writes the store); `boot` is the client-attached
#                        fallback, see the restore branch below
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

# store_lock / store_unlock (mkdir as mutex — macOS has no flock(1), and the
# durable record used by `note.sh restore` would otherwise lose a row when two
# writers race) now live in helpers.sh, sourced above, so a second durable
# store can reuse them instead of carrying its own copy. See there for the
# mkdir-as-mutex mechanics and the stale-lock force-break timeout.

# --- the durable index -------------------------------------------------------
# SNAPSHOT-MERGE, the shape flag_store.sh uses, and for the same reason: every
# write rebuilds the store from LIVE state under the lock instead of patching
# one row, so a save and a rename hook racing each other cannot leave a row
# under a name the window no longer has. Whichever writer takes the lock last
# sees both the note and the new name.
#
# What the merge does with each store row:
#   - its id is carried by a LIVE window (and the note file exists): the id is
#     live-owned. It ends up with exactly one row per window carrying it, under
#     that window's current (session, name); every other row for the id — the
#     one a rename left under the old name — is dropped.
#   - anything else is KEPT VERBATIM: rows for closed windows and closed
#     sessions (this store deliberately keeps a note for a window that will
#     come back), legacy inline-text rows, and lines it cannot parse.
#
# Unlike the flag store, a live window with NO note removes nothing. For a flag
# "live and unset" means the user cleared it; for a note it is simply what
# every window looks like before a restore has run, and treating it as a clear
# would cost the row its only pointer. Clearing is always explicit: see
# apply_note. That is also why this needs no restore-in-flight stand-down of
# the kind flag_store.sh carries — a sync landing mid-restore sees windows that
# carry no note yet, and those it leaves alone.
#
# A DISPLACED row — a different note already filed under the name a live noted
# window has just been renamed to — is kept too, behind the live one. Dropping
# it would orphan a file `gc` then deletes, i.e. lose text as a side effect of a
# rename. Keeping it costs one stale-looking row and gives the name back to the
# waiting note the moment the live window moves on. The live row goes FIRST
# because `restore` applies the first row filed under a key, and after a
# restart the window must get its own note back, not the one it displaced.
#
# A FAILED WRITE IS A NO-OP, NEVER A CLEAR (the house rule sanitize_file paid
# for): the new store is built in a temp file beside the real one and moved into
# place only after every step reported success.

# store_live <file>: one "session <TAB> window <TAB> id" row per live window
# carrying a note, behind a sentinel line.
#
# The id leads the list-windows format behind a literal "n", and the window name
# trails it, for the two reasons flag_store_write_live spells out: `read` with
# IFS=TAB collapses an EMPTY field and shifts everything after it (most windows
# carry no note), and a name may hold a tab, which last position hands whole to
# one variable to be squashed. A window with an empty name has no representable
# key and is not recorded — as before, its row simply stays where it was.
#
# A legacy inline value is skipped: its text IS the value, so two closed windows
# can legitimately hold identical rows and nothing may be deduplicated by it. It
# is re-filed the first time it is saved, when it becomes an id. An id whose
# file is gone is skipped as well — filing it would create the very dangling
# row a clear exists to remove.
store_live() {
    local out="$1" d nval wid sname wname id
    d="$(notes_dir)"
    : > "$out" 2>/dev/null || return 1
    # Sentinel: awk never opens an EMPTY first file, so the store's own records
    # would be numbered as file 1 and be mistaken for the live snapshot.
    printf '#live\n' >> "$out" 2>/dev/null || return 1
    while IFS="$TAB" read -r nval wid sname wname; do
        [ -n "$wid" ] || continue
        [ -n "$wname" ] || continue
        id="${nval#n}"
        valid_id "$id" || continue
        [ -f "$d/$id" ] || continue
        sname="${sname//$TAB/ }"; wname="${wname//$TAB/ }"
        printf '%s\t%s\t%s\n' "$sname" "$wname" "$id" >> "$out" 2>/dev/null || return 1
    done <<< "$(tmux list-windows -a \
        -F "n#{$NOTE_OPTION}${TAB}#{window_id}${TAB}#{session_name}${TAB}#{window_name}" 2>/dev/null)"
    return 0
}

# store_merge <storefile> <livefile> <tmpfile> [drop_id] [sname wname value]:
# the pure-data half of the sync; any failure is a plain non-zero return.
#   drop_id             remove EVERY row holding this id, under any key (a clear)
#   sname wname value   remove the row holding exactly this legacy inline value
#                       under this key (a legacy note being cleared or converted)
# Both arrive through ENVIRON, not -v: awk expands backslash escapes in a -v
# value, and a legacy value is full of them. Comparisons append "" to force a
# STRING compare — awk would otherwise call a session named 1 equal to one
# named 01.
store_merge() {
    local f="$1" livef="$2" tmpf="$3" src="$1"
    [ -f "$f" ] || src=/dev/null
    dropid="${4:-}" ls="${5:-}" lw="${6:-}" lv="${7:-}" awk -F"$TAB" '
        BEGIN { dropid = ENVIRON["dropid"]; ls = ENVIRON["ls"]; lw = ENVIRON["lw"]; lv = ENVIRON["lv"] }
        FNR == 1 { fileno++ }
        fileno == 1 {
            if ($0 == "#live" || NF < 3) next
            p = $1 "\t" $2 "\t" $3
            if (p in PAIR) next          # same name AND same note: one row
            PAIR[p] = 1; HELD[$3] = 1
            k = $1 "\t" $2
            KP[k "\t" (++NK[k])] = p
            ORDER[++n] = p
            next
        }
        {
            if (NF < 3) { print; next }
            k = $1 "\t" $2
            # First row filed under a live key: the live rows for that key go
            # out HERE, ahead of anything they displace, and in place rather
            # than appended, so a sync of a store that is already right is
            # byte-identical.
            if ((k in NK) && !(k in FLUSHED)) {
                FLUSHED[k] = 1
                for (i = 1; i <= NK[k]; i++) { p = KP[k "\t" i]; print p; EMIT[p] = 1 }
            }
            # A store saved by an editor with CRLF endings carries a \r on its
            # last field. Compared raw, "id\r" is not the id: a live note would
            # gain a second row, and a clear would leave one pointing at the
            # file it just deleted. Only the COMPARISON is normalized — a row
            # that is kept is still printed exactly as it was read.
            v = $3; sub(/\r$/, "", v)
            if (v in HELD) next          # live-owned: emitted above or in END
            if (dropid != "" && (v "") == dropid) next
            if (lv != "" && ($1 "") == ls && ($2 "") == lw && (v "") == lv) next
            print
        }
        END {
            for (i = 1; i <= n; i++) if (!(ORDER[i] in EMIT)) print ORDER[i]
        }
    ' "$livef" "$src" > "$tmpf" 2>/dev/null || return 1
    return 0
}

# The critical section: everything between reading the store and replacing it.
# Split out of store_sync() so every early return still releases the lock.
store_sync_locked() {
    local f="$1" tmpf livef rc=0
    shift
    tmpf="${f}.tmp.$$"
    livef="${f}.live.$$"
    if store_live "$livef" && store_merge "$f" "$livef" "$tmpf" "$@"; then
        # Nothing to record and no store yet: do not create one. And an
        # unchanged store is left alone rather than replaced by its twin — this
        # runs on every window rename, automatic ones included.
        if [ ! -f "$f" ] && [ ! -s "$tmpf" ]; then
            :
        elif [ -f "$f" ] && cmp -s "$tmpf" "$f" 2>/dev/null; then
            :
        else
            mv "$tmpf" "$f" 2>/dev/null || rc=1
        fi
    else
        rc=1
    fi
    rm -f "$tmpf" "$livef" 2>/dev/null || true
    return "$rc"
}

# store_sync [drop_id] [sname wname value]: snapshot live notes into the store
# (arguments as store_merge). Best-effort in both directions — an unwritable
# store must never abort the live state change that called us, and proceeding
# unlocked when the lock cannot be taken at all still beats refusing to save.
store_sync() {
    local f lockd held=0
    f="$(store_path)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    lockd="${f}.lock"
    store_lock "$lockd" && held=1
    store_sync_locked "$f" "$@" || true
    [ "$held" = "1" ] && store_unlock "$lockd"
    return 0
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
        # Drop what THIS window's note was filed as, and nothing else. For an id
        # that is every row holding it, whatever name it sits under — a row left
        # pointing at the file just deleted is a note that looks present and
        # opens empty. A window with no live note has nothing to clear, so the
        # row filed under its name (a note still waiting to be restored there)
        # is not this command's to remove.
        if valid_id "$cur"; then
            store_sync "$cur"
        elif [ -n "$cur" ]; then
            store_sync "" "$SNAME" "$WNAME" "$cur"
        fi
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
        # The option is set FIRST: the sync files whatever is live. A legacy
        # inline value this save has just converted leaves its old row behind
        # under the same key, holding text the new file now supersedes.
        if [ -n "$cur" ] && ! valid_id "$cur"; then
            store_sync "" "$SNAME" "$WNAME" "$cur"
        else
            store_sync
        fi
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

sync)
    # The window-renamed / session-renamed hook: a rename changed the key some
    # note is filed under, so re-file it. Also safe to run by hand at any time —
    # it is idempotent, and it is what collapses the old-name/new-name duplicate
    # rows a store written before this existed can hold.
    store_sync
    ;;

restore)
    # Re-seed after a server restart: window ids do not survive, so match by
    # (session name, window name). First window with a given name wins, and a
    # window that already has a live note is never touched — same rules (and
    # shape) as timer_restore.sh.
    #
    # READ-ONLY on the durable side: this sets window options and nothing else.
    # It never writes the store and never touches a note file, so running it at
    # the wrong moment (or twice) can do nothing worse than attach a note that
    # is still on disk.
    #
    # Two delivery paths, deliberately not symmetric — the split timer_restore
    # and flag_restore use, for the same reason:
    #   (default)  resurrect_post.sh, after a tmux-resurrect restore. Always
    #              runs, is safe to run by hand, and claims the generation.
    #   boot       the client-attached fallback registered by sidetabs.tmux, for
    #              when tmux-continuum skips auto-restore entirely and the
    #              resurrect hook never fires. Only while the server is YOUNG
    #              (< BOOT_MAX_AGE_S) and only once per server generation:
    #              firing on a later attach would hand a window created hours
    #              afterwards the note of a long-gone window with its name.
    # The claim is one-directional on purpose: `boot` stands down once anything
    # has restored this generation, but a resurrect restore never stands down
    # for `boot` — losing that race (a client attaching before continuum
    # restores) would leave every note unattached, and re-seeding an
    # already-seeded window is a no-op.
    MODE="${2:-}"
    # Test hook: SIDETABS_NOTE_BOOT_MAX_AGE_S overrides the boot window in
    # seconds (a non-integer is ignored). Documented here per the search.sh:7-8
    # convention — run-shell does not inherit a test shell's exports, so tests
    # pass it inline on the run-shell command string.
    BOOT_MAX_AGE_S="${SIDETABS_NOTE_BOOT_MAX_AGE_S:-120}"
    case "$BOOT_MAX_AGE_S" in ''|*[!0-9]*) BOOT_MAX_AGE_S=120 ;; esac
    if [ "$MODE" = "boot" ]; then
        [ "$(get_tmux_option "$NOTE_RESTORED_OPTION" '0')" = "1" ] && exit 0
        # A restore in flight owns this generation; the post hook will claim it.
        [ "$(get_tmux_option "$RESTORING_OPTION" '0')" = "1" ] && exit 0
        # #{start_time} is raw epoch seconds. Fail CLOSED: an unreadable or
        # nonsense server age means we cannot prove we are inside the boot
        # window, and a note on the wrong window is worse than none.
        started="$(tmux display-message -p '#{start_time}' 2>/dev/null || true)"
        case "$started" in ''|*[!0-9]*) exit 0 ;; esac
        [ "$(( $(date +%s) - started ))" -lt "$BOOT_MAX_AGE_S" ] || exit 0
    fi
    set_tmux_option "$NOTE_RESTORED_OPTION" "1"
    STORE="$(store_path)"
    [ -f "$STORE" ] || exit 0
    NDIR="$(notes_dir)"
    applied="$US"
    changed=0
    # Same field order as store_live, for the same two reasons (see there): the
    # note leads behind a literal "n" so an unset option cannot shift the
    # fields, and the window name trails so a tab inside it lands whole in one
    # variable. The name is then squashed exactly as the writer squashes it, or
    # a row would never match the window it was filed for.
    while IFS="$TAB" read -r nval wid sname wname; do
        [ -n "$wid" ] || continue
        [ -n "$wname" ] || continue
        sname="${sname//$TAB/ }"; wname="${wname//$TAB/ }"
        key="${sname}${US}${wname}"
        case "$applied" in *"${US}${key}${US}"*) continue ;; esac
        # Every row filed under this key, in store order; the first USABLE one
        # is applied. A row pointing at a deleted note file is not usable — it
        # would light the row's glyph for a note with no text — and it must not
        # shadow a good row behind it either, so it is stepped over rather than
        # ending the lookup. (Stepped over, never removed: restore does not
        # write the store.)
        #
        # Names go in through ENVIRON, not -v: awk expands backslash escapes in
        # a -v value, so a name holding one would never match itself. And each
        # side is forced to a STRING with "": two numeric-looking names compare
        # as NUMBERS otherwise, and session `01` would be handed the note filed
        # under session `1`. The \r a CRLF line ending leaves on the last field
        # is dropped first; left on, the id would fail valid_id and be applied
        # as inline text. The store is read as a FILE and awk never exits
        # early, so there is no writer to SIGPIPE.
        note=""
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            if valid_id "$cand" && [ ! -f "$NDIR/$cand" ]; then
                continue
            fi
            note="$cand"
            break
        done <<< "$(s="$sname" w="$wname" awk -F"$TAB" '
            { sub(/\r$/, "") }
            NF >= 3 && ($1 "") == ENVIRON["s"] && ($2 "") == ENVIRON["w"] { print $3 }
        ' "$STORE" 2>/dev/null || true)"
        [ -n "$note" ] || continue
        # Marked applied BEFORE the live check, so a second window with the same
        # name is not seeded from the row the first one already owns.
        applied="${applied}${key}${US}"
        # Live value wins: it was set this generation and is fresher than the
        # store.
        [ -z "${nval#n}" ] || continue
        # A set that fails skips that window; under `set -e` it would otherwise
        # abort the whole restore and leave every window after it unseeded.
        # (tmux 3.6b's `set-option -q` reports a window that vanished since the
        # listing as SUCCESS, so this is for the versions that do not.)
        set_window_option "$wid" "$NOTE_OPTION" "$note" 2>/dev/null || continue
        changed=1
    done <<< "$(tmux list-windows -a \
        -F "n#{$NOTE_OPTION}${TAB}#{window_id}${TAB}#{session_name}${TAB}#{window_name}" 2>/dev/null)"
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
    # incomplete: a live note the store has no row for (its store write failed,
    # or the plugin's rename hooks are not loaded) is referenced only by the
    # live option, and a note whose window is gone is referenced only by the
    # store.
    NDIR="$(notes_dir)"
    [ -d "$NDIR" ] || exit 0
    STORE="$(store_path)"
    REFS="$US"
    if [ -f "$STORE" ]; then
        while IFS= read -r rid; do
            [ -n "$rid" ] && REFS="${REFS}${rid}${US}"
        # The \r of a CRLF line ending comes off first: left on the id, the file
        # that row references would look unreferenced and be swept.
        done <<< "$(awk -F"$TAB" '{ sub(/\r$/, "") } NF>=3 && $3 != "" { print $3 }' "$STORE" 2>/dev/null || true)"
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
