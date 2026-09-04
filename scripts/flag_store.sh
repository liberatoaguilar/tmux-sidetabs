#!/usr/bin/env bash
# Durable record of flag colours, so they survive a tmux server restart.
#
# The live truth is the @sidetabs_flag WINDOW option, which dies with the
# server: tmux does not save user options and neither does tmux-resurrect. This
# is the same gap notes and timers each closed with a TSV keyed by (session
# name, window name), and this is the third instance of that pattern.
#
# Store shape — three tab-separated columns:
#   session_name <TAB> window_name <TAB> index   -- a WINDOW flag  (@sidetabs_flag)
#   session_name <TAB>     (empty)   <TAB> index -- a SESSION colour (@sidetabs_sflag)
# A session row's key can never collide with a window row's, because a window
# with an empty name is never recorded at all. Both shapes are snapshotted by
# the same sync below, under one lock, and replayed by one restore pass.
#
# SNAPSHOT-MERGE, not row surgery. Any flag change rewrites the whole store from
# live state:
#   - for every LIVE (session, window) the row becomes the live value, or is
#     REMOVED when the flag is now unset — which is how CLEARING persists;
#   - rows whose key is not currently live are KEPT verbatim, so a closed
#     session's colours come back when that session does.
# Nothing is ever pruned. Two consequences are accepted deliberately: stale rows
# accumulate (bytes), and a new session reusing an old name inherits that name's
# colours — judged correct, not a bug.
#
# A FAILED WRITE MUST BE A NO-OP, NEVER A CLEAR. This is a house rule paid for
# once already: a sanitize step in the notes work swallowed its own failure, so
# a disk-full error read as "the user emptied the buffer" and DELETED the note.
# Everything below builds the new store in a temp file beside the real one and
# `mv`s it into place only after every step reported success, under the lock —
# so an unreadable store, a full disk or a read-only directory leaves the store
# exactly as it was.
#
# Usage: flag_store.sh sync
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

CMD="${1:-sync}"
TAB="$(printf '\t')"

store_path() { get_tmux_option '@sidetabs-flag-store' "$DEFAULT_FLAG_STORE"; }

# flag_store_write_live <file>: one row per live window AND one per live session,
# "session <TAB> window <TAB> value" (the window field empty on a session row),
# where value is the flag index or empty for "live but unflagged" (the
# distinction the merge needs in order to REMOVE a cleared row).
#
# The format puts the flag first behind a literal "f" and the window name last,
# for two reasons that are easy to trip over:
#   - `read` with IFS=TAB treats tab as IFS *whitespace*, so a run of tabs
#     collapses and an EMPTY field silently shifts every field after it. The
#     "f" prefix makes the flag field non-empty whether or not the option is
#     set, so nothing shifts.
#   - a window name may legally contain a tab; last position lets `read` hand
#     the whole remainder to one variable, which is then squashed to spaces so
#     the store row stays exactly three fields. Restore squashes the live name
#     the same way, so the two still match. (A tab in a SESSION name would still
#     shift — the same limitation note.sh restore has always carried.)
flag_store_write_live() {
    local out="$1" fval wid sid sname wname
    : > "$out" 2>/dev/null || return 1
    # Sentinel: awk's classic FNR==NR two-file idiom breaks when the first file
    # is EMPTY (awk never opens it, so the SECOND file's records satisfy
    # FNR==NR and the store gets mistaken for the live snapshot). One
    # guaranteed line keeps the file non-empty on a server with no windows.
    printf '#live\n' >> "$out" 2>/dev/null || return 1
    while IFS="$TAB" read -r fval wid sname wname; do
        [ -n "$wid" ] || continue
        # A window CAN be renamed to the empty string, and such a row would be
        # indistinguishable from the reserved session-colour shape. It has no
        # representable key, so it is simply not recorded.
        [ -n "$wname" ] || continue
        sname="${sname//$TAB/ }"; wname="${wname//$TAB/ }"
        printf '%s\t%s\t%s\n' "$sname" "$wname" "${fval#f}" >> "$out" 2>/dev/null || return 1
    done <<< "$(tmux list-windows -a \
        -F "f#{$FLAG_OPTION}${TAB}#{window_id}${TAB}#{session_name}${TAB}#{window_name}" 2>/dev/null)"
    # Session colours, in the reserved empty-window-name shape. Same field
    # order and the same "f" prefix, for the same two reasons: an unset option
    # must not shift the fields under IFS=TAB, and the name goes last so a tab
    # inside it lands in the remainder rather than creating a fourth field.
    #
    # A session whose colour is unset still gets a row here with an EMPTY value,
    # exactly like an unflagged window: that is the signal the merge needs to
    # REMOVE a stored row, which is how clearing a session colour persists.
    while IFS="$TAB" read -r fval sid sname; do
        [ -n "$sid" ] || continue
        # An empty session name would make an all-empty row: no key, and
        # indistinguishable from a blank line. Skipped for the same reason an
        # empty window name is — it has no representable key.
        [ -n "$sname" ] || continue
        sname="${sname//$TAB/ }"
        printf '%s\t\t%s\n' "$sname" "${fval#f}" >> "$out" 2>/dev/null || return 1
    done <<< "$(tmux list-sessions \
        -F "f#{$SFLAG_OPTION}${TAB}#{session_id}${TAB}#{session_name}" 2>/dev/null)"
    return 0
}

