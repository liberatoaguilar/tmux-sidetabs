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
# whitespace. Control chars must not reach the option or the store, the row must
# stay a clean 3-field TSV record, and spaces must collapse/trim.
SETW="$WORK/set_dirty.sh"
cat > "$SETW" <<EOF
#!/usr/bin/env bash
exec "$PLUGIN_DIR/scripts/note.sh" set "$w0" \$'  first\tsecond\x01third    fourth  '
EOF
chmod +x "$SETW"
run "$SETW"
sleep 0.3
got="$(winopt "$w0" @sidetabs_note)"
[ "$got" = "first secondthird fourth" ] || fail "sanitized note: got '$got'"
[ -f "$STORE" ] || fail "no store file written"
[ "$(storerows)" = "1" ] || fail "expected 1 store row, got $(storerows)"
nf="$(awk -F'\t' '{print NF}' "$STORE" | sort -u)"
[ "$nf" = "3" ] || fail "expected 3 TSV fields on every store row, got: $nf"
awk -F'\t' '$1=="main" && $2=="alpha" && $3=="first secondthird fourth"' "$STORE" | grep -q . \
  || fail "store row missing/incorrect: $(cat "$STORE")"
pass "set sanitizes (tab/control chars/space runs) and writes a 3-field store row"

# --- 4. 200-char cap ---------------------------------------------------------
LONG="$(printf 'a%.0s' $(seq 250))"
run "$PLUGIN_DIR/scripts/note.sh set $w1 $LONG"
sleep 0.3
got="$(winopt "$w1" @sidetabs_note)"
[ "${#got}" = "200" ] || fail "note not capped at 200 chars: len=${#got}"
[ "$(storerows)" = "2" ] || fail "expected 2 store rows, got $(storerows)"
awk -F'\t' -v n=200 '$2=="beta" && length($3)==n' "$STORE" | grep -q . \
  || fail "store row for beta not capped at 200"
pass "note capped at 200 chars (option + store)"

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
[ "$got" = "note from the editor" ] || fail "edit-popup EDITOR write: got '$got'"
[ "$(storerows)" = "1" ] || fail "edit-popup write: expected 1 store row, got $(storerows)"

# The editor must be pre-seeded with the current note (round-trip: an editor
# that leaves the file alone keeps the note).
ED_NOOP="$WORK/ed_noop.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ED_NOOP"; chmod +x "$ED_NOOP"
run "EDITOR=$ED_NOOP $PLUGIN_DIR/scripts/note.sh edit-popup $w0"
sleep 0.3
[ "$(winopt "$w0" @sidetabs_note)" = "note from the editor" ] || fail "no-op editor lost the note"

run "EDITOR=$ED_EMPTY $PLUGIN_DIR/scripts/note.sh edit-popup $w0"
sleep 0.3
[ -z "$(winopt "$w0" @sidetabs_note)" ] || fail "empty editor buffer did not clear the note"
[ "$(storerows)" = "0" ] || fail "empty editor buffer left store rows: $(storerows)"
pass "edit-popup honors \$EDITOR (write sets, no-op keeps, empty clears)"

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
[ "$(winopt "$w0" @sidetabs_note)" = "live note wins" ] || fail "setup: live note not set"

{
  printf 'main%salpha%sSHOULD NOT WIN\n'  "$TAB" "$TAB"
  printf 'main%sresto%srestored note\n'   "$TAB" "$TAB"
  printf 'main%sdupe%sdupe note\n'        "$TAB" "$TAB"
  printf 'main%sghost%signored\n'         "$TAB" "$TAB"
  printf 'other%sresto%swrong session\n'  "$TAB" "$TAB"
} > "$STORE"

run "$PLUGIN_DIR/scripts/note.sh restore"
sleep 0.5
[ "$(winopt "$w0" @sidetabs_note)" = "live note wins" ] || fail "restore clobbered a live note: '$(winopt "$w0" @sidetabs_note)'"
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
# truthiness (which reads the string "0" as false).
tmux -L "$SOCKET" select-window -t "$w0"
run "$PLUGIN_DIR/scripts/note.sh set $w0 0"
sleep 1
[ "$(winopt "$w0" @sidetabs_note)" = "0" ] || fail "note '0' not stored: '$(winopt "$w0" @sidetabs_note)'"
awk -F'\t' '$2=="alpha" && $3=="0"' "$STORE" | grep -q . || fail "store row for note '0' missing"
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

# --- 15. Uninstall removes the binding --------------------------------------
run "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.3
if tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'note.sh'; then
  fail "note key survived uninstall"
fi
pass "note key removed on uninstall"

echo "ALL NOTES SMOKE TESTS PASSED"
