#!/usr/bin/env bash
# Notes FOLLOW RENAMES, the index never dangles, and restore has a boot path.
#
# The bug this pins down, end to end: a note was written in window `dealmemo-3`,
# the window was renamed `dm-qh`, and nothing re-filed the index row — it stayed
# under the old name, a later save added a SECOND row under the new one, and a
# clear dropped only the current-key row, leaving the other pointing at a
# deleted file. Notes also had no boot-time restore, so a server generation
# where tmux-resurrect's post-restore hook never fired re-attached nothing.
#
# Covered, one section per guarantee:
#   A  a window rename AND a session rename re-file the row: exactly one row per
#      note id, under the window's current (session, name); rows for windows
#      that are not live are carried through byte for byte
#   B  clearing a note removes EVERY row that references its id
#   C  nothing but an explicit clear (or `gc`) ever deletes note text: a row
#      displaced by a rename keeps its file AND its row, and an empty save on a
#      window with no live note removes nobody else's row
#   D  `restore boot`: once per generation, only on a young server, standing
#      down while a resurrect restore is in flight — and never blocking the
#      resurrect path
#   E  restore never writes the store or touches a note file
#   F  saves and renames racing each other lose no row
#   G  names and ids are compared exactly: numeric-looking names (`1` vs `01`),
#      names holding a backslash or a tab, a dangling row ahead of a valid one,
#      and a CRLF line ending on a row
# plus the reported scenario itself, across real server restarts.
#
# -f /dev/null is required on every server started here: without it a new server
# on this socket still auto-loads the user's ~/.tmux.conf (which run-shells this
# plugin AND others), polluting hooks/keys and defeating test isolation. The
# flag store and the timer log are repointed as well as the note store: loading
# the plugin wires flag_store.sh to the same rename hooks, and it would
# otherwise snapshot THIS server into the user's real flags.tsv.
set -euo pipefail

SOCKET="sidetab_noter_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/sidetabs_noterename_$$"
STORE="$WORK/notes.tsv"
NDIR="$STORE.d"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK"

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
run() { tmux -L "$SOCKET" run-shell "$*"; }
winopt() { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }
gopt() { tmux -L "$SOCKET" show-option -gqv "$1"; }

TAB="$(printf '\t')"

# boot <first window name>: a NEW server generation on the same socket. Killing
# the server is the honest simulation of a restart — window ids and every tmux
# option are gone, and only the store and the note files cross the boundary.
boot() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    sleep 0.5
    tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n "$1" -x 200 -y 50
    tmux -L "$SOCKET" set-option -g @sidetabs-summary off
    tmux -L "$SOCKET" set-option -g @sidetabs-note-store "$STORE"
    tmux -L "$SOCKET" set-option -g @sidetabs-flag-store "$WORK/flags.tsv"
    tmux -L "$SOCKET" set-option -g @sidetabs-timer-log "$WORK/timelog.tsv"
}
# No `head`/`exit` in a pipe reader: under pipefail a reader closing the pipe
# early can SIGPIPE tmux and fail the whole pipeline.
winid() {
    tmux -L "$SOCKET" list-windows -t "$1" -F "#{window_id}${TAB}#{window_name}" 2>/dev/null \
        | n="$2" awk -F"$TAB" '$2 == ENVIRON["n"] && !seen { print $1; seen = 1 }'
}
# Note id of the FIRST row filed under (session, window), or empty. First is
# what `note.sh restore` applies, so it is the row that matters.
storerow() {
    [ -f "$STORE" ] || return 0
    s="$1" w="$2" awk -F"$TAB" \
        '$1 == ENVIRON["s"] && $2 == ENVIRON["w"] && !seen { print $3; seen = 1 }' "$STORE"
}
# How many rows reference a note id, under ANY key.
idrows() {
    if [ -f "$STORE" ]; then
        i="$1" awk -F"$TAB" '$3 == ENVIRON["i"] { n++ } END { print n + 0 }' "$STORE"
    else
        echo 0
    fi
}
# Is this exact row in the store?
hasrow() { [ -f "$STORE" ] && grep -qxF "$1${TAB}$2${TAB}$3" "$STORE"; }
# A fingerprint of every note file: any delete, truncate or rewrite changes it.
notesum() { ( cd "$NDIR" 2>/dev/null && cksum n1-* 2>/dev/null ) || true; }
noteid() {
    local got
    got="$(winopt "$1" @sidetabs_note)"
    case "$got" in n1-[A-Za-z0-9]*) printf '%s' "$got" ;; *) fail "$2: option is not a note id: '$got'" ;; esac
}

CAP="$WORK/captured.txt"
ED_CAPTURE="$WORK/ed_capture.sh"
cat > "$ED_CAPTURE" <<EOF
#!/usr/bin/env bash
cp "\$1" "$CAP"
EOF
ED_EMPTY="$WORK/ed_empty.sh"
cat > "$ED_EMPTY" <<'EOF'
#!/usr/bin/env bash
: > "$1"
EOF
chmod +x "$ED_CAPTURE" "$ED_EMPTY"

