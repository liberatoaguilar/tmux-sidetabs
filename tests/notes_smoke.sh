#!/usr/bin/env bash
# Smoke test for per-window NOTES: temporary tmux server, sources the plugin,
# drives scripts/note.sh via run-shell, asserts state via show-option -w, the
# durable TSV store via a hermetic @sidetabs-note-store path, and rendering via
# capture-pane -e (presence-only sticky-note glyph, expanded mode only).
#
# -f /dev/null is required: without it a new server on this socket still
# auto-loads the user's ~/.tmux.conf (which run-shells this plugin AND others),
# polluting hooks/keys and defeating test isolation.
set -euo pipefail

SOCKET="sidetab_note_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE="${TMPDIR:-/tmp}/sidetabs_notes_$$.tsv"
WORK="${TMPDIR:-/tmp}/sidetabs_notework_$$"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$STORE" "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK"

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
winopt() { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }
storerows() { if [ -f "$STORE" ]; then awk 'NF{n++} END{print n+0}' "$STORE"; else echo 0; fi; }
run() { tmux -L "$SOCKET" run-shell "$*"; }

TAB="$(printf '\t')"
GLYPH="$(printf '\xef\x89\x89')"   # U+F249 nerd-font sticky-note

# --- 1. Boot: 2 named windows, summary off (deterministic layout), hermetic store
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n alpha -x 200 -y 50
tmux -L "$SOCKET" set-option -g @sidetabs-summary off
tmux -L "$SOCKET" set-option -g @sidetabs-note-store "$STORE"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.4
tmux -L "$SOCKET" new-window -n beta
sleep 0.4
w0="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="alpha"{print $2}')"
w1="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="beta"{print $2}')"
sb0="$(tmux -L "$SOCKET" list-panes -t "$w0" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
[ -n "$w0" ] && [ -n "$w1" ] && [ -n "$sb0" ] || fail "setup: expected 2 windows with sidebars"

# --- 2. Binding registered on load ------------------------------------------
tmux -L "$SOCKET" list-keys -T root | grep -q 'note.sh' || fail "note key not bound on load"
pass "note key bound on load"

# --- 3. set + sanitization ---------------------------------------------------
# Feed a real TAB, a control char (0x01) and runs of spaces + surrounding
# whitespace. Control chars must never reach the store; the row must stay a
# clean 3-field TSV record holding a note ID, with the TEXT in its own file.
# Tabs and leading indentation now SURVIVE — nothing downstream is
# whitespace-sensitive once the text is out of the option and the TSV.
NDIR="$STORE.d"
SETW="$WORK/set_dirty.sh"
cat > "$SETW" <<EOF
#!/usr/bin/env bash
exec "$PLUGIN_DIR/scripts/note.sh" set "$w0" \$'  first\tsecond\x01third    fourth  '
EOF
chmod +x "$SETW"
run "$SETW"
sleep 0.3
got="$(winopt "$w0" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "option is not a note id: '$got'" ;; esac
[ -f "$NDIR/$got" ] || fail "note file $NDIR/$got missing"
[ "$(cat "$NDIR/$got")" = "$(printf '  first\tsecondthird    fourth')" ] \
  || fail "note file content wrong: [$(cat "$NDIR/$got")]"
[ -f "$STORE" ] || fail "no store file written"
[ "$(storerows)" = "1" ] || fail "expected 1 store row, got $(storerows)"
nf="$(awk -F'\t' '{print NF}' "$STORE" | sort -u)"
[ "$nf" = "3" ] || fail "expected 3 TSV fields on every store row, got: $nf"
awk -F'\t' -v id="$got" '$1=="main" && $2=="alpha" && $3==id' "$STORE" | grep -q . \
  || fail "store row does not reference the note id: $(cat "$STORE")"
pass "set drops control chars, keeps tabs/indentation, stores an id + a text file"

# An editor that copies the buffer out, needed from section 4 onward.
CAP_EARLY="$WORK/captured_early.txt"
ED_CAPTURE_EARLY="$WORK/ed_capture_early.sh"
cat > "$ED_CAPTURE_EARLY" <<EOF
#!/usr/bin/env bash
cp "\$1" "$CAP_EARLY"
EOF
chmod +x "$ED_CAPTURE_EARLY"

