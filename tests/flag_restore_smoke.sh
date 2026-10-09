#!/usr/bin/env bash
# Window flag colours AND session colours survive a server restart
# (tickets 03 + 04 — one store, one lock, one restore pass, so one test).
#
# Two halves against ONE socket. Phase A drives flag_cycle.sh / flag_set.sh on a
# live server and asserts the durable TSV store they write through to; the
# server is then killed and rebuilt on the same socket, which is a genuine new
# server generation (fresh #{start_time}, every option and window id gone), and
# phase B asserts flag_restore.sh replays the store onto it by NAME.
#
# Covered, one section per acceptance criterion:
#   1  set + clear write through, from both the cycle key and the picker path
#   2  after a restart, flagged windows regain their colour by session+window
#      name (ids do not survive)
#   3  a live flag is never clobbered
#   4  the `boot` fallback: once per generation, only on a young server,
#      standing down while a restore is in flight, and holding a write-through
#      guard of its own (@sidetabs_flag_restoring) so a sync landing mid-replay
#      cannot delete the very rows it is about to read — released from a trap,
#      so it cannot leak and disable write-through for good
#   5  clearing removes the record, so a cleared window comes back uncoloured
#   6  a row naming a window that no longer exists is ignored, never misapplied
#   7  a name containing escape-like characters (a literal backslash-t) still
#      matches its row — the awk ENVIRON guarantee, which `awk -v` would break
#   8  a closed session's rows are preserved and return with the session
#   9  SESSION colours (@sidetabs_sflag, ticket 04) ride the same store in the
#      empty-window-name row shape: set + clear write through, the two row
#      shapes never leak into each other's restore pass, a live session colour
#      is never clobbered, and unusable indices are ignored exactly as they are
#      for windows
# plus the house rule the notes work paid for once already: A FAILED WRITE IS A
# NO-OP, NEVER A CLEAR — both an unreadable store and an unwritable directory
# must leave the store byte-for-byte as it was.
#
# -f /dev/null is required on every server started here: without it a new server
# on this socket still auto-loads the user's ~/.tmux.conf (which run-shells this
# plugin AND others), polluting hooks/keys and defeating test isolation.
set -euo pipefail

SOCKET="sidetab_flagr_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE="${TMPDIR:-/tmp}/sidetabs_flags_$$.tsv"
BAK="${TMPDIR:-/tmp}/sidetabs_flags_bak_$$.tsv"
RODIR="${TMPDIR:-/tmp}/sidetabs_flagro_$$"

cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    # The read-only-directory section leaves RODIR unwritable on purpose; make
    # it removable again before rm, or the trap silently leaves debris behind.
    chmod 755 "$RODIR" 2>/dev/null || true
    chmod 644 "$STORE" 2>/dev/null || true
    rm -rf "$STORE" "$BAK" "$RODIR" "${STORE}.lock" "${STORE}"*.tmp.* "${STORE}"*.live.*
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
run() { tmux -L "$SOCKET" run-shell "$*"; }
winopt() { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }
gopt() { tmux -L "$SOCKET" show-option -gqv "$1"; }
sopt() { tmux -L "$SOCKET" show-option -t "$1" -qv "$2"; }
# The session picker/setter take a PANE id, never a session id: run-shell hands
# its command string to `sh -c`, which expands a session id ("$0", "$1", …) into
# a positional parameter and destroys it. Every session_flag_set.sh call below
# therefore addresses a pane, exactly as the key binding does.
#
# No `head`/`exit` in the reader: under `set -o pipefail` a reader closing the
# pipe early can SIGPIPE tmux and fail the whole pipeline.
spane() { tmux -L "$SOCKET" list-panes -t "$1" -F '#{pane_id}' 2>/dev/null \
        | awk '!seen { print; seen = 1 }'; }

TAB="$(printf '\t')"
# A window name holding a LITERAL backslash followed by 't'. `awk -v w='esc\tname'`
# expands that to a real tab, so a store lookup built with -v would compare
# "esc<TAB>name" against the stored "esc\tname" and never match. ENVIRON does no
# such expansion — this name is the whole reason for that choice.
ESCNAME='esc\tname'