# flag_store_merge <storefile> <livefile> <tmpfile>: the pure-data half of the sync, split
# out so every failure path is a plain non-zero return the caller turns into a
# no-op. Emits the merged store on stdout (redirected into <tmpfile>).
#
# A missing store reads as /dev/null rather than being created: with an empty
# second file the END block still emits every live row, which is exactly the
# first-ever-write case.
flag_store_merge() {
    local f="$1" livef="$2" tmpf="$3" src="$1"
    [ -f "$f" ] || src=/dev/null
    # Names arrive already tab-free, so "$1 TAB $2" is an unambiguous composite
    # key — unlike SUBSEP, which is a byte a name could in principle contain.
    awk -F"$TAB" '
        FNR == 1 { fileno++ }
        fileno == 1 {
            if ($0 == "#live") next
            if (NF < 2) next
            k = $1 "\t" $2
            if (k in LIVE) next          # duplicate name: the first window wins
            LIVE[k] = 1; S1[k] = $1; S2[k] = $2
            VAL[k] = (NF >= 3) ? $3 : ""
            ORDER[++n] = k
            next
        }
        {
            # A row we cannot parse is data we do not understand, so it is
            # carried through rather than dropped: this store never prunes.
            if (NF < 3) { print; next }
            k = $1 "\t" $2
            if (!(k in LIVE)) { print; next }   # not live -> keep verbatim
            if (k in DONE) next                 # already rewritten in place
            DONE[k] = 1
            # Rewriting in place (rather than dropping and appending) keeps the
            # store stable across syncs, so a diff of it shows only real changes.
            if (VAL[k] != "") printf "%s\t%s\t%s\n", $1, $2, VAL[k]
        }
        END {
            for (i = 1; i <= n; i++) {
                k = ORDER[i]
                if (!(k in DONE) && VAL[k] != "")
                    printf "%s\t%s\t%s\n", S1[k], S2[k], VAL[k]
            }
        }
    ' "$livef" "$src" > "$tmpf" 2>/dev/null || return 1
    return 0
}

# The critical section: everything between reading the store and replacing it.
# Split out of flag_store_sync() so every early return still releases the lock.
flag_store_sync_locked() {
    local f="$1" tmpf livef rc=0
    tmpf="${f}.tmp.$$"
    livef="${f}.live.$$"
    # Staged beside the real store on purpose: same filesystem, so the mv below
    # is atomic and a concurrent reader never sees a half-written store.
    if flag_store_write_live "$livef" && flag_store_merge "$f" "$livef" "$tmpf"; then
        # The ONLY line that can destroy data, and it is reached only after
        # every step above reported success. A partial awk run (ENOSPC on the
        # temp file is the realistic case) exits non-zero and lands here with
        # rc=1, leaving the real store untouched.
        mv "$tmpf" "$f" 2>/dev/null || rc=1
    else
        rc=1
    fi
    rm -f "$tmpf" "$livef" 2>/dev/null || true
    return "$rc"
}

# flag_store_sync: snapshot live flag state into the store. Best-effort in both directions
# — an unwritable store must never abort the live state change that called us.
flag_store_sync() {
    local f lockd held=0 rc=0
    # A tmux-resurrect restore creates and renames windows LONG before
    # flag_restore.sh re-seeds their flags. A sync landing in that gap would see
    # every restored window as legitimately unflagged and remove its row — the
    # snapshot would wipe the very record the restore is about to replay. So
    # while a restore is in flight this is a no-op; the restore's own hook path
    # brings state back, and the next real flag change re-snapshots.
    [ "$(get_tmux_option "$RESTORING_OPTION" '0')" = "1" ] && return 0
    f="$(store_path)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    lockd="${f}.lock"
    # Serializes the read-modify-write against any other durable-store writer
    # sharing this file. Proceeding unlocked when the lock cannot be taken at
    # all matches note.sh: losing a row to a rare race beats refusing to save.
    store_lock "$lockd" && held=1
    flag_store_sync_locked "$f" || rc=1
    [ "$held" = "1" ] && store_unlock "$lockd"
    return "$rc"
}

case "$CMD" in
    sync) flag_store_sync || true ;;
    *)    exit 0 ;;
esac