# --- 4. No length cap: a 200KB+ note round-trips intact ----------------------
# The old 200-char cap existed because the text lived in a tmux option, and
# tmux refuses any command over ~16KB ("command too long"). With the text in
# its own file there is no ceiling, and this note is >13x that tmux limit.
BIG="$WORK/big.txt"
awk 'BEGIN { for (i = 1; i <= 5000; i++) printf "line %05d padded out to fifty characters ok\n", i }' > "$BIG"
bigbytes="$(wc -c < "$BIG" | tr -d ' ')"
[ "$bigbytes" -gt 200000 ] || fail "setup: big note is only $bigbytes bytes"
ED_BIG="$WORK/ed_big.sh"
cat > "$ED_BIG" <<EOF
#!/usr/bin/env bash
cp "$BIG" "\$1"
EOF
chmod +x "$ED_BIG"
run "EDITOR=$ED_BIG $PLUGIN_DIR/scripts/note.sh edit-popup $w1"
sleep 1
got="$(winopt "$w1" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "big note: option is not an id: '$got'" ;; esac
[ -f "$NDIR/$got" ] || fail "big note file missing"
cmp -s "$BIG" "$NDIR/$got" || fail "$bigbytes-byte note did not round-trip byte-for-byte"
[ "$(storerows)" = "2" ] || fail "expected 2 store rows, got $(storerows)"
# ...and the editor gets all of it back on the next open.
rm -f "$CAP_EARLY"
run "EDITOR=$ED_CAPTURE_EARLY $PLUGIN_DIR/scripts/note.sh edit-popup $w1"
sleep 1
cmp -s "$BIG" "$CAP_EARLY" || fail "editor was not re-seeded with the full $bigbytes-byte note"
pass "a ${bigbytes}-byte note round-trips with no cap"

# --- 5. Icon renders in expanded mode; text is never rendered ----------------
tmux -L "$SOCKET" select-window -t "$w0"
sleep 1
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
n="$(echo "$cap" | grep -c -- "$GLYPH" || true)"
[ "$n" = "2" ] || fail "expected the note glyph on 2 rows, got $n"
if echo "$cap" | grep -q 'secondthird'; then fail "note TEXT rendered in the sidebar"; fi
pass "note glyph renders on both noted rows; text never rendered"

# --- 6. Collapsed mode has no room for the glyph (documented) ---------------
run "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 1
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
if echo "$cap" | grep -q -- "$GLYPH"; then fail "note glyph rendered in collapsed mode"; fi
run "$PLUGIN_DIR/scripts/toggle_collapse.sh"
sleep 1
pass "collapsed mode omits the note glyph"

# --- 7. clear: option unset, row gone, other rows survive, glyph disappears --
run "$PLUGIN_DIR/scripts/note.sh clear $w1"
sleep 1
[ -z "$(winopt "$w1" @sidetabs_note)" ] || fail "clear left the option set"
[ "$(storerows)" = "1" ] || fail "expected 1 store row after clear, got $(storerows)"
if awk -F'\t' '$2=="beta"' "$STORE" | grep -q .; then fail "beta store row survived clear"; fi
awk -F'\t' '$2=="alpha"' "$STORE" | grep -q . || fail "alpha store row lost on beta clear"
cap="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb0")"
n="$(echo "$cap" | grep -c -- "$GLYPH" || true)"
[ "$n" = "1" ] || fail "expected the glyph on 1 row after clear, got $n"
pass "clear unsets the option, drops only its store row, glyph disappears"

# --- 8. Setting an all-whitespace/control-only note behaves as clear ---------
run "$PLUGIN_DIR/scripts/note.sh set $w0 '   '"
sleep 0.3
[ -z "$(winopt "$w0" @sidetabs_note)" ] || fail "empty-after-sanitize set did not clear"
[ "$(storerows)" = "0" ] || fail "empty-after-sanitize set left store rows: $(storerows)"
pass "empty-after-sanitize set behaves as clear"

# --- 9. edit-popup honors $EDITOR -------------------------------------------
ED_WRITE="$WORK/ed_write.sh"
cat > "$ED_WRITE" <<'EOF'
#!/usr/bin/env bash
printf 'note from the editor\n' > "$1"
EOF
ED_EMPTY="$WORK/ed_empty.sh"
cat > "$ED_EMPTY" <<'EOF'
#!/usr/bin/env bash
: > "$1"
EOF
chmod +x "$ED_WRITE" "$ED_EMPTY"