# Names reach awk through the environment here for exactly the same reason the
# production code does it: winid must be able to find $ESCNAME too.
winid() {
    tmux -L "$SOCKET" list-windows -t "$1" -F "#{window_id}${TAB}#{window_name}" 2>/dev/null \
        | n="$2" awk -F"$TAB" '$2 == ENVIRON["n"] { print $1; exit }' || true
}
# Third column of the row for (session, window), or empty. An empty <window>
# addresses the reserved SESSION row shape.
storerow() {
    [ -f "$STORE" ] || return 0
    s="$1" w="$2" awk -F"$TAB" \
        '$1 == ENVIRON["s"] && $2 == ENVIRON["w"] { print $3; exit }' "$STORE" 2>/dev/null || true
}
storerows() { if [ -f "$STORE" ]; then awk 'NF{n++} END{print n+0}' "$STORE"; else echo 0; fi; }

# ===========================================================================
# PHASE A — write-through (server generation 1)
# ===========================================================================
# No plugin load: sections 1-9 are pure state work on windows and a TSV, and a
# sidebar per window would only add render forks and timing noise. The plugin
# IS loaded at the very end, where hook wiring is what is under test.
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n alpha -x 200 -y 50
tmux -L "$SOCKET" set -g @sidetabs-flag-store "$STORE"
for w in beta gamma livewin; do tmux -L "$SOCKET" new-window -t main -n "$w"; done
tmux -L "$SOCKET" new-window -t main -n "$ESCNAME"
tmux -L "$SOCKET" new-session -d -s other -n omega

wa="$(winid main alpha)"; wb="$(winid main beta)"; wg="$(winid main gamma)"
wl="$(winid main livewin)"; we="$(winid main "$ESCNAME")"; wo="$(winid other omega)"
[ -n "$wa" ] && [ -n "$wb" ] && [ -n "$wg" ] && [ -n "$wl" ] || fail "setup: missing main windows"
[ -n "$we" ] || fail "setup: window named '$ESCNAME' not found"
[ -n "$wo" ] || fail "setup: missing other:omega"

# --- 1. The cycle key writes through -----------------------------------------
run "$PLUGIN_DIR/scripts/flag_cycle.sh $wa"
sleep 0.3
[ "$(winopt "$wa" @sidetabs_flag)" = "1" ] || fail "cycle did not set the live flag"
[ -f "$STORE" ] || fail "cycle wrote no store file"
[ "$(storerow main alpha)" = "1" ] || fail "store row for main/alpha: '$(storerow main alpha)' (want 1)"
[ "$(storerows)" = "1" ] || fail "expected 1 store row, got $(storerows)"
nf="$(awk -F"$TAB" '{print NF}' "$STORE" | sort -u)"
[ "$nf" = "3" ] || fail "expected 3 TSV fields on every row, got: $nf"
# A second press moves the row rather than appending a duplicate: the store is a
# SNAPSHOT of live state, not an append-only log.
run "$PLUGIN_DIR/scripts/flag_cycle.sh $wa"
sleep 0.3
[ "$(storerow main alpha)" = "2" ] || fail "second cycle did not update the row in place"
[ "$(storerows)" = "1" ] || fail "second cycle duplicated the row ($(storerows) rows)"
pass "cycle key writes through and updates its row in place"

# --- 2. The picker path (flag_set.sh) writes through -------------------------
run "$PLUGIN_DIR/scripts/flag_set.sh $wa 1"
run "$PLUGIN_DIR/scripts/flag_set.sh $wb 3"
sleep 0.4
[ "$(storerow main alpha)" = "1" ] || fail "flag_set did not update alpha's row"
[ "$(storerow main beta)" = "3" ] || fail "flag_set did not write beta's row"
[ "$(storerows)" = "2" ] || fail "expected 2 store rows, got $(storerows)"
# An out-of-range pick changes nothing at all — not the option, not the store.
run "$PLUGIN_DIR/scripts/flag_set.sh $wb 99"
sleep 0.3
[ "$(winopt "$wb" @sidetabs_flag)" = "3" ] || fail "out-of-range pick changed the live flag"
[ "$(storerow main beta)" = "3" ] || fail "out-of-range pick changed the store row"
pass "picker path writes through; an out-of-range pick is inert"