# ===========================================================================
# PHASE 1 — the reported scenario, generation 1: note, rename, save
# ===========================================================================
boot dealmemo-3
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.6
wdm="$(winid main dealmemo-3)"
[ -n "$wdm" ] || fail "setup: window dealmemo-3 missing"

run "$PLUGIN_DIR/scripts/note.sh set $wdm deal memo v1"
sleep 0.4
dm_id="$(noteid "$wdm" "dealmemo-3")"
hasrow main dealmemo-3 "$dm_id" || fail "setup: no row under the original name: $(cat "$STORE")"

# --- A1. A window rename re-files the row ------------------------------------
tmux -L "$SOCKET" rename-window -t "$wdm" dm-qh
sleep 1
hasrow main dm-qh "$dm_id" \
    || fail "window-renamed did not re-file the note under the new name: $(cat "$STORE")"
[ -z "$(storerow main dealmemo-3)" ] \
    || fail "the row under the OLD name survived the rename: $(cat "$STORE")"
[ "$(idrows "$dm_id")" = "1" ] || fail "expected exactly 1 row for the note, got $(idrows "$dm_id")"
[ "$(cat "$NDIR/$dm_id")" = "deal memo v1" ] || fail "the rename changed the note text"
pass "A: renaming a window re-files its note row under the new name (one row, text intact)"

# ...and the save AFTER the rename — the second half of the reported sequence —
# must still leave exactly one row. Before the fix this is where the duplicate
# appeared: the save appended a row under the new name and left the old one.
run "$PLUGIN_DIR/scripts/note.sh set $wdm deal memo v2"
sleep 0.4
[ "$(noteid "$wdm" "dm-qh")" = "$dm_id" ] || fail "re-saving after a rename changed the note id"
[ "$(idrows "$dm_id")" = "1" ] || fail "a save after a rename left $(idrows "$dm_id") rows for one note"
hasrow main dm-qh "$dm_id" || fail "a save after a rename lost the row: $(cat "$STORE")"
[ "$(cat "$NDIR/$dm_id")" = "deal memo v2" ] || fail "the save after the rename did not land"
pass "A: a save after a rename still leaves exactly one row"

# --- A2. A store already carrying the old duplicate heals itself -------------
# This is what an index written before the fix looks like: the same id filed
# under the old name AND the new one. Any sync collapses it onto the live key.
printf 'main\tdealmemo-3\t%s\n' "$dm_id" >> "$STORE"
[ "$(idrows "$dm_id")" = "2" ] || fail "setup: could not inject the stale duplicate row"
run "$PLUGIN_DIR/scripts/note.sh sync"
sleep 0.3
[ "$(idrows "$dm_id")" = "1" ] || fail "a sync left $(idrows "$dm_id") rows for one live note"
hasrow main dm-qh "$dm_id" || fail "the sync kept the wrong row: $(cat "$STORE")"
pass "A: a pre-fix duplicate (old name + new name) collapses onto the live key"

# --- A3. A session rename re-files the row too -------------------------------
tmux -L "$SOCKET" new-session -d -s proj -n w1 -x 200 -y 50
sleep 0.6
wp="$(winid proj w1)"
[ -n "$wp" ] || fail "setup: proj:w1 missing"
run "$PLUGIN_DIR/scripts/note.sh set $wp session scoped note"
sleep 0.4
proj_id="$(noteid "$wp" "proj:w1")"
hasrow proj w1 "$proj_id" || fail "setup: no row for proj/w1"
tmux -L "$SOCKET" rename-session -t proj proj2
sleep 1
hasrow proj2 w1 "$proj_id" \
    || fail "session-renamed did not re-file the note under the new session name: $(cat "$STORE")"
[ "$(idrows "$proj_id")" = "1" ] \
    || fail "expected exactly 1 row after a session rename, got $(idrows "$proj_id")"
pass "A: renaming a SESSION re-files its windows' note rows"

# --- A4. Rows for windows that are not live are carried through untouched ----
# The store deliberately keeps rows for windows that will come back: a closed
# window, a closed session, a legacy inline-text row, and a line it cannot parse
# at all. None of them is live, so a sync must not rewrite or drop a single one.
printf 'ghost text\n'  > "$NDIR/n1-ghost0001"
printf 'closed text\n' > "$NDIR/n1-closed001"
{
    printf 'main\tghost\tn1-ghost0001\n'
    printf 'closedsess\twin\tn1-closed001\n'
    printf 'main\tlegacyghost\tinline legacy text\n'
    printf 'unparseable line\n'
} >> "$STORE"
tmux -L "$SOCKET" rename-window -t "$wp" w1b
sleep 1
hasrow proj2 w1b "$proj_id" || fail "setup: the rename under test did not land: $(cat "$STORE")"
hasrow main ghost n1-ghost0001 || fail "a sync dropped the row of a closed window"
hasrow closedsess win n1-closed001 || fail "a sync dropped the row of a closed session"
hasrow main legacyghost 'inline legacy text' || fail "a sync dropped a legacy inline row"
grep -qxF 'unparseable line' "$STORE" || fail "a sync dropped a line it could not parse"
[ -f "$NDIR/n1-ghost0001" ] && [ -f "$NDIR/n1-closed001" ] || fail "a sync deleted a note file"
pass "A: rows for windows that are not live survive a sync byte for byte"