run "EDITOR=$ED_WRITE $PLUGIN_DIR/scripts/note.sh edit-popup $w0"
sleep 0.3
got="$(winopt "$w0" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "edit-popup did not store an id: '$got'" ;; esac
[ "$(cat "$NDIR/$got")" = "note from the editor" ] \
  || fail "edit-popup EDITOR write: [$(cat "$NDIR/$got")]"
[ "$(storerows)" = "1" ] || fail "edit-popup write: expected 1 store row, got $(storerows)"
edit_id="$got"

# The editor must be pre-seeded with the current note (round-trip: an editor
# that leaves the file alone keeps the note).
ED_NOOP="$WORK/ed_noop.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ED_NOOP"; chmod +x "$ED_NOOP"
run "EDITOR=$ED_NOOP $PLUGIN_DIR/scripts/note.sh edit-popup $w0"
sleep 0.3
[ "$(winopt "$w0" @sidetabs_note)" = "$edit_id" ] || fail "no-op editor lost the note"
[ "$(cat "$NDIR/$edit_id")" = "note from the editor" ] || fail "no-op editor changed the text"

# Clearing must delete the note FILE too, not just the option and the row.
run "EDITOR=$ED_EMPTY $PLUGIN_DIR/scripts/note.sh edit-popup $w0"
sleep 0.3
[ -z "$(winopt "$w0" @sidetabs_note)" ] || fail "empty editor buffer did not clear the note"
[ "$(storerows)" = "0" ] || fail "empty editor buffer left store rows: $(storerows)"
[ ! -f "$NDIR/$edit_id" ] || fail "clear left the note file behind: $NDIR/$edit_id"
pass "edit-popup honors \$EDITOR (write sets, no-op keeps, empty clears + deletes the file)"

# --- 10. restore: seed by (session, window name), first wins, never clobber --
tmux -L "$SOCKET" new-window -n resto; sleep 0.3
tmux -L "$SOCKET" new-window -n dupe;  sleep 0.3
tmux -L "$SOCKET" new-window -n dupe;  sleep 0.3
wr="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="resto"{print $2}')"
wd1="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="dupe"{print $2; exit}')"
wd2="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="dupe"{c++; if(c==2){print $2; exit}}')"
[ -n "$wr" ] && [ -n "$wd1" ] && [ -n "$wd2" ] || fail "setup: restore windows missing"

# A live note that the store disagrees with must survive untouched.
run "$PLUGIN_DIR/scripts/note.sh set $w0 live note wins"
sleep 0.3
live_id="$(winopt "$w0" @sidetabs_note)"
case "$live_id" in n1-[A-Za-z0-9]*) : ;; *) fail "setup: live note not set: '$live_id'" ;; esac
[ "$(cat "$NDIR/$live_id")" = "live note wins" ] || fail "setup: live note text wrong"

{
  printf 'main%salpha%sSHOULD NOT WIN\n'  "$TAB" "$TAB"
  printf 'main%sresto%srestored note\n'   "$TAB" "$TAB"
  printf 'main%sdupe%sdupe note\n'        "$TAB" "$TAB"
  printf 'main%sghost%signored\n'         "$TAB" "$TAB"
  printf 'other%sresto%swrong session\n'  "$TAB" "$TAB"
} > "$STORE"

# The seeded rows below are plain text, not ids: restore copies them into the
# option verbatim through the legacy path, which is exactly what a store written
# by an older release looks like.
run "$PLUGIN_DIR/scripts/note.sh restore"
sleep 0.5
[ "$(winopt "$w0" @sidetabs_note)" = "$live_id" ] || fail "restore clobbered a live note: '$(winopt "$w0" @sidetabs_note)'"
[ "$(winopt "$wr" @sidetabs_note)" = "restored note" ] || fail "restore did not seed 'resto': '$(winopt "$wr" @sidetabs_note)'"
[ "$(winopt "$wd1" @sidetabs_note)" = "dupe note" ] || fail "restore did not seed the first 'dupe'"
[ -z "$(winopt "$wd2" @sidetabs_note)" ] || fail "restore seeded the second 'dupe' too: '$(winopt "$wd2" @sidetabs_note)'"
[ -z "$(winopt "$w1" @sidetabs_note)" ] || fail "restore seeded an unrelated window"
pass "restore seeds by session+name, first window wins, live notes never clobbered"