# --- 3. Clearing REMOVES the record ------------------------------------------
# The snapshot is what makes this work: the clear is not a delete of one row,
# it is a re-snapshot in which beta is live and unflagged, so its row is gone.
run "$PLUGIN_DIR/scripts/flag_set.sh $wb none"
sleep 0.3
[ -z "$(winopt "$wb" @sidetabs_flag)" ] || fail "clear left a live flag"
[ -z "$(storerow main beta)" ] || fail "clear left beta's row: '$(storerow main beta)'"
[ "$(storerow main alpha)" = "1" ] || fail "clearing beta disturbed alpha's row"
# Cycling off the end of the palette is the same clear by another route.
run "$PLUGIN_DIR/scripts/flag_set.sh $wg 8"
sleep 0.3
[ "$(storerow main gamma)" = "8" ] || fail "gamma not stored at the last palette slot"
run "$PLUGIN_DIR/scripts/flag_cycle.sh $wg"
sleep 0.3
[ -z "$(winopt "$wg" @sidetabs_flag)" ] || fail "cycle past the palette end left a flag"
[ -z "$(storerow main gamma)" ] || fail "cycle-to-clear left gamma's row"
pass "clearing removes the record (both the picker and the cycle wrap)"

# --- 4. A name full of escape-like characters round-trips ---------------------
run "$PLUGIN_DIR/scripts/flag_set.sh $we 2"
run "$PLUGIN_DIR/scripts/flag_set.sh $wl 4"
run "$PLUGIN_DIR/scripts/flag_set.sh $wo 6"
sleep 0.5
[ "$(storerow main "$ESCNAME")" = "2" ] || fail "no store row for '$ESCNAME'"
grep -qF "$ESCNAME" "$STORE" || fail "store does not hold the name verbatim: $(od -c "$STORE" | head -5)"
pass "a name containing a literal backslash-t is stored verbatim"

# --- 5. Rows for keys that are not live are preserved -------------------------
# Injected by hand, the way a previous server generation would have left them:
# a window that no longer exists, two unusable index values, and a SESSION row
# (empty middle field) for a session that is not open. A sync must carry every
# one of them through untouched — this store prunes nothing, which is what lets
# a closed session's colour come back later.
#
# The session row names a session that does NOT exist on purpose. A row for a
# LIVE session is a different case entirely: it is part of the snapshot, so a
# sync rewrites (or removes) it from live state, and section 5b covers that.
{
    printf 'main\tghost\t2\n'
    printf 'main\tbadidx\tzz\n'
    printf 'main\toorange\t99\n'
    printf 'ghostsess\t\t5\n'
} >> "$STORE"
before="$(storerows)"
run "$PLUGIN_DIR/scripts/flag_set.sh $wa 1"
sleep 0.4
[ "$(storerows)" = "$before" ] || fail "a sync pruned rows ($before -> $(storerows))"
[ "$(storerow main ghost)" = "2" ] || fail "sync dropped the row for a dead window"
[ "$(storerow main badidx)" = "zz" ] || fail "sync dropped a row with an unusable index"
[ "$(storerow ghostsess "")" = "5" ] || fail "sync dropped a closed session's colour row"
pass "a sync preserves rows for dead windows, bad indices and closed sessions"