# --- A5. Idempotent ----------------------------------------------------------
before="$(cksum < "$STORE")"
run "$PLUGIN_DIR/scripts/note.sh sync"
run "$PLUGIN_DIR/scripts/note.sh sync"
sleep 0.3
[ "$(cksum < "$STORE")" = "$before" ] || fail "a repeated sync changed a store that was already right"
pass "A: a sync of a store that is already right changes nothing"

# --- A5b. A failed write is a NO-OP, never a clear ---------------------------
# The house rule: an unreadable store makes the merge fail, and nothing may be
# moved over the real file — it must come back byte-identical. The rename is
# what makes this a real test: it is a change the sync WANTS to write.
cp "$STORE" "$WORK/store.bak"
chmod 000 "$STORE"
tmux -L "$SOCKET" rename-window -t "$wp" w1c
sleep 1
run "$PLUGIN_DIR/scripts/note.sh sync"
chmod 644 "$STORE"
cmp -s "$STORE" "$WORK/store.bak" \
    || fail "an unreadable store was rewritten: $(diff "$WORK/store.bak" "$STORE" | head -5)"
[ -z "$(ls "$WORK" | grep -E '^notes\.tsv\.(tmp|live|lock)' || true)" ] \
    || fail "a failed sync left temp/lock debris beside the store: $(ls "$WORK")"
# ...and once the store is readable again the next sync catches up by itself.
run "$PLUGIN_DIR/scripts/note.sh sync"
sleep 0.3
hasrow proj2 w1c "$proj_id" || fail "the sync after a failed write did not catch up: $(cat "$STORE")"
[ "$(idrows "$proj_id")" = "1" ] || fail "catching up left $(idrows "$proj_id") rows for one note"
pass "A: an unreadable store is left byte-identical, and the next sync catches up"

# --- A6. A sync never CREATES a dangling row ---------------------------------
# A live option naming a note whose file is gone must not be filed: that would
# manufacture exactly the dangling row section B exists to prevent.
tmux -L "$SOCKET" new-window -t main -n nofile
sleep 0.5
wnf="$(winid main nofile)"
tmux -L "$SOCKET" set-option -w -t "$wnf" @sidetabs_note n1-nofile001
run "$PLUGIN_DIR/scripts/note.sh sync"
sleep 0.3
[ "$(idrows n1-nofile001)" = "0" ] || fail "a sync filed a row for a note with no file"
tmux -L "$SOCKET" set-option -w -t "$wnf" -qu @sidetabs_note
pass "A: a live id with no file behind it is never filed"

# ===========================================================================
# B — clearing a note removes every row that references it
# ===========================================================================
tmux -L "$SOCKET" new-window -t main -n clearme
sleep 0.5
wc="$(winid main clearme)"
run "$PLUGIN_DIR/scripts/note.sh set $wc about to be cleared"
sleep 0.4
clr_id="$(noteid "$wc" "clearme")"
# The stale row a rename used to leave behind. It is injected and the clear run
# straight away, with no rename in between, so nothing but the clear itself can
# be what removes it.
printf 'main\tclearme-oldname\t%s\n' "$clr_id" >> "$STORE"
[ "$(idrows "$clr_id")" = "2" ] || fail "setup: could not inject the stale row"
run "EDITOR=$ED_EMPTY $PLUGIN_DIR/scripts/note.sh edit-popup $wc"
sleep 0.4
[ -z "$(winopt "$wc" @sidetabs_note)" ] || fail "an empty save did not clear the option"
[ ! -f "$NDIR/$clr_id" ] || fail "an empty save left the note file behind"
[ "$(idrows "$clr_id")" = "0" ] \
    || fail "a cleared note still has $(idrows "$clr_id") row(s) pointing at its deleted file: $(cat "$STORE")"
hasrow main dm-qh "$dm_id" || fail "clearing one note disturbed another note's row"
hasrow main ghost n1-ghost0001 || fail "clearing one note dropped a closed window's row"
pass "B: an empty save removes EVERY row for the deleted note, under any name"

# ===========================================================================
# C — never delete text as a side effect
# ===========================================================================
# --- C1. A rename onto a name another note is filed under --------------------
# `taken` belongs to a window that is closed for now; its row is waiting for it.
# A live noted window is then renamed to that same name. The live note has to be
# filed under the name (A), and the displaced one must lose neither its file nor
# its only pointer.
printf 'the displaced note\n' > "$NDIR/n1-displaced1"
printf 'main\ttaken\tn1-displaced1\n' >> "$STORE"
tmux -L "$SOCKET" new-window -t main -n mover
sleep 0.5
wm="$(winid main mover)"
run "$PLUGIN_DIR/scripts/note.sh set $wm the moving note"
sleep 0.4
mov_id="$(noteid "$wm" "mover")"
tmux -L "$SOCKET" rename-window -t "$wm" taken
sleep 1
hasrow main taken "$mov_id" || fail "the live note was not filed under its new name: $(cat "$STORE")"
[ "$(idrows "$mov_id")" = "1" ] || fail "expected 1 row for the live note, got $(idrows "$mov_id")"
[ "$(cat "$NDIR/n1-displaced1" 2>/dev/null)" = "the displaced note" ] \
    || fail "a rename onto a taken name deleted or changed the displaced note's file"