# --- 11. A custom multi-column note icon must not wrap the row --------------
# @sidetabs-note-icon is documented as "any string", so the row's width math has
# to reserve the icon's REAL width. When it doesn't, the pill's cap + powerline
# arrow spill onto the next screen line (regression: hardcoded 2 columns).
# render.sh reads the icon once at startup, so the icon is set BEFORE creating
# the window whose sidebar we capture.
ARROW="$(printf '\xee\x82\xb0')"   # U+E0B0 powerline right cap
tmux -L "$SOCKET" set-option -g @sidetabs-note-icon 'NOTE'
tmux -L "$SOCKET" new-window -n wide; sleep 0.6
ww="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="wide"{print $2}')"
sbw="$(tmux -L "$SOCKET" list-panes -t "$ww" -F '#{pane_id} #{@is_sidetab}' | awk '$2==1{print $1}')"
[ -n "$ww" ] && [ -n "$sbw" ] || fail "setup: wide-icon window/sidebar missing"
run "$PLUGIN_DIR/scripts/note.sh set $ww noted"
tmux -L "$SOCKET" select-window -t "$ww"
sleep 1
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sbw")"
nl="$(printf '%s\n' "$cap" | grep -c -- 'NOTE' || true)"
[ "$nl" -ge 1 ] || fail "custom note icon never rendered"
# Every row carrying the icon must still end with its own cap arrow...
while IFS= read -r noteline; do
  case "$noteline" in
    *"$ARROW") : ;;
    *) fail "noted row does not end with the cap arrow (row wrapped): [$noteline]" ;;
  esac
done <<< "$(printf '%s\n' "$cap" | grep -- 'NOTE')"
# ...and nothing may be left over on a line of its own.
if printf '%s\n' "$cap" | grep -q "^ *${ARROW} *$"; then
  fail "an orphaned cap/arrow fragment landed on its own line (row overflowed)"
fi
tmux -L "$SOCKET" set-option -gu @sidetabs-note-icon
pass "a multi-column custom note icon keeps the row within its width"

# --- 12. A note whose text is exactly "0" still shows the glyph -------------
# The presence flag must test the option for a non-empty VALUE, not tmux's
# truthiness (which reads the string "0" as false). An id can never itself be
# "0", but the hazard is worth keeping under test: it is one option-format edit
# away from returning.
tmux -L "$SOCKET" select-window -t "$w0"
run "$PLUGIN_DIR/scripts/note.sh set $w0 0"
sleep 1
got="$(winopt "$w0" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "note '0' not stored as an id: '$got'" ;; esac
[ "$(cat "$NDIR/$got")" = "0" ] || fail "note text '0' not stored"
awk -F'\t' -v id="$got" '$2=="alpha" && $3==id' "$STORE" | grep -q . || fail "store row for note '0' missing"
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
alphaline="$(printf '%s\n' "$cap" | grep -- 'alpha' | head -1)"
case "$alphaline" in
  *"$GLYPH"*) : ;;
  *) fail "note '0' rendered no glyph on its row: [$alphaline]" ;;
esac
pass "a note of exactly \"0\" still renders the presence glyph"

# --- 13. Narrow sidebar: the icon/note widths must be reclaimed too ---------
# When the row doesn't fit, only the name used to shrink — the command icon and
# the note glyph kept their columns, so a narrow sidebar pushed the cap arrow
# past the pane edge and tmux clipped it off every noted row.
tmux -L "$SOCKET" resize-pane -t "$sb0" -x 8
sleep 1.5
cap="$(tmux -L "$SOCKET" capture-pane -p -t "$sb0")"
n="$(printf '%s\n' "$cap" | grep -c -- "$GLYPH" || true)"
[ "$n" -ge 1 ] || fail "no noted row rendered at width 8"
while IFS= read -r gline; do
  case "$gline" in
    *"$ARROW") : ;;
    *) fail "noted row lost its cap arrow at width 8: [$gline]" ;;
  esac