# --- 5b. SESSION colours write through, in the empty-window-name row shape ----
# The whole point of D6: one store file holds both shapes, so the two states
# need one lock and one restore pass. A session row can never collide with a
# window row, because a window whose name is the empty string is never recorded.
pmain="$(spane main)"; poth="$(spane other)"
[ -n "$pmain" ] && [ -n "$poth" ] || fail "setup: could not resolve a pane per session"
run "$PLUGIN_DIR/scripts/session_flag_set.sh $pmain 2"
run "$PLUGIN_DIR/scripts/session_flag_set.sh $poth 6"
sleep 0.5
[ "$(sopt main @sidetabs_sflag)" = "2" ] || fail "session colour not set on main: '$(sopt main @sidetabs_sflag)'"
[ "$(sopt other @sidetabs_sflag)" = "6" ] || fail "session colour not set on other"
[ "$(storerow main "")" = "2" ] || fail "no session row for main: '$(storerow main "")'"
[ "$(storerow other "")" = "6" ] || fail "no session row for other"
# The window rows for the same session must be untouched by a session write —
# the two shapes are independent keys, not two readings of one row.
[ "$(storerow main alpha)" = "1" ] || fail "setting a session colour disturbed a window row"
# An out-of-range or garbage pick is inert in BOTH directions: no option change
# and no store write. A stale menu built from a longer palette must not be able
# to write an unrenderable index.
run "$PLUGIN_DIR/scripts/session_flag_set.sh $pmain 99"
run "$PLUGIN_DIR/scripts/session_flag_set.sh $pmain garbage"
sleep 0.5
[ "$(sopt main @sidetabs_sflag)" = "2" ] || fail "an unusable session pick changed the live colour"
[ "$(storerow main "")" = "2" ] || fail "an unusable session pick changed the store row"
pass "session colours write through to the empty-window-name row; bad picks are inert"

# Clearing removes the record, exactly as it does for a window flag: the store
# is a snapshot, so the clear is what makes the cleared state durable.
run "$PLUGIN_DIR/scripts/session_flag_set.sh $poth none"
sleep 0.4
[ -z "$(sopt other @sidetabs_sflag)" ] || fail "clear left a live session colour"
[ -z "$(storerow other "")" ] || fail "clear left other's session row: '$(storerow other "")'"
[ "$(storerow main "")" = "2" ] || fail "clearing other's colour disturbed main's row"
[ "$(storerow ghostsess "")" = "5" ] || fail "a session write pruned a closed session's row"
# Put it back: section 6 closes `other`, and phase B needs its colour stored.
run "$PLUGIN_DIR/scripts/session_flag_set.sh $poth 6"
sleep 0.4
[ "$(storerow other "")" = "6" ] || fail "other's session colour not restored before the close"
pass "clearing a session colour removes its row and disturbs nothing else"

# --- 6. A closed session keeps its rows ---------------------------------------
tmux -L "$SOCKET" kill-session -t other
sleep 0.3
run "$PLUGIN_DIR/scripts/flag_set.sh $wa 1"
sleep 0.4
[ "$(storerow other omega)" = "6" ] || fail "closing a session dropped its stored colour"
[ "$(storerow other "")" = "6" ] || fail "closing a session dropped its own session-colour row"
pass "a closed session's window AND session rows survive later syncs"

# --- 7. A failed write is a NO-OP, never a clear (unreadable store) ----------
# The lesson the notes work paid for: a step that swallows its own failure turns
# a transient I/O error into "the user cleared it" and destroys data. An
# unreadable store makes the merge's awk fail; nothing may be mv'd over the real
# file, so it must come back byte-identical.
cp "$STORE" "$BAK"
chmod 000 "$STORE"
run "$PLUGIN_DIR/scripts/flag_set.sh $wa 5"
sleep 0.5
chmod 644 "$STORE"
cmp -s "$STORE" "$BAK" || fail "an unreadable store was rewritten: $(diff "$BAK" "$STORE" | head -5)"
# The LIVE change still happened — only the durable write was skipped. An
# unwritable store must never make a keypress look like it failed.
[ "$(winopt "$wa" @sidetabs_flag)" = "5" ] || fail "the live flag change was lost too"
pass "an unreadable store is left byte-identical (and the live change still lands)"

# --- 8. A failed write is a NO-OP (unwritable directory) ---------------------
# The other realistic failure: the store is readable but no temp file can be
# created beside it, so the merge never produces anything to mv. This is also
# the path where the mkdir lock itself cannot be taken.
mkdir -p "$RODIR"
ROSTORE="$RODIR/flags.tsv"
printf 'main\tkeepme\t3\n' > "$ROSTORE"
rosum="$(cksum < "$ROSTORE")"
chmod 555 "$RODIR"
tmux -L "$SOCKET" set -g @sidetabs-flag-store "$ROSTORE"
run "$PLUGIN_DIR/scripts/flag_set.sh $wa 7"
sleep 2   # store_lock spins ~1s before giving up on an undoable mkdir
[ "$(cksum < "$ROSTORE")" = "$rosum" ] || fail "an unwritable store directory still rewrote the store"
[ "$(ls "$RODIR")" = "flags.tsv" ] || fail "temp/lock debris left in the store directory: $(ls "$RODIR")"
chmod 755 "$RODIR"
tmux -L "$SOCKET" set -g @sidetabs-flag-store "$STORE"
pass "an unwritable store directory leaves the store untouched and drops no debris"