hasrow main taken n1-displaced1 \
    || fail "a rename onto a taken name destroyed the displaced note's only row: $(cat "$STORE")"
# The LIVE note has to be the first row under the shared key: restore applies
# the first match, and after a restart this window must get its own note back.
[ "$(storerow main taken)" = "$mov_id" ] \
    || fail "the displaced row shadows the live note under their shared name: $(cat "$STORE")"
pass "C: a rename onto a taken name keeps the displaced note's file AND its row"

# A later SAVE in that window must not finish the job the rename refused to do.
run "$PLUGIN_DIR/scripts/note.sh set $wm the moving note, edited"
sleep 0.4
hasrow main taken n1-displaced1 || fail "a save dropped the displaced note's row: $(cat "$STORE")"
[ -f "$NDIR/n1-displaced1" ] || fail "a save deleted the displaced note's file"
[ "$(storerow main taken)" = "$mov_id" ] || fail "a save let the displaced row shadow the live one"
# Renaming away again leaves the name to the note that was waiting for it.
tmux -L "$SOCKET" rename-window -t "$wm" moved-on
sleep 1
hasrow main moved-on "$mov_id" || fail "the live note did not follow the second rename"
[ "$(storerow main taken)" = "n1-displaced1" ] \
    || fail "the displaced note did not get its name back: $(cat "$STORE")"
# gc is the only sweeper, and it only takes files nothing references — which the
# displaced note still is, precisely because its row was kept.
run "$PLUGIN_DIR/scripts/note.sh gc"
sleep 0.4
[ -f "$NDIR/n1-displaced1" ] || fail "gc swept a displaced note that still had its row"
pass "C: a displaced note survives later saves, renames and a gc"

# --- C2. An empty save on a window with NO live note removes nobody's row ----
# The window carries no note option (this is what a window looks like before a
# restore has run), but a note is filed under its name. Opening the editor and
# closing it empty is not a request to delete that note.
printf 'not yours to clear\n' > "$NDIR/n1-waiting01"
printf 'main\tidle\tn1-waiting01\n' >> "$STORE"
tmux -L "$SOCKET" new-window -t main -n idle
sleep 0.5
wi="$(winid main idle)"
[ -z "$(winopt "$wi" @sidetabs_note)" ] || fail "setup: idle already has a note option"
run "EDITOR=$ED_EMPTY $PLUGIN_DIR/scripts/note.sh edit-popup $wi"
run "$PLUGIN_DIR/scripts/note.sh clear $wi"
sleep 0.4
hasrow main idle n1-waiting01 \
    || fail "an empty save on an un-noted window dropped a stored note's row: $(cat "$STORE")"
[ "$(cat "$NDIR/n1-waiting01" 2>/dev/null)" = "not yours to clear" ] \
    || fail "an empty save on an un-noted window touched a stored note's file"
pass "C: an empty save on a window with no live note leaves the stored note alone"

# ===========================================================================
# F — saves and renames racing each other lose no row
# ===========================================================================
# Every window already HAS a note filed under its first name. Each one is then
# re-saved and renamed AT THE SAME TIME, so every save's write-back overlaps a
# rename hook's. The store is a snapshot taken under the lock, so whichever
# writer goes last sees both the note and the new name; row-at-a-time surgery
# would leave the save's row under whichever name it happened to read.
K=6
i=1
while [ "$i" -le "$K" ]; do tmux -L "$SOCKET" new-window -d -t main -n "race$i"; i=$((i + 1)); done
sleep 1
RW=""
i=1
while [ "$i" -le "$K" ]; do
    rw="$(winid main "race$i")"
    [ -n "$rw" ] || fail "setup: window race$i missing"
    RW="$RW $rw"
    run "$PLUGIN_DIR/scripts/note.sh set $rw first draft $i"
    i=$((i + 1))
done
sleep 0.5
i=1
for rw in $RW; do
    hasrow main "race$i" "$(noteid "$rw" "race$i")" || fail "setup: no row for race$i before the race"
    i=$((i + 1))