done <<< "$(printf '%s\n' "$cap" | grep -- "$GLYPH")"
tmux -L "$SOCKET" resize-pane -t "$sb0" -x 20
sleep 1
pass "narrow sidebar reclaims icon/note width; rows keep their cap arrow"

# --- 14. Concurrent sets for different windows keep every store row ---------
# store_write is a read-modify-write of the whole TSV; unlocked, the second
# writer's mv drops the first writer's freshly added row and the note is gone
# from the durable record (restore can never bring it back).
K=10
: > "$STORE"
i=1
while [ "$i" -le "$K" ]; do tmux -L "$SOCKET" new-window -d -n "conc$i"; i=$((i + 1)); done
sleep 1
CW=""
i=1
while [ "$i" -le "$K" ]; do
  cw="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk -v n="conc$i" '$1==n{print $2; exit}')"
  [ -n "$cw" ] || fail "setup: window conc$i missing"
  CW="$CW $cw"
  i=$((i + 1))
done
i=1
for cw in $CW; do
  ( tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/note.sh set $cw concurrent note $i" ) &
  i=$((i + 1))
done
wait
sleep 1
[ "$(storerows)" = "$K" ] || fail "concurrent sets lost store rows: expected $K, got $(storerows)"
i=1
while [ "$i" -le "$K" ]; do
  awk -F'\t' -v n="conc$i" '$1=="main" && $2==n' "$STORE" | grep -q . \
    || fail "store row for conc$i lost to a concurrent write"
  i=$((i + 1))
done
pass "concurrent note writes for different windows keep every store row"

# --- 15. Multi-line notes round-trip through the editor ---------------------
# The store row must stay a 3-field record, which it does by holding an id; the
# newlines live in the note file, unescaped, and reopening the popup has to give
# the editor back the original multi-line text.
CAP="$CAP_EARLY"
ED_CAPTURE="$ED_CAPTURE_EARLY"
ED_MULTI="$WORK/ed_multi.sh"
cat > "$ED_MULTI" <<'EOF'
#!/usr/bin/env bash
printf 'line1\n\nline3\n' > "$1"
EOF
chmod +x "$ED_MULTI"

tmux -L "$SOCKET" new-window -n multi; sleep 0.4
wm="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="multi"{print $2}')"
[ -n "$wm" ] || fail "setup: multi window missing"

run "EDITOR=$ED_MULTI $PLUGIN_DIR/scripts/note.sh edit-popup $wm"
sleep 0.4
multi_id="$(winopt "$wm" @sidetabs_note)"
case "$multi_id" in n1-[A-Za-z0-9]*) : ;; *) fail "multi-line note: option is not an id: '$multi_id'" ;; esac
[ "$(cat "$NDIR/$multi_id")" = "$(printf 'line1\n\nline3')" ] \
  || fail "multi-line note file wrong: [$(cat "$NDIR/$multi_id")]"
nf="$(awk -F'\t' 'NF{print NF}' "$STORE" | sort -u)"
[ "$nf" = "3" ] || fail "store rows are not all 3 TSV fields after a multi-line note: $nf"
[ "$(awk -F'\t' '$2=="multi"{n++} END{print n+0}' "$STORE")" = "1" ] \
  || fail "expected exactly 1 store row for 'multi', got $(awk -F'\t' '$2=="multi"{n++} END{print n+0}' "$STORE")"

rm -f "$CAP"
run "EDITOR=$ED_CAPTURE $PLUGIN_DIR/scripts/note.sh edit-popup $wm"
sleep 0.4
[ -f "$CAP" ] || fail "capture editor never ran"
[ "$(cat "$CAP")" = "$(printf 'line1\n\nline3')" ] \
  || fail "editor not seeded with the multi-line note: [$(cat "$CAP")]"
[ "$(winopt "$wm" @sidetabs_note)" = "$multi_id" ] \
  || fail "re-saving the seeded buffer changed the note id: '$(winopt "$wm" @sidetabs_note)'"
pass "multi-line notes round-trip through the editor; store rows stay 3 fields"