# --- 9. A sync stands down while a restore is in flight ----------------------
# tmux-resurrect creates and renames windows long before flag_restore.sh seeds
# their flags. A sync landing in that gap would see every restored window as
# legitimately unflagged and wipe the very rows the restore is about to replay.
tmux -L "$SOCKET" set -g @sidetabs_restoring 1
run "$PLUGIN_DIR/scripts/flag_store.sh sync"
sleep 0.4
[ "$(storerow main alpha)" = "1" ] || fail "a sync during a restore rewrote the store"
[ "$(storerow other omega)" = "6" ] || fail "a sync during a restore dropped a closed session's row"
[ "$(storerow main "")" = "2" ] || fail "a sync during a restore dropped a live session's colour row"
tmux -L "$SOCKET" set -g @sidetabs_restoring 0
# Put alpha back to its stored value, so phase B starts from a store that
# matches what sections 1-6 built.
run "$PLUGIN_DIR/scripts/flag_set.sh $wa 1"
sleep 0.4
[ "$(storerow main alpha)" = "1" ] || fail "alpha's row not restored to 1 before the restart"
pass "a sync is a no-op while @sidetabs_restoring is set"

# ===========================================================================
# PHASE B — restore after a real server restart
# ===========================================================================
# Killing the server is the honest simulation: window ids, session ids and every
# tmux option are gone, and only the TSV crosses the boundary.
tmux -L "$SOCKET" kill-server 2>/dev/null || true
sleep 0.5
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n alpha -x 200 -y 50
tmux -L "$SOCKET" set -g @sidetabs-flag-store "$STORE"
# beta had its flag cleared, so it must come back uncoloured; delta was never
# stored at all; badidx/oorange exist only to prove their rows are ignored; the
# second `alpha` proves first-window-with-a-name wins.
for w in beta delta badidx oorange "$ESCNAME" livewin alpha; do
    tmux -L "$SOCKET" new-window -t main -n "$w"
done
tmux -L "$SOCKET" new-session -d -s other -n omega
# Session-colour fixtures, mirroring the window ones one scope up: `livesess`
# carries a live colour the restore must not clobber, and `badsess`/`oosess`
# have rows whose index is unusable and must be ignored rather than applied.
{
    printf 'livesess\t\t3\n'
    printf 'badsess\t\tzz\n'
    printf 'oosess\t\t99\n'
} >> "$STORE"
for s in livesess badsess oosess; do
    tmux -L "$SOCKET" new-session -d -s "$s" -n w1
done
tmux -L "$SOCKET" set-option -t livesess -q @sidetabs_sflag 7
sleep 0.3

wa="$(winid main alpha)"; wb="$(winid main beta)"; wd="$(winid main delta)"
wbi="$(winid main badidx)"; wor="$(winid main oorange)"
we="$(winid main "$ESCNAME")"; wl="$(winid main livewin)"; wo="$(winid other omega)"
wa2="$(tmux -L "$SOCKET" list-windows -t main -F "#{window_id}${TAB}#{window_name}" \
        | awk -F"$TAB" '$2 == "alpha" { c++; if (c == 2) { print $1; exit } }')"
[ -n "$wa" ] && [ -n "$wa2" ] && [ "$wa" != "$wa2" ] || fail "setup: need two windows named alpha"

# livewin carries a live flag the restore must not touch.
tmux -L "$SOCKET" set -w -t "$wl" @sidetabs_flag 7

tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_restore.sh"
sleep 0.6

[ "$(winopt "$wa" @sidetabs_flag)" = "1" ] || fail "alpha not restored: '$(winopt "$wa" @sidetabs_flag)' (want 1)"
pass "a flagged window regains its colour, matched by session + window name"