done
i=1
for rw in $RW; do
    ( tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/note.sh set $rw racing note $i" ) &
    ( tmux -L "$SOCKET" rename-window -t "$rw" "raced$i" ) &
    i=$((i + 1))
done
wait
sleep 2.5
i=1
for rw in $RW; do
    rid="$(noteid "$rw" "raced$i")"
    [ "$(idrows "$rid")" = "1" ] \
        || fail "raced$i: expected exactly 1 row, got $(idrows "$rid"): $(cat "$STORE")"
    hasrow main "raced$i" "$rid" \
        || fail "raced$i: its row is not under the name it ended up with: $(cat "$STORE")"
    [ "$(cat "$NDIR/$rid")" = "racing note $i" ] || fail "raced$i: note text lost in the race"
    i=$((i + 1))
done
hasrow main dm-qh "$dm_id" || fail "the race dropped an unrelated live note's row"
hasrow main ghost n1-ghost0001 || fail "the race dropped a closed window's row"
hasrow main taken n1-displaced1 || fail "the race dropped the displaced note's row"
pass "F: $K saves racing $K renames leave exactly one correctly-keyed row each"

# ===========================================================================
# PHASE 2 — the reported scenario, generation 2: back under the OLD name
# ===========================================================================
# The restart brings the window back as `dealmemo-3`, the name it had BEFORE the
# rename (a tmux-resurrect save file older than the rename does exactly this).
# The note is filed under `dm-qh`, so it attaches to nothing here — and that must
# be all that happens: no row moved, no file touched, nothing deleted.
boot dealmemo-3
wold="$(winid main dealmemo-3)"
[ -n "$wold" ] || fail "setup: generation 2 window missing"
store_before="$(cksum < "$STORE")"
notes_before="$(notesum)"
[ -n "$notes_before" ] || fail "setup: no note files to fingerprint"
run "$PLUGIN_DIR/scripts/note.sh restore"
tmux -L "$SOCKET" set -g @sidetabs_note_restored 0
run "$PLUGIN_DIR/scripts/note.sh restore boot"
sleep 0.5
[ -z "$(winopt "$wold" @sidetabs_note)" ] \
    || fail "a window under the old name was given a note: '$(winopt "$wold" @sidetabs_note)'"
hasrow main dm-qh "$dm_id" || fail "the note's row under the new name is gone: $(cat "$STORE")"
[ -z "$(storerow main dealmemo-3)" ] || fail "a row reappeared under the old name"
[ "$(idrows "$dm_id")" = "1" ] || fail "expected exactly 1 row for the note, got $(idrows "$dm_id")"
[ "$(cat "$NDIR/$dm_id")" = "deal memo v2" ] || fail "the note text did not survive the restart"
[ "$(cksum < "$STORE")" = "$store_before" ] || fail "restore WROTE the store"
[ "$(notesum)" = "$notes_before" ] || fail "restore touched a note file"
pass "E2E: back under the OLD name nothing attaches, and nothing at all is moved or deleted"
pass "E: restore (both delivery paths) never writes the store or a note file"

# The documented way out of that state: give the window the name the note is
# filed under and run the restore by hand.
tmux -L "$SOCKET" rename-window -t "$wold" dm-qh
run "$PLUGIN_DIR/scripts/note.sh restore"
sleep 0.5
[ "$(winopt "$wold" @sidetabs_note)" = "$dm_id" ] \
    || fail "renaming to the filed name + a manual restore did not re-attach the note"
[ "$(cksum < "$STORE")" = "$store_before" ] || fail "the manual recovery rewrote the store"
pass "E2E: renaming the window to the filed name and re-running restore re-attaches it"

# ===========================================================================
# PHASE 3 — generation 3: back under the NEW name, via the boot fallback
# ===========================================================================
# No plugin load yet: the boot-mode checks are pure state work, and the hook
# wiring is asserted at the very end.
boot dm-qh
wnew="$(winid main dm-qh)"
[ -n "$wnew" ] || fail "setup: generation 3 window missing"
tmux -L "$SOCKET" new-window -t main -n bootwin
wbt="$(winid main bootwin)"
[ -n "$wbt" ] || fail "setup: bootwin missing"
store_before="$(cksum < "$STORE")"
notes_before="$(notesum)"

# --- D1. Outside the boot window: stands down WITHOUT claiming ---------------
# The guard against handing a window created hours later the note of a long-gone
# window with the same name.
tmux -L "$SOCKET" run-shell "SIDETABS_NOTE_BOOT_MAX_AGE_S=0 '$PLUGIN_DIR/scripts/note.sh' restore boot"
sleep 0.4
[ -z "$(winopt "$wnew" @sidetabs_note)" ] || fail "boot mode seeded on an old server"
[ "$(gopt @sidetabs_note_restored)" != "1" ] \
    || fail "boot mode claimed the generation despite standing down on age"
pass "D: boot mode stands down (without claiming) outside the boot window"

# --- D2. A resurrect restore in flight owns the generation -------------------
tmux -L "$SOCKET" set -g @sidetabs_restoring 1
run "$PLUGIN_DIR/scripts/note.sh restore boot"
sleep 0.4
[ -z "$(winopt "$wnew" @sidetabs_note)" ] || fail "boot mode seeded while a restore was in flight"
[ "$(gopt @sidetabs_note_restored)" != "1" ] || fail "boot mode claimed the generation mid-restore"
tmux -L "$SOCKET" set -g @sidetabs_restoring 0
pass "D: boot mode stands down while a restore is in flight"

# --- D3. Young server, nothing claimed: this is the fallback doing its job ---
run "$PLUGIN_DIR/scripts/note.sh restore boot"
sleep 0.5
[ "$(winopt "$wnew" @sidetabs_note)" = "$dm_id" ] \
    || fail "boot mode did not re-attach the note: '$(winopt "$wnew" @sidetabs_note)'"
[ "$(gopt @sidetabs_note_restored)" = "1" ] || fail "boot mode did not claim the generation"
pass "D: boot mode seeds a young server and claims the generation"

# --- D4. Once claimed, the fallback stands down ------------------------------
printf 'boot window note\n' > "$NDIR/n1-bootwin01"
printf 'main\tbootwin\tn1-bootwin01\n' >> "$STORE"
run "$PLUGIN_DIR/scripts/note.sh restore boot"
sleep 0.4
[ -z "$(winopt "$wbt" @sidetabs_note)" ] || fail "boot mode seeded despite a claimed generation"
pass "D: boot mode stands down once the generation is claimed"

# --- D5. The resurrect path never stands down for the fallback ---------------
# Losing that race (a client attaching before continuum restores) would leave
# every note unattached, and re-seeding an already-seeded window is a no-op.
run "$PLUGIN_DIR/scripts/note.sh restore"
sleep 0.5
[ "$(winopt "$wbt" @sidetabs_note)" = "n1-bootwin01" ] \
    || fail "default (resurrect) mode stood down for a claimed generation"
[ "$(winopt "$wnew" @sidetabs_note)" = "$dm_id" ] || fail "a second restore disturbed a seeded window"
pass "D: the resurrect path still restores after the fallback claimed the generation"

# --- E. Every restore above was read-only ------------------------------------
# The only writes to the store in this generation are this test's own two
# appended fixtures (the bootwin row and its file), so strip them and compare.
grep -vxF "main${TAB}bootwin${TAB}n1-bootwin01" "$STORE" > "$WORK/store_minus_fixture" || true
[ "$(cksum < "$WORK/store_minus_fixture")" = "$store_before" ] \
    || fail "a restore rewrote the store: $(diff "$WORK/store_minus_fixture" "$STORE" | head -5)"
[ "$(notesum | grep -v 'n1-bootwin01' || true)" = "$notes_before" ] \
    || fail "a restore touched a note file"
pass "E: five restores later the store and every note file are unchanged"

# ...and the note that came back is the real thing, not just an id on a window:
# the editor opens with the text written two server generations ago. (Kept after
# the read-only check above on purpose — closing the editor is a SAVE.)
rm -f "$CAP"
run "EDITOR=$ED_CAPTURE $PLUGIN_DIR/scripts/note.sh edit-popup $wnew"
sleep 0.4
[ "$(cat "$CAP" 2>/dev/null)" = "deal memo v2" ] \
    || fail "the re-attached note did not open with its text: [$(cat "$CAP" 2>/dev/null)]"
[ "$(idrows "$dm_id")" = "1" ] || fail "re-saving the restored note left $(idrows "$dm_id") rows"
pass "E2E: back under the NEW name the note is re-attached, text and all"

# --- D6. Wiring --------------------------------------------------------------
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 1
tmux -L "$SOCKET" show-hooks -g 2>/dev/null \
    | grep -q 'client-attached\[5\].*note.sh restore boot' \
    || fail "client-attached[5] does not run note.sh restore boot"
tmux -L "$SOCKET" show-hooks -g 2>/dev/null \
    | grep -q 'session-renamed\[2\].*note.sh sync' \
    || fail "session-renamed[2] does not run note.sh sync"
grep -q 'note.sh" restore' "$PLUGIN_DIR/scripts/resurrect_post.sh" \
    || fail "resurrect_post.sh no longer calls note.sh restore"
pass "D: the boot fallback is wired to client-attached[5]; the resurrect hook still restores"
# (window-renamed is one of the hook names `show-hooks -g` does not enumerate on
# tmux 3.6b even when set — it is asserted functionally, by section A1.)

# --- D7. ...and the fallback really fires, on a REAL client attach -----------
# Everything above called `restore boot` by hand. This is the path the bug
# report is about: a fresh server generation, no resurrect hook, and a client
# attaching — nothing else. It needs a pty for the client, which BSD script(1)
# provides; where that form of script is missing the section is skipped rather
# than failed, since the wiring is already asserted above.
if script -q /dev/null true > /dev/null 2>&1; then
    boot dm-qh
    tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
    sleep 1
    wreal="$(winid main dm-qh)"
    [ -n "$wreal" ] || fail "setup: generation 4 window missing"
    [ -z "$(winopt "$wreal" @sidetabs_note)" ] || fail "setup: the note was attached before any client"
    # The client's stdin is held open by the sleep: an immediate EOF would reach
    # the pane's shell as ^D and end the session under the assertion.
    ( sleep 6 | script -q /dev/null tmux -L "$SOCKET" attach-session -t main > /dev/null 2>&1 & )
    sleep 3
    [ "$(winopt "$wreal" @sidetabs_note)" = "$dm_id" ] \
        || fail "a real client attach did not re-attach the note: '$(winopt "$wreal" @sidetabs_note)'"
    [ "$(gopt @sidetabs_note_restored)" = "1" ] || fail "the attach-driven restore did not claim the generation"
    [ "$(idrows "$dm_id")" = "1" ] || fail "the attach-driven restore changed the note's rows"
    pass "D: a real client attach on a fresh server re-attaches the note through the hook"
else
    echo "SKIP: D: real client attach (no BSD script(1) to give the client a pty)"
fi

# ===========================================================================
# PHASE 4 — names and ids are compared EXACTLY, as strings
# ===========================================================================
# Every case here is a way for a restore to hand a window the WRONG note, or
# none, from a store that is perfectly well-formed (or merely hand-edited):
#   G1  awk compares two numeric-looking strings as NUMBERS, so a lookup for
#       session `01` used to match the row filed under session `1` — and a
#       clear in that window then deleted the other session's note text
#   G2  `awk -v` expands backslash escapes, so a name holding a literal
#       backslash-t never matched its own row
#   G3  a real TAB inside a window name shifted the fields of the live listing
#   G4  a first row whose file is gone shadowed a valid later row under its key
#   G5  a CRLF line ending (a store saved by an editor) left a \r on the id
# No plugin load: this is pure state work, driven through note.sh directly.
boot hardening
US=$'\x1f'
CR="$(printf '\r')"
ESCNAME='esc\tname'
TABNAME="tab${TAB}name"
tmux -L "$SOCKET" new-session -d -s 1 -n foo
tmux -L "$SOCKET" new-session -d -s 01 -n foo
for w in "$ESCNAME" "$TABNAME" shadow crlfwin crheld; do
    tmux -L "$SOCKET" new-window -t main -n "$w"
done
# By session AND window name, both compared as strings, and split on a byte no
# name can hold — `winid` above would trip over every one of these names itself.
winid_x() {
    tmux -L "$SOCKET" list-windows -a -F "#{window_id}${US}#{session_name}${US}#{window_name}" 2>/dev/null \
        | s="$1" n="$2" awk -F"$US" \
            '($2 "") == ENVIRON["s"] && ($3 "") == ENVIRON["n"] && !seen { print $1; seen = 1 }'
}
w1="$(winid_x 1 foo)"; w01="$(winid_x 01 foo)"
wesc="$(winid_x main "$ESCNAME")"; wtab="$(winid_x main "$TABNAME")"
wsh="$(winid_x main shadow)"; wcr="$(winid_x main crlfwin)"; wch="$(winid_x main crheld)"
[ -n "$w1" ] && [ -n "$w01" ] && [ "$w1" != "$w01" ] || fail "setup: need foo in session 1 AND in session 01"
[ -n "$wesc" ] && [ -n "$wtab" ] || fail "setup: backslash-named or tab-named window missing"
[ -n "$wsh" ] && [ -n "$wcr" ] && [ -n "$wch" ] || fail "setup: phase 4 windows missing"

for f in numone001 numzero01 escname01 tabname01 goodfile1 crlfgood1 crlfonly1; do
    printf 'text of %s\n' "$f" > "$NDIR/n1-$f"
done
{
    printf '1\tfoo\tn1-numone001\n'
    printf '01\tfoo\tn1-numzero01\n'
    printf 'main\t%s\tn1-escname01\n' "$ESCNAME"
    # Filed the way the writer files it: a tab in a name is squashed to a space.
    printf 'main\ttab name\tn1-tabname01\n'
    # n1-deadfile1 has no file behind it; n1-goodfile1 does.
    printf 'main\tshadow\tn1-deadfile1\n'
    printf 'main\tshadow\tn1-goodfile1\n'
    printf 'main\tcrlfwin\tn1-crlfgood1\r\n'
    # Referenced by nothing but a CRLF row: no window carries it.
    printf 'main\tgonecr\tn1-crlfonly1\r\n'
} >> "$STORE"

run "$PLUGIN_DIR/scripts/note.sh restore"
sleep 0.5

[ "$(winopt "$w1" @sidetabs_note)" = "n1-numone001" ] \
    || fail "session 1 did not get its own note: '$(winopt "$w1" @sidetabs_note)'"
[ "$(winopt "$w01" @sidetabs_note)" = "n1-numzero01" ] \
    || fail "session 01 was handed another session's note (numeric compare?): '$(winopt "$w01" @sidetabs_note)'"
pass "G: sessions named 1 and 01 each get their OWN note back"

[ "$(winopt "$wesc" @sidetabs_note)" = "n1-escname01" ] \
    || fail "a name holding a literal backslash-t did not match its row: '$(winopt "$wesc" @sidetabs_note)'"
pass "G: a window name containing a backslash still matches its row"

[ "$(winopt "$wtab" @sidetabs_note)" = "n1-tabname01" ] \
    || fail "a name holding a real TAB did not match its row: '$(winopt "$wtab" @sidetabs_note)'"
pass "G: a window name containing a tab still matches its row"

[ "$(winopt "$wsh" @sidetabs_note)" = "n1-goodfile1" ] \
    || fail "a dangling first row shadowed the valid row behind it: '$(winopt "$wsh" @sidetabs_note)'"
hasrow main shadow n1-deadfile1 || fail "restore pruned the dangling row (it must never write the store)"
pass "G: a dangling first row no longer shadows a valid row under the same name"

[ "$(winopt "$wcr" @sidetabs_note)" = "n1-crlfgood1" ] \
    || fail "a CRLF row was not applied as its id: '$(winopt "$wcr" @sidetabs_note | od -c | head -2)'"
pass "G: a CRLF row restores as the id it names, not as inline text ending in \\r"

# The WRITE side agrees: a sync must keep those keys apart and file the tab name
# the way it was filed before.
run "$PLUGIN_DIR/scripts/note.sh sync"
sleep 0.3
hasrow 1 foo n1-numone001 || fail "a sync lost session 1's row: $(cat "$STORE")"
hasrow 01 foo n1-numzero01 || fail "a sync lost session 01's row: $(cat "$STORE")"
[ "$(idrows n1-numone001)" = "1" ] && [ "$(idrows n1-numzero01)" = "1" ] \
    || fail "a sync conflated sessions 1 and 01: $(cat "$STORE")"
hasrow main "$ESCNAME" n1-escname01 || fail "a sync rewrote the backslash name: $(cat "$STORE")"
hasrow main 'tab name' n1-tabname01 || fail "a sync re-filed the tab name differently: $(cat "$STORE")"
[ "$(idrows n1-tabname01)" = "1" ] || fail "a sync duplicated the tab-named window's row"
pass "G: a sync keeps numeric-looking, backslash and tab names filed exactly as they were"

# "One row per note" is really one row per window CARRYING it: a window linked
# into a second session is live under two keys, and is filed under both.
tmux -L "$SOCKET" link-window -s "$wsh" -t 01:
run "$PLUGIN_DIR/scripts/note.sh sync"
sleep 0.3
hasrow main shadow n1-goodfile1 || fail "linking a window lost its original row: $(cat "$STORE")"
hasrow 01 shadow n1-goodfile1 || fail "a linked window was not filed under its second session: $(cat "$STORE")"
[ "$(idrows n1-goodfile1)" = "2" ] \
    || fail "expected one row per session for a linked window, got $(idrows n1-goodfile1)"
pass "G: a window linked into two sessions is filed once under each"

# --- G5. CRLF in the merge ---------------------------------------------------
# crlf_row <id>: give the row holding <id> a CRLF ending, as an editor would.
crlf_row() {
    awk -F"$TAB" -v id="$1" -v cr="$CR" \
        '{ if ($3 == id) printf "%s%s\n", $0, cr; else print }' "$STORE" > "$WORK/store.crlf"
    mv "$WORK/store.crlf" "$STORE"
    grep -q "$1$CR\$" "$STORE" || fail "setup: could not give $1 a CRLF row"
}
# How many store lines mention an id at all, whatever follows it.
mentions() { grep -c "$1" "$STORE" || true; }

run "$PLUGIN_DIR/scripts/note.sh set $wch held behind a carriage return"
sleep 0.4
ch_id="$(noteid "$wch" "crheld")"
crlf_row "$ch_id"
run "$PLUGIN_DIR/scripts/note.sh sync"
sleep 0.3
[ "$(mentions "$ch_id")" = "1" ] \
    || fail "a CRLF row was not recognised as the live note's own: $(mentions "$ch_id") rows for one note"
hasrow main crheld "$ch_id" || fail "the live note's row is not the clean one: $(grep "$ch_id" "$STORE" | od -c | head -3)"
pass "G: a CRLF row for a live note is re-filed, not duplicated"

crlf_row "$ch_id"
run "$PLUGIN_DIR/scripts/note.sh clear $wch"
sleep 0.4
[ ! -f "$NDIR/$ch_id" ] || fail "setup: the clear did not delete the note file"
[ "$(mentions "$ch_id")" = "0" ] \
    || fail "a cleared note's CRLF row survived, pointing at its deleted file: $(grep "$ch_id" "$STORE" | od -c | head -3)"
run "$PLUGIN_DIR/scripts/note.sh restore"
sleep 0.4
[ -z "$(winopt "$wch" @sidetabs_note)" ] \
    || fail "a restore re-attached a cleared note: '$(winopt "$wch" @sidetabs_note)'"
pass "G: clearing a note removes its CRLF row too, and nothing brings it back"

# gc reads ids out of the same rows: a file only a CRLF row references is
# REFERENCED, and sweeping it would delete text over a line ending.
grep -q "n1-crlfonly1$CR\$" "$STORE" || fail "setup: the gc fixture's row lost its CRLF ending"
run "$PLUGIN_DIR/scripts/note.sh gc"
sleep 0.4
[ -f "$NDIR/n1-crlfonly1" ] || fail "gc swept a note file a CRLF row still references"
pass "G: gc keeps a note file that only a CRLF row references"

echo "ALL NOTE RENAME TESTS PASSED"