# --- 16. A literal backslash-n stays literal --------------------------------
# The escaping this used to need is gone with the text in a file, so the 4 chars
# a \ n b must survive verbatim — and must never turn into a newline.
ED_BS="$WORK/ed_backslash.sh"
cat > "$ED_BS" <<'EOF'
#!/usr/bin/env bash
printf 'a\\nb\n' > "$1"
EOF
chmod +x "$ED_BS"
tmux -L "$SOCKET" new-window -n bslash; sleep 0.4
wb="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="bslash"{print $2}')"
[ -n "$wb" ] || fail "setup: bslash window missing"

run "EDITOR=$ED_BS $PLUGIN_DIR/scripts/note.sh edit-popup $wb"
sleep 0.4
got="$(winopt "$wb" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "backslash note: option is not an id: '$got'" ;; esac
[ "$(cat "$NDIR/$got")" = 'a\nb' ] || fail "literal backslash-n not stored verbatim: [$(cat "$NDIR/$got")]"
rm -f "$CAP"
run "EDITOR=$ED_CAPTURE $PLUGIN_DIR/scripts/note.sh edit-popup $wb"
sleep 0.4
back="$(cat "$CAP")"
[ "$back" = 'a\nb' ] || fail "literal 'a\\nb' did not round-trip: [$back]"
[ "${#back}" = "4" ] || fail "literal 'a\\nb' came back as ${#back} chars (a newline crept in)"
[ "$(winopt "$wb" @sidetabs_note)" = "$got" ] || fail "re-saving changed the note id"
pass "a literal backslash-n survives the round-trip verbatim"

# --- 17. restore re-seeds the id; the editor still sees the text ------------
tmux -L "$SOCKET" set-option -w -t "$wm" -qu @sidetabs_note
[ -z "$(winopt "$wm" @sidetabs_note)" ] || fail "setup: could not wipe the note option"
run "$PLUGIN_DIR/scripts/note.sh restore"
sleep 0.5
[ "$(winopt "$wm" @sidetabs_note)" = "$multi_id" ] \
  || fail "restore did not re-seed the note id: '$(winopt "$wm" @sidetabs_note)'"
rm -f "$CAP"
run "EDITOR=$ED_CAPTURE $PLUGIN_DIR/scripts/note.sh edit-popup $wm"
sleep 0.4
[ "$(cat "$CAP")" = "$(printf 'line1\n\nline3')" ] \
  || fail "editor not seeded correctly after restore: [$(cat "$CAP")]"
pass "restore re-seeds the note id; the editor still sees the multi-line text"

# --- 17b. restore skips a row whose note file is gone -----------------------
# Setting the option from a dangling row would light the row's glyph for a note
# with no text behind it.
tmux -L "$SOCKET" set-option -w -t "$wm" -qu @sidetabs_note
mv "$NDIR/$multi_id" "$WORK/parked_note"
run "$PLUGIN_DIR/scripts/note.sh restore"
sleep 0.5
[ -z "$(winopt "$wm" @sidetabs_note)" ] \
  || fail "restore seeded a dangling id: '$(winopt "$wm" @sidetabs_note)'"
mv "$WORK/parked_note" "$NDIR/$multi_id"
run "$PLUGIN_DIR/scripts/note.sh restore"
sleep 0.5
[ "$(winopt "$wm" @sidetabs_note)" = "$multi_id" ] || fail "restore did not recover once the file was back"
pass "restore skips a store row whose note file is missing"

# --- 18. Sanitizing: control chars die, indentation and structure survive ----
# Trailing whitespace and blank lines at the very edges still go. Tabs, leading
# indentation and interior blank runs are now KEPT — the old squeeze existed to
# stop a 200-char budget being padded out, and that budget is gone.
ED_DIRTY="$WORK/ed_dirty.sh"
cat > "$ED_DIRTY" <<'EOF'
#!/usr/bin/env bash
printf '%s' $'\n\n  first\tsecond\x01third   fourth  \n\n  keep  \n\n\n\ntail\n\n\n' > "$1"
EOF
chmod +x "$ED_DIRTY"
tmux -L "$SOCKET" new-window -n dirty; sleep 0.4
wdy="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="dirty"{print $2}')"
[ -n "$wdy" ] || fail "setup: dirty window missing"
run "EDITOR=$ED_DIRTY $PLUGIN_DIR/scripts/note.sh edit-popup $wdy"
sleep 0.4
got="$(winopt "$wdy" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "dirty note: option is not an id: '$got'" ;; esac
want="$(printf '  first\tsecondthird   fourth\n\n  keep\n\n\n\ntail')"
[ "$(cat "$NDIR/$got")" = "$want" ] || fail "sanitize: got [$(cat "$NDIR/$got")]"
rm -f "$CAP"
run "EDITOR=$ED_CAPTURE $PLUGIN_DIR/scripts/note.sh edit-popup $wdy"
sleep 0.4
[ "$(cat "$CAP")" = "$want" ] \
  || fail "sanitized multi-line buffer did not seed correctly: [$(cat "$CAP")]"