[ -z "$(winopt "$wb" @sidetabs_flag)" ] || fail "beta came back flagged despite a cleared record"
pass "a cleared window comes back uncoloured"

[ "$(winopt "$we" @sidetabs_flag)" = "2" ] \
    || fail "'$ESCNAME' not restored: '$(winopt "$we" @sidetabs_flag)' (want 2) — awk -v escape expansion?"
pass "a name containing escape-like characters still matches its record"

[ "$(winopt "$wl" @sidetabs_flag)" = "7" ] || fail "restore clobbered a live flag"
pass "restore never overwrites a flag already set on a live window"

[ -z "$(winopt "$wd" @sidetabs_flag)" ] || fail "delta was painted from a record that is not its own"
[ -z "$(winopt "$wbi" @sidetabs_flag)" ] || fail "a non-numeric stored index was applied"
[ -z "$(winopt "$wor" @sidetabs_flag)" ] || fail "an out-of-palette stored index was applied"
[ -z "$(winopt "$wa2" @sidetabs_flag)" ] || fail "a duplicate-named window was seeded from the first one's record"
pass "unmatched, unusable and duplicate-name records are ignored, never misapplied"

# A SESSION row must never reach a window. ghostsess/""/5 names no live session,
# so if the window pass ever stopped filtering on the middle field, index 5 is
# what would show up on some window — nothing else in this store holds a 5.
#
# The read is #{@sidetabs_flag} on windows, and the option chain resolves
# pane -> window -> session -> global, so this would ALSO catch a session
# colour written under the window option's name (the reason SFLAG_OPTION has a
# name of its own).
badfive="$(tmux -L "$SOCKET" list-windows -a -F "#{window_name}${TAB}#{@sidetabs_flag}" \
    | awk -F"$TAB" '$2 == "5" { print $1 }' || true)"
[ -z "$badfive" ] || fail "a session-colour row was applied to window(s): $badfive"
[ "$(storerow ghostsess "")" = "5" ] || fail "restore disturbed a closed session's colour row"
pass "session rows are skipped by the window restore and left in place"

# --- session colours restore, by session name --------------------------------
[ "$(sopt main @sidetabs_sflag)" = "2" ] \
    || fail "main's session colour not restored: '$(sopt main @sidetabs_sflag)' (want 2)"
[ "$(sopt other @sidetabs_sflag)" = "6" ] \
    || fail "a reopened session did not regain its colour: '$(sopt other @sidetabs_sflag)'"
pass "session colours are restored, matched by session name"

[ "$(sopt livesess @sidetabs_sflag)" = "7" ] || fail "restore clobbered a live session colour"
pass "restore never overwrites a colour already set on a live session"

[ -z "$(sopt badsess @sidetabs_sflag)" ] || fail "a non-numeric stored session index was applied"
[ -z "$(sopt oosess @sidetabs_sflag)" ] || fail "an out-of-palette stored session index was applied"
pass "unusable session-colour records are ignored, never misapplied"

# The mirror of the check above: a WINDOW row must never reach a session. Only
# main/livewin holds a 4, and it is a window row.
badsess4="$(tmux -L "$SOCKET" list-sessions -F "#{session_name}${TAB}#{@sidetabs_sflag}" \
    | awk -F"$TAB" '$2 == "4" { print $1 }' || true)"
[ -z "$badsess4" ] || fail "a window-flag row was applied to session(s): $badsess4"
pass "window rows are skipped by the session restore"

[ "$(winopt "$wo" @sidetabs_flag)" = "6" ] \
    || fail "a reopened session did not regain its colour: '$(winopt "$wo" @sidetabs_flag)'"
pass "a closed session's colour returns when the session does"

[ "$(gopt @sidetabs_flag_restored)" = "1" ] || fail "restore did not claim @sidetabs_flag_restored"
pass "the restore claims the generation flag"

# ===========================================================================
# PHASE C — the `boot` fallback
# ===========================================================================
printf 'main\tbootwin\t4\n' >> "$STORE"
tmux -L "$SOCKET" new-window -t main -n bootwin
wbt="$(winid main bootwin)"
[ -n "$wbt" ] || fail "setup: missing bootwin"

# The phase-B restore claimed this generation, so the fallback stands down.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_restore.sh boot"
sleep 0.5
[ -z "$(winopt "$wbt" @sidetabs_flag)" ] || fail "boot mode seeded despite a claimed generation flag"
pass "boot mode stands down once the generation is claimed"

# Released, but outside the boot window: stands down WITHOUT claiming. This is
# the guard against painting a window created hours later with a long-gone
# same-named window's colour.
tmux -L "$SOCKET" set -g @sidetabs_flag_restored 0
tmux -L "$SOCKET" run-shell "SIDETABS_FLAG_BOOT_MAX_AGE_S=0 '$PLUGIN_DIR/scripts/flag_restore.sh' boot"
sleep 0.5
[ -z "$(winopt "$wbt" @sidetabs_flag)" ] || fail "boot mode seeded on an old server"
[ "$(gopt @sidetabs_flag_restored)" = "0" ] \
    || fail "boot mode claimed the generation despite standing down on age"
pass "boot mode stands down (without claiming) outside the boot window"

# Released, inside the boot window, but a restore is in flight: stands down and
# leaves the claim to the post-restore hook.
tmux -L "$SOCKET" set -g @sidetabs_restoring 1
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_restore.sh boot"
sleep 0.5
[ -z "$(winopt "$wbt" @sidetabs_flag)" ] || fail "boot mode seeded while a restore was in flight"
[ "$(gopt @sidetabs_flag_restored)" = "0" ] || fail "boot mode claimed the generation mid-restore"
tmux -L "$SOCKET" set -g @sidetabs_restoring 0
pass "boot mode stands down while a restore is in flight"

# Young server, nothing else has claimed: this is the path that covers
# tmux-continuum skipping auto-restore altogether.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_restore.sh boot"
sleep 0.5
[ "$(winopt "$wbt" @sidetabs_flag)" = "4" ] || fail "boot mode did not seed bootwin"
[ "$(gopt @sidetabs_flag_restored)" = "1" ] || fail "boot mode did not claim the generation flag"
pass "boot mode seeds a young server and claims the generation"

# --- the boot restore holds the write-through guard --------------------------
# THE DATA-LOSS CASE. flag_store.sh's sync is a whole-state SNAPSHOT, so a sync
# that runs while a restore is mid-flight sees every not-yet-seeded window as
# legitimately unflagged and DELETES its row — wiping the durable record the
# restore was about to read. The resurrect path is covered by
# @sidetabs_restoring (section 9); the `boot` path is not, because continuum
# declining to auto-restore means nothing ever raises that flag, so `boot` holds
# @sidetabs_flag_restoring instead. window-renamed[1] and session-renamed[1] both
# fire a sync, so a rename anywhere on the server during a boot restore is all
# it takes.
#
# The race is milliseconds wide in reality, so the seam SIDETABS_FLAG_RESTORE_-
# TEST_DELAY_S holds the replay open and the sync is landed squarely inside it.
# Without the guard the store is emptied of every live window's row here, and
# bootwin comes back uncoloured — the restore reads the store AFTER the sync
# deleted it.
tmux -L "$SOCKET" set -g @sidetabs_flag_restored 0
tmux -L "$SOCKET" set -w -t "$wbt" -u @sidetabs_flag
tmux -L "$SOCKET" run-shell -b \
    "SIDETABS_FLAG_RESTORE_TEST_DELAY_S=3 '$PLUGIN_DIR/scripts/flag_restore.sh' boot"
sleep 1
# The guard is a tmux option precisely so ANOTHER process can see it; asserting
# it from here is asserting exactly what flag_store.sh reads.
[ "$(gopt @sidetabs_flag_restoring)" = "1" ] \
    || fail "the boot restore did not raise @sidetabs_flag_restoring while replaying"
run "$PLUGIN_DIR/scripts/flag_store.sh sync"
sleep 0.5
[ "$(storerow main bootwin)" = "4" ] \
    || fail "a sync during a BOOT restore deleted the row the restore was about to replay"