pass "sanitize drops control chars and trailing space, keeps indentation, tabs and blank runs"

# --- 19. Legacy inline notes still open, and convert on save ----------------
# Rows written before notes moved to files hold escape-encoded TEXT, not an id.
# They must still open in the editor with their newlines intact, and saving must
# migrate them to a file without the user doing anything.
tmux -L "$SOCKET" new-window -n legacy; sleep 0.4
wl="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="legacy"{print $2}')"
[ -n "$wl" ] || fail "setup: legacy window missing"
tmux -L "$SOCKET" set-option -w -t "$wl" @sidetabs_note 'old1\nold2\\nliteral'
printf 'main%slegacy%sold1\\nold2\\\\nliteral\n' "$TAB" "$TAB" >> "$STORE"

rm -f "$CAP"
run "EDITOR=$ED_CAPTURE $PLUGIN_DIR/scripts/note.sh edit-popup $wl"
sleep 0.5
[ -f "$CAP" ] || fail "legacy note: capture editor never ran"
[ "$(cat "$CAP")" = "$(printf 'old1\nold2\\nliteral')" ] \
  || fail "legacy note did not decode into the editor: [$(cat "$CAP")]"
# Re-saving the seeded buffer converts it to a file, text unchanged.
got="$(winopt "$wl" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "legacy note did not convert to an id: '$got'" ;; esac
[ "$(cat "$NDIR/$got")" = "$(printf 'old1\nold2\\nliteral')" ] \
  || fail "legacy conversion changed the text: [$(cat "$NDIR/$got")]"
awk -F'\t' -v id="$got" '$2=="legacy" && $3==id' "$STORE" | grep -q . \
  || fail "legacy store row was not rewritten to the note id"
pass "legacy inline notes open correctly and migrate to a file on save"

# --- 20. gc removes only unreferenced note files ----------------------------
# An orphan is a file that no store row AND no live window option points at.
# A file either one still references must survive.
tmux -L "$SOCKET" new-window -n gckeep; sleep 0.4
wg="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="gckeep"{print $2}')"
[ -n "$wg" ] || fail "setup: gckeep window missing"
run "$PLUGIN_DIR/scripts/note.sh set $wg keep me"
sleep 0.4
keep_id="$(winopt "$wg" @sidetabs_note)"
case "$keep_id" in n1-[A-Za-z0-9]*) : ;; *) fail "setup: gckeep has no note id" ;; esac
# A window renamed after its note was set is referenced ONLY by the live option
# (its store row still sits under the old name) — gc must keep it.
tmux -L "$SOCKET" rename-window -t "$wg" gcrenamed; sleep 0.3

orphan="$NDIR/n1-orphan01"
printf 'nobody points at me\n' > "$orphan"
# A file only the STORE references (its window is gone) must also survive.
storeonly="$NDIR/n1-storeonly"
printf 'the store still knows me\n' > "$storeonly"
printf 'main%sdeparted%sn1-storeonly\n' "$TAB" "$TAB" >> "$STORE"

run "$PLUGIN_DIR/scripts/note.sh gc"
sleep 0.5
[ ! -f "$orphan" ] || fail "gc did not remove the orphaned note file"
[ -f "$storeonly" ] || fail "gc removed a file the store still references"
[ -f "$NDIR/$keep_id" ] || fail "gc removed a file a live (renamed) window references"
pass "gc removes only note files nothing references"

# --- 21. Uninstall removes the binding --------------------------------------
run "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.3
if tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'note.sh'; then
  fail "note key survived uninstall"
fi
pass "note key removed on uninstall"

echo "ALL NOTES SMOKE TESTS PASSED"