[ "$(storerow main alpha)" = "1" ] || fail "a sync during a boot restore rewrote the store"
[ "$(storerow main "")" = "2" ] \
    || fail "a sync during a boot restore dropped a live session's colour row"
pass "a sync is a no-op while a BOOT restore is in flight"

# ...and the replay still lands, from a store the sync left alone.
sleep 3
[ "$(winopt "$wbt" @sidetabs_flag)" = "4" ] \
    || fail "the boot restore did not seed bootwin after a sync landed mid-flight"
# A leaked guard would stay "1" for the rest of the server's life and silently
# disable EVERY write-through from then on, which is worse than the bug it
# guards. flag_restore.sh releases it from a trap, so this holds on the failure
# paths too.
[ "$(gopt @sidetabs_flag_restoring)" = "0" ] \
    || fail "the boot restore leaked @sidetabs_flag_restoring: '$(gopt @sidetabs_flag_restoring)'"
pass "the guard is released when the restore finishes, so write-through resumes"

# Proof the release is real and not just "the option looks clear": a set after
# the restore must reach the store again.
run "$PLUGIN_DIR/scripts/flag_set.sh $wbt 5"
sleep 0.5
[ "$(storerow main bootwin)" = "5" ] || fail "write-through did not resume after the boot restore"
run "$PLUGIN_DIR/scripts/flag_set.sh $wbt 4"
sleep 0.5
[ "$(storerow main bootwin)" = "4" ] || fail "could not put bootwin's row back to 4"
pass "write-through works again once the boot restore has finished"

# The resurrect path never stands down for the fallback: losing that race (a
# client attaching before continuum restores) would leave every flag unseeded.
tmux -L "$SOCKET" set -w -t "$wbt" -u @sidetabs_flag
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_restore.sh"
sleep 0.5
[ "$(winopt "$wbt" @sidetabs_flag)" = "4" ] \
    || fail "default (resurrect) mode stood down for a claimed generation"
pass "the resurrect path still restores after the fallback claimed the generation"

# --- Master switch ------------------------------------------------------------
tmux -L "$SOCKET" set -g @sidetabs-flag-restore off
tmux -L "$SOCKET" set -w -t "$wbt" -u @sidetabs_flag
tmux -L "$SOCKET" set -g @sidetabs_flag_restored 0
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_restore.sh"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/flag_restore.sh boot"
sleep 0.6
[ -z "$(winopt "$wbt" @sidetabs_flag)" ] || fail "@sidetabs-flag-restore off did not disable the restore"
[ "$(gopt @sidetabs_flag_restored)" = "0" ] || fail "a disabled restore still claimed the generation"
tmux -L "$SOCKET" set -g @sidetabs-flag-restore on
pass "@sidetabs-flag-restore off disables both delivery paths"

# ===========================================================================
# PHASE D — wiring
# ===========================================================================
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 1

tmux -L "$SOCKET" show-hooks -g 2>/dev/null | grep -q 'client-attached\[3\].*flag_restore.sh boot' \
    || fail "client-attached[3] does not run flag_restore.sh boot"
pass "the boot fallback is wired to client-attached[3]"

grep -q 'flag_restore.sh' "$PLUGIN_DIR/scripts/resurrect_post.sh" \
    || fail "resurrect_post.sh does not call flag_restore.sh"
pass "the post-restore hook calls flag_restore.sh"

# window-renamed is one of the hook names `show-hooks -g` does not enumerate on
# tmux 3.6b even when set, so this is asserted FUNCTIONALLY: rename a flagged
# window and watch the store re-file it under the new name, keeping the old row.
run "$PLUGIN_DIR/scripts/flag_set.sh $wd 3"
sleep 0.4
[ "$(storerow main delta)" = "3" ] || fail "setup: delta not stored before the rename"
tmux -L "$SOCKET" rename-window -t "$wd" deltarenamed
sleep 0.8
[ "$(storerow main deltarenamed)" = "3" ] \
    || fail "window-renamed did not re-file the flag: '$(storerow main deltarenamed)'"
[ "$(storerow main delta)" = "3" ] || fail "the row under the old name was pruned"
pass "renaming a flagged window re-files it in the store and keeps the old row"

echo "ALL FLAG RESTORE TESTS PASSED"
